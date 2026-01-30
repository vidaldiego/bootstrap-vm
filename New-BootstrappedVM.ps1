<#
.SYNOPSIS
    Creates a VM from template and runs bootstrap-vm.sh to configure it.

.DESCRIPTION
    This script automates VM provisioning by:
    1. Cloning a VM from a vCenter template
    2. Waiting for the VM to boot and get an IP
    3. Waiting for SSH to become available
    4. Running bootstrap-vm.sh with specified arguments

.PARAMETER Name
    Name for the new VM (also used as hostname for bootstrap)

.PARAMETER Template
    Name of the VM template to clone from

.PARAMETER Datacenter
    vCenter datacenter name

.PARAMETER Cluster
    vCenter cluster to deploy to

.PARAMETER Datastore
    Datastore for VM storage

.PARAMETER Folder
    VM folder path (optional)

.PARAMETER Network
    Network/port group name (optional, uses template default if not specified)

.PARAMETER NumCpu
    Number of CPUs (optional, uses template default)

.PARAMETER MemoryGB
    Memory in GB (optional, uses template default)

.PARAMETER StaticIP
    Static IP in CIDR notation (e.g., 10.10.30.50/24). If omitted, uses DHCP.

.PARAMETER Gateway
    Gateway IP (auto-detected by bootstrap if omitted)

.PARAMETER DNS
    Comma-separated DNS servers (auto-detected by bootstrap if omitted)

.PARAMETER SSHUser
    SSH username (default: sysadmin)

.PARAMETER SSHKeyPath
    Path to SSH private key (default: ~/.ssh/id_ed25519)

.PARAMETER BootstrapArgs
    Additional arguments to pass to bootstrap-vm.sh

.PARAMETER NoSSHCA
    Skip SSH CA configuration

.PARAMETER NoPKICA
    Skip PKI CA configuration

.PARAMETER SkipBootstrap
    Only create VM, don't run bootstrap

.PARAMETER VCenterServer
    vCenter server address (can also use VI_SERVER env var)

.PARAMETER TimeoutMinutes
    Timeout waiting for VM to be ready (default: 10)

.EXAMPLE
    ./New-BootstrappedVM.ps1 -Name "web-server-01" -Template "ubuntu-24.04-template" `
        -Datacenter "DC1" -Cluster "Production" -Datastore "vsanDatastore"

.EXAMPLE
    ./New-BootstrappedVM.ps1 -Name "db-server-01" -Template "ubuntu-24.04-template" `
        -Datacenter "DC1" -Cluster "Production" -Datastore "vsanDatastore" `
        -StaticIP "10.10.30.50/24" -Gateway "10.10.30.1" -NumCpu 4 -MemoryGB 16

.EXAMPLE
    # Using environment variables for vCenter connection
    $env:VI_SERVER = "vcenter.example.com"
    $env:VI_USERNAME = "administrator@vsphere.local"
    $env:VI_PASSWORD = "secret"
    ./New-BootstrappedVM.ps1 -Name "app-01" -Template "ubuntu-template" ...
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Template,

    [Parameter(Mandatory = $true)]
    [string]$Datacenter,

    [Parameter(Mandatory = $true)]
    [string]$Cluster,

    [Parameter(Mandatory = $true)]
    [string]$Datastore,

    [string]$Folder,
    [string]$Network,
    [int]$NumCpu,
    [int]$MemoryGB,
    [string]$StaticIP,
    [string]$Gateway,
    [string]$DNS,
    [string]$SSHUser = "sysadmin",
    [string]$SSHKeyPath = "~/.ssh/id_ed25519",
    [string[]]$BootstrapArgs = @(),
    [switch]$NoSSHCA,
    [switch]$NoPKICA,
    [switch]$SkipBootstrap,
    [string]$VCenterServer = $env:VI_SERVER,
    [int]$TimeoutMinutes = 10
)

$ErrorActionPreference = "Stop"

# Expand SSH key path
$SSHKeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SSHKeyPath)

#region Helper Functions

function Write-Step {
    param([string]$Message)
    Write-Host "`n[*] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Gray
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Red
}

function Test-SSHConnection {
    param(
        [string]$Host,
        [string]$User,
        [string]$KeyPath
    )

    $result = ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no `
        -i $KeyPath "$User@$Host" "echo ok" 2>$null
    return $result -eq "ok"
}

function Wait-ForSSH {
    param(
        [string]$Host,
        [string]$User,
        [string]$KeyPath,
        [int]$TimeoutSeconds = 300
    )

    $elapsed = 0
    $interval = 5

    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-SSHConnection -Host $Host -User $User -KeyPath $KeyPath) {
            return $true
        }
        Write-Host "." -NoNewline
        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }

    return $false
}

function Wait-ForVMIP {
    param(
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]$VM,
        [int]$TimeoutSeconds = 300
    )

    $elapsed = 0
    $interval = 5

    while ($elapsed -lt $TimeoutSeconds) {
        $vm = Get-VM -Id $VM.Id
        $ip = $vm.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.254\.' } | Select-Object -First 1

        if ($ip) {
            return $ip
        }

        Write-Host "." -NoNewline
        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }

    return $null
}

#endregion

#region Main Script

# Check for PowerCLI
if (-not (Get-Module -ListAvailable VMware.PowerCLI)) {
    Write-ErrorMsg "VMware PowerCLI is not installed. Install with: Install-Module VMware.PowerCLI -Scope CurrentUser"
    exit 1
}

Import-Module VMware.PowerCLI -ErrorAction SilentlyContinue

# Suppress certificate warnings (optional)
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

# Connect to vCenter if not already connected
Write-Step "Connecting to vCenter"

if (-not $VCenterServer) {
    Write-ErrorMsg "vCenter server not specified. Use -VCenterServer or set VI_SERVER environment variable."
    exit 1
}

$existingConnection = $global:DefaultVIServers | Where-Object { $_.Name -eq $VCenterServer }
if (-not $existingConnection) {
    if ($env:VI_USERNAME -and $env:VI_PASSWORD) {
        $credential = New-Object PSCredential($env:VI_USERNAME, (ConvertTo-SecureString $env:VI_PASSWORD -AsPlainText -Force))
        Connect-VIServer -Server $VCenterServer -Credential $credential | Out-Null
    } else {
        Connect-VIServer -Server $VCenterServer | Out-Null
    }
}
Write-Success "Connected to $VCenterServer"

# Verify template exists
Write-Step "Locating template '$Template'"
$vmTemplate = Get-Template -Name $Template -ErrorAction SilentlyContinue
if (-not $vmTemplate) {
    # Try as a VM (for linked clones or VM-based templates)
    $vmTemplate = Get-VM -Name $Template -ErrorAction SilentlyContinue
    if (-not $vmTemplate) {
        Write-ErrorMsg "Template '$Template' not found"
        exit 1
    }
}
Write-Success "Found template: $($vmTemplate.Name)"

# Get target resources
Write-Step "Resolving target resources"
$dc = Get-Datacenter -Name $Datacenter
$cl = Get-Cluster -Name $Cluster -Location $dc
$ds = Get-Datastore -Name $Datastore -Location $dc
$vmHost = Get-VMHost -Location $cl | Get-Random  # Pick a random host in cluster

Write-Info "Datacenter: $($dc.Name)"
Write-Info "Cluster: $($cl.Name)"
Write-Info "Datastore: $($ds.Name)"
Write-Info "Host: $($vmHost.Name)"

# Build clone parameters
$cloneParams = @{
    Name = $Name
    Template = $vmTemplate
    VMHost = $vmHost
    Datastore = $ds
    DiskStorageFormat = "Thin"
}

if ($Folder) {
    $vmFolder = Get-Folder -Name $Folder -Location $dc -Type VM -ErrorAction SilentlyContinue
    if ($vmFolder) {
        $cloneParams.Location = $vmFolder
        Write-Info "Folder: $Folder"
    }
}

# Create the VM
Write-Step "Creating VM '$Name' from template"
$vm = New-VM @cloneParams
Write-Success "VM created: $($vm.Name)"

# Configure VM resources if specified
if ($NumCpu -or $MemoryGB -or $Network) {
    Write-Step "Configuring VM resources"

    $setParams = @{}
    if ($NumCpu) {
        $setParams.NumCpu = $NumCpu
        Write-Info "CPUs: $NumCpu"
    }
    if ($MemoryGB) {
        $setParams.MemoryGB = $MemoryGB
        Write-Info "Memory: ${MemoryGB}GB"
    }

    if ($setParams.Count -gt 0) {
        $vm | Set-VM @setParams -Confirm:$false | Out-Null
    }

    if ($Network) {
        $pg = Get-VirtualPortGroup -Name $Network -VMHost $vmHost -ErrorAction SilentlyContinue
        if ($pg) {
            $vm | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup $pg -Confirm:$false | Out-Null
            Write-Info "Network: $Network"
        } else {
            Write-ErrorMsg "Network '$Network' not found, using template default"
        }
    }
}

# Power on the VM
Write-Step "Powering on VM"
$vm | Start-VM | Out-Null
Write-Success "VM powered on"

# Wait for IP address
Write-Step "Waiting for VM to get IP address (timeout: $TimeoutMinutes min)"
Write-Host "    Waiting" -NoNewline
$vmIP = Wait-ForVMIP -VM $vm -TimeoutSeconds ($TimeoutMinutes * 60)

if (-not $vmIP) {
    Write-Host ""
    Write-ErrorMsg "Timeout waiting for VM IP address"
    Write-Info "VM created but bootstrap not run. Check VM console."
    exit 1
}

Write-Host ""
Write-Success "VM IP: $vmIP"

if ($SkipBootstrap) {
    Write-Success "VM creation complete (bootstrap skipped)"
    Write-Host "`nVM Details:"
    Write-Info "Name: $Name"
    Write-Info "IP: $vmIP"
    exit 0
}

# Wait for SSH
Write-Step "Waiting for SSH to be available"
Write-Host "    Waiting" -NoNewline
$sshReady = Wait-ForSSH -Host $vmIP -User $SSHUser -KeyPath $SSHKeyPath -TimeoutSeconds ($TimeoutMinutes * 60)

if (-not $sshReady) {
    Write-Host ""
    Write-ErrorMsg "Timeout waiting for SSH"
    Write-Info "VM created but bootstrap not run. Connect manually to: ssh $SSHUser@$vmIP"
    exit 1
}

Write-Host ""
Write-Success "SSH is available"

# Build bootstrap command
Write-Step "Running bootstrap on VM"

$bootstrapCmd = "curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash -s -- --hostname $Name"

if ($StaticIP) {
    $bootstrapCmd += " --static-ip $StaticIP"
}
if ($Gateway) {
    $bootstrapCmd += " --gateway $Gateway"
}
if ($DNS) {
    $bootstrapCmd += " --dns `"$DNS`""
}
if ($NoSSHCA) {
    $bootstrapCmd += " --no-ssh-ca"
}
if ($NoPKICA) {
    $bootstrapCmd += " --no-pki-ca"
}

# Add any extra bootstrap args
foreach ($arg in $BootstrapArgs) {
    $bootstrapCmd += " $arg"
}

# Always add --yes for non-interactive
$bootstrapCmd += " --yes"

Write-Info "Command: $bootstrapCmd"

# Run bootstrap via SSH
$sshCmd = "ssh -o StrictHostKeyChecking=no -i `"$SSHKeyPath`" `"$SSHUser@$vmIP`" `"$bootstrapCmd`""
Write-Host ""

try {
    Invoke-Expression $sshCmd
    $exitCode = $LASTEXITCODE
} catch {
    Write-ErrorMsg "SSH command failed: $_"
    exit 1
}

if ($exitCode -ne 0) {
    Write-ErrorMsg "Bootstrap exited with code $exitCode"
    exit $exitCode
}

Write-Host ""
Write-Success "Bootstrap complete!"
Write-Host "`nVM Details:"
Write-Info "Name: $Name"
Write-Info "IP: $vmIP"

if ($StaticIP) {
    $newIP = $StaticIP -replace '/\d+$', ''
    Write-Info "New IP (after reboot): $newIP"
    Write-Host "`nThe VM will reboot to apply changes. Connect with:"
    Write-Host "    ssh $SSHUser@$newIP" -ForegroundColor Yellow
} else {
    Write-Host "`nThe VM will reboot to apply changes. Connect with:"
    Write-Host "    ssh $SSHUser@$vmIP" -ForegroundColor Yellow
}

#endregion
