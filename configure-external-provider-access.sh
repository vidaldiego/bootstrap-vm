#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

PUBLIC_KEY_FILE="${ARCHON_PUBLIC_KEY_FILE:-}"
EXPECTED_FINGERPRINT="${ARCHON_PUBLIC_KEY_FINGERPRINT:-}"
VAULT_TRUST_SCRIPT="${VAULT_TRUST_SCRIPT:-${SCRIPT_DIR}/configure-vault-trust.sh}"
SKIP_VAULT_TRUST=false
readonly ADMIN_USER="sysadmin"
readonly AUTHORIZED_KEYS_FILE=".ssh/authorized_keys"

usage() {
  cat <<'EOF'
Usage: sudo ./configure-external-provider-access.sh [options]

Prepare an Ubuntu guest for human ZnVault-CA access and Archon automation.
The script is idempotent and never disables the provider's root/break-glass path.

Options:
  --public-key-file PATH       Archon automation public key file (required)
  --expected-fingerprint FP   Require this SHA256 public-key fingerprint
  --vault-trust-script PATH   Local configure-vault-trust.sh to execute
  --skip-vault-trust          Keep existing ZnVault CA/PKI configuration
  -h, --help                  Show this help

Environment equivalents:
  ARCHON_PUBLIC_KEY_FILE, ARCHON_PUBLIC_KEY_FINGERPRINT, VAULT_TRUST_SCRIPT
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[external-provider-access] %s\n' "$*"
}

while (($#)); do
  case "$1" in
    --public-key-file)
      (($# >= 2)) || die "--public-key-file requires a path"
      PUBLIC_KEY_FILE="$2"
      shift 2
      ;;
    --expected-fingerprint)
      (($# >= 2)) || die "--expected-fingerprint requires a value"
      EXPECTED_FINGERPRINT="$2"
      shift 2
      ;;
    --vault-trust-script)
      (($# >= 2)) || die "--vault-trust-script requires a path"
      VAULT_TRUST_SCRIPT="$2"
      shift 2
      ;;
    --skip-vault-trust)
      SKIP_VAULT_TRUST=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "run as root (sudo $0)"
[[ -n "${PUBLIC_KEY_FILE}" ]] || die "set --public-key-file or ARCHON_PUBLIC_KEY_FILE"
[[ -r "${PUBLIC_KEY_FILE}" ]] || die "public key is not readable: ${PUBLIC_KEY_FILE}"

for command_name in getent install ssh-keygen useradd usermod visudo; do
  command -v "${command_name}" >/dev/null 2>&1 || die "required command not found: ${command_name}"
done

key_line_count="$(grep -Ec '^(ssh-|ecdsa-)' "${PUBLIC_KEY_FILE}" || true)"
[[ ${key_line_count} -eq 1 ]] || die "public-key file must contain exactly one OpenSSH public key"

actual_fingerprint="$(ssh-keygen -lf "${PUBLIC_KEY_FILE}" -E sha256 | awk 'NR == 1 { print $2 }')"
[[ -n "${actual_fingerprint}" ]] || die "could not calculate public-key fingerprint"
if [[ -n "${EXPECTED_FINGERPRINT}" && "${actual_fingerprint}" != "${EXPECTED_FINGERPRINT}" ]]; then
  die "public-key fingerprint does not match the approved identity"
fi
log "validated Archon public key ${actual_fingerprint}"

if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${ADMIN_USER}"
  log "created ${ADMIN_USER}"
fi

supplementary_groups=()
for group_name in adm sudo; do
  if getent group "${group_name}" >/dev/null 2>&1; then
    supplementary_groups+=("${group_name}")
  fi
done
if ((${#supplementary_groups[@]})); then
  group_csv="$(IFS=,; printf '%s' "${supplementary_groups[*]}")"
  usermod --append --groups "${group_csv}" "${ADMIN_USER}"
fi

sudoers_source="${SCRIPT_DIR}/assets/90-sysadmin"
[[ -r "${sudoers_source}" ]] || die "sudoers asset is not readable: ${sudoers_source}"
visudo -cf "${sudoers_source}" >/dev/null
install -d -o root -g root -m 0755 /etc/sudoers.d
install -o root -g root -m 0440 "${sudoers_source}" /etc/sudoers.d/90-sysadmin
visudo -cf /etc/sudoers.d/90-sysadmin >/dev/null
log "installed validated sysadmin sudo policy"

if [[ "${SKIP_VAULT_TRUST}" == false ]]; then
  [[ -r "${VAULT_TRUST_SCRIPT}" ]] || die "local Vault trust script is not readable: ${VAULT_TRUST_SCRIPT}"
  log "configuring ZnVault SSH CA and PKI trust from local reviewed script"
  bash "${VAULT_TRUST_SCRIPT}"
fi

admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
[[ -n "${admin_home}" ]] || die "could not resolve ${ADMIN_USER} home directory"
install -d -o "${ADMIN_USER}" -g "${ADMIN_USER}" -m 0700 "${admin_home}/.ssh"
touch "${admin_home}/${AUTHORIZED_KEYS_FILE}"
chown "${ADMIN_USER}:${ADMIN_USER}" "${admin_home}/${AUTHORIZED_KEYS_FILE}"
chmod 0600 "${admin_home}/${AUTHORIZED_KEYS_FILE}"

approved_key="$(grep -E '^(ssh-|ecdsa-)' "${PUBLIC_KEY_FILE}")"
if ! grep -qxF "${approved_key}" "${admin_home}/${AUTHORIZED_KEYS_FILE}"; then
  if [[ -s "${admin_home}/${AUTHORIZED_KEYS_FILE}" ]] &&
     [[ -n "$(tail -c1 "${admin_home}/${AUTHORIZED_KEYS_FILE}")" ]]; then
    printf '\n' >> "${admin_home}/${AUTHORIZED_KEYS_FILE}"
  fi
  printf '%s\n' "${approved_key}" >> "${admin_home}/${AUTHORIZED_KEYS_FILE}"
  log "appended Archon key without replacing existing recovery keys"
else
  log "Archon key is already present"
fi

sshd_config_files=(/etc/ssh/sshd_config)
shopt -s nullglob
sshd_config_files+=(/etc/ssh/sshd_config.d/*.conf)
shopt -u nullglob
for sshd_config_file in "${sshd_config_files[@]}"; do
  [[ -f "${sshd_config_file}" ]] || continue
  if grep -Eq '^[[:space:]]*AuthorizedKeysFile[[:space:]]+none([[:space:]]*(#.*)?)?$' "${sshd_config_file}"; then
    backup_file="${sshd_config_file}.pre-archon-external-cloud-v1"
    [[ -e "${backup_file}" ]] || cp -a -- "${sshd_config_file}" "${backup_file}"
    sed -Ei 's|^[[:space:]]*AuthorizedKeysFile[[:space:]]+none([[:space:]]*(#.*)?)?$|AuthorizedKeysFile .ssh/authorized_keys|' "${sshd_config_file}"
    log "enabled authorized_keys in ${sshd_config_file}; backup: ${backup_file}"
  fi
done

sshd_binary="$(command -v sshd || true)"
[[ -n "${sshd_binary}" ]] || sshd_binary=/usr/sbin/sshd
[[ -x "${sshd_binary}" ]] || die "sshd binary not found"
"${sshd_binary}" -t

if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
  log "reloaded OpenSSH after a successful configuration test"
else
  die "OpenSSH configuration is valid but the service could not be reloaded"
fi

log "access baseline ready; provider root/break-glass access was not changed"
printf '\nVerification (from approved clients):\n'
printf '  znvault ssh connect sysadmin@<management-address>\n'
printf '  Archon: sync inventory, assign the automation identity, then run SSH health\n'
