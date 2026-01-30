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
#   - Unattended-upgrades management (disable or set window)
#   - IP shorthand input (.25 for last octet change)
#   - IP availability check via ping
#   - ZnVault SSH CA integration (certificate-based SSH auth)
#   - ZnVault PKI CA trust (add root CA to system store)
#
# ZnVault Configuration:
#   VAULT_URL    - Vault server URL (default: https://vault.zincapp.com)
#   VAULT_TENANT - Tenant for SSH CA (default: root)
# ============================================================

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="2.3.1"
readonly BOOTSTRAP_MARKER="/etc/bootstrap-done"
readonly GITHUB_REPO="vidaldiego/bootstrap-vm"

# ZnVault configuration
readonly VAULT_URL="${VAULT_URL:-https://vault.zincapp.com}"
readonly VAULT_TENANT="${VAULT_TENANT:-zincapp}"

# Preserve timestamp/logfile across phases
readonly TIMESTAMP="${BOOT_TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
readonly LOGFILE="${BOOT_LOGFILE:-/var/log/bootstrap-${TIMESTAMP}.log}"

# Runtime flags (can be overridden via environment)
DRY_RUN="${DRY_RUN:-no}"
FORCE="${FORCE:-no}"
FORCE_RERUN="${FORCE_RERUN:-no}"

# Two-phase execution: "interactive" (collect input) or "apply" (execute as root)
BOOTSTRAP_PHASE="${BOOTSTRAP_PHASE:-interactive}"

# CLI mode flag (set when any CLI args are provided)
CLI_MODE="${CLI_MODE:-no}"

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
    CLI_MODE="${CLI_MODE}" \
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
    BOOT_UNATTENDED_ACTION="${BOOT_UNATTENDED_ACTION:-none}" \
    BOOT_UNATTENDED_WINDOW="${BOOT_UNATTENDED_WINDOW:-}" \
    BOOT_SSH_CA="${BOOT_SSH_CA:-no}" \
    BOOT_PKI_CA="${BOOT_PKI_CA:-no}" \
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
# CLI Argument Parsing
# ============================================================

show_help() {
  cat <<EOF
${BOLD}Ubuntu VM Bootstrap v${SCRIPT_VERSION}${RESET}

${BOLD}USAGE:${RESET}
    ${SCRIPT_NAME} [OPTIONS]

    Without options, runs in interactive mode.
    With options, runs in non-interactive CLI mode.

${BOLD}OPTIONS:${RESET}
    ${BOLD}Required in CLI mode:${RESET}
    -H, --hostname NAME       Set the hostname

    ${BOLD}Network configuration:${RESET}
    -i, --static-ip CIDR      Static IP with subnet (e.g., 10.10.30.50/24)
    -g, --gateway IP          Gateway address (auto-detected from current config)
    -d, --dns SERVERS         Comma-separated DNS servers (auto-detected from current config)
    -I, --interface IF        Network interface (auto-detected if omitted)

    ${BOLD}Disk and system:${RESET}
    --expand-disk             Expand root filesystem (default in CLI mode)
    --no-expand-disk          Skip disk expansion
    --sysprep                 Clean system state (history, logs, temp files)
    --cloud-init-clean        Clean cloud-init state
    --clean-creds             Clean cloud credentials (AWS/Azure/GCP)

    ${BOLD}Updates:${RESET}
    --disable-updates         Disable unattended-upgrades
    --update-window HH:MM     Set maintenance window (e.g., 04:00)

    ${BOLD}ZnVault integration:${RESET}
    --ssh-ca                  Configure SSH CA trust (default in CLI mode)
    --no-ssh-ca               Skip SSH CA configuration
    --pki-ca                  Add PKI root CA to trust store (default in CLI mode)
    --no-pki-ca               Skip PKI CA configuration

    ${BOLD}General:${RESET}
    -y, --yes                 Skip confirmation prompts
    -n, --dry-run             Show what would be done without making changes
    --force-rerun             Allow re-running on already bootstrapped machine
    -h, --help                Show this help message
    -v, --version             Show version

${BOLD}ENVIRONMENT VARIABLES:${RESET}
    VAULT_URL                 Vault server URL (default: https://vault.zincapp.com)
    VAULT_TENANT              Tenant for SSH CA (default: zincapp)
    DRY_RUN=yes               Same as --dry-run
    FORCE=yes                 Same as --yes
    FORCE_RERUN=yes           Same as --force-rerun

${BOLD}EXAMPLES:${RESET}
    # Interactive mode (prompts for all values)
    ${SCRIPT_NAME}

    # Minimal CLI mode (hostname only, defaults for everything else)
    ${SCRIPT_NAME} --hostname myserver

    # Full CLI mode with static IP
    ${SCRIPT_NAME} --hostname myserver --static-ip 10.10.30.50/24 --gateway 10.10.30.1

    # Via curl installer with arguments
    curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | bash -s -- --hostname myserver

    # Dry-run to preview changes
    ${SCRIPT_NAME} --hostname myserver --dry-run

EOF
}

show_version() {
  echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
}

parse_args() {
  # If no arguments, stay in interactive mode
  [[ $# -eq 0 ]] && return 0

  # Track if we've seen any "real" options (not just -h or -v)
  local has_config_args="no"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -H|--hostname)
        [[ -z "${2:-}" ]] && die "Option $1 requires an argument"
        BOOT_NEW_HOSTNAME="$2"
        has_config_args="yes"
        shift 2
        ;;
      -i|--static-ip)
        [[ -z "${2:-}" ]] && die "Option $1 requires an argument"
        CLI_STATIC_IP="$2"
        BOOT_CHANGE_IP="yes"
        has_config_args="yes"
        shift 2
        ;;
      -g|--gateway)
        [[ -z "${2:-}" ]] && die "Option $1 requires an argument"
        BOOT_GATEWAY="$2"
        has_config_args="yes"
        shift 2
        ;;
      -d|--dns)
        [[ -z "${2:-}" ]] && die "Option $1 requires an argument"
        BOOT_DNS_SERVERS="$2"
        has_config_args="yes"
        shift 2
        ;;
      -I|--interface)
        [[ -z "${2:-}" ]] && die "Option $1 requires an argument"
        BOOT_PRIMARY_IF="$2"
        has_config_args="yes"
        shift 2
        ;;
      --expand-disk)
        BOOT_EXPAND_DISK="yes"
        has_config_args="yes"
        shift
        ;;
      --no-expand-disk)
        BOOT_EXPAND_DISK="no"
        has_config_args="yes"
        shift
        ;;
      --sysprep)
        BOOT_SYSPREP="yes"
        has_config_args="yes"
        shift
        ;;
      --cloud-init-clean)
        BOOT_CLOUD_INIT_CLEAN="yes"
        has_config_args="yes"
        shift
        ;;
      --clean-creds)
        BOOT_CLEAN_CREDS="yes"
        has_config_args="yes"
        shift
        ;;
      --disable-updates)
        BOOT_UNATTENDED_ACTION="disable"
        has_config_args="yes"
        shift
        ;;
      --update-window)
        [[ -z "${2:-}" ]] && die "Option $1 requires an argument"
        BOOT_UNATTENDED_ACTION="window"
        BOOT_UNATTENDED_WINDOW="$2"
        has_config_args="yes"
        shift 2
        ;;
      --ssh-ca)
        BOOT_SSH_CA="yes"
        has_config_args="yes"
        shift
        ;;
      --no-ssh-ca)
        BOOT_SSH_CA="no"
        has_config_args="yes"
        shift
        ;;
      --pki-ca)
        BOOT_PKI_CA="yes"
        has_config_args="yes"
        shift
        ;;
      --no-pki-ca)
        BOOT_PKI_CA="no"
        has_config_args="yes"
        shift
        ;;
      -y|--yes)
        FORCE="yes"
        shift
        ;;
      -n|--dry-run)
        DRY_RUN="yes"
        shift
        ;;
      --force-rerun)
        FORCE_RERUN="yes"
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      -v|--version)
        show_version
        exit 0
        ;;
      -*)
        die "Unknown option: $1 (use --help for usage)"
        ;;
      *)
        die "Unexpected argument: $1 (use --help for usage)"
        ;;
    esac
  done

  # If we parsed config arguments, switch to CLI mode
  if [[ "$has_config_args" == "yes" ]]; then
    CLI_MODE="yes"
  fi
}

# Set CLI mode defaults (called after parse_args if in CLI mode)
apply_cli_defaults() {
  # These default to "yes" in CLI mode if not explicitly set
  BOOT_EXPAND_DISK="${BOOT_EXPAND_DISK:-yes}"
  BOOT_SSH_CA="${BOOT_SSH_CA:-yes}"
  BOOT_PKI_CA="${BOOT_PKI_CA:-yes}"

  # These default to "no" in CLI mode if not explicitly set
  BOOT_CHANGE_IP="${BOOT_CHANGE_IP:-no}"
  BOOT_CLOUD_INIT_CLEAN="${BOOT_CLOUD_INIT_CLEAN:-no}"
  BOOT_CLEAN_CREDS="${BOOT_CLEAN_CREDS:-no}"
  BOOT_SYSPREP="${BOOT_SYSPREP:-no}"
  BOOT_UNATTENDED_ACTION="${BOOT_UNATTENDED_ACTION:-none}"
  BOOT_UNATTENDED_WINDOW="${BOOT_UNATTENDED_WINDOW:-}"
}

# Validate CLI arguments
validate_cli_args() {
  # Hostname is required in CLI mode
  if [[ -z "${BOOT_NEW_HOSTNAME:-}" ]]; then
    die "Hostname is required in CLI mode. Use --hostname NAME"
  fi

  if ! validate_hostname "$BOOT_NEW_HOSTNAME"; then
    die "Invalid hostname: $BOOT_NEW_HOSTNAME"
  fi

  # If static IP is requested, validate network settings
  if [[ "${BOOT_CHANGE_IP}" == "yes" ]]; then
    # Auto-detect interface if not specified
    if [[ -z "${BOOT_PRIMARY_IF:-}" ]]; then
      BOOT_PRIMARY_IF="$(detect_primary_interface)"
      [[ -z "$BOOT_PRIMARY_IF" ]] && die "Could not auto-detect network interface. Use --interface"
    fi

    # Expand and validate static IP
    if [[ -n "${CLI_STATIC_IP:-}" ]]; then
      local current_ip
      current_ip="$(detect_current_ip "$BOOT_PRIMARY_IF")"

      # Expand shorthand notation
      BOOT_STATIC_IP="$(expand_ip_input "$CLI_STATIC_IP" "${current_ip:-0.0.0.0/24}")"
      if [[ -z "$BOOT_STATIC_IP" ]] || ! validate_cidr "$BOOT_STATIC_IP"; then
        die "Invalid static IP: $CLI_STATIC_IP"
      fi
    fi

    # Auto-detect gateway if not provided
    if [[ -z "${BOOT_GATEWAY:-}" ]]; then
      BOOT_GATEWAY="$(detect_current_gateway)"
      if [[ -z "$BOOT_GATEWAY" ]]; then
        die "Could not auto-detect gateway. Use --gateway IP"
      fi
      info "Auto-detected gateway: ${CYAN}${BOOT_GATEWAY}${RESET}"
    fi

    if ! validate_ip "$BOOT_GATEWAY"; then
      die "Invalid gateway: $BOOT_GATEWAY"
    fi

    # Auto-detect DNS if not provided
    if [[ -z "${BOOT_DNS_SERVERS:-}" ]]; then
      BOOT_DNS_SERVERS="$(detect_current_dns "$BOOT_PRIMARY_IF")"
      if [[ -n "$BOOT_DNS_SERVERS" ]]; then
        info "Auto-detected DNS: ${CYAN}${BOOT_DNS_SERVERS}${RESET}"
      fi
    fi

    # Validate DNS if provided (auto-detected or explicit)
    if [[ -n "${BOOT_DNS_SERVERS:-}" ]] && ! validate_dns_list "$BOOT_DNS_SERVERS"; then
      die "Invalid DNS servers: $BOOT_DNS_SERVERS"
    fi
  fi

  # Validate update window format if specified
  if [[ "${BOOT_UNATTENDED_ACTION}" == "window" ]]; then
    if [[ -z "${BOOT_UNATTENDED_WINDOW:-}" ]]; then
      die "Update window time required with --update-window"
    fi
    if [[ ! "$BOOT_UNATTENDED_WINDOW" =~ ^[0-2]?[0-9]:[0-5][0-9]$ ]]; then
      die "Invalid update window format: $BOOT_UNATTENDED_WINDOW (use HH:MM)"
    fi
  fi
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

# Expand IP shorthand notation relative to current IP
# Supports:
#   - Full CIDR: "10.10.30.50/24" -> unchanged
#   - IP only: "10.10.30.50" -> adds subnet from current_ip
#   - Last octet: ".50" -> replaces last octet, keeps subnet
#   - Last two octets: ".30.50" -> replaces last two octets, keeps subnet
expand_ip_input() {
  local input="$1"
  local current_ip="$2"  # Current IP in CIDR format (e.g., 172.16.220.217/24)

  # Extract parts from current IP
  local current_addr="${current_ip%/*}"
  local current_mask="${current_ip#*/}"

  # If input already has subnet, validate and return as-is
  if [[ "$input" == */* ]]; then
    echo "$input"
    return 0
  fi

  # If input starts with ".", it's a shorthand
  if [[ "$input" == .* ]]; then
    # Count the dots to determine how many octets to replace
    local dot_count="${input//[^.]/}"
    dot_count="${#dot_count}"

    local IFS='.'
    local -a current_octets
    read -r -a current_octets <<< "$current_addr"

    # Remove leading dot and split
    local shorthand="${input#.}"
    local -a new_octets
    read -r -a new_octets <<< "$shorthand"

    case "$dot_count" in
      1)
        # .50 -> replace last octet
        echo "${current_octets[0]}.${current_octets[1]}.${current_octets[2]}.${new_octets[0]}/${current_mask}"
        ;;
      2)
        # .30.50 -> replace last two octets
        echo "${current_octets[0]}.${current_octets[1]}.${new_octets[0]}.${new_octets[1]}/${current_mask}"
        ;;
      3)
        # .10.30.50 -> replace last three octets
        echo "${current_octets[0]}.${new_octets[0]}.${new_octets[1]}.${new_octets[2]}/${current_mask}"
        ;;
      *)
        # Invalid shorthand
        echo ""
        return 1
        ;;
    esac
    return 0
  fi

  # Full IP without subnet - add current subnet
  if validate_ip "$input"; then
    echo "${input}/${current_mask}"
    return 0
  fi

  # Invalid input
  echo ""
  return 1
}

# Check if an IP is reachable (already in use)
check_ip_available() {
  local ip="$1"
  local addr="${ip%/*}"

  # Quick ping with 1 second timeout, 2 attempts
  if ping -c 2 -W 1 "$addr" &>/dev/null; then
    return 1  # IP responds, NOT available
  else
    return 0  # IP doesn't respond, available (or unreachable)
  fi
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

configure_unattended_upgrades() {
  local action="$1"
  local window="${2:-}"

  step "Configuring unattended-upgrades"

  local apt_conf="/etc/apt/apt.conf.d/20auto-upgrades"
  local unattended_conf="/etc/apt/apt.conf.d/50unattended-upgrades"

  if [[ "$action" == "disable" ]]; then
    info "Disabling automatic updates..."
    if [[ "${DRY_RUN}" != "yes" ]]; then
      # Disable automatic updates
      cat > "${apt_conf}" <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
EOF
      # Also disable the timers if they exist
      systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
      systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    else
      printf '  %s[dry-run]%s Would disable unattended-upgrades\n' "${DIM}" "${RESET}"
    fi
    success "Automatic updates disabled"

  elif [[ "$action" == "window" && -n "$window" ]]; then
    info "Setting maintenance window to: ${window}"

    # Ensure unattended-upgrades is installed
    run apt-get -y install unattended-upgrades || warn "Failed to install unattended-upgrades"

    if [[ "${DRY_RUN}" != "yes" ]]; then
      # Enable automatic updates
      cat > "${apt_conf}" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

      # Configure the maintenance window
      # Create or update the configuration
      if [[ -f "${unattended_conf}" ]]; then
        # Update existing config - set OnlyOnACPower and add time window
        if grep -q '^//Unattended-Upgrade::OnlyOnACPower' "${unattended_conf}"; then
          sed -i 's|^//Unattended-Upgrade::OnlyOnACPower.*|Unattended-Upgrade::OnlyOnACPower "false";|' "${unattended_conf}"
        elif ! grep -q '^Unattended-Upgrade::OnlyOnACPower' "${unattended_conf}"; then
          echo 'Unattended-Upgrade::OnlyOnACPower "false";' >> "${unattended_conf}"
        fi
      fi

      # Configure the systemd timer to run at the specified time
      local timer_override_dir="/etc/systemd/system/apt-daily-upgrade.timer.d"
      mkdir -p "${timer_override_dir}"
      cat > "${timer_override_dir}/override.conf" <<EOF
[Timer]
OnCalendar=
OnCalendar=*-*-* ${window}
RandomizedDelaySec=0
EOF
      systemctl daemon-reload
      systemctl enable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    else
      printf '  %s[dry-run]%s Would set maintenance window to %s\n' "${DIM}" "${RESET}" "${window}"
    fi
    success "Maintenance window configured: ${window}"
  fi
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

# ============================================================
# ZnVault Integration
# ============================================================

configure_ssh_ca() {
  step "Configuring SSH Certificate Authority trust"

  local ca_url="${VAULT_URL}/v1/ssh/ca/${VAULT_TENANT}/public-key/raw"
  local ca_file="/etc/ssh/trusted-user-ca-keys.pub"
  local principals_dir="/etc/ssh/auth_principals"

  info "Fetching CA public key from ${DIM}${ca_url}${RESET}"

  if [[ "${DRY_RUN}" != "yes" ]]; then
    # Fetch CA public key (allow self-signed certs with -k if needed)
    if ! curl -fsSL -k "${ca_url}" -o "${ca_file}"; then
      warn "Failed to fetch SSH CA public key from vault"
      warn "SSH certificate authentication will not be configured"
      return 0
    fi

    # Validate the key was fetched
    if ! grep -q "^ssh-" "${ca_file}"; then
      warn "Invalid SSH CA public key received"
      rm -f "${ca_file}"
      return 0
    fi

    chmod 644 "${ca_file}"
    info "CA public key saved to ${DIM}${ca_file}${RESET}"

    # Create principals directory
    mkdir -p "${principals_dir}"

    # Configure which principals can access sysadmin
    # "admin" principal = full access (matches infrastructure group mapping)
    echo "admin" > "${principals_dir}/sysadmin"
    chmod 644 "${principals_dir}/sysadmin"
    info "Configured principal 'admin' for user 'sysadmin'"

    # Update sshd_config if not already configured
    if ! grep -q "TrustedUserCAKeys" /etc/ssh/sshd_config; then
      cat >> /etc/ssh/sshd_config <<'EOF'

# ZnVault SSH Certificate Authority
TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pub
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
EOF
      info "Updated sshd_config with CA trust settings"
    else
      info "sshd_config already has TrustedUserCAKeys configured"
    fi

    # Restart SSH to apply changes
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  else
    printf '  %s[dry-run]%s Would fetch SSH CA key and configure sshd\n' "${DIM}" "${RESET}"
  fi

  success "SSH CA trust configured"
}

configure_vault_pki_ca() {
  step "Adding ZnVault PKI root CA to system trust store"

  local ca_url="${VAULT_URL}/v1/pki/root-ca/cert"
  local ca_file="/usr/local/share/ca-certificates/znvault-root-ca.crt"

  info "Fetching PKI root CA from ${DIM}${ca_url}${RESET}"

  if [[ "${DRY_RUN}" != "yes" ]]; then
    # Ensure ca-certificates directory exists
    mkdir -p /usr/local/share/ca-certificates

    # Fetch root CA certificate (allow self-signed with -k for initial bootstrap)
    if ! curl -fsSL -k "${ca_url}" -o "${ca_file}"; then
      warn "Failed to fetch PKI root CA from vault"
      warn "Vault CA will not be added to system trust store"
      return 0
    fi

    # Validate it looks like a certificate
    if ! grep -q "BEGIN CERTIFICATE" "${ca_file}"; then
      warn "Invalid certificate received from vault"
      rm -f "${ca_file}"
      return 0
    fi

    chmod 644 "${ca_file}"
    info "Root CA saved to ${DIM}${ca_file}${RESET}"

    # Update system CA trust store
    update-ca-certificates || warn "update-ca-certificates failed"
  else
    printf '  %s[dry-run]%s Would fetch PKI CA and update system trust store\n' "${DIM}" "${RESET}"
  fi

  success "ZnVault PKI CA added to system trust store"
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

  # ZnVault integration status
  if [[ -f /etc/ssh/trusted-user-ca-keys.pub ]]; then
    printf "  %sSSH CA:%s       %s✓ Configured%s (cert auth enabled)\n" "${BOLD}" "${RESET}" "${GREEN}" "${RESET}"
  fi
  if [[ -f /usr/local/share/ca-certificates/znvault-root-ca.crt ]]; then
    printf "  %sVault PKI:%s    %s✓ Trusted%s (root CA installed)\n" "${BOLD}" "${RESET}" "${GREEN}" "${RESET}"
  fi
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
  local unattended_action="${12:-none}"
  local unattended_window="${13:-}"
  local ssh_ca="${14:-no}"
  local pki_ca="${15:-no}"

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
  if [[ "$unattended_action" == "disable" ]]; then
    printf "    %s✓%s Disable automatic updates\n" "${GREEN}" "${RESET}"
  elif [[ "$unattended_action" == "window" ]]; then
    printf "    %s✓%s Set updates window: %s\n" "${GREEN}" "${RESET}" "${unattended_window}"
  fi
  [[ "$sysprep" == "yes" ]] && printf "    %s✓%s Clean system state (sysprep)\n" "${GREEN}" "${RESET}"

  # ZnVault integration
  if [[ "$ssh_ca" == "yes" || "$pki_ca" == "yes" ]]; then
    echo ""
    printf "    %s── ZnVault Integration ──%s\n" "${DIM}" "${RESET}"
    [[ "$ssh_ca" == "yes" ]] && printf "    %s✓%s Configure SSH CA trust (${VAULT_TENANT}@${VAULT_URL})\n" "${GREEN}" "${RESET}"
    [[ "$pki_ca" == "yes" ]] && printf "    %s✓%s Add PKI root CA to system trust\n" "${GREEN}" "${RESET}"
  fi

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
  while true; do
    read -r -p "New hostname: " new_hostname
    if [[ -z "$new_hostname" ]]; then
      warn "Hostname is required"
      continue
    fi
    if validate_hostname "$new_hostname"; then
      break
    fi
    warn "Invalid hostname format. Use letters, numbers, hyphens (max 63 chars, no leading/trailing hyphen)"
  done
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

    # Static IP prompt with current as default and shorthand support
    while true; do
      if [[ -n "$current_ip" ]]; then
        info "Shortcuts: .25 = change last octet, .30.25 = change last two, or full IP"
        read -r -p "Static IP [${current_ip}]: " static_ip
        if [[ -z "$static_ip" ]]; then
          static_ip="$current_ip"
        else
          # Expand shorthand notation
          local expanded
          expanded="$(expand_ip_input "$static_ip" "$current_ip")"
          if [[ -n "$expanded" ]]; then
            static_ip="$expanded"
          fi
        fi
      else
        read -r -p "Static IP (CIDR format, e.g. 10.10.30.50/24): " static_ip
      fi

      if ! validate_cidr "$static_ip"; then
        warn "Invalid IP format. Use: full CIDR (10.10.30.50/24), IP only (10.10.30.50), or shorthand (.50)"
        continue
      fi

      # Check if IP is already in use (skip if it's the current IP)
      local new_addr="${static_ip%/*}"
      local current_addr="${current_ip%/*}"
      if [[ "$new_addr" != "$current_addr" ]]; then
        info "Checking if ${new_addr} is available..."
        if ! check_ip_available "$static_ip"; then
          printf '  %s⚠%s  %sWarning: %s responds to ping (may be in use)%s\n' "${YELLOW}" "${RESET}" "${BOLD_YELLOW}" "${new_addr}" "${RESET}"
          if ! ask_yes_no "Continue anyway?" "no"; then
            continue
          fi
        else
          success "IP ${new_addr} appears to be available"
        fi
      fi
      break
    done

    # Gateway prompt with current as default
    while true; do
      if [[ -n "$current_gw" ]]; then
        read -r -p "Gateway [${current_gw}]: " gateway
        gateway="${gateway:-$current_gw}"
      else
        read -r -p "Gateway (e.g. 10.10.30.1): " gateway
      fi
      if validate_ip "$gateway"; then
        break
      fi
      warn "Invalid gateway IP. Use format like 10.10.30.1"
    done

    # DNS prompt with current as default
    while true; do
      if [[ -n "$current_dns" ]]; then
        read -r -p "DNS servers (comma-separated) [${current_dns}]: " dns_servers
        dns_servers="${dns_servers:-$current_dns}"
      else
        read -r -p "DNS servers (comma-separated, empty to skip): " dns_servers
      fi
      dns_servers="${dns_servers// /}"
      if validate_dns_list "$dns_servers"; then
        break
      fi
      warn "Invalid DNS server list. Use comma-separated IPs like 8.8.8.8,1.1.1.1"
    done
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

  # Unattended upgrades configuration
  local unattended_action="none"
  local unattended_window=""
  if ask_yes_no "Disable Ubuntu unattended (automatic) updates?" "no"; then
    unattended_action="disable"
  else
    if ask_yes_no "Change the automatic updates maintenance window?" "no"; then
      unattended_action="window"
      # Show current timer schedule
      local current_schedule=""
      if systemctl is-active apt-daily-upgrade.timer &>/dev/null; then
        current_schedule="$(systemctl show apt-daily-upgrade.timer --property=TimersCalendar 2>/dev/null | cut -d= -f2 | head -1 || true)"
      fi
      if [[ -n "$current_schedule" ]]; then
        info "Current schedule: ${current_schedule}"
      fi
      while true; do
        read -r -p "Maintenance window (24h format, e.g., 04:00 for 4 AM): " unattended_window
        if [[ "$unattended_window" =~ ^[0-2]?[0-9]:[0-5][0-9]$ ]]; then
          break
        fi
        warn "Invalid time format. Use HH:MM (24-hour format), e.g., 04:00 or 23:30"
      done
    fi
  fi
  export BOOT_UNATTENDED_ACTION="${unattended_action}"
  export BOOT_UNATTENDED_WINDOW="${unattended_window}"

  local sysprep="no"
  if ask_yes_no "Clean system state (sysprep: history, logs, temp files)?" "no"; then
    sysprep="yes"
  fi
  export BOOT_SYSPREP="${sysprep}"

  # ZnVault integration
  echo ""
  printf '  %s── ZnVault Integration ──%s\n\n' "${BOLD_CYAN}" "${RESET}"

  local configure_ssh_ca="no"
  if ask_yes_no "Configure SSH CA trust (certificate-based SSH auth via ZnVault)?" "yes"; then
    configure_ssh_ca="yes"
  fi
  export BOOT_SSH_CA="${configure_ssh_ca}"

  local configure_pki_ca="no"
  if ask_yes_no "Add ZnVault PKI root CA to system trust store?" "yes"; then
    configure_pki_ca="yes"
  fi
  export BOOT_PKI_CA="${configure_pki_ca}"

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
    "$BOOT_SYSPREP" \
    "$BOOT_UNATTENDED_ACTION" \
    "$BOOT_UNATTENDED_WINDOW" \
    "$BOOT_SSH_CA" \
    "$BOOT_PKI_CA"

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
  [[ "${BOOT_UNATTENDED_ACTION}" != "none" ]] && configure_unattended_upgrades \
    "${BOOT_UNATTENDED_ACTION}" \
    "${BOOT_UNATTENDED_WINDOW}"
  [[ "${BOOT_SYSPREP}" == "yes" ]] && clean_system_state

  # ZnVault integration
  [[ "${BOOT_SSH_CA}" == "yes" ]] && configure_ssh_ca
  [[ "${BOOT_PKI_CA}" == "yes" ]] && configure_vault_pki_ca

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
# Main - CLI Phase (non-interactive)
# ============================================================

cli_phase() {
  header "Ubuntu VM Bootstrap v${SCRIPT_VERSION} (CLI Mode)"

  [[ "${DRY_RUN}" == "yes" ]] && printf '  %s⚠  Running in DRY-RUN mode%s\n\n' "${BOLD_YELLOW}" "${RESET}"

  # Check if bootstrap was already run on this machine
  check_previous_run

  # Auto-detect interface if not specified
  if [[ -z "${BOOT_PRIMARY_IF:-}" ]]; then
    BOOT_PRIMARY_IF="$(detect_primary_interface)"
  fi

  local virt
  virt="$(detect_virtualization)"

  info "Detected interface: ${CYAN}${BOOT_PRIMARY_IF:-none}${RESET}"
  info "Detected environment: ${CYAN}${virt}${RESET}"
  echo ""

  # Apply defaults for unspecified options
  apply_cli_defaults

  # Validate all CLI arguments
  validate_cli_args

  # Show summary
  print_summary \
    "$BOOT_NEW_HOSTNAME" \
    "$BOOT_CHANGE_IP" \
    "$BOOT_PRIMARY_IF" \
    "${BOOT_STATIC_IP:-}" \
    "${BOOT_GATEWAY:-}" \
    "${BOOT_DNS_SERVERS:-}" \
    "$BOOT_CLOUD_INIT_CLEAN" \
    "$BOOT_EXPAND_DISK" \
    "$BOOT_CLEAN_CREDS" \
    "$virt" \
    "$BOOT_SYSPREP" \
    "$BOOT_UNATTENDED_ACTION" \
    "$BOOT_UNATTENDED_WINDOW" \
    "$BOOT_SSH_CA" \
    "$BOOT_PKI_CA"

  # Confirm unless --yes was passed
  ask_yes_no "Proceed with these changes?" "no" || die "Aborted by user"

  # Re-execute as root with all state passed via environment
  if [[ "${EUID}" -ne 0 ]]; then
    info "Elevating to root..."
    elevate_and_apply
  else
    apply_phase
  fi
}

# ============================================================
# Entry Point
# ============================================================

main() {
  # Parse command line arguments first (before phase check)
  # Skip parsing if we're in apply phase (already parsed in interactive/cli phase)
  if [[ "${BOOTSTRAP_PHASE}" == "interactive" ]]; then
    parse_args "$@"
  fi

  case "${BOOTSTRAP_PHASE}" in
    interactive)
      if [[ "${CLI_MODE}" == "yes" ]]; then
        cli_phase
      else
        interactive_phase
      fi
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
