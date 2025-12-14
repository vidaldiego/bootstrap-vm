# Bootstrap VM

A bash script for bootstrapping Ubuntu VMs after cloning from a template. Handles all the initial configuration needed to turn a cloned VM into a unique, production-ready machine.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash
```

Or to use a specific version:

```bash
BOOTSTRAP_VERSION=v2.0.0 curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash
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

- **Hostname configuration** - Set a new hostname with proper `/etc/hosts` update
- **Static IP configuration** - Generate and validate netplan config (applied on reboot)
- **SSH host key regeneration** - Generate new unique host keys
- **Machine-ID reset** - Ensure unique machine identity for DHCP, logging, etc.
- **Root filesystem expansion** - Supports both regular partitions and LVM
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
1. New hostname (optional)
2. Static IP configuration (optional)
3. Cloud-init cleanup (if cloud-init is present)
4. Cloud credentials cleanup (if cloud environment detected)
5. Root filesystem expansion
6. Sysprep cleanup

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | `no` | Set to `yes` to preview changes without applying |
| `FORCE` | `no` | Set to `yes` to skip confirmation prompts |
| `FORCE_RERUN` | `no` | Set to `yes` to bypass previous-run detection |

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
