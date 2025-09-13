#!/bin/bash
# mdm_bypass.sh
# Improved / safer version of the MDM bypass utility
# NOTE: Running or modifying system account/db files can break your system.
# Use at your own risk. This script only improves robustness of original logic.

# Exit on error
set -o pipefail

# Colors
RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
PUR='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Exiting.${NC}"
    exit 1
fi

echo -e "${CYAN}Bypass MDM By Assaf Dori (assafdori.com) - improved wrapper${NC}"
echo

# Detect likely data/system roots (Recovery differences)
# Prefer mounted Data volume if present (common in Recovery)
ROOT=""
HOST_ROOT=""   # where /etc/hosts and var/db/ConfigurationProfiles live (system volume)
if [ -d "/Volumes/Macintosh HD - Data" ]; then
    ROOT="/Volumes/Macintosh HD - Data"
    HOST_ROOT="/Volumes/Macintosh HD"
elif [ -d "/Volumes/Data" ]; then
    ROOT="/Volumes/Data"
    # guess system volume at /Volumes/Macintosh HD if present
    if [ -d "/Volumes/Macintosh HD" ]; then
        HOST_ROOT="/Volumes/Macintosh HD"
    else
        HOST_ROOT="$ROOT"
    fi
elif [ -d "/var/db/dslocal/nodes/Default" ]; then
    # running on a normal boot
    ROOT="/"
    HOST_ROOT="/"
else
    # fallback
    ROOT="/"
    HOST_ROOT="/"
fi

dscl_path="${ROOT}private/var/db/dslocal/nodes/Default"

# Menu options
PS3='Please enter your choice: '
options=(
    "Bypass MDM from Recovery"
    "Disable Notification (SIP)"
    "Disable Notification (Recovery)"
    "Check MDM Enrollment"
    "Reboot & Exit"
)
select opt in "${options[@]}"; do
    case $opt in
        "Bypass MDM from Recovery")
            echo -e "${YEL}Selected: Bypass MDM from Recovery${NC}"

            # Optionally rename Data volume (as original script tried)
            if [ -d "/Volumes/Macintosh HD - Data" ] && [ ! -d "/Volumes/Data" ]; then
                echo -e "${BLU}Found '/Volumes/Macintosh HD - Data' - attempting to rename to 'Data' (if desired)${NC}"
                # It's safer to not rename automatically; prompt user
                read -p "Rename 'Macintosh HD - Data' to 'Data'? [y/N]: " ans
                if [[ "$ans" =~ ^[Yy]$ ]]; then
                    diskutil rename "Macintosh HD - Data" "Data" 2>/dev/null || echo -e "${RED}Rename failed or not permitted${NC}"
                fi
            fi

            # Prompt for temporary user info
            echo -e "${CYAN}Create a Temporary User${NC}"
            read -p "Enter Temporary Fullname (Default 'Apple'): " realName
            realName="${realName:=Apple}"
            read -p "Enter Temporary Username (Default 'appleuser'): " username
            username="${username:=appleuser}"
            read -p "Enter Temporary Password (Default '1234'): " passw
            passw="${passw:=1234}"

            # Determine where to create home dir (consistent with ROOT)
            user_home_dir="${ROOT}Users/${username}"
            # On the user record, NFSHomeDirectory should be /Users/$username (so macOS sees it correctly)
            nfs_home="/Users/${username}"

            echo -e "${BLU}Using dscl path: ${dscl_path}${NC}"
            # Ensure dscl path exists
            if [ ! -d "${dscl_path}" ]; then
                echo -e "${RED}dscl node not found at ${dscl_path}. Aborting.${NC}"
                exit 1
            fi

            # Find next available UID (>=501) to avoid collisions
            existing_uids=$(dscl -f "${dscl_path}" localhost -list /Local/Default/Users UniqueID 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]+' || true)
            if [ -z "$existing_uids" ]; then
                max_uid=500
            else
                max_uid=$(printf "%s\n" $existing_uids | sort -n | tail -n1)
            fi
            next_uid=$((max_uid + 1))
            # ensure at least 501
            if [ "$next_uid" -lt 501 ]; then
                next_uid=501
            fi

            echo -e "${GRN}Creating user '${username}' with UID ${next_uid} and home ${nfs_home}${NC}"

            # Create the user in dslocal
            dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}"
            dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" UserShell "/bin/zsh"
            dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" RealName "${realName}"
            dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" UniqueID "${next_uid}"
            dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" PrimaryGroupID "20"
            dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" NFSHomeDirectory "${nfs_home}"
            dscl -f "${dscl_path}" localhost -passwd "/Local/Default/Users/${username}" "${passw}"
            # Add to admin group (so account is admin)
            dscl -f "${dscl_path}" localhost -append "/Local/Default/Groups/admin" GroupMembership "${username}"

            # Create the physical home directory on the selected root
            mkdir -p "${user_home_dir}"
            chown "${next_uid}:20" "${user_home_dir}"
            chmod 700 "${user_home_dir}"

            echo -e "${GRN}Temporary user created.${NC}"

            # Block MDM domains in system hosts (use HOST_ROOT)
            hosts_file="${HOST_ROOT}etc/hosts"
            if [ ! -f "${hosts_file}" ]; then
                # If hosts file doesn't exist at HOST_ROOT (possible), fallback to /
                hosts_file="/etc/hosts"
            fi

            echo "0.0.0.0 deviceenrollment.apple.com" >> "${hosts_file}"
            echo "0.0.0.0 mdmenrollment.apple.com" >> "${hosts_file}"
            echo "0.0.0.0 iprofiles.apple.com" >> "${hosts_file}"
            echo -e "${GRN}Successfully updated hosts to block MDM domains (${hosts_file}).${NC}"

            # Remove/add profile flags (use HOST_ROOT/var/db/ConfigurationProfiles/Settings)
            cfg_dir="${HOST_ROOT}var/db/ConfigurationProfiles/Settings"
            if [ -d "${cfg_dir}" ]; then
                rm -rf "${cfg_dir}/.cloudConfigHasActivationRecord" 2>/dev/null || true
                rm -rf "${cfg_dir}/.cloudConfigRecordFound" 2>/dev/null || true
                touch "${cfg_dir}/.cloudConfigProfileInstalled" 2>/dev/null || true
                touch "${cfg_dir}/.cloudConfigRecordNotFound" 2>/dev/null || true
                echo -e "${GRN}Updated configuration profile flags in ${cfg_dir}.${NC}"
            else
                echo -e "${YEL}ConfigurationProfiles settings directory not found at ${cfg_dir} — skipping profile file touches.${NC}"
            fi

            # Mark Apple Setup done in the data root if possible
            touch "${ROOT}private/var/db/.AppleSetupDone" 2>/dev/null || true

            echo -e "${GRN}MDM enrollment steps attempted.${NC}"
            echo -e "${NC}Exit terminal and reboot your Mac.${NC}"
            break
            ;;
        "Disable Notification (SIP)")
            echo -e "${RED}Disable Notification (SIP) - requires root. Proceeding...${NC}"
            # On a normal boot (SIP enabled), system paths are under /
            rm -f /var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord 2>/dev/null || true
            rm -f /var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound 2>/dev/null || true
            touch /var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled 2>/dev/null || true
            touch /var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound 2>/dev/null || true
            echo -e "${GRN}Notification files updated under /var/db/ConfigurationProfiles/Settings.${NC}"
            break
            ;;
        "Disable Notification (Recovery)")
            echo -e "${YEL}Disable Notification (Recovery)${NC}"
            recover_cfg="${HOST_ROOT}var/db/ConfigurationProfiles/Settings"
            if [ -d "${recover_cfg}" ]; then
                rm -rf "${recover_cfg}/.cloudConfigHasActivationRecord" 2>/dev/null || true
                rm -rf "${recover_cfg}/.cloudConfigRecordFound" 2>/dev/null || true
                touch "${recover_cfg}/.cloudConfigProfileInstalled" 2>/dev/null || true
                touch "${recover_cfg}/.cloudConfigRecordNotFound" 2>/dev/null || true
                echo -e "${GRN}Notifications cleared in ${recover_cfg}.${NC}"
            else
                echo -e "${RED}Could not find ${recover_cfg}. Nothing changed.${NC}"
            fi
            break
            ;;
        "Check MDM Enrollment")
            echo ""
            echo -e "${GRN}Check MDM Enrollment. 'Error' may mean no enrollment present.${NC}"
            echo ""
            echo -e "${RED}Running 'profiles show -type enrollment' (requires network & proper boot state)${NC}"
            sudo profiles show -type enrollment || true
            break
            ;;
        "Reboot & Exit")
            echo "Rebooting..."
            reboot
            break
            ;;
        *) echo "Invalid option $REPLY" ;;
    esac
done
