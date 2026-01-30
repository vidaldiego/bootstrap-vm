#!/usr/bin/env bash
set -euo pipefail

# Bootstrap VM Installer
#
# Interactive mode:
#   curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash
#
# CLI mode (pass arguments with -s --):
#   curl -fsSL .../install.sh | bash -s -- --hostname myserver
#   curl -fsSL .../install.sh | bash -s -- --hostname myserver --static-ip 10.10.30.50/24 --gateway 10.10.30.1
#   curl -fsSL .../install.sh | bash -s -- --help
#
# Specify version/branch:
#   BOOTSTRAP_VERSION=v2.3.0 curl -fsSL .../install.sh | bash -s -- --hostname myserver

REPO="vidaldiego/bootstrap-vm"
BRANCH="${BOOTSTRAP_VERSION:-main}"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/bootstrap-vm.sh"

echo "Downloading bootstrap-vm.sh from ${BRANCH}..."
curl -fsSL "${SCRIPT_URL}" -o /tmp/bootstrap-vm.sh
chmod +x /tmp/bootstrap-vm.sh

echo "Running bootstrap-vm.sh..."
exec /tmp/bootstrap-vm.sh "$@"
