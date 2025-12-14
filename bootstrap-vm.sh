#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Ubuntu VM Bootstrap (Improved)
# ============================================================
# Features:
#   - Input validation (IP, CIDR, gateway)
#   - Idempotent operations
#   - Persistent logging
#   - Netplan rollback support
#   - Dry-run mode (DRY_RUN=yes ./bootstrap.sh)
#   - Virtualization detection
#   - Cloud credentials cleanup
#   - Trap-based error handling
#   - Previous run detection (use FORCE_RERUN=yes to override)
#   - LVM root filesystem expansion
#   - Sysprep cleanup (with /tmp self-deletion protection)
# ============================================================

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="2.0.1"
readonly BOOTSTRAP_MARKER="/etc/bootstrap-done"
readonly GITHUB_REPO="vidaldiego/bootstrap-vm"

# Preserve timestamp/logfile across phases
readonly TIMESTAMP="${BOOT_TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
readonly LOGFILE="${BOOT_LOGFILE:-/var/log/bootstrap-${TIMESTAMP}.log}"

# Runtime flags (can be overridden via environment)
DRY_RUN="${DRY_RUN:-no}"
FORCE="${FORCE:-no}"
FORCE_RERUN="${FORCE_RERUN:-no}"

# Two-phase execution: "interactive" (collect input) or "apply" (execute as root)
BOOTSTRAP_PHASE="${BOOTSTRAP_PHASE:-interactive}"

# ============================================================
# Color Support
# ============================================================

setup_colors() {
  # Respect NO_COLOR standard (https://no-color.org/)
  # Also disable colors if not running in a terminal
  if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    COLOR_ENABLED="no"
  else
    COLOR_ENABLED="yes"
  fi

  if [[ "${COLOR_ENABLED}" == "yes" ]]; then
    # Regular colors (using $'...' for escape sequence interpretation)
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'

    # Bold colors
    BOLD=$'\033[1m'
    BOLD_RED=$'\033[1;31m'
    BOLD_GREEN=$'\033[1;32m'
    BOLD_YELLOW=$'\033[1;33m'
    BOLD_BLUE=$'\033[1;34m'
    BOLD_CYAN=$'\033[1;36m'

    # Other styles
    DIM=$'\033[2m'
    UNDERLINE=$'\033[4m'

    # Reset
    RESET=$'\033[0m'
  else
    RED='' GREEN='' YELLOW='' CYAN=''
    BOLD='' BOLD_RED='' BOLD_GREEN='' BOLD_YELLOW='' BOLD_BLUE='' BOLD_CYAN=''
    DIM='' UNDERLINE='' RESET=''
  fi
}

# Initialize colors immediately
setup_colors

# ============================================================
# Logging & Utilities
# ============================================================

setup_logging() {
  if [[ "${DRY_RUN}" != "yes" ]]; then
    mkdir -p "$(dirname "$LOGFILE")"
    # Use script to preserve colors in log while still showing on terminal
    exec > >(tee -a "$LOGFILE") 2>&1
  fi
}

log() {
  printf '%s[%s]%s %sINFO%s  %s\n' "${GREEN}" "$(date +%H:%M:%S)" "${RESET}" "${BOLD}" "${RESET}" "$*"
}

warn() {
  printf '%s[%s]%s %sWARN%s  %s\n' "${YELLOW}" "$(date +%H:%M:%S)" "${RESET}" "${BOLD_YELLOW}" "${RESET}" "$*" >&2
}

error() {
  printf '%s[%s]%s %sERROR%s %s\n' "${RED}" "$(date +%H:%M:%S)" "${RESET}" "${BOLD_RED}" "${RESET}" "$*" >&2
}

die() {
  error "$*"
  exit 1
}

# Additional styled output helpers
header() {
  local text="$1"
  local width=60
  local padding=$(( (width - ${#text} - 2) / 2 ))
  local line=""

  for ((i=0; i<width; i++)); do line+="─"; done

  echo ""
  printf '%s╭%s╮%s\n' "${BOLD_CYAN}" "$line" "${RESET}"
  printf '%s│%s%*s %s%s%s %*s%s│%s\n' "${BOLD_CYAN}" "${RESET}" $padding "" "${BOLD}" "$text" "${RESET}" $((width - padding - ${#text} - 2)) "" "${BOLD_CYAN}" "${RESET}"
  printf '%s╰%s╯%s\n' "${BOLD_CYAN}" "$line" "${RESET}"
  echo ""
}

success() {
  printf '%s✓%s %s\n' "${BOLD_GREEN}" "${RESET}" "$*"
}

info() {
  printf '%s→%s %s\n' "${CYAN}" "${RESET}" "$*"
}

step() {
  printf '\n%s▶%s %s%s%s\n' "${BOLD_BLUE}" "${RESET}" "${BOLD}" "$*" "${RESET}"
}

run() {
  if [[ "${DRY_RUN}" == "yes" ]]; then
    printf '  %s[dry-run]%s %s\n' "${DIM}" "${RESET}" "$*"
    return 0
  else
    "$@"
  fi
}

cleanup() {
  local exit_code=$?
  if (( exit_code != 0 )); then
    error "Script terminated with error (code: ${exit_code})"
    if [[ -f "${LOGFILE}" ]]; then
      error "Check log file: ${LOGFILE}"
    fi
  fi
}
trap cleanup EXIT

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This function requires root privileges"
  fi
}

# Re-execute script as root with all collected state passed via environment
elevate_and_apply() {
  exec sudo -E env \
    BOOTSTRAP_PHASE=apply \
    DRY_RUN="${DRY_RUN}" \
    FORCE="${FORCE}" \
    FORCE_RERUN="${FORCE_RERUN}" \
    BOOT_TIMESTAMP="${TIMESTAMP}" \
    BOOT_LOGFILE="${LOGFILE}" \
    BOOT_NEW_HOSTNAME="${BOOT_NEW_HOSTNAME:-}" \
    BOOT_CHANGE_IP="${BOOT_CHANGE_IP:-no}" \
    BOOT_PRIMARY_IF="${BOOT_PRIMARY_IF:-}" \
    BOOT_STATIC_IP="${BOOT_STATIC_IP:-}" \
    BOOT_GATEWAY="${BOOT_GATEWAY:-}" \
    BOOT_DNS_SERVERS="${BOOT_DNS_SERVERS:-}" \
    BOOT_CLOUD_INIT_CLEAN="${BOOT_CLOUD_INIT_CLEAN:-no}" \
    BOOT_CLEAN_CREDS="${BOOT_CLEAN_CREDS:-no}" \
    BOOT_EXPAND_DISK="${BOOT_EXPAND_DISK:-no}" \
    BOOT_SYSPREP="${BOOT_SYSPREP:-no}" \
    bash "$0"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-no}"
  local yn

  [[ "${FORCE}" == "yes" ]] && return 0

  while true; do
    if [[ "$default" == "yes" ]]; then
      read -r -p "${prompt} [Y/n]: " yn
      yn="${yn:-Y}"
    else
      read -r -p "${prompt} [y/N]: " yn
      yn="${yn:-N}"
    fi
    case "$yn" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# ============================================================
# Validation Functions
# ============================================================

validate_ip() {
  local ip="$1"
  local IFS='.'
  local -a octets

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( octet <= 255 )) || return 1
  done
  return 0
}

validate_cidr() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local mask="${cidr#*/}"

  [[ "$cidr" == */* ]] || return 1
  validate_ip "$ip" || return 1
  [[ "$mask" =~ ^[0-9]+$ ]] && (( mask >= 0 && mask <= 32 ))
}

validate_dns_list() {
  local dns_list="$1"
  local IFS=','
  local -a servers

  [[ -z "$dns_list" ]] && return 0

  read -r -a servers <<< "$dns_list"
  for server in "${servers[@]}"; do
    server="${server// /}"
    validate_ip "$server" || return 1
  done
  return 0
}

validate_hostname() {
  local hostname="$1"
  [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]]
}

# ============================================================
# Detection Functions
# ============================================================

detect_primary_interface() {
  local iface

  iface="$(ip route show default 0.0.0.0/0 2>/dev/null | awk '{print $5}' | head -n1 || true)"
  if [[ -z "$iface" ]]; then
    iface="$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')"
  fi

  echo "$iface"
}

detect_virtualization() {
  local virt="physical"

  if command -v systemd-detect-virt &>/dev/null; then
    virt="$(systemd-detect-virt 2>/dev/null || echo "physical")"
  fi

  # Try to detect specific cloud providers
  if [[ -f /sys/class/dmi/id/sys_vendor ]]; then
    local vendor
    vendor="$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/sys_vendor 2>/dev/null)"
    case "$vendor" in
      *amazon*)       virt="amazon" ;;
      *microsoft*)    virt="azure" ;;
      *google*)       virt="gce" ;;
      *digitalocean*) virt="digitalocean" ;;
    esac
  fi

  # Fallback to product_name for hypervisor detection
  if [[ "$virt" == "physical" ]] && [[ -f /sys/class/dmi/id/product_name ]]; then
    local product
    product="$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_name 2>/dev/null)"
    case "$product" in
      *virtualbox*) virt="virtualbox" ;;
      *vmware*)     virt="vmware" ;;
      *kvm*|*qemu*) virt="kvm" ;;
      *xen*)        virt="xen" ;;
      *hyper-v*)    virt="hyperv" ;;
    esac
  fi

  echo "$virt"
}

detect_root_device() {
  findmnt -n -o SOURCE / 2>/dev/null || true
}

detect_root_fstype() {
  findmnt -n -o FSTYPE / 2>/dev/null || true
}

detect_current_ip() {
  local iface="$1"
  # Get first IPv4 address with CIDR notation
  ip -4 addr show dev "$iface" 2>/dev/null | \
    awk '/inet / {print $2; exit}'
}

detect_current_gateway() {
  ip route show default 2>/dev/null | \
    awk '/default/ {print $3; exit}'
}

detect_current_dns() {
  local iface="${1:-}"

  # Try systemd-resolved first
  if command -v resolvectl &>/dev/null; then
    local dns_output=""

    # Prefer interface-specific DNS if interface provided
    if [[ -n "$iface" ]]; then
      dns_output="$(resolvectl dns "$iface" 2>/dev/null | sed 's/.*: //' || true)"
    fi

    # Fallback to global DNS
    if [[ -z "$dns_output" ]]; then
      dns_output="$(resolvectl dns 2>/dev/null | grep -E '(Global|Link)' | head -1 | sed 's/.*: //' || true)"
    fi

    if [[ -n "$dns_output" ]]; then
      echo "$dns_output" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -3 | paste -sd',' -
      return
    fi
  fi

  # Fallback to resolv.conf
  if [[ -f /etc/resolv.conf ]]; then
    grep -E '^nameserver' /etc/resolv.conf | \
      awk '{print $2}' | \
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
      head -3 | \
      paste -sd',' -
  fi
}

check_previous_run() {
  if [[ -f "${BOOTSTRAP_MARKER}" ]]; then
    local prev_date prev_hostname
    prev_date="$(grep '^DATE=' "${BOOTSTRAP_MARKER}" 2>/dev/null | cut -d'=' -f2- || echo 'unknown')"
    prev_hostname="$(grep '^HOSTNAME=' "${BOOTSTRAP_MARKER}" 2>/dev/null | cut -d'=' -f2- || echo 'unknown')"

    echo ""
    printf '  %s⚠  WARNING: Bootstrap was already run on this machine%s\n' "${BOLD_YELLOW}" "${RESET}"
    printf '     Previous run: %s\n' "${prev_date}"
    printf '     Hostname was: %s\n' "${prev_hostname}"
    echo ""
    printf '  Running again may cause issues (new SSH keys, new machine-id, etc.)\n'
    echo ""

    if [[ "${FORCE_RERUN}" == "yes" ]]; then
      warn "FORCE_RERUN=yes specified, continuing anyway..."
      return 0
    fi

    if ! ask_yes_no "Are you sure you want to run bootstrap again?" "no"; then
      die "Aborted. Use FORCE_RERUN=yes to skip this check."
    fi
  fi
}

write_bootstrap_marker() {
  if [[ "${DRY_RUN}" != "yes" ]]; then
    {
      echo "# Bootstrap completion marker"
      echo "DATE=$(date -Iseconds)"
      echo "HOSTNAME=$(hostname)"
      echo "SCRIPT_VERSION=${SCRIPT_VERSION}"
      echo "IP=$(hostname -I 2>/dev/null | awk '{print $1}')"
      echo "LOGFILE=${LOGFILE}"
    } > "${BOOTSTRAP_MARKER}"
    chmod 644 "${BOOTSTRAP_MARKER}"
  fi
}


# ============================================================
# Core Operations
# ============================================================

update_system() {
  step "Updating system packages"
  run apt-get update || warn "apt update failed"
  run apt-get -y full-upgrade || warn "apt full-upgrade failed"
  run apt-get -y autoremove || true
  run apt-get clean || true
  success "System packages updated"
}

regenerate_ssh_keys() {
  step "Regenerating SSH host keys"
  run rm -f /etc/ssh/ssh_host_*
  run dpkg-reconfigure openssh-server || warn "dpkg-reconfigure openssh-server failed"
  run systemctl restart ssh 2>/dev/null || run systemctl restart sshd 2>/dev/null || true
  success "SSH host keys regenerated"
}

reset_machine_id() {
  step "Resetting machine-id"
  run truncate -s 0 /etc/machine-id
  run rm -f /var/lib/dbus/machine-id
  run ln -sf /etc/machine-id /var/lib/dbus/machine-id
  success "Machine-id reset"
}

clean_logs() {
  step "Cleaning journal logs"
  run journalctl --rotate || true
  run journalctl --vacuum-time=1s || true
  success "Journal logs cleaned"
}

clean_cloud_init() {
  if command -v cloud-init &>/dev/null; then
    step "Cleaning cloud-init state"
    run cloud-init clean --logs --seed || warn "cloud-init clean failed"
    success "Cloud-init state cleaned"
  fi
}

clean_cloud_credentials() {
  step "Cleaning cloud provider credentials"

  # AWS
  run rm -rf /root/.aws /home/*/.aws 2>/dev/null || true

  # Azure
  run rm -rf /var/lib/waagent/*.xml 2>/dev/null || true

  # GCP
  run rm -rf /root/.config/gcloud /home/*/.config/gcloud 2>/dev/null || true

  # Generic SSH keys that might be leftover
  run rm -f /root/.ssh/authorized_keys 2>/dev/null || true

  success "Cloud credentials cleaned"
}

clean_system_state() {
  step "Cleaning system state (sysprep)"

  # Safety check: detect if script is running from /tmp to avoid self-deletion
  local script_path
  script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  local script_in_tmp="no"

  if [[ "${script_path}" == /tmp/* ]] || [[ "${script_path}" == /var/tmp/* ]]; then
    script_in_tmp="yes"
    warn "Script is running from temporary directory: ${script_path}"
    warn "Skipping /tmp cleanup to avoid self-deletion"
    info "Recommendation: Run script from ~/bootstrap-vm.sh or /usr/local/bin/bootstrap-vm.sh"
    echo ""
  fi

  # Clear shell history for all users
  info "Clearing shell history..."
  run rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null || true
  for histfile in /root/.bash_history /home/*/.bash_history; do
    run truncate -s 0 "$histfile" 2>/dev/null || true
  done

  # Clear login records
  info "Clearing login records..."
  run truncate -s 0 /var/log/wtmp 2>/dev/null || true
  run truncate -s 0 /var/log/btmp 2>/dev/null || true
  run truncate -s 0 /var/log/lastlog 2>/dev/null || true

  # Clear temp files (skip if script is in /tmp to avoid self-deletion)
  if [[ "${script_in_tmp}" == "no" ]]; then
    info "Clearing temporary files..."
    run rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
  else
    info "Skipping temporary file cleanup (script running from temp directory)"
  fi

  # Clear apt cache and lists (will re-download on next update)
  info "Clearing apt cache..."
  run apt-get clean || true
  run rm -rf /var/lib/apt/lists/* || true

  # Clear old logs (keep structure)
  info "Truncating old logs..."
  run find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
  run find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
  run find /var/log -type f -name "*.[0-9]" -delete 2>/dev/null || true

  # Reset failed login counters
  run pam_tally2 --reset 2>/dev/null || true
  run faillock --reset 2>/dev/null || true

  # Clear random seed (will regenerate on boot)
  run rm -f /var/lib/systemd/random-seed 2>/dev/null || true

  success "System state cleaned"
}

set_hostname() {
  local new_hostname="$1"

  step "Setting hostname to '${CYAN}${new_hostname}${RESET}'"
  run hostnamectl set-hostname "${new_hostname}" || warn "hostnamectl failed"

  if [[ "${DRY_RUN}" != "yes" ]]; then
    # Update or add 127.0.1.1 entry (don't delete other lines to avoid breaking things)
    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${new_hostname}/" /etc/hosts
    else
      printf "127.0.1.1\t%s\n" "${new_hostname}" >> /etc/hosts
    fi
  else
    printf '  %s[dry-run]%s Would update /etc/hosts for %s\n' "${DIM}" "${RESET}" "${new_hostname}"
  fi

  success "Hostname configured"
}

configure_static_ip() {
  local interface="$1"
  local static_ip="$2"
  local gateway="$3"
  local dns_servers="$4"

  step "Configuring static IP on '${CYAN}${interface}${RESET}'"

  local netplan_dir="/etc/netplan"
  local backup_dir="/root/netplan-backups-${TIMESTAMP}"
  local netplan_file="${netplan_dir}/99-bootstrap-static.yaml"

  # Backup existing configs
  run mkdir -p "${backup_dir}"
  if [[ "${DRY_RUN}" != "yes" ]]; then
    cp -a "${netplan_dir}"/* "${backup_dir}/" 2>/dev/null || true
    info "Backed up existing netplan configs to ${DIM}${backup_dir}${RESET}"
  fi

  # Build DNS list
  local dns_list=""
  if [[ -n "${dns_servers}" ]]; then
    local IFS=','
    local -a dns_array
    read -r -a dns_array <<< "${dns_servers}"
    dns_list="$(printf "%s, " "${dns_array[@]}" | sed 's/, $//')"
  fi

  # Generate netplan config
  if [[ "${DRY_RUN}" != "yes" ]]; then
    cat > "${netplan_file}" <<EOF
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on ${TIMESTAMP}
network:
  version: 2
  renderer: networkd
  ethernets:
    ${interface}:
      dhcp4: no
      addresses:
        - ${static_ip}
      routes:
        - to: default
          via: ${gateway}
EOF

    if [[ -n "${dns_list}" ]]; then
      cat >> "${netplan_file}" <<EOF
      nameservers:
        addresses: [${dns_list}]
EOF
    fi

    chmod 600 "${netplan_file}"
  else
    printf '  %s[dry-run]%s Would create %s\n' "${DIM}" "${RESET}" "${netplan_file}"
  fi

  # Validate config without applying (safe for SSH sessions)
  # Config will be applied on next reboot
  if [[ "${DRY_RUN}" != "yes" ]]; then
    info "Validating netplan configuration..."
    if netplan generate; then
      success "Network configuration validated"
      info "Config saved to ${DIM}${netplan_file}${RESET}"
      info "Network changes will apply on next reboot"
      BOOT_REBOOT_REQUIRED="yes"
    else
      warn "Netplan validation failed, restoring backup..."
      cp -a "${backup_dir}"/* "${netplan_dir}/" 2>/dev/null || true
      rm -f "${netplan_file}"
      die "Network configuration invalid and was rolled back"
    fi
  else
    printf '  %s[dry-run]%s Would run: netplan generate (validate only)\n' "${DIM}" "${RESET}"
  fi
}

expand_root_filesystem() {
  step "Expanding root filesystem"

  local root_dev
  root_dev="$(detect_root_device)"

  if [[ -z "${root_dev}" ]]; then
    warn "Could not detect root device, skipping expansion"
    return 0  # Not an error, just nothing to do
  fi

  local fstype
  fstype="$(detect_root_fstype)"

  # Handle LVM
  if [[ "${root_dev}" == /dev/mapper/* || "${root_dev}" == /dev/dm-* ]]; then
    expand_lvm_root "${root_dev}" "${fstype}"
    return 0
  fi

  # Handle regular partitions
  if [[ "${fstype}" != "ext4" ]]; then
    warn "Root filesystem is '${fstype}', only ext4 expansion is supported"
    return 0
  fi

  local disk_dev part_num
  disk_dev="$(lsblk -no PKNAME "${root_dev}" 2>/dev/null | head -n1 || true)"
  part_num="$(echo "${root_dev}" | grep -o '[0-9]*$' || true)"

  if [[ -z "${disk_dev}" || -z "${part_num}" ]]; then
    warn "Could not determine disk/partition for root device"
    return 0
  fi

  local disk="/dev/${disk_dev}"

  info "Growing partition ${part_num} on ${disk}..."

  # Ensure tools are available
  run apt-get -y install cloud-guest-utils e2fsprogs || warn "Failed to install expansion tools"

  run growpart "${disk}" "${part_num}" || warn "growpart failed (disk may already be full size)"
  run resize2fs "${root_dev}" || warn "resize2fs failed"

  success "Filesystem expansion complete"
}

expand_lvm_root() {
  local root_dev="$1"
  local fstype="$2"

  info "Detected LVM root: ${root_dev}"

  # Ensure LVM tools are available
  run apt-get -y install lvm2 e2fsprogs xfsprogs cloud-guest-utils || warn "Failed to install LVM/FS tools"

  # Get VG and LV names reliably using lvs (not by parsing mapper name)
  local vg_name lv_name
  vg_name="$(lvs --noheadings -o vg_name "${root_dev}" 2>/dev/null | xargs || true)"
  lv_name="$(lvs --noheadings -o lv_name "${root_dev}" 2>/dev/null | xargs || true)"

  if [[ -z "${vg_name}" || -z "${lv_name}" ]]; then
    warn "Could not determine VG/LV for ${root_dev}"
    return 0
  fi

  info "VG: ${vg_name}, LV: ${lv_name}"

  # Find the PV backing this VG
  local pv_dev
  pv_dev="$(pvs --noheadings -o pv_name -S vg_name="${vg_name}" 2>/dev/null | xargs | awk '{print $1}' || true)"

  if [[ -z "${pv_dev}" ]]; then
    warn "Could not find physical volume for VG '${vg_name}'"
    return 0
  fi

  info "Physical volume: ${pv_dev}"

  # Try to grow the underlying partition first
  local disk_dev part_num
  disk_dev="$(lsblk -no PKNAME "${pv_dev}" 2>/dev/null | head -n1 || true)"
  part_num="$(echo "${pv_dev}" | grep -o '[0-9]*$' || true)"

  if [[ -n "${disk_dev}" && -n "${part_num}" ]]; then
    local disk="/dev/${disk_dev}"
    info "Growing partition ${part_num} on ${disk}..."
    run growpart "${disk}" "${part_num}" 2>/dev/null || info "Partition already at max size"
  fi

  # Resize PV to use new space
  info "Resizing physical volume..."
  run pvresize "${pv_dev}" || warn "pvresize failed"

  # Extend LV to use all free space
  info "Extending logical volume..."
  run lvextend -l +100%FREE "/dev/${vg_name}/${lv_name}" 2>/dev/null || info "LV already at max size"

  # Resize filesystem
  info "Resizing filesystem..."
  case "${fstype}" in
    ext4)
      run resize2fs "${root_dev}" || warn "resize2fs failed"
      ;;
    xfs)
      # xfs_growfs requires mountpoint, not device
      run xfs_growfs / || warn "xfs_growfs failed"
      ;;
    *)
      warn "Filesystem '${fstype}' resize not supported"
      return 0
      ;;
  esac

  success "LVM filesystem expansion complete"
}

print_final_report() {
  local report_file="/root/bootstrap-report-${TIMESTAMP}.txt"

  echo ""
  printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "${BOLD_CYAN}" "${RESET}"
  printf '%s║%s            %sBootstrap Completion Report%s                     %s║%s\n' "${BOLD_CYAN}" "${RESET}" "${BOLD}" "${RESET}" "${BOLD_CYAN}" "${RESET}"
  printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "${BOLD_CYAN}" "${RESET}"
  echo ""

  # Gather system info
  local current_ip current_gw current_dns root_fs mem_info
  current_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  current_gw="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')"
  current_dns="$(resolvectl dns 2>/dev/null | grep -v '^Global' | head -1 | sed 's/.*: //' || grep nameserver /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}')"
  root_fs="$(df -h / 2>/dev/null | awk 'NR==2 {print $2 " total, " $4 " free (" $5 " used)"}')"
  mem_info="$(free -h 2>/dev/null | awk '/Mem:/ {print $2 " total, " $7 " available"}')"

  # Display report
  printf "  %sDate:%s         %s\n" "${BOLD}" "${RESET}" "$(date)"
  printf "  %sHostname:%s     %s%s%s\n" "${BOLD}" "${RESET}" "${CYAN}" "$(hostname)" "${RESET}"
  printf "  %sIP Address:%s   %s%s%s\n" "${BOLD}" "${RESET}" "${CYAN}" "${current_ip:-N/A}" "${RESET}"
  printf "  %sGateway:%s      %s\n" "${BOLD}" "${RESET}" "${current_gw:-N/A}"
  printf "  %sDNS:%s          %s\n" "${BOLD}" "${RESET}" "${current_dns:-N/A}"
  echo ""
  printf "  %sRoot FS:%s      %s\n" "${BOLD}" "${RESET}" "${root_fs:-N/A}"
  printf "  %sMemory:%s       %s\n" "${BOLD}" "${RESET}" "${mem_info:-N/A}"
  echo ""
  printf "  %sSSH Keys:%s     %s host keys regenerated\n" "${BOLD}" "${RESET}" "$(find /etc/ssh -maxdepth 1 -name 'ssh_host_*_key' 2>/dev/null | wc -l)"
  printf "  %sMachine ID:%s   %s%s%s\n" "${BOLD}" "${RESET}" "${DIM}" "$(cat /etc/machine-id 2>/dev/null || echo 'N/A')" "${RESET}"
  echo ""
  printf "  %sLog file:%s     %s%s%s\n" "${BOLD}" "${RESET}" "${DIM}" "${LOGFILE}" "${RESET}"
  printf "  %sReport:%s       %s%s%s\n" "${BOLD}" "${RESET}" "${DIM}" "${report_file}" "${RESET}"
  printf "  %sMarker:%s       %s%s%s\n" "${BOLD}" "${RESET}" "${DIM}" "${BOOTSTRAP_MARKER}" "${RESET}"
  echo ""

  # Write plain text version to file
  if [[ "${DRY_RUN}" != "yes" ]]; then
    {
      echo "========================================"
      echo "   Bootstrap Completion Report"
      echo "========================================"
      echo ""
      echo "Date:         $(date)"
      echo "Hostname:     $(hostname)"
      echo "IP Address:   ${current_ip:-N/A}"
      echo "Gateway:      ${current_gw:-N/A}"
      echo "DNS:          ${current_dns:-N/A}"
      echo ""
      echo "Root FS:      ${root_fs:-N/A}"
      echo "Memory:       ${mem_info:-N/A}"
      echo ""
      echo "SSH Keys:     $(find /etc/ssh -maxdepth 1 -name 'ssh_host_*_key' 2>/dev/null | wc -l) host keys regenerated"
      echo "Machine ID:   $(cat /etc/machine-id 2>/dev/null || echo 'N/A')"
      echo ""
      echo "Script Ver:   ${SCRIPT_VERSION}"
      echo "Log file:     ${LOGFILE}"
      echo "Marker:       ${BOOTSTRAP_MARKER}"
      echo ""
      echo "========================================"
    } > "${report_file}"
  fi
}

# ============================================================
# Summary & Confirmation
# ============================================================

print_summary() {
  local hostname="$1"
  local change_ip="$2"
  local interface="$3"
  local static_ip="$4"
  local gateway="$5"
  local dns="$6"
  local cloud_init_clean="$7"
  local expand_disk="$8"
  local clean_creds="$9"
  local virt="${10}"
  local sysprep="${11}"

  header "Bootstrap Summary"

  printf "  %sEnvironment:%s        %s\n" "${BOLD}" "${RESET}" "${virt}"
  printf "  %sCurrent hostname:%s   %s\n" "${BOLD}" "${RESET}" "$(hostname)"
  [[ -n "$hostname" ]] && printf "  %sNew hostname:%s       %s%s%s\n" "${BOLD}" "${RESET}" "${CYAN}" "${hostname}" "${RESET}"
  echo ""

  printf "  %s%sOperations to perform:%s\n\n" "${BOLD}" "${UNDERLINE}" "${RESET}"

  printf "    %s✓%s Update system packages\n" "${GREEN}" "${RESET}"
  printf "    %s✓%s Regenerate SSH host keys\n" "${GREEN}" "${RESET}"
  printf "    %s✓%s Reset machine-id\n" "${GREEN}" "${RESET}"
  printf "    %s✓%s Clean journal logs\n" "${GREEN}" "${RESET}"

  [[ "$cloud_init_clean" == "yes" ]] && printf "    %s✓%s Clean cloud-init state\n" "${GREEN}" "${RESET}"
  if [[ "$clean_creds" == "yes" ]]; then
    printf "    %s✓%s %sClean cloud credentials (destructive)%s\n" "${YELLOW}" "${RESET}" "${BOLD_YELLOW}" "${RESET}"
  fi
  [[ -n "$hostname" ]] && printf "    %s✓%s Set hostname: %s%s%s\n" "${GREEN}" "${RESET}" "${CYAN}" "${hostname}" "${RESET}"

  if [[ "$change_ip" == "yes" ]]; then
    printf "    %s✓%s Configure static IP:\n" "${GREEN}" "${RESET}"
    printf "        %sInterface:%s %s\n" "${DIM}" "${RESET}" "${interface}"
    printf "        %sIP/CIDR:%s   %s%s%s\n" "${DIM}" "${RESET}" "${CYAN}" "${static_ip}" "${RESET}"
    printf "        %sGateway:%s   %s\n" "${DIM}" "${RESET}" "${gateway}"
    [[ -n "$dns" ]] && printf "        %sDNS:%s       %s\n" "${DIM}" "${RESET}" "${dns}"
  fi

  [[ "$expand_disk" == "yes" ]] && printf "    %s✓%s Expand root filesystem\n" "${GREEN}" "${RESET}"
  [[ "$sysprep" == "yes" ]] && printf "    %s✓%s Clean system state (sysprep)\n" "${GREEN}" "${RESET}"

  printf "    %s✓%s Reboot system\n" "${GREEN}" "${RESET}"
  echo ""

  if [[ "${DRY_RUN}" == "yes" ]]; then
    printf "  %s⚠  DRY-RUN MODE — No changes will be applied%s\n\n" "${BOLD_YELLOW}" "${RESET}"
  fi
}

# ============================================================
# Main
# ============================================================

# ============================================================
# Main - Interactive Phase (collect input)
# ============================================================

interactive_phase() {
  header "Ubuntu VM Bootstrap v${SCRIPT_VERSION}"

  [[ "${DRY_RUN}" == "yes" ]] && printf '  %s⚠  Running in DRY-RUN mode%s\n\n' "${BOLD_YELLOW}" "${RESET}"

  # Check if bootstrap was already run on this machine
  check_previous_run

  # Detect environment
  local primary_if virt
  primary_if="$(detect_primary_interface)"
  virt="$(detect_virtualization)"

  info "Detected interface: ${CYAN}${primary_if:-none}${RESET}"
  info "Detected environment: ${CYAN}${virt}${RESET}"
  echo ""

  # Export for apply phase
  export BOOT_PRIMARY_IF="${primary_if}"

  # Gather user input
  local new_hostname=""
  read -r -p "New hostname (empty to keep '$(hostname)'): " new_hostname
  if [[ -n "$new_hostname" ]] && ! validate_hostname "$new_hostname"; then
    die "Invalid hostname format: ${new_hostname}"
  fi
  export BOOT_NEW_HOSTNAME="${new_hostname}"

  local change_ip="no"
  local static_ip="" gateway="" dns_servers=""

  if [[ -n "$primary_if" ]] && ask_yes_no "Configure static IP on '${primary_if}'?" "no"; then
    change_ip="yes"

    # Detect current network config for defaults
    local current_ip current_gw current_dns
    current_ip="$(detect_current_ip "$primary_if")"
    current_gw="$(detect_current_gateway)"
    current_dns="$(detect_current_dns "$primary_if")"

    # Static IP prompt with current as default
    if [[ -n "$current_ip" ]]; then
      read -r -p "Static IP (CIDR) [${current_ip}]: " static_ip
      static_ip="${static_ip:-$current_ip}"
    else
      read -r -p "Static IP (CIDR format, e.g. 10.10.30.50/24): " static_ip
    fi
    validate_cidr "$static_ip" || die "Invalid CIDR format: ${static_ip}"

    # Gateway prompt with current as default
    if [[ -n "$current_gw" ]]; then
      read -r -p "Gateway [${current_gw}]: " gateway
      gateway="${gateway:-$current_gw}"
    else
      read -r -p "Gateway (e.g. 10.10.30.1): " gateway
    fi
    validate_ip "$gateway" || die "Invalid gateway IP: ${gateway}"

    # DNS prompt with current as default
    if [[ -n "$current_dns" ]]; then
      read -r -p "DNS servers (comma-separated) [${current_dns}]: " dns_servers
      dns_servers="${dns_servers:-$current_dns}"
    else
      read -r -p "DNS servers (comma-separated, empty to skip): " dns_servers
    fi
    dns_servers="${dns_servers// /}"
    validate_dns_list "$dns_servers" || die "Invalid DNS server list: ${dns_servers}"
  fi
  export BOOT_CHANGE_IP="${change_ip}"
  export BOOT_STATIC_IP="${static_ip}"
  export BOOT_GATEWAY="${gateway}"
  export BOOT_DNS_SERVERS="${dns_servers}"

  local cloud_init_clean="no"
  if command -v cloud-init &>/dev/null && ask_yes_no "Clean cloud-init state?" "no"; then
    cloud_init_clean="yes"
  fi
  export BOOT_CLOUD_INIT_CLEAN="${cloud_init_clean}"

  # Only offer credential cleanup if we detect a real cloud environment
  # /var/lib/cloud/instances is a reliable indicator that cloud-init ran with a cloud datasource
  local clean_creds="no"
  local is_cloud_vm="no"

  if [[ -d /var/lib/cloud/instances ]] && [[ -n "$(ls -A /var/lib/cloud/instances 2>/dev/null)" ]]; then
    is_cloud_vm="yes"
  fi

  if [[ "$is_cloud_vm" == "yes" ]]; then
    echo ""
    printf '  %s⚠%s  %sCloud environment detected.%s\n' "${YELLOW}" "${RESET}" "${DIM}" "${RESET}"
    if ask_yes_no "Clean cloud credentials (AWS/Azure/GCP)? ${BOLD_YELLOW}(destructive)${RESET}" "no"; then
      # Extra confirmation for dangerous operation
      printf '\n  %sWARNING:%s This will delete:\n' "${BOLD_RED}" "${RESET}"
      printf "    • ~/.aws credentials\n"
      printf "    • Azure waagent configs\n"
      printf "    • GCP gcloud configs\n"
      printf "    • root authorized_keys\n\n"
      if ask_yes_no "Are you SURE? This cannot be undone" "no"; then
        clean_creds="yes"
      fi
    fi
  fi
  export BOOT_CLEAN_CREDS="${clean_creds}"

  local expand_disk="no"
  if ask_yes_no "Expand root filesystem to use all disk space?" "yes"; then
    expand_disk="yes"
  fi
  export BOOT_EXPAND_DISK="${expand_disk}"

  local sysprep="no"
  if ask_yes_no "Clean system state (sysprep: history, logs, temp files)?" "no"; then
    sysprep="yes"
  fi
  export BOOT_SYSPREP="${sysprep}"

  # Show summary and confirm
  print_summary \
    "$BOOT_NEW_HOSTNAME" \
    "$BOOT_CHANGE_IP" \
    "$BOOT_PRIMARY_IF" \
    "$BOOT_STATIC_IP" \
    "$BOOT_GATEWAY" \
    "$BOOT_DNS_SERVERS" \
    "$BOOT_CLOUD_INIT_CLEAN" \
    "$BOOT_EXPAND_DISK" \
    "$BOOT_CLEAN_CREDS" \
    "$virt" \
    "$BOOT_SYSPREP"

  ask_yes_no "Proceed with these changes?" "no" || die "Aborted by user"

  # Re-execute as root with all state passed via environment
  if [[ "${EUID}" -ne 0 ]]; then
    info "Elevating to root..."
    elevate_and_apply
  else
    # Already root, proceed directly to apply
    apply_phase
  fi
}

# ============================================================
# Main - Apply Phase (execute as root)
# ============================================================

apply_phase() {
  require_root

  # Setup logging (only in apply phase)
  setup_logging
  export DEBIAN_FRONTEND=noninteractive

  header "Executing Bootstrap"

  # Execute operations using environment variables
  update_system
  regenerate_ssh_keys
  reset_machine_id
  clean_logs

  [[ "${BOOT_CLOUD_INIT_CLEAN}" == "yes" ]] && clean_cloud_init
  [[ "${BOOT_CLEAN_CREDS}" == "yes" ]] && clean_cloud_credentials
  [[ -n "${BOOT_NEW_HOSTNAME}" ]] && set_hostname "${BOOT_NEW_HOSTNAME}"
  [[ "${BOOT_CHANGE_IP}" == "yes" ]] && configure_static_ip \
    "${BOOT_PRIMARY_IF}" \
    "${BOOT_STATIC_IP}" \
    "${BOOT_GATEWAY}" \
    "${BOOT_DNS_SERVERS}"
  [[ "${BOOT_EXPAND_DISK}" == "yes" ]] && expand_root_filesystem
  [[ "${BOOT_SYSPREP}" == "yes" ]] && clean_system_state

  # Print completion report
  print_final_report

  # Write marker file to indicate bootstrap was completed
  write_bootstrap_marker

  # Final reboot
  echo ""
  printf '%s══════════════════════════════════════════════════════════%s\n' "${BOLD_GREEN}" "${RESET}"
  printf '%s  ✓ Bootstrap complete!%s\n' "${BOLD_GREEN}" "${RESET}"
  printf '%s══════════════════════════════════════════════════════════%s\n' "${BOLD_GREEN}" "${RESET}"
  echo ""
  info "Rebooting in 5 seconds..."

  if [[ "${DRY_RUN}" != "yes" ]]; then
    sleep 5
    reboot
  else
    printf '\n  %s[dry-run]%s Would reboot now\n' "${DIM}" "${RESET}"
  fi
}

# ============================================================
# Entry Point
# ============================================================

main() {
  case "${BOOTSTRAP_PHASE}" in
    interactive)
      interactive_phase
      ;;
    apply)
      apply_phase
      ;;
    *)
      die "Unknown phase: ${BOOTSTRAP_PHASE}"
      ;;
  esac
}

main "$@"
