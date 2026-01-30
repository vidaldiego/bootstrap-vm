# Bootstrap VM

A bash script for bootstrapping Ubuntu VMs after cloning from a template. Handles all the initial configuration needed to turn a cloned VM into a unique, production-ready machine.

## Quick Start

```bash
# Interactive mode (prompts for all values)
curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash

# CLI mode (non-interactive)
curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash -s -- --hostname myserver

# CLI mode with static IP (gateway/DNS auto-detected from current config)
curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash -s -- \
  --hostname myserver \
  --static-ip 10.10.30.50/24 \
  --yes
```

Or to use a specific version:

```bash
BOOTSTRAP_VERSION=v2.3.0 curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash
```

## Template Setup

For VM templates, install the `bootstrap` command so users can just run it after cloning:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/bootstrap -o /usr/local/bin/bootstrap
sudo chmod +x /usr/local/bin/bootstrap
```

Then after cloning a VM from the template:

```bash
bootstrap
```

## Features

- **CLI mode** - Fully non-interactive bootstrapping with command-line arguments
- **Hostname configuration** - Set a new hostname with proper `/etc/hosts` update
- **Static IP configuration** - Generate and validate netplan config (applied on reboot)
- **SSH host key regeneration** - Generate new unique host keys
- **Machine-ID reset** - Ensure unique machine identity for DHCP, logging, etc.
- **Root filesystem expansion** - Supports both regular partitions and LVM
- **SSH CA trust** - Configure SSH to trust ZnVault SSH CA for certificate-based auth
- **PKI CA trust** - Add PKI root CA to system trust store
- **Unattended-upgrades** - Configure or disable automatic security updates
- **Cloud-init cleanup** - Reset cloud-init state for re-initialization
- **Cloud credentials cleanup** - Remove AWS/Azure/GCP credentials (optional)
- **Sysprep** - Clean logs, history, temp files for a fresh start
- **Dry-run mode** - Preview all changes before applying
- **Idempotent** - Detects previous runs and warns before re-running

## Usage

### Interactive Mode (default)

```bash
./bootstrap-vm.sh
```

The script will prompt for:
1. New hostname
2. Static IP configuration (optional)
3. Cloud-init cleanup (if cloud-init is present)
4. Cloud credentials cleanup (if cloud environment detected)
5. Root filesystem expansion
6. Unattended-upgrades configuration
7. SSH CA trust (ZnVault integration)
8. PKI CA trust
9. Sysprep cleanup

### CLI Mode (non-interactive)

```bash
./bootstrap-vm.sh --hostname myserver [OPTIONS]
```

In CLI mode, `--hostname` is required. Other options have sensible defaults.

#### CLI Options

| Option | Description |
|--------|-------------|
| `-H, --hostname NAME` | Set hostname (required in CLI mode) |
| `-i, --static-ip CIDR` | Static IP with subnet (e.g., `10.10.30.50/24`) |
| `-g, --gateway IP` | Gateway address (auto-detected if omitted) |
| `-d, --dns SERVERS` | Comma-separated DNS servers (auto-detected if omitted) |
| `-I, --interface IF` | Network interface (auto-detected if omitted) |
| `--expand-disk` | Expand root filesystem (default: yes) |
| `--no-expand-disk` | Skip disk expansion |
| `--ssh-ca` | Configure SSH CA trust (default: yes) |
| `--no-ssh-ca` | Skip SSH CA configuration |
| `--pki-ca` | Add PKI CA to trust store (default: yes) |
| `--no-pki-ca` | Skip PKI CA configuration |
| `--disable-updates` | Disable unattended-upgrades |
| `--update-window HH:MM` | Set maintenance window (e.g., `04:00`) |
| `--sysprep` | Clean system state (history, logs, temp files) |
| `--cloud-init-clean` | Clean cloud-init state |
| `--clean-creds` | Clean cloud credentials (AWS/Azure/GCP) |
| `-y, --yes` | Skip confirmation prompts |
| `-n, --dry-run` | Preview changes without applying |
| `--force-rerun` | Allow re-running on already bootstrapped machine |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

#### CLI Examples

```bash
# Minimal - hostname only (uses defaults)
./bootstrap-vm.sh --hostname myserver

# With static IP (gateway/DNS auto-detected)
./bootstrap-vm.sh --hostname myserver --static-ip 10.10.30.50/24

# With static IP and explicit gateway/DNS
./bootstrap-vm.sh --hostname myserver \
  --static-ip 10.10.30.50/24 \
  --gateway 10.10.30.1 \
  --dns "172.16.50.250,8.8.8.8"

# Full automation (no prompts)
./bootstrap-vm.sh --hostname myserver --yes

# Skip SSH/PKI CA integration
./bootstrap-vm.sh --hostname myserver --no-ssh-ca --no-pki-ca

# Dry-run to preview
./bootstrap-vm.sh --hostname myserver --dry-run
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | `no` | Set to `yes` to preview changes without applying |
| `FORCE` | `no` | Set to `yes` to skip confirmation prompts |
| `FORCE_RERUN` | `no` | Set to `yes` to bypass previous-run detection |
| `VAULT_URL` | `https://vault.zincapp.com` | Vault server URL for SSH/PKI CA |
| `VAULT_TENANT` | `zincapp` | Tenant for SSH CA configuration |

### Examples

```bash
# Dry-run to preview changes
DRY_RUN=yes ./bootstrap-vm.sh

# Non-interactive with all confirmations auto-accepted
FORCE=yes ./bootstrap-vm.sh

# Re-run on an already-bootstrapped machine
FORCE_RERUN=yes ./bootstrap-vm.sh
```

## What It Does

1. **System update** - Runs `apt-get update && apt-get full-upgrade`
2. **SSH keys** - Regenerates all host keys in `/etc/ssh/`
3. **Machine-ID** - Truncates `/etc/machine-id` (regenerates on next boot)
4. **Journal logs** - Rotates and vacuums systemd journal
5. **Hostname** - Updates hostname and `/etc/hosts`
6. **Network** - Validates and saves netplan config (applied on reboot)
7. **Disk** - Expands partition and filesystem to use available space
8. **Sysprep** - Cleans history, logs, temp files, apt cache
9. **Reboot** - Applies all changes with a fresh boot

## Files Created

| Path | Description |
|------|-------------|
| `/var/log/bootstrap-{timestamp}.log` | Full execution log |
| `/etc/bootstrap-done` | Marker file with run metadata |
| `/root/bootstrap-report-{timestamp}.txt` | Summary report |
| `/root/netplan-backups-{timestamp}/` | Backup of original netplan configs |

## Requirements

- Ubuntu (tested on 20.04, 22.04, 24.04)
- Bash 4.0+
- Root access (script will elevate via sudo)

## License

MIT
