#!/bin/bash
# configure-ovn.sh
# Creates ProviderNetworks for external bridges with physical interfaces

set -e  # Exit on error
set -o pipefail  # Catch errors in pipes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/ovn-config-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

error() {
  echo -e "${RED}[$(date +'%H:%M:%S')] ERROR:${NC} $*" | tee -a "$LOG_FILE" >&2
}

warn() {
  echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING:${NC} $*" | tee -a "$LOG_FILE"
}

info() {
  echo -e "${BLUE}[$(date +'%H:%M:%S')] INFO:${NC} $*" | tee -a "$LOG_FILE"
}

log "=========================================="
log "OVN External Bridge Configuration"
log "=========================================="

# Check prerequisites
log "Checking prerequisites..."

if ! kubectl get crd provider-networks.kubeovn.io &>/dev/null; then
  error "ProviderNetwork CRD not found. Is KubeOVN installed?"
  exit 1
fi

log "✓ Prerequisites OK"

# Function to get annotation
get_annotation() {
  local node=$1
  local annotation=$2
  local escaped_annotation=$(echo "$annotation" | sed 's/\./\\./g')
  local result
  result=$(kubectl get node "$node" -o jsonpath="{.metadata.annotations['$escaped_annotation']}" 2>/dev/null || echo "null")
  echo "$result"
}

# Discover annotated nodes
log ""
log "Discovering nodes with external bridge annotations..."

ANNOTATED_NODES=$(kubectl get nodes -o json | jq -r '.items[] |
  select(.metadata.annotations["ovn.openstack.org/mappings"] != null) |
  .metadata.name')

if [ -z "$ANNOTATED_NODES" ]; then
  error "No nodes found with ovn.openstack.org/mappings annotation"
  echo ""
  echo "To configure external bridges on nodes:"
  echo ""
  echo "Single provider network:"
  echo "  kubectl annotate nodes -l openstack-network-node=enabled \\"
  echo "    ovn.openstack.org/mappings='physnet1:br-ex' \\"
  echo "    ovn.openstack.org/ports='br-ex:eno2'"
  echo ""
  echo "Multiple provider networks:"
  echo "  kubectl annotate nodes -l openstack-network-node=enabled \\"
  echo "    ovn.openstack.org/mappings='physnet1:br-ex,physnet2:br-ex1' \\"
  echo "    ovn.openstack.org/ports='br-ex:eno2,br-ex1:eno3'"
  echo ""
  echo "Note: The 'bridges' annotation is optional and will be derived from mappings if not specified."
  echo ""
  exit 1
fi

NODE_COUNT=$(echo "$ANNOTATED_NODES" | wc -l)
log "✓ Found $NODE_COUNT configured node(s)"
log "Node list:"
echo "$ANNOTATED_NODES" | sed 's/^/  - /' | tee -a "$LOG_FILE"

# Process nodes and build ProviderNetwork groups
log ""
log "Processing external bridge configurations..."

declare -A PROVIDER_NETWORKS
PROCESSING_ERRORS=0

for NODE in $ANNOTATED_NODES; do
  log "  Processing $NODE..."

  # Get annotations with error handling
  BRIDGES=$(get_annotation "$NODE" "ovn.openstack.org/bridges")
  PORTS=$(get_annotation "$NODE" "ovn.openstack.org/ports")
  MAPPINGS=$(get_annotation "$NODE" "ovn.openstack.org/mappings")

  log "    bridges: $BRIDGES"
  log "    ports: $PORTS"
  log "    mappings: $MAPPINGS"

  if [ "$MAPPINGS" = "null" ] || [ -z "$MAPPINGS" ]; then
    error "    No mappings defined - required to determine provider network names"
    error "    Example: ovn.openstack.org/mappings='physnet1:br-ex,physnet2:br-ex1'"
    PROCESSING_ERRORS=$((PROCESSING_ERRORS + 1))
    continue
  fi

  # Build mapping lookup (bridge -> provider network name) and extract bridge list
  declare -A BRIDGE_TO_PHYSNET
  declare -a BRIDGES_FROM_MAPPINGS
  IFS=',' read -r -a MAPPING_ARRAY <<< "$MAPPINGS"
  log "    Parsing ${#MAPPING_ARRAY[@]} mapping(s)..."

  for MAPPING in "${MAPPING_ARRAY[@]}"; do
    MAPPING=$(echo "$MAPPING" | xargs)
    IFS=':' read -r PHYSNET BRIDGE <<< "$MAPPING"

    if [ -z "$PHYSNET" ] || [ -z "$BRIDGE" ]; then
      error "      Invalid mapping format: '$MAPPING' (expected 'physnet:bridge')"
      PROCESSING_ERRORS=$((PROCESSING_ERRORS + 1))
      continue
    fi

    BRIDGE_TO_PHYSNET["$BRIDGE"]="$PHYSNET"
    BRIDGES_FROM_MAPPINGS+=("$BRIDGE")
    log "      Mapped: $BRIDGE -> provider network '$PHYSNET'"
  done

  # Determine which bridges to process
  # If bridges annotation is set, use it; otherwise use bridges from mappings
  if [ "$BRIDGES" != "null" ] && [ -n "$BRIDGES" ]; then
    IFS=',' read -r -a BRIDGE_ARRAY <<< "$BRIDGES"
    log "    Using ${#BRIDGE_ARRAY[@]} bridge(s) from 'bridges' annotation"
  else
    BRIDGE_ARRAY=("${BRIDGES_FROM_MAPPINGS[@]}")
    log "    Using ${#BRIDGE_ARRAY[@]} bridge(s) derived from 'mappings' annotation"
  fi

  # Build port mapping lookup (bridge -> interface)
  declare -A PORT_MAP
  if [ "$PORTS" != "null" ] && [ -n "$PORTS" ]; then
    IFS=',' read -r -a PORT_ARRAY <<< "$PORTS"
    log "    Parsing ${#PORT_ARRAY[@]} port mapping(s)..."

    for PORT_MAPPING in "${PORT_ARRAY[@]}"; do
      PORT_MAPPING=$(echo "$PORT_MAPPING" | xargs)
      IFS=':' read -r PORT_BRIDGE PORT_INTERFACE <<< "$PORT_MAPPING"
      PORT_MAP["$PORT_BRIDGE"]="$PORT_INTERFACE"
      log "      Port: $PORT_BRIDGE -> interface $PORT_INTERFACE"
    done
  else
    warn "    No port mappings found"
  fi

  # Process each bridge
  for FULL_BRIDGE in "${BRIDGE_ARRAY[@]}"; do
    FULL_BRIDGE=$(echo "$FULL_BRIDGE" | xargs)

    log "    Processing bridge: $FULL_BRIDGE"

    # Get provider network name from mappings
    PROVIDER_NET_NAME="${BRIDGE_TO_PHYSNET[$FULL_BRIDGE]}"

    if [ -z "$PROVIDER_NET_NAME" ]; then
      error "      Bridge $FULL_BRIDGE has no mapping in mappings annotation"
      error "      Each bridge must have a corresponding entry in 'mappings'"
      error "      Example: mappings='physnet1:br-ex,physnet2:br-ex1'"
      PROCESSING_ERRORS=$((PROCESSING_ERRORS + 1))
      continue
    fi

    log "      Provider network name: $PROVIDER_NET_NAME (from mappings)"

    # Get interface for this bridge
    INTERFACE="${PORT_MAP[$FULL_BRIDGE]}"

    if [ -z "$INTERFACE" ]; then
      error "      Bridge $FULL_BRIDGE has no interface mapping in ports annotation"
      error "      Each bridge in 'mappings' must have a corresponding entry in 'ports'"
      error "      Example: mappings='physnet1:br-ex,physnet2:br-ex1' ports='br-ex:eno2,br-ex1:eno3'"
      PROCESSING_ERRORS=$((PROCESSING_ERRORS + 1))
      continue
    fi

    log "      Physical interface: $INTERFACE (from ports)"

    # Use bridge name as ProviderNetwork name (KubeOVN creates bridge from ProviderNetwork name)
    PN_KEY="${FULL_BRIDGE}|${INTERFACE}|${PROVIDER_NET_NAME}"

    if [ -z "${PROVIDER_NETWORKS[$PN_KEY]}" ]; then
      PROVIDER_NETWORKS[$PN_KEY]="$NODE"
    else
      PROVIDER_NETWORKS[$PN_KEY]="${PROVIDER_NETWORKS[$PN_KEY]} $NODE"
    fi

    log "      ✓ Will create ProviderNetwork: $FULL_BRIDGE (physnet: $PROVIDER_NET_NAME, interface: $INTERFACE)"
  done

  # Clear the associative arrays for next iteration
  unset PORT_MAP
  unset BRIDGE_TO_PHYSNET
done

if [ $PROCESSING_ERRORS -gt 0 ]; then
  error "Encountered $PROCESSING_ERRORS error(s) during processing"
  exit 1
fi

if [ ${#PROVIDER_NETWORKS[@]} -eq 0 ]; then
  error "No external bridges with physical interfaces found"
  exit 1
fi

log ""
log "✓ Successfully processed all nodes"
log "✓ Will configure ${#PROVIDER_NETWORKS[@]} ProviderNetwork(s):"
for PN_KEY in "${!PROVIDER_NETWORKS[@]}"; do
  IFS='|' read -r BRIDGE INTERFACE PHYSNET <<< "$PN_KEY"
  log "    - $BRIDGE (physnet: $PHYSNET, interface: $INTERFACE)"
done

# Create/Update ProviderNetworks
log ""
log "Creating/Updating ProviderNetwork CRDs..."

CREATED=0
UPDATED=0
FAILED=0

for PN_KEY in "${!PROVIDER_NETWORKS[@]}"; do
  IFS='|' read -r BRIDGE INTERFACE PHYSNET <<< "$PN_KEY"
  NODES=${PROVIDER_NETWORKS[$PN_KEY]}
  NODE_LIST=$(echo "$NODES" | tr ' ' '\n' | sed 's/^/        - /')

  log ""
  log "ProviderNetwork: $BRIDGE"
  log "  Physical Network: $PHYSNET"
  log "  Interface: $INTERFACE"
  log "  Nodes: $NODES"

  if kubectl get provider-networks "$BRIDGE" &>/dev/null; then
    ACTION="updated"
    UPDATED=$((UPDATED + 1))
  else
    ACTION="created"
    CREATED=$((CREATED + 1))
  fi

  YAML_CONTENT=$(cat <<EOF
apiVersion: kubeovn.io/v1
kind: ProviderNetwork
metadata:
  name: $BRIDGE
  labels:
    managed-by: ovn-annotation-script
    openstack-physnet: "$PHYSNET"
  annotations:
    configured-by: configure-ovn.sh
    configured-at: "$(date -Iseconds)"
    openstack-physnet: "$PHYSNET"
spec:
  defaultInterface: $INTERFACE
  customInterfaces:
    - interface: $INTERFACE
      nodes:
$NODE_LIST
EOF
)

  log "  Applying ProviderNetwork..."
  if echo "$YAML_CONTENT" | kubectl apply -f - >> "$LOG_FILE" 2>&1; then
    log "  ✓ ProviderNetwork '$BRIDGE' $ACTION (physnet: $PHYSNET)"
  else
    error "  ✗ Failed to configure ProviderNetwork '$BRIDGE'"
    echo ""
    echo "YAML that failed:"
    echo "$YAML_CONTENT"
    echo ""
    echo "Error details:"
    kubectl apply -f - <<< "$YAML_CONTENT" 2>&1
    FAILED=$((FAILED + 1))
  fi
done

# Summary
log ""
log "=========================================="
log "Configuration Summary"
log "=========================================="
log ""

kubectl get provider-networks -l managed-by=ovn-annotation-script 2>&1 | tee -a "$LOG_FILE"

log ""
if [ $FAILED -eq 0 ]; then
  log "✅ External bridge configuration complete!"
else
  error "⚠️  Configuration completed with errors!"
fi
log ""
log "Statistics:"
log "  • Created: $CREATED ProviderNetwork(s)"
log "  • Updated: $UPDATED ProviderNetwork(s)"
log "  • Failed: $FAILED ProviderNetwork(s)"
log "  • Configured: $NODE_COUNT node(s)"
log ""
log "Verification commands:"
log "  # List all provider networks"
log "  kubectl get provider-networks"
log ""

# Generate describe commands for each provider network
UNIQUE_BRIDGES=$(for PN_KEY in "${!PROVIDER_NETWORKS[@]}"; do
  IFS='|' read -r BRIDGE _ _ <<< "$PN_KEY"
  echo "$BRIDGE"
done | sort -u)

for BRIDGE_NAME in $UNIQUE_BRIDGES; do
  log "  # View details for $BRIDGE_NAME"
  log "  kubectl describe provider-network $BRIDGE_NAME"
done

log ""
log "Full log: $LOG_FILE"

[ $FAILED -eq 0 ] || exit 1
