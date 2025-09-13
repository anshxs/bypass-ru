cat > /tmp/mdm_bypass.sh <<'EOF'
#!/bin/bash
# mdm_bypass_recovery.sh
# Recovery-friendly: assumes you're already root (no sudo).
# Includes optional dry-run: pass --dry-run to only print actions.

set -o pipefail
DRY_RUN=0
if [ "$1" = "--dry-run" ] || [ "$1" = "-n" ]; then
  DRY_RUN=1
  echo "Running in dry-run mode (no changes will be made)"
fi

# Helpers
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] $*"
  else
    echo "[RUN] $*"
    eval "$@"
  fi
}

# Colors
RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# Ensure we are root (Recovery shells usually are)
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}This script must be run as root. Exiting.${NC}"
  exit 1
fi

echo -e "${CYAN}Recovery-mode MDM helper (no sudo)${NC}"
echo

# Detect expected mount points (common Recovery mounts)
ROOT=""
HOST_ROOT=""
if [ -d "/Volumes/Macintosh HD - Data" ]; then
  ROOT="/Volumes/Macintosh HD - Data/"
  HOST_ROOT="/Volumes/Macintosh HD/"
elif [ -d "/Volumes/Data" ]; then
  ROOT="/Volumes/Data/"
  if [ -d "/Volumes/Macintosh HD" ]; then
    HOST_ROOT="/Volumes/Macintosh HD/"
  else
    HOST_ROOT="${ROOT}"
  fi
elif [ -d "/private/var/db/dslocal/nodes/Default" ]; then
  # Running in normal boot, but script still works
  ROOT="/"
  HOST_ROOT="/"
else
  # Fallback to root
  ROOT="/"
  HOST_ROOT="/"
fi

# Print discovered roots
echo -e "${BLU}Using ROOT='${ROOT}'  HOST_ROOT='${HOST_ROOT}'${NC}"

# dscl node path inside the data root
dscl_path="${ROOT}private/var/db/dslocal/nodes/Default"
if [ ! -d "${dscl_path}" ]; then
  echo -e "${YEL}Warning: dscl node '${dscl_path}' not found. You may need to mount the Data/volume containing /var/db/dslocal.${NC}"
fi

# Prompt values (non-interactive in some recovery shells may not have read; default values provided)
read -p "Enter Temporary Fullname (Default 'Apple'): " realName 2>/dev/null || true
realName="${realName:=Apple}"
read -p "Enter Temporary Username (Default 'appleuser'): " username 2>/dev/null || true
username="${username:=appleuser}"
read -p "Enter Temporary Password (Default '1234'): " passw 2>/dev/null || true
passw="${passw:=1234}"

# Pick home directory paths
user_home_dir="${ROOT}Users/${username}"
nfs_home="/Users/${username}"

# Find next available UID safely using dscl (if dscl node exists); otherwise fallback to 501+
next_uid=501
if [ -d "${dscl_path}" ]; then
  existing_uids=$(dscl -f "${dscl_path}" localhost -list /Local/Default/Users UniqueID 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]+' || true)
  if [ -n "${existing_uids}" ]; then
    max_uid=$(printf "%s\n" ${existing_uids} | sort -n | tail -n1)
    next_uid=$((max_uid + 1))
    if [ "${next_uid}" -lt 501 ]; then next_uid=501; fi
  fi
fi

echo -e "${GRN}Creating user '${username}' UID=${next_uid} home=${nfs_home}${NC}"

# Create user record (if dscl path exists)
if [ -d "${dscl_path}" ]; then
  run dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}"
  run dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" UserShell "/bin/zsh"
  run dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" RealName "${realName}"
  run dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" UniqueID "${next_uid}"
  run dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" PrimaryGroupID "20"
  run dscl -f "${dscl_path}" localhost -create "/Local/Default/Users/${username}" NFSHomeDirectory "${nfs_home}"
  run dscl -f "${dscl_path}" localhost -passwd "/Local/Default/Users/${username}" "${passw}"
  run dscl -f "${dscl_path}" localhost -append "/Local/Default/Groups/admin" GroupMembership "${username}"
else
  echo -e "${YEL}Skipping dscl user creation because dscl node not found at ${dscl_path}${NC}"
fi

# Create home directory in the data/root area and set permissions
run mkdir -p "${user_home_dir}"
run chown "${next_uid}:20" "${user_home_dir}" || true
run chmod 700 "${user_home_dir}" || true

# Update hosts file to block MDM domains (use HOST_ROOT; fallback to /etc/hosts)
hosts_file="${HOST_ROOT}etc/hosts"
if [ ! -f "${hosts_file}" ]; then
  hosts_file="/etc/hosts"
fi

run printf "\n# Added by mdm_bypass_recovery\n0.0.0.0 deviceenrollment.apple.com\n0.0.0.0 mdmenrollment.apple.com\n0.0.0.0 iprofiles.apple.com\n" >> "${hosts_file}"
echo -e "${GRN}Hosts updated at ${hosts_file}${NC}"

# Update ConfigurationProfiles indicator files under HOST_ROOT if present
cfg_dir="${HOST_ROOT}var/db/ConfigurationProfiles/Settings"
if [ -d "${cfg_dir}" ]; then
  run rm -f "${cfg_dir}/.cloudConfigHasActivationRecord" || true
  run rm -f "${cfg_dir}/.cloudConfigRecordFound" || true
  run touch "${cfg_dir}/.cloudConfigProfileInstalled" || true
  run touch "${cfg_dir}/.cloudConfigRecordNotFound" || true
  echo -e "${GRN}ConfigurationProfiles flags updated in ${cfg_dir}${NC}"
else
  echo -e "${YEL}ConfigurationProfiles settings dir not found at ${cfg_dir} — skipping those steps.${NC}"
fi

# Mark Apple setup done inside ROOT if possible
run touch "${ROOT}private/var/db/.AppleSetupDone" || true

echo -e "${GRN}Finished (or simulated) operations. If not in dry-run, reboot to apply changes.${NC}"
echo -e "${CYAN}To reboot now run: reboot${NC}"
EOF
