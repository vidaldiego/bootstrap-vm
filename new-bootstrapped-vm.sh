#!/usr/bin/env bash
#
# new-bootstrapped-vm.sh - Create a VM from template and bootstrap it
#
# Prerequisites:
#   - govc: https://github.com/vmware/govmomi/releases
#   - ssh client
#   - SSH key for the template's default user
#
# Environment variables for vCenter connection:
#   GOVC_URL       - vCenter URL (e.g., vcenter.example.com)
#   GOVC_USERNAME  - vCenter username
#   GOVC_PASSWORD  - vCenter password
#   GOVC_INSECURE  - Set to 1 to skip certificate verification
#
# Example:
#   export GOVC_URL=vcenter.example.com
#   export GOVC_USERNAME=administrator@vsphere.local
#   export GOVC_PASSWORD=secret
#   export GOVC_INSECURE=1
#   ./new-bootstrapped-vm.sh --name web-01 --template ubuntu-24.04-template \
#       --datacenter DC1 --cluster Production --datastore vsanDatastore

set -euo pipefail

VERSION="1.0.0"

# Defaults
SSH_USER="sysadmin"
SSH_KEY="$HOME/.ssh/id_ed25519"
TIMEOUT_MINUTES=10
SKIP_BOOTSTRAP=false
NO_SSH_CA=false
NO_PKI_CA=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

log_step()    { echo -e "\n${CYAN}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[+]${NC} $1"; }
log_info()    { echo -e "    ${GRAY}$1${NC}"; }
log_error()   { echo -e "${RED}[!]${NC} $1" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create a VM from vCenter template and run bootstrap-vm.sh

Required:
  --name NAME              VM name (also used as hostname)
  --template TEMPLATE      Template name to clone from
  --datacenter DC          vCenter datacenter
  --cluster CLUSTER        Target cluster
  --datastore DS           Target datastore

Optional - VM Configuration:
  --folder FOLDER          VM folder path
  --network NETWORK        Port group name
  --num-cpu N              Number of CPUs
  --memory-gb N            Memory in GB

Optional - Network:
  --static-ip IP/CIDR      Static IP (e.g., 10.10.30.50/24)
  --gateway IP             Gateway IP
  --dns SERVERS            Comma-separated DNS servers

Optional - SSH:
  --ssh-user USER          SSH username (default: sysadmin)
  --ssh-key PATH           SSH private key (default: ~/.ssh/id_ed25519)

Optional - Bootstrap:
  --no-ssh-ca              Skip SSH CA configuration
  --no-pki-ca              Skip PKI CA configuration
  --skip-bootstrap         Only create VM, don't run bootstrap
  --bootstrap-args "ARGS"  Extra arguments for bootstrap-vm.sh

Optional - Other:
  --timeout MINUTES        Timeout waiting for VM (default: 10)
  --resource-pool POOL     Resource pool (optional)
  -h, --help               Show this help
  -v, --version            Show version

Environment Variables:
  GOVC_URL                 vCenter URL
  GOVC_USERNAME            vCenter username
  GOVC_PASSWORD            vCenter password
  GOVC_INSECURE            Set to 1 to skip cert verification

Examples:
  # Basic - VM with DHCP
  $(basename "$0") --name web-01 --template ubuntu-24.04-template \\
      --datacenter DC1 --cluster Production --datastore vsanDatastore

  # With static IP and custom resources
  $(basename "$0") --name db-01 --template ubuntu-24.04-template \\
      --datacenter DC1 --cluster Production --datastore vsanDatastore \\
      --static-ip 10.10.30.50/24 --num-cpu 4 --memory-gb 16
EOF
    exit 0
}

version() {
    echo "new-bootstrapped-vm.sh version $VERSION"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)           VM_NAME="$2"; shift 2 ;;
        --template)       TEMPLATE="$2"; shift 2 ;;
        --datacenter)     DATACENTER="$2"; shift 2 ;;
        --cluster)        CLUSTER="$2"; shift 2 ;;
        --datastore)      DATASTORE="$2"; shift 2 ;;
        --folder)         FOLDER="$2"; shift 2 ;;
        --network)        NETWORK="$2"; shift 2 ;;
        --num-cpu)        NUM_CPU="$2"; shift 2 ;;
        --memory-gb)      MEMORY_GB="$2"; shift 2 ;;
        --static-ip)      STATIC_IP="$2"; shift 2 ;;
        --gateway)        GATEWAY="$2"; shift 2 ;;
        --dns)            DNS="$2"; shift 2 ;;
        --ssh-user)       SSH_USER="$2"; shift 2 ;;
        --ssh-key)        SSH_KEY="$2"; shift 2 ;;
        --no-ssh-ca)      NO_SSH_CA=true; shift ;;
        --no-pki-ca)      NO_PKI_CA=true; shift ;;
        --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
        --bootstrap-args) BOOTSTRAP_ARGS="$2"; shift 2 ;;
        --timeout)        TIMEOUT_MINUTES="$2"; shift 2 ;;
        --resource-pool)  RESOURCE_POOL="$2"; shift 2 ;;
        -h|--help)        usage ;;
        -v|--version)     version ;;
        *)                log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required arguments
missing=()
[[ -z "${VM_NAME:-}" ]] && missing+=("--name")
[[ -z "${TEMPLATE:-}" ]] && missing+=("--template")
[[ -z "${DATACENTER:-}" ]] && missing+=("--datacenter")
[[ -z "${CLUSTER:-}" ]] && missing+=("--cluster")
[[ -z "${DATASTORE:-}" ]] && missing+=("--datastore")

if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required arguments: ${missing[*]}"
    echo "Use --help for usage information"
    exit 1
fi

# Check for govc
if ! command -v govc &>/dev/null; then
    log_error "govc is not installed"
    echo "Install from: https://github.com/vmware/govmomi/releases"
    echo "  curl -L -o govc.tar.gz https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz"
    echo "  tar -xzf govc.tar.gz govc && sudo mv govc /usr/local/bin/"
    exit 1
fi

# Check vCenter connection
if [[ -z "${GOVC_URL:-}" ]]; then
    log_error "GOVC_URL not set. Export vCenter connection variables:"
    echo "  export GOVC_URL=vcenter.example.com"
    echo "  export GOVC_USERNAME=administrator@vsphere.local"
    echo "  export GOVC_PASSWORD=secret"
    echo "  export GOVC_INSECURE=1  # optional, skip cert check"
    exit 1
fi

# Expand SSH key path
SSH_KEY="${SSH_KEY/#\~/$HOME}"

# Check SSH key
if [[ ! -f "$SSH_KEY" ]]; then
    log_error "SSH key not found: $SSH_KEY"
    exit 1
fi

# Build resource paths
DC_PATH="/$DATACENTER"
CLUSTER_PATH="$DC_PATH/host/$CLUSTER"
DATASTORE_PATH="$DC_PATH/datastore/$DATASTORE"

# Determine VM folder path
if [[ -n "${FOLDER:-}" ]]; then
    VM_FOLDER="$DC_PATH/vm/$FOLDER"
else
    VM_FOLDER="$DC_PATH/vm"
fi

# Function to wait for VM IP
wait_for_ip() {
    local vm_path="$1"
    local timeout_seconds=$((TIMEOUT_MINUTES * 60))
    local elapsed=0
    local interval=5

    while [[ $elapsed -lt $timeout_seconds ]]; do
        local ip
        ip=$(govc vm.ip -wait=0s "$vm_path" 2>/dev/null || true)

        # Filter out link-local addresses
        if [[ -n "$ip" && ! "$ip" =~ ^169\.254\. ]]; then
            echo "$ip"
            return 0
        fi

        echo -n "."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    return 1
}

# Function to wait for SSH
wait_for_ssh() {
    local host="$1"
    local timeout_seconds=$((TIMEOUT_MINUTES * 60))
    local elapsed=0
    local interval=5

    while [[ $elapsed -lt $timeout_seconds ]]; do
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
               -i "$SSH_KEY" "$SSH_USER@$host" "echo ok" 2>/dev/null | grep -q "ok"; then
            return 0
        fi
        echo -n "."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    return 1
}

# Start provisioning
log_step "Connecting to vCenter"
if ! govc about &>/dev/null; then
    log_error "Cannot connect to vCenter at $GOVC_URL"
    exit 1
fi
log_success "Connected to $GOVC_URL"

# Find template
log_step "Locating template '$TEMPLATE'"
TEMPLATE_PATH=$(govc find "$DC_PATH" -type m -name "$TEMPLATE" 2>/dev/null | head -1)

if [[ -z "$TEMPLATE_PATH" ]]; then
    # Try finding as VM template
    TEMPLATE_PATH=$(govc find "$DC_PATH" -type VirtualMachine -name "$TEMPLATE" 2>/dev/null | head -1)
fi

if [[ -z "$TEMPLATE_PATH" ]]; then
    log_error "Template '$TEMPLATE' not found in $DATACENTER"
    exit 1
fi
log_success "Found template: $TEMPLATE_PATH"

# Find a host in the cluster
log_step "Resolving target resources"
HOST=$(govc find "$CLUSTER_PATH" -type h | head -1)
if [[ -z "$HOST" ]]; then
    log_error "No hosts found in cluster $CLUSTER"
    exit 1
fi

log_info "Datacenter: $DATACENTER"
log_info "Cluster: $CLUSTER"
log_info "Datastore: $DATASTORE"
log_info "Host: $(basename "$HOST")"

# Build clone command
log_step "Creating VM '$VM_NAME' from template"

CLONE_ARGS=(
    -vm "$TEMPLATE_PATH"
    -ds "$DATASTORE_PATH"
    -host "$HOST"
    -folder "$VM_FOLDER"
    -on=false
)

if [[ -n "${RESOURCE_POOL:-}" ]]; then
    CLONE_ARGS+=(-pool "$DC_PATH/host/$CLUSTER/Resources/$RESOURCE_POOL")
fi

govc vm.clone "${CLONE_ARGS[@]}" "$VM_NAME"
log_success "VM created: $VM_NAME"

VM_PATH="$VM_FOLDER/$VM_NAME"

# Configure VM resources
if [[ -n "${NUM_CPU:-}" || -n "${MEMORY_GB:-}" ]]; then
    log_step "Configuring VM resources"

    CHANGE_ARGS=()
    if [[ -n "${NUM_CPU:-}" ]]; then
        CHANGE_ARGS+=(-c "$NUM_CPU")
        log_info "CPUs: $NUM_CPU"
    fi
    if [[ -n "${MEMORY_GB:-}" ]]; then
        MEMORY_MB=$((MEMORY_GB * 1024))
        CHANGE_ARGS+=(-m "$MEMORY_MB")
        log_info "Memory: ${MEMORY_GB}GB"
    fi

    govc vm.change -vm "$VM_PATH" "${CHANGE_ARGS[@]}"
fi

# Configure network
if [[ -n "${NETWORK:-}" ]]; then
    log_step "Configuring network"
    govc vm.network.change -vm "$VM_PATH" -net "$NETWORK" ethernet-0
    log_info "Network: $NETWORK"
fi

# Power on
log_step "Powering on VM"
govc vm.power -on "$VM_PATH"
log_success "VM powered on"

# Wait for IP
log_step "Waiting for VM to get IP address (timeout: ${TIMEOUT_MINUTES}min)"
echo -n "    Waiting"

if ! VM_IP=$(wait_for_ip "$VM_PATH"); then
    echo ""
    log_error "Timeout waiting for VM IP address"
    log_info "VM created but bootstrap not run. Check VM console."
    exit 1
fi

echo ""
log_success "VM IP: $VM_IP"

if [[ "$SKIP_BOOTSTRAP" == "true" ]]; then
    log_success "VM creation complete (bootstrap skipped)"
    echo ""
    echo "VM Details:"
    log_info "Name: $VM_NAME"
    log_info "IP: $VM_IP"
    exit 0
fi

# Wait for SSH
log_step "Waiting for SSH to be available"
echo -n "    Waiting"

if ! wait_for_ssh "$VM_IP"; then
    echo ""
    log_error "Timeout waiting for SSH"
    log_info "VM created but bootstrap not run. Connect manually:"
    log_info "ssh $SSH_USER@$VM_IP"
    exit 1
fi

echo ""
log_success "SSH is available"

# Build bootstrap command
log_step "Running bootstrap on VM"

BOOTSTRAP_CMD="curl -fsSL https://raw.githubusercontent.com/vidaldiego/bootstrap-vm/main/install.sh | bash -s -- --hostname $VM_NAME"

if [[ -n "${STATIC_IP:-}" ]]; then
    BOOTSTRAP_CMD+=" --static-ip $STATIC_IP"
fi
if [[ -n "${GATEWAY:-}" ]]; then
    BOOTSTRAP_CMD+=" --gateway $GATEWAY"
fi
if [[ -n "${DNS:-}" ]]; then
    BOOTSTRAP_CMD+=" --dns \"$DNS\""
fi
if [[ "$NO_SSH_CA" == "true" ]]; then
    BOOTSTRAP_CMD+=" --no-ssh-ca"
fi
if [[ "$NO_PKI_CA" == "true" ]]; then
    BOOTSTRAP_CMD+=" --no-pki-ca"
fi
if [[ -n "${BOOTSTRAP_ARGS:-}" ]]; then
    BOOTSTRAP_CMD+=" $BOOTSTRAP_ARGS"
fi

# Always add --yes for non-interactive
BOOTSTRAP_CMD+=" --yes"

log_info "Command: $BOOTSTRAP_CMD"
echo ""

# Run bootstrap via SSH
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$VM_IP" "$BOOTSTRAP_CMD"
EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    log_error "Bootstrap exited with code $EXIT_CODE"
    exit $EXIT_CODE
fi

echo ""
log_success "Bootstrap complete!"
echo ""
echo "VM Details:"
log_info "Name: $VM_NAME"
log_info "IP: $VM_IP"

if [[ -n "${STATIC_IP:-}" ]]; then
    NEW_IP="${STATIC_IP%/*}"
    log_info "New IP (after reboot): $NEW_IP"
    echo ""
    echo -e "The VM will reboot to apply changes. Connect with:"
    echo -e "    ${CYAN}ssh $SSH_USER@$NEW_IP${NC}"
else
    echo ""
    echo -e "The VM will reboot to apply changes. Connect with:"
    echo -e "    ${CYAN}ssh $SSH_USER@$VM_IP${NC}"
fi
