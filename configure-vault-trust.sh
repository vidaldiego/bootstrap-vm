#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Configure ZnVault Trust
# ============================================================
# Adds ZnVault SSH CA and PKI CA trust to an existing VM.
# Safe to run on already-bootstrapped machines.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/configure-vault-trust.sh | sudo bash
#
# Or with custom vault URL:
#   VAULT_URL=https://vault.example.com VAULT_TENANT=mytenant sudo ./configure-vault-trust.sh
# ============================================================

readonly VAULT_URL="${VAULT_URL:-https://vault.zincapp.com}"
readonly VAULT_TENANT="${VAULT_TENANT:-zincapp}"

# Colors
if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
else
  GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

log()     { printf '%s[%s]%s %sINFO%s  %s\n' "${GREEN}" "$(date +%H:%M:%S)" "${RESET}" "${BOLD}" "${RESET}" "$*"; }
warn()    { printf '%s[%s]%s %sWARN%s  %s\n' "${YELLOW}" "$(date +%H:%M:%S)" "${RESET}" "${YELLOW}" "${RESET}" "$*" >&2; }
success() { printf '%s✓%s %s\n' "${GREEN}" "${RESET}" "$*"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root. Use: sudo $0" >&2
    exit 1
  fi
}

configure_ssh_ca() {
  log "Configuring SSH Certificate Authority trust..."

  local ca_url="${VAULT_URL}/v1/ssh/ca/${VAULT_TENANT}/public-key/raw"
  local ca_file="/etc/ssh/trusted-user-ca-keys.pub"
  local principals_dir="/etc/ssh/auth_principals"

  echo "  Fetching CA public key from ${DIM}${ca_url}${RESET}"

  # Fetch CA public key
  if ! curl -fsSL "${ca_url}" -o "${ca_file}"; then
    warn "Failed to fetch SSH CA public key from vault"
    return 1
  fi

  # Validate the key was fetched
  if ! grep -q "^ssh-" "${ca_file}"; then
    warn "Invalid SSH CA public key received"
    rm -f "${ca_file}"
    return 1
  fi

  chmod 644 "${ca_file}"
  echo "  CA public key saved to ${DIM}${ca_file}${RESET}"

  # Create principals directory
  mkdir -p "${principals_dir}"

  # Ensure the required principals are present for user 'sysadmin' WITHOUT
  # wiping any principals added by a prior run / by operators. Append-if-missing.
  local principals_file="${principals_dir}/sysadmin"
  touch "${principals_file}"
  chmod 644 "${principals_file}"
  # Guard against a pre-existing file that lacks a trailing newline (e.g. an
  # operator hand-edited it): appending would otherwise concatenate onto the
  # last principal, corrupting it. Normalize to a newline-terminated file first.
  if [ -s "${principals_file}" ] && [ -n "$(tail -c1 "${principals_file}")" ]; then
    echo >> "${principals_file}"
  fi
  # shellcheck disable=SC2043  # deliberate single-element seam; more principals (e.g. archon-deploy) added in a later plan
  for principal in admin; do
    if ! grep -qxF "${principal}" "${principals_file}"; then
      echo "${principal}" >> "${principals_file}"
      echo "  Added principal '${principal}' for user 'sysadmin'"
    else
      echo "  Principal '${principal}' already present for user 'sysadmin'"
    fi
  done

  # Update sshd_config if not already configured
  if ! grep -q "TrustedUserCAKeys" /etc/ssh/sshd_config; then
    cat >> /etc/ssh/sshd_config <<'EOF'

# ZnVault SSH Certificate Authority
TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pub
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
EOF
    echo "  Updated sshd_config with CA trust settings"
  else
    echo "  sshd_config already has TrustedUserCAKeys configured"
  fi

  # Restart SSH to apply changes
  if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
    success "SSH CA trust configured"
  else
    warn "Failed to restart SSH service"
  fi
}

configure_vault_pki_ca() {
  log "Adding ZnVault PKI root CA to system trust store..."

  local ca_url="${VAULT_URL}/v1/pki/root-ca/cert"
  local ca_file="/usr/local/share/ca-certificates/znvault-root-ca.crt"

  echo "  Fetching PKI root CA from ${DIM}${ca_url}${RESET}"

  # Ensure ca-certificates directory exists
  mkdir -p /usr/local/share/ca-certificates

  # Fetch root CA certificate
  if ! curl -fsSL "${ca_url}" -o "${ca_file}"; then
    warn "Failed to fetch PKI root CA from vault"
    return 1
  fi

  # Validate it looks like a certificate
  if ! grep -q "BEGIN CERTIFICATE" "${ca_file}"; then
    warn "Invalid certificate received from vault"
    rm -f "${ca_file}"
    return 1
  fi

  chmod 644 "${ca_file}"
  echo "  Root CA saved to ${DIM}${ca_file}${RESET}"

  # Update system CA trust store
  if update-ca-certificates; then
    success "ZnVault PKI CA added to system trust store"
  else
    warn "update-ca-certificates failed"
  fi
}

main() {
  require_root

  echo ""
  echo "${BOLD}ZnVault Trust Configuration${RESET}"
  echo "${DIM}Vault: ${VAULT_URL}${RESET}"
  echo "${DIM}Tenant: ${VAULT_TENANT}${RESET}"
  echo ""

  local ssh_ok=true
  local pki_ok=true

  configure_ssh_ca || ssh_ok=false
  echo ""
  configure_vault_pki_ca || pki_ok=false

  echo ""
  echo "════════════════════════════════════════════════════════"
  if [[ "$ssh_ok" == true && "$pki_ok" == true ]]; then
    echo "${GREEN}${BOLD}✓ All configured successfully${RESET}"
  else
    echo "${YELLOW}${BOLD}⚠ Some configurations failed (see warnings above)${RESET}"
  fi
  echo "════════════════════════════════════════════════════════"
  echo ""

  if [[ "$ssh_ok" == true ]]; then
    echo "You can now SSH using certificates:"
    echo ""
    echo "  ${BOLD}Quick connect (recommended):${RESET}"
    echo "  ${CYAN}znvault ssh connect sysadmin@$(hostname)${RESET}"
    echo ""
    echo "  ${BOLD}Manual signing:${RESET}"
    echo "  ${CYAN}znvault ssh cert sign ~/.ssh/id_ed25519.pub -o ~/.ssh/id_ed25519-cert.pub${RESET}"
    echo "  ${CYAN}ssh sysadmin@$(hostname)${RESET}"
    echo ""
  fi
}

main "$@"
