#!/usr/bin/env bash
set -euo pipefail

# Bootstrap VM Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash

REPO="vidaldiego/bootstrap-vm"
BRANCH="${BOOTSTRAP_VERSION:-main}"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/bootstrap-vm.sh"

echo "Downloading bootstrap-vm.sh from ${BRANCH}..."
curl -fsSL "${SCRIPT_URL}" -o /tmp/bootstrap-vm.sh
chmod +x /tmp/bootstrap-vm.sh

echo "Running bootstrap-vm.sh..."
exec /tmp/bootstrap-vm.sh "$@"
