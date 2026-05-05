#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURE_ROOT="${TDS_OPENSTACK_CAPTURE_ROOT:-${ROOT}/captures/openstack-lab}"

OPENSTACK_HOST="${TDS_OPENSTACK_HOST:-ord-deployer}"
OPENSTACK_CLOUD="${TDS_OPENSTACK_CLOUD:-default}"
OPENSTACK_NETWORK="${TDS_OPENSTACK_NETWORK:-talos-lab-net}"
FLOATING_NETWORK="${TDS_OPENSTACK_FLOATING_NETWORK:-EXTERNAL_NETWORK}"
UBUNTU_IMAGE="${TDS_OPENSTACK_UBUNTU_IMAGE:-noble}"
UBUNTU_FLAVOR="${TDS_OPENSTACK_UBUNTU_FLAVOR:-m1.large}"
TALOS_FLAVOR="${TDS_OPENSTACK_TALOS_FLAVOR:-m1.medium}"
TALOS_VERSION="${TDS_TALOS_VERSION:-v1.13.0}"
KUBERNETES_VERSION="${TDS_KUBERNETES_VERSION:-v1.34.1}"
FACTORY_URL="${TDS_TALOS_FACTORY_URL:-https://factory.talos.dev}"
TALOS_EXTENSIONS="${TDS_TALOS_EXTENSIONS:-siderolabs/qemu-guest-agent,siderolabs/iscsi-tools,siderolabs/util-linux-tools,siderolabs/bnx2-bnx2x}"
TALOS_IMAGE_FORMAT="${TDS_OPENSTACK_TALOS_IMAGE_FORMAT:-qcow2}"
TALOS_IMAGE_USE_IMPORT="${TDS_OPENSTACK_TALOS_IMAGE_USE_IMPORT:-false}"
DEPLOYER_USER="${TDS_OPENSTACK_DEPLOYER_USER:-ubuntu}"
NETWORK_PREFIX="${TDS_OPENSTACK_NETWORK_PREFIX:-24}"
NETWORK_GATEWAY="${TDS_OPENSTACK_GATEWAY:-192.168.120.1}"
NETWORK_MTU="${TDS_OPENSTACK_MTU:-1442}"
DNS1="${TDS_OPENSTACK_DNS1:-1.1.1.1}"
DNS2="${TDS_OPENSTACK_DNS2:-1.0.0.1}"
TALOS_IMAGE_NAME="${TDS_OPENSTACK_TALOS_IMAGE_NAME:-tds-talos-openstack-${TALOS_VERSION}}"
CLEANUP="${TDS_OPENSTACK_CLEANUP:-always}"
PURGE_IMAGE=false
RUN_ID="${TDS_OPENSTACK_RUN_ID:-}"

usage() {
  cat <<'EOF'
usage: scripts/tds-openstack-lab.sh COMMAND [options]

Commands:
  prepare-image   Upload/cache the Talos OpenStack image for this run schematic.
  up              Create the Ubuntu deployer and 3 control-plane + 1 worker VMs.
  run-tds         Generate the TDS spec and run deployer-owned TDS flow.
  collect         Collect OpenStack console logs and deployer state.
  down            Delete ephemeral VMs, ports, floating IP, and keypair.
  e2e             prepare-image, up, run-tds, collect, and down.

Options:
  --run-id ID        Use or resume captures/openstack-lab/ID.
  --cleanup MODE    e2e cleanup mode: always or never. Default: always.
  --purge-image     With down, also delete the cached Talos image.
  --help            Show this help.

Environment overrides:
  TDS_OPENSTACK_HOST, TDS_OPENSTACK_CLOUD, TDS_OPENSTACK_NETWORK,
  TDS_OPENSTACK_FLOATING_NETWORK, TDS_OPENSTACK_UBUNTU_IMAGE,
  TDS_OPENSTACK_UBUNTU_FLAVOR, TDS_OPENSTACK_TALOS_FLAVOR,
  TDS_TALOS_VERSION, TDS_KUBERNETES_VERSION, TDS_TALOS_EXTENSIONS,
  TDS_OPENSTACK_TALOS_IMAGE_FORMAT, TDS_OPENSTACK_TALOS_IMAGE_USE_IMPORT.
EOF
}

log() {
  printf '[tds-openstack-lab] %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

init_run() {
  if [ -z "$RUN_ID" ]; then
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  RUN_DIR="${CAPTURE_ROOT}/${RUN_ID}"
  PREFIX="${TDS_OPENSTACK_PREFIX:-tds-oslab-${RUN_ID}}"
  STATE_FILE="${RUN_DIR}/state.json"
  PARTIAL_FILE="${RUN_DIR}/partial-resources.tsv"
  SPEC_FILE="${RUN_DIR}/deployment-spec.json"
  SCHEMATIC_FILE="${RUN_DIR}/talos-openstack-schematic.yaml"
  IMAGE_ENV="${RUN_DIR}/image.env"
  KEY_PATH="${RUN_DIR}/${PREFIX}-key"
  mkdir -p "$RUN_DIR" "$RUN_DIR/logs"
}

remote() {
  ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20 "$OPENSTACK_HOST" "$@"
}

remote_bash() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20 "$OPENSTACK_HOST" 'bash -s' -- "$@"
}

remote_put() {
  local path="$1"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20 "$OPENSTACK_HOST" "cat > '$path'"
}

os() {
  remote openstack --os-cloud "$OPENSTACK_CLOUD" "$@"
}

track_resource() {
  local type="$1"
  local id="$2"
  [ -n "$id" ] || return 0
  printf '%s\t%s\n' "$type" "$id" >> "$PARTIAL_FILE"
}

delete_prefixed_servers() {
  local ids
  for attempt in $(seq 1 6); do
    ids="$(os server list --name "$PREFIX" -f value -c ID || true)"
    [ -n "$ids" ] || return 0
    printf '%s\n' "$ids" | while IFS= read -r server_id; do
      [ -n "$server_id" ] || continue
      os server delete --wait "$server_id" >/dev/null 2>&1 || true
    done
    sleep 5
  done
}

delete_prefixed_ports() {
  local ids
  for attempt in $(seq 1 6); do
    ids="$(os port list --name "$PREFIX" -f value -c ID || true)"
    [ -n "$ids" ] || return 0
    printf '%s\n' "$ids" | while IFS= read -r port_id; do
      [ -n "$port_id" ] || continue
      os port delete "$port_id" >/dev/null 2>&1 || true
    done
    sleep 5
  done
}

tds() {
  if [ -n "${TDS_BIN:-}" ]; then
    "$TDS_BIN" "$@"
  else
    (cd "$ROOT" && swift run tds "$@")
  fi
}

write_schematic() {
  local extensions="$TALOS_EXTENSIONS"
  {
    printf 'customization:\n'
    printf '  systemExtensions:\n'
    printf '    officialExtensions:\n'
    IFS=',' read -r -a extension_array <<< "$extensions"
    for extension in "${extension_array[@]}"; do
      extension="$(printf '%s' "$extension" | xargs)"
      [ -n "$extension" ] || continue
      printf '      - %s\n' "$extension"
    done
  } > "$SCHEMATIC_FILE"
}

resolve_schematic() {
  need curl
  need jq
  write_schematic
  local response
  response="$(curl -fsS -X POST --data-binary @"$SCHEMATIC_FILE" "${FACTORY_URL%/}/schematics")"
  TALOS_SCHEMATIC_ID="$(printf '%s' "$response" | jq -r '.id')"
  [ -n "$TALOS_SCHEMATIC_ID" ] && [ "$TALOS_SCHEMATIC_ID" != "null" ] || die "Image Factory did not return a schematic id"
  {
    printf 'TALOS_SCHEMATIC_ID=%q\n' "$TALOS_SCHEMATIC_ID"
    printf 'TALOS_IMAGE_NAME=%q\n' "$TALOS_IMAGE_NAME"
  } > "$IMAGE_ENV"
  log "resolved Talos schematic ${TALOS_SCHEMATIC_ID}"
}

load_image_env() {
  [ -f "$IMAGE_ENV" ] || resolve_schematic
  # shellcheck disable=SC1090
  . "$IMAGE_ENV"
}

prepare_image() {
  init_run
  resolve_schematic
  load_image_env
  local image_status
  image_status="$(os image show "$TALOS_IMAGE_NAME" -f value -c status 2>/dev/null || true)"
  if [ "$image_status" = "active" ]; then
    log "Talos image already exists: ${TALOS_IMAGE_NAME}"
    return
  fi
  if [ -n "$image_status" ]; then
    log "deleting non-active Talos image cache ${TALOS_IMAGE_NAME} with status ${image_status}"
    os image delete "$TALOS_IMAGE_NAME" >/dev/null 2>&1 || true
  fi

  log "uploading Talos ${TALOS_VERSION} OpenStack image ${TALOS_IMAGE_NAME}"
  remote_bash "$OPENSTACK_CLOUD" "$FACTORY_URL" "$TALOS_VERSION" "$TALOS_SCHEMATIC_ID" "$TALOS_IMAGE_NAME" "$TALOS_IMAGE_FORMAT" "$TALOS_IMAGE_USE_IMPORT" <<'REMOTE'
set -euo pipefail
cloud="$1"
factory_url="${2%/}"
talos_version="$3"
schematic_id="$4"
image_name="$5"
disk_format="$6"
use_import="$7"
work="/var/tmp/tds-openstack-images/${talos_version}-${schematic_id}"
mkdir -p "$work"
xz_path="${work}/openstack-amd64.raw.xz"
raw_path="${work}/openstack-amd64.raw"
qcow_path="${work}/openstack-amd64.qcow2"
url="${factory_url}/image/${schematic_id}/${talos_version}/openstack-amd64.raw.xz"
status="$(openstack --os-cloud "$cloud" image show "$image_name" -f value -c status 2>/dev/null || true)"
if [ "$status" != "active" ]; then
  if [ -n "$status" ]; then
    openstack --os-cloud "$cloud" image delete "$image_name" >/dev/null 2>&1 || true
  fi
  if [ ! -s "$xz_path" ]; then
    curl -fL --retry 3 --retry-delay 5 -o "$xz_path" "$url"
  fi
  if [ ! -s "$raw_path" ] || [ "$xz_path" -nt "$raw_path" ]; then
    unxz -k -f "$xz_path"
  fi
  case "$disk_format" in
    raw)
      upload_path="$raw_path"
      ;;
    qcow2)
      if ! command -v qemu-img >/dev/null 2>&1; then
        echo "[tds-openstack-lab] qemu-img is required for qcow2 image upload; install qemu-utils or set TDS_OPENSTACK_TALOS_IMAGE_FORMAT=raw" >&2
        exit 1
      fi
      if [ ! -s "$qcow_path" ] || [ "$raw_path" -nt "$qcow_path" ]; then
        qemu-img convert -p -f raw -O qcow2 -c "$raw_path" "$qcow_path"
      fi
      upload_path="$qcow_path"
      ;;
    *)
      echo "[tds-openstack-lab] unsupported Talos image format: ${disk_format}" >&2
      exit 1
      ;;
  esac
  upload_rc=0
  for attempt in 1 2 3; do
    openstack --os-cloud "$cloud" image delete "$image_name" >/dev/null 2>&1 || true
    image_args=(
      image create "$image_name"
      --container-format bare
      --disk-format "$disk_format"
      --file "$upload_path"
      --property os_distro=talos \
      --property os_version="${talos_version#v}" \
      --property os_admin_user=talos \
      --property hw_firmware_type=uefi \
      --property hw_machine_type=q35 \
      --property hw_qemu_guest_agent=yes \
      --property hw_vif_multiqueue_enabled=true \
      --property img_config_drive=optional \
      --tag tds-openstack-lab
    )
    if [ "$use_import" = "true" ]; then
      image_args+=(--import)
    fi
    if openstack --os-cloud "$cloud" "${image_args[@]}"; then
      upload_rc=0
      break
    else
      upload_rc=$?
    fi
    echo "[tds-openstack-lab] image upload attempt ${attempt}/3 failed with rc=${upload_rc}" >&2
    if [ "$attempt" -eq 3 ]; then
      exit "$upload_rc"
    fi
    sleep $((attempt * 15))
  done
  for status_attempt in $(seq 1 60); do
    status="$(openstack --os-cloud "$cloud" image show "$image_name" -f value -c status 2>/dev/null || true)"
    if [ "$status" = "active" ]; then
      break
    fi
    if [ "$status" = "killed" ] || [ "$status" = "deleted" ]; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "active" ]; then
    echo "[tds-openstack-lab] image ${image_name} ended with status ${status:-missing}" >&2
    exit 1
  fi
fi
REMOTE
}

create_keypair() {
  need ssh-keygen
  [ -f "$KEY_PATH" ] || ssh-keygen -t ed25519 -N '' -f "$KEY_PATH" -C "$PREFIX" >/dev/null
  chmod 0600 "$KEY_PATH"
  if os keypair show "$PREFIX" >/dev/null 2>&1; then
    track_resource keypair "$PREFIX"
    return
  fi
  local remote_pub="/tmp/${PREFIX}.pub"
  remote_put "$remote_pub" < "${KEY_PATH}.pub"
  os keypair create --public-key "$remote_pub" "$PREFIX" >/dev/null
  remote rm -f "$remote_pub"
  track_resource keypair "$PREFIX"
}

create_port_json() {
  local name="$1"
  shift
  local args=(port create "$name" --network "$OPENSTACK_NETWORK")
  for sg in "$@"; do
    args+=(--security-group "$sg")
  done
  os "${args[@]}" -f json
}

create_server_json() {
  local name="$1"
  local image="$2"
  local flavor="$3"
  local port_id="$4"
  local key_name="$5"
  shift 5
  local args=(server create "$name" --image "$image" --flavor "$flavor" --port "$port_id" --wait)
  if [ -n "$key_name" ]; then
    args+=(--key-name "$key_name")
  fi
  while [ "$#" -gt 0 ]; do
    args+=("$1")
    shift
  done
  os "${args[@]}" -f json
}

wait_for_deployer_ssh() {
  local host="$1"
  log "waiting for SSH on deployer ${host} through ${OPENSTACK_HOST}"
  for attempt in $(seq 1 60); do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEY_PATH" -J "$OPENSTACK_HOST" "${DEPLOYER_USER}@${host}" true >/dev/null 2>&1; then
      return
    fi
    if [ "$attempt" -eq 60 ]; then
      die "timed out waiting for SSH on deployer ${host}"
    fi
    sleep 10
  done
}

write_state() {
  local deployer_port_json="$1"
  local deployer_server_json="$2"
  local fip_json="$3"
  local cp1_port_json="$4"
  local cp1_server_json="$5"
  local cp2_port_json="$6"
  local cp2_server_json="$7"
  local cp3_port_json="$8"
  local cp3_server_json="$9"
  local worker_port_json="${10}"
  local worker_server_json="${11}"

  jq -n \
    --arg run_id "$RUN_ID" \
    --arg prefix "$PREFIX" \
    --arg keypair "$PREFIX" \
    --arg private_key "$KEY_PATH" \
    --arg network "$OPENSTACK_NETWORK" \
    --arg network_prefix "$NETWORK_PREFIX" \
    --arg gateway "$NETWORK_GATEWAY" \
    --arg mtu "$NETWORK_MTU" \
    --arg dns1 "$DNS1" \
    --arg dns2 "$DNS2" \
    --arg floating_network "$FLOATING_NETWORK" \
    --arg talos_image "$TALOS_IMAGE_NAME" \
    --arg schematic_id "$TALOS_SCHEMATIC_ID" \
    --arg talos_version "$TALOS_VERSION" \
    --argjson deployer_port "$deployer_port_json" \
    --argjson deployer_server "$deployer_server_json" \
    --argjson fip "$fip_json" \
    --argjson cp1_port "$cp1_port_json" \
    --argjson cp1_server "$cp1_server_json" \
    --argjson cp2_port "$cp2_port_json" \
    --argjson cp2_server "$cp2_server_json" \
    --argjson cp3_port "$cp3_port_json" \
    --argjson cp3_server "$cp3_server_json" \
    --argjson worker_port "$worker_port_json" \
    --argjson worker_server "$worker_server_json" \
    '
    def ip($port): $port.fixed_ips[0].ip_address;
    def mac($port): $port.mac_address;
    def node($role; $name; $port; $server): {
      role: $role,
      name: $name,
      port_id: $port.id,
      server_id: $server.id,
      fixed_ip: ip($port),
      mac_address: mac($port)
    };
    {
      run_id: $run_id,
      prefix: $prefix,
      keypair: $keypair,
      private_key: $private_key,
      network: { name: $network, prefix: $network_prefix, gateway: $gateway, mtu: ($mtu | tonumber), dns: [$dns1, $dns2] },
      floating_ip: { id: $fip.id, address: $fip.floating_ip_address, network: $floating_network },
      images: { talos: $talos_image, schematic_id: $schematic_id, talos_version: $talos_version },
      deployer: node("deployer"; ($prefix + "-deployer"); $deployer_port; $deployer_server),
      talos_nodes: [
        node("controlplane"; ($prefix + "-cp1"); $cp1_port; $cp1_server),
        node("controlplane"; ($prefix + "-cp2"); $cp2_port; $cp2_server),
        node("controlplane"; ($prefix + "-cp3"); $cp3_port; $cp3_server),
        node("worker"; ($prefix + "-worker1"); $worker_port; $worker_server)
      ]
    }' > "$STATE_FILE"
}

render_spec() {
  need jq
  [ -f "$STATE_FILE" ] || die "state file not found: $STATE_FILE"
  local cluster_name="tds-openstack-lab-${RUN_ID}"
  jq -n \
    --slurpfile state "$STATE_FILE" \
    --arg cluster_name "$cluster_name" \
    --arg talos_version "$TALOS_VERSION" \
    --arg kubernetes_version "$KUBERNETES_VERSION" \
    --arg extensions "$TALOS_EXTENSIONS" \
    '
    def st: $state[0];
    def cidr($ip): ($ip + "/" + st.network.prefix);
    def iface($node): [{
      id: $node.port_id,
      name: "eth0",
      addresses: [cidr($node.fixed_ip)],
      macAddress: $node.mac_address,
      mtu: st.network.mtu
    }];
    def static_network($node): {
      managementInterface: "eth0",
      managementAddressCIDR: cidr($node.fixed_ip),
      gateway: st.network.gateway,
      nameservers: st.network.dns,
      searchDomains: ["openstack.local"],
      routes: [{ to: "default", via: st.network.gateway }],
      vlans: [],
      bridges: []
    };
    def device($node; $os): {
      id: $node.server_id,
      accountNumber: "openstack-lab",
      name: $node.name,
      primaryIP: (if $node.role == "deployer" then st.floating_ip.address else $node.fixed_ip end),
      privateIP: $node.fixed_ip,
      platformName: "OpenStack",
      osType: $os,
      serviceTag: "",
      installDisk: "/dev/vda",
      networkInterfaces: iface($node)
    };
    def deployer_node: {
      device: device(st.deployer; "Ubuntu 24.04"),
      assignment: {
        deviceID: st.deployer.server_id,
        role: "deployer",
        deployerMode: "existing",
        shouldInstallOS: false,
        preferredInstall: "automatic",
        networkSource: "manual",
        staticNetwork: static_network(st.deployer)
      }
    };
    def talos_node($node): {
      device: device($node; "Talos"),
      assignment: {
        deviceID: $node.server_id,
        role: $node.role,
        deployerMode: "existing",
        shouldInstallOS: false,
        preferredInstall: "stagedOnly",
        networkSource: "manual",
        staticNetwork: static_network($node)
      }
    };
    {
      accountNumber: "openstack-lab",
      clusterName: $cluster_name,
      clusterEndpoint: ("https://" + st.talos_nodes[0].fixed_ip + ":6443"),
      talosVersion: $talos_version,
      kubernetesVersion: $kubernetes_version,
      deployerStateRoot: "/var/lib/talos-deploy",
      talosFactory: {
        baseURL: "https://factory.talos.dev",
        pxeBaseURL: "https://pxe.factory.talos.dev",
        registryHost: "factory.talos.dev",
        architecture: "amd64",
        platform: "metal",
        schematicID: st.images.schematic_id,
        selectedSystemExtensions: ($extensions | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
        extraKernelArgs: []
      },
      talosProvisioning: {
        wipeSystemDiskBeforeInstall: false,
        allowDeployerRegistry: true,
        deployerRegistryPort: 5000,
        deployerRegistryMirrorHosts: ["ghcr.io", "registry.k8s.io"],
        allowDeployerHostedMedia: false,
        allowDeployerPXE: false,
        allowExternalOOBURL: false
      },
      enableLonghornExtraMounts: false,
      nodes: ([deployer_node] + (st.talos_nodes | map(talos_node(.))))
    }' > "$SPEC_FILE"
  log "rendered TDS spec at ${SPEC_FILE}"
}

up() {
  init_run
  need jq
  prepare_image
  create_keypair

  log "creating OpenStack ports and servers for ${PREFIX}"
  local deployer_port_json deployer_server_json fip_json
  local cp1_port_json cp1_server_json cp2_port_json cp2_server_json
  local cp3_port_json cp3_server_json worker_port_json worker_server_json

  deployer_port_json="$(create_port_json "${PREFIX}-deployer-port" talos-lab-secgroup talos-lab-jump-secgroup)"
  track_resource port "$(printf '%s' "$deployer_port_json" | jq -r '.id')"
  cp1_port_json="$(create_port_json "${PREFIX}-cp1-port" talos-lab-secgroup talos-lab-talos-secgroup)"
  track_resource port "$(printf '%s' "$cp1_port_json" | jq -r '.id')"
  cp2_port_json="$(create_port_json "${PREFIX}-cp2-port" talos-lab-secgroup talos-lab-talos-secgroup)"
  track_resource port "$(printf '%s' "$cp2_port_json" | jq -r '.id')"
  cp3_port_json="$(create_port_json "${PREFIX}-cp3-port" talos-lab-secgroup talos-lab-talos-secgroup)"
  track_resource port "$(printf '%s' "$cp3_port_json" | jq -r '.id')"
  worker_port_json="$(create_port_json "${PREFIX}-worker1-port" talos-lab-secgroup talos-lab-talos-secgroup)"
  track_resource port "$(printf '%s' "$worker_port_json" | jq -r '.id')"

  deployer_server_json="$(create_server_json "${PREFIX}-deployer" "$UBUNTU_IMAGE" "$UBUNTU_FLAVOR" "$(printf '%s' "$deployer_port_json" | jq -r '.id')" "$PREFIX")"
  track_resource server "$(printf '%s' "$deployer_server_json" | jq -r '.id')"
  cp1_server_json="$(create_server_json "${PREFIX}-cp1" "$TALOS_IMAGE_NAME" "$TALOS_FLAVOR" "$(printf '%s' "$cp1_port_json" | jq -r '.id')" "" --config-drive true)"
  track_resource server "$(printf '%s' "$cp1_server_json" | jq -r '.id')"
  cp2_server_json="$(create_server_json "${PREFIX}-cp2" "$TALOS_IMAGE_NAME" "$TALOS_FLAVOR" "$(printf '%s' "$cp2_port_json" | jq -r '.id')" "" --config-drive true)"
  track_resource server "$(printf '%s' "$cp2_server_json" | jq -r '.id')"
  cp3_server_json="$(create_server_json "${PREFIX}-cp3" "$TALOS_IMAGE_NAME" "$TALOS_FLAVOR" "$(printf '%s' "$cp3_port_json" | jq -r '.id')" "" --config-drive true)"
  track_resource server "$(printf '%s' "$cp3_server_json" | jq -r '.id')"
  worker_server_json="$(create_server_json "${PREFIX}-worker1" "$TALOS_IMAGE_NAME" "$TALOS_FLAVOR" "$(printf '%s' "$worker_port_json" | jq -r '.id')" "" --config-drive true)"
  track_resource server "$(printf '%s' "$worker_server_json" | jq -r '.id')"

  fip_json="$(os floating ip create "$FLOATING_NETWORK" -f json)"
  track_resource fip "$(printf '%s' "$fip_json" | jq -r '.id')"
  os server add floating ip "$(printf '%s' "$deployer_server_json" | jq -r '.id')" "$(printf '%s' "$fip_json" | jq -r '.floating_ip_address')"

  write_state \
    "$deployer_port_json" "$deployer_server_json" "$fip_json" \
    "$cp1_port_json" "$cp1_server_json" \
    "$cp2_port_json" "$cp2_server_json" \
    "$cp3_port_json" "$cp3_server_json" \
    "$worker_port_json" "$worker_server_json"
  render_spec
  wait_for_deployer_ssh "$(jq -r '.floating_ip.address' "$STATE_FILE")"
  log "OpenStack lab is up; state=${STATE_FILE}"
}

run_tds() {
  init_run
  [ -f "$STATE_FILE" ] || die "state file not found: $STATE_FILE"
  render_spec
  local fip
  fip="$(jq -r '.floating_ip.address' "$STATE_FILE")"
  log "running TDS against deployer ${fip}"
  tds deploy run \
    --spec "$SPEC_FILE" \
    --execute true \
    --access directSSH \
    --deployer-host "$fip" \
    --deployer-user "$DEPLOYER_USER" \
    --identity-file "$KEY_PATH" \
    --proxy-jump "$OPENSTACK_HOST" 2>&1 | tee "$RUN_DIR/tds-run.log"
}

collect() {
  init_run
  [ -f "$STATE_FILE" ] || die "state file not found: $STATE_FILE"
  mkdir -p "$RUN_DIR/openstack" "$RUN_DIR/deployer-state"
  log "collecting OpenStack and deployer evidence"
  os server list --long -f table > "$RUN_DIR/openstack/server-list.txt" || true
  os port list --network "$OPENSTACK_NETWORK" -f table > "$RUN_DIR/openstack/port-list.txt" || true
  jq -r '.deployer.server_id, (.talos_nodes[].server_id)' "$STATE_FILE" | while IFS= read -r server_id; do
    [ -n "$server_id" ] || continue
    os server show "$server_id" -f yaml > "$RUN_DIR/openstack/${server_id}.server.yaml" || true
    os console log show "$server_id" > "$RUN_DIR/openstack/${server_id}.console.log" || true
  done
  local fip
  fip="$(jq -r '.floating_ip.address' "$STATE_FILE")"
  rsync -az --delete \
    --exclude 'bin/talosctl' \
    --exclude 'registry/' \
    --exclude 'media/*.iso' \
    --exclude 'media/*.raw' \
    --exclude 'media/*.raw.xz' \
    --exclude 'media/*.qcow2' \
    -e "ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i ${KEY_PATH} -J ${OPENSTACK_HOST}" \
    "${DEPLOYER_USER}@${fip}:/var/lib/talos-deploy/" \
    "$RUN_DIR/deployer-state/" >/dev/null 2>&1 || true
  log "collected evidence under ${RUN_DIR}"
}

down() {
  init_run
  [ -f "$STATE_FILE" ] || die "state file not found: $STATE_FILE"
  log "deleting OpenStack lab resources for ${PREFIX}"
  jq -r '.deployer.server_id, (.talos_nodes[].server_id)' "$STATE_FILE" | while IFS= read -r server_id; do
    [ -n "$server_id" ] || continue
    os server delete --wait "$server_id" >/dev/null 2>&1 || true
  done
  delete_prefixed_servers
  local fip_id
  fip_id="$(jq -r '.floating_ip.id // empty' "$STATE_FILE")"
  [ -z "$fip_id" ] || os floating ip delete "$fip_id" >/dev/null 2>&1 || true
  jq -r '.deployer.port_id, (.talos_nodes[].port_id)' "$STATE_FILE" | while IFS= read -r port_id; do
    [ -n "$port_id" ] || continue
    os port delete "$port_id" >/dev/null 2>&1 || true
  done
  delete_prefixed_ports
  os keypair delete "$(jq -r '.keypair' "$STATE_FILE")" >/dev/null 2>&1 || true
  os keypair delete "$PREFIX" >/dev/null 2>&1 || true
  if [ "$PURGE_IMAGE" = true ]; then
    os image delete "$(jq -r '.images.talos' "$STATE_FILE")" >/dev/null 2>&1 || true
  fi
  rm -f "$PARTIAL_FILE"
  log "cleanup complete"
}

down_partial() {
  init_run
  [ -f "$PARTIAL_FILE" ] || {
    log "no partial resource tracking file found for ${PREFIX}"
    return 0
  }
  log "deleting partially created OpenStack lab resources for ${PREFIX}"
  awk '$1 == "server" { print $2 }' "$PARTIAL_FILE" | while IFS= read -r server_id; do
    [ -n "$server_id" ] || continue
    os server delete --wait "$server_id" >/dev/null 2>&1 || true
  done
  awk '$1 == "fip" { print $2 }' "$PARTIAL_FILE" | while IFS= read -r fip_id; do
    [ -n "$fip_id" ] || continue
    os floating ip delete "$fip_id" >/dev/null 2>&1 || true
  done
  awk '$1 == "port" { print $2 }' "$PARTIAL_FILE" | while IFS= read -r port_id; do
    [ -n "$port_id" ] || continue
    os port delete "$port_id" >/dev/null 2>&1 || true
  done
  awk '$1 == "keypair" { print $2 }' "$PARTIAL_FILE" | while IFS= read -r keypair; do
    [ -n "$keypair" ] || continue
    os keypair delete "$keypair" >/dev/null 2>&1 || true
  done
  rm -f "$PARTIAL_FILE"
  log "partial cleanup complete"
}

e2e_cleanup_on_exit() {
  local rc=$?
  [ "${E2E_CLEANUP_ON_EXIT:-false}" = true ] || return "$rc"
  [ "$CLEANUP" = "always" ] || return "$rc"
  [ "$rc" -ne 0 ] || return "$rc"
  log "e2e failed with rc=${rc}; cleaning up tracked resources"
  if [ -f "$STATE_FILE" ]; then
    collect || true
    down || true
  else
    down_partial || true
  fi
  return "$rc"
}

e2e() {
  init_run
  local rc=0
  E2E_CLEANUP_ON_EXIT=true
  trap e2e_cleanup_on_exit EXIT
  up
  set +e
  run_tds
  rc=$?
  set -e
  collect || true
  if [ "$CLEANUP" = "always" ]; then
    down || true
  else
    log "cleanup=${CLEANUP}; leaving resources running"
  fi
  E2E_CLEANUP_ON_EXIT=false
  trap - EXIT
  return "$rc"
}

COMMAND="${1:-}"
[ -n "$COMMAND" ] || { usage; exit 2; }
shift || true

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id)
      RUN_ID="${2:-}"
      [ -n "$RUN_ID" ] || die "--run-id requires a value"
      shift 2
      ;;
    --cleanup)
      CLEANUP="${2:-}"
      [ "$CLEANUP" = "always" ] || [ "$CLEANUP" = "never" ] || die "--cleanup must be always or never"
      shift 2
      ;;
    --purge-image)
      PURGE_IMAGE=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

case "$COMMAND" in
  prepare-image)
    prepare_image
    ;;
  up)
    up
    ;;
  run-tds)
    run_tds
    ;;
  collect)
    collect
    ;;
  down)
    down
    ;;
  e2e)
    e2e
    ;;
  *)
    usage
    exit 2
    ;;
esac
