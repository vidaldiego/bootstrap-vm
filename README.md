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

## Automated VM Provisioning (vCenter)

Two scripts automate VM creation from vCenter templates:

| Script | Platform | Tool |
|--------|----------|------|
| `new-bootstrapped-vm.sh` | Linux/macOS | govc |
| `New-BootstrappedVM.ps1` | Windows/Cross-platform | PowerCLI |

Both scripts:
1. Clone a VM from a vCenter template
2. Wait for the VM to boot and get an IP (via VMware Tools)
3. Wait for SSH to become available
4. Run bootstrap-vm.sh with specified arguments

### Linux/macOS (govc)

**Prerequisites:**
- [govc](https://github.com/vmware/govmomi/releases) CLI tool
- SSH key for the template's default user

```bash
# Install govc
curl -L -o govc.tar.gz https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz
tar -xzf govc.tar.gz govc && sudo mv govc /usr/local/bin/

# Set vCenter credentials
export GOVC_URL=vcenter.example.com
export GOVC_USERNAME=administrator@vsphere.local
export GOVC_PASSWORD=secret
export GOVC_INSECURE=1  # optional, skip cert check

# Basic - creates VM with DHCP
./new-bootstrapped-vm.sh --name web-01 --template ubuntu-24.04-template \
    --datacenter DC1 --cluster Production --datastore vsanDatastore

# With static IP and custom resources
./new-bootstrapped-vm.sh --name db-01 --template ubuntu-24.04-template \
    --datacenter DC1 --cluster Production --datastore vsanDatastore \
    --static-ip 10.10.30.50/24 --num-cpu 4 --memory-gb 16

# With custom network and folder
./new-bootstrapped-vm.sh --name app-01 --template ubuntu-24.04-template \
    --datacenter DC1 --cluster Production --datastore vsanDatastore \
    --network VLAN100 --folder "Production VMs" --static-ip 10.10.100.20/24
```

**Options:**

| Option | Required | Description |
|--------|----------|-------------|
| `--name` | Yes | VM name (also used as hostname) |
| `--template` | Yes | Template name to clone from |
| `--datacenter` | Yes | vCenter datacenter |
| `--cluster` | Yes | Target cluster |
| `--datastore` | Yes | Target datastore |
| `--folder` | No | VM folder path |
| `--network` | No | Port group name |
| `--num-cpu` | No | CPU count |
| `--memory-gb` | No | Memory in GB |
| `--static-ip` | No | Static IP in CIDR notation |
| `--gateway` | No | Gateway (auto-detected if omitted) |
| `--dns` | No | DNS servers (auto-detected if omitted) |
| `--ssh-user` | No | SSH user (default: sysadmin) |
| `--ssh-key` | No | SSH key path (default: ~/.ssh/id_ed25519) |
| `--no-ssh-ca` | No | Skip SSH CA configuration |
| `--no-pki-ca` | No | Skip PKI CA configuration |
| `--skip-bootstrap` | No | Only create VM, don't run bootstrap |
| `--timeout` | No | Timeout in minutes (default: 10) |

### Windows/PowerShell (PowerCLI)

**Prerequisites:**
- PowerShell 7+ (pwsh)
- VMware PowerCLI: `Install-Module VMware.PowerCLI -Scope CurrentUser`
- SSH client available in PATH

```powershell
# Set vCenter credentials (or use -VCenterServer with interactive login)
$env:VI_SERVER = "vcenter.example.com"
$env:VI_USERNAME = "administrator@vsphere.local"
$env:VI_PASSWORD = "secret"

# Basic - creates VM with DHCP
./New-BootstrappedVM.ps1 -Name "web-01" -Template "ubuntu-24.04-template" `
    -Datacenter "DC1" -Cluster "Production" -Datastore "vsanDatastore"

# With static IP
./New-BootstrappedVM.ps1 -Name "db-01" -Template "ubuntu-24.04-template" `
    -Datacenter "DC1" -Cluster "Production" -Datastore "vsanDatastore" `
    -StaticIP "10.10.30.50/24" -NumCpu 4 -MemoryGB 16
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name` | Yes | VM name (also used as hostname) |
| `-Template` | Yes | Template name to clone from |
| `-Datacenter` | Yes | vCenter datacenter |
| `-Cluster` | Yes | Target cluster |
| `-Datastore` | Yes | Target datastore |
| `-Folder` | No | VM folder path |
| `-Network` | No | Port group name |
| `-NumCpu` | No | CPU count |
| `-MemoryGB` | No | Memory in GB |
| `-StaticIP` | No | Static IP in CIDR notation |
| `-Gateway` | No | Gateway (auto-detected if omitted) |
| `-DNS` | No | DNS servers (auto-detected if omitted) |
| `-SSHUser` | No | SSH user (default: sysadmin) |
| `-SSHKeyPath` | No | SSH key path (default: ~/.ssh/id_ed25519) |
| `-NoSSHCA` | No | Skip SSH CA configuration |
| `-NoPKICA` | No | Skip PKI CA configuration |
| `-SkipBootstrap` | No | Only create VM, don't run bootstrap |
| `-TimeoutMinutes` | No | Timeout for VM ready (default: 10) |

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
