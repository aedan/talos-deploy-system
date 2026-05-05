# TDS Quickstart

This is the shortest practical path for using `tds`. The desktop app is the primary operator interface; the CLI covers the same core workflows for automation, validation, and repeatable runbooks.

For the full feature and options reference, see [docs/QUICK_START.md](docs/QUICK_START.md).

## Open TDS

Use the released desktop app and CLI artifacts provided for your workstation.

1. Open `tds.app` for the normal desktop workflow.
2. Put the released `tds` CLI on `PATH` for automation and runbook checks.
3. Keep the released resource bundle next to the CLI binary.
4. If macOS blocks the unsigned alpha app, use the normal Finder trust action for the app.

## Prerequisites

- macOS 14 or newer.
- Network access to Core, Hammertime-backed Core auth, OOB/iLO/iDRAC paths, and any required proxy or bastion.
- `ht` when using Hammertime inventory, OOB helpers, live facts, or Hammertime deployer access.
- A stock Ubuntu 24.04 server ISO when building deployer install media.
- `xorriso` when building or validating Ubuntu autoinstall media.
- SSH access to the Ubuntu deployer after install.
- `TDS_RACK_PASSWORD_HASH` and `TDS_ROOT_PASSWORD_HASH`, or secure UI input, when building Ubuntu media.

Keep real account numbers, device IDs, credentials, generated specs, Talos secrets, kubeconfigs, and captures out of git.

## Workflow At A Glance

1. Load account inventory.
2. Select exactly one Ubuntu deployer.
3. Select Talos control-plane and worker nodes.
4. Review final static networking for every Talos node.
5. Build or validate Ubuntu 24.04 on the deployer.
6. Prepare deployer services.
7. Stage and run Talos deployment.
8. Use recovery actions to resume, reprovision, verify, or collect maintenance bundles.

## UI Quickstart

### 1. Sign In

Open `tds.app`, then use **Sign In**.

- Click **Refresh Session** to detect a stored Core session.
- Click **Import From Hammertime Cache** if Hammertime already has an active Core-authenticated session.
- Use manual username/header/secret only when needed.

### 2. Load Inventory

Go to **Inventory + Roles**.

1. Enter the Rackspace account number.
2. Click **Load Devices**.
3. Wait for the loading indicator to clear.
4. Use the filter field to search by name, device ID, IP, OOB address, platform, or role.

Assign roles:

- Pick exactly one `deployer`.
- Pick one or more `controlplane` nodes.
- Pick any `worker` nodes.
- Leave unrelated devices `unassigned`.

For Talos nodes, review **Talos Static Networking** and the install preference. Use `stagedOnly` only for cloud-image or already-booted Talos nodes that should be configured in place.

### 3. Configure Settings

Open **Settings**.

Important sections:

- **Core Session**: inventory source `auto`, `core`, or `hammertime`.
- **Hammertime**: `ht` path, SSO preflight, deployer copy/command behavior.
- **Talos Defaults**: Talos version, Kubernetes version, system extensions, kernel modules, Image Factory options.
- **Talos Provisioning**: deployer-hosted media, PXE, OOB URL media, registry mirror, wipe, BIOS support.
- **Bootstrap Media**: first Ubuntu deployer media delivery.
- **Deployer Defaults**: SSH user, state root, HTTP/registry ports, package cache.

### 4. Bootstrap Or Validate The Ubuntu Deployer

Go to **Bootstrap Deployer**.

Use this when the selected deployer needs Ubuntu 24.04 installed or rebuilt:

1. Capture a preinstall snapshot.
2. Build Ubuntu autoinstall media.
3. Validate the ISO.
4. Prepare an iLO local-media session or use explicit OOB URL boot when the OOB network can fetch the media.

If the deployer already has Ubuntu 24.04 and SSH works, skip the ISO build and go to deployer operations.

### 5. Prepare Talos Artifacts

Go to **Talos Factory**.

- **Refresh Versions** loads deployable Talos versions.
- **Render Schematic** shows the Image Factory schematic.
- **Upload Schematic** resolves a schematic ID.
- **Compute Artifacts** shows ISO, PXE, and installer references.
- **Talos OOB URL Boot** can direct-boot explicitly configured OOB-reachable media.

### 6. Prepare The Deployer

Go to **Deployer Ops**.

1. Click **Plan Services** to review what will be installed/configured.
2. Click **Test Access** to validate the deployer path.
3. Click **Prepare Deployer** to install/configure deployer services.

The deployer hosts media, caches images, serves registry content, stores deployment state, and runs Talos apply/bootstrap/health scripts.

### 7. Stage And Run Deployment

Go to **Deployment Run**.

For UI-selected inventory:

1. Click **Stage Selected Inventory**.
2. Review the plan and warnings.
3. Click **Dry Run Selected Inventory**.
4. Click **Execute Selected Inventory** only after the plan and deployer access are correct.

For a checked-in/local JSON spec:

1. Enter the spec path.
2. Click **Plan Spec**.
3. Click **Dry Run Spec**.
4. Click **Execute Spec** when ready.

### 8. Recover Or Resume

Go to **Recovery**.

Use this for:

- Loading a previous deployment state.
- Resuming the deployer-owned apply/bootstrap/health phase.
- Reprovisioning selected Talos nodes.
- Preparing installed-disk boot.
- Verifying cluster health.
- Rewriting a maintenance bundle.
- Direct OOB URL boot for a selected device.

## CLI Quickstart

Replace fake account numbers and device IDs with local operator values.

### 1. Session And Inventory

```bash
tds login --source hammertime
tds devices --account 0000000 --source auto --output table
tds facts --account 0000000 --source auto 100001 100002 100003
```

### 2. Ubuntu Deployer Media

```bash
tds ubuntu snapshot \
  --account 0000000 \
  --device 100001 \
  --source auto \
  --output-dir ~/tds-captures

tds ubuntu network-plan \
  --capture ~/tds-captures/0000000/100001/snapshot.json \
  --output yaml

tds ubuntu build-iso \
  --capture ~/tds-captures/0000000/100001/snapshot.json \
  --source-iso ~/iso/ubuntu-24.04-live-server-amd64.iso \
  --output-iso ~/iso/tds-100001-ubuntu.iso \
  --rack-password-hash "$TDS_RACK_PASSWORD_HASH" \
  --root-password-hash "$TDS_ROOT_PASSWORD_HASH"

tds ubuntu validate-iso --iso ~/iso/tds-100001-ubuntu.iso
```

When explicitly using OOB-reachable URL media:

```bash
tds ubuntu oob-boot-url \
  --device 100001 \
  --url http://oob-reachable.example.test/tds-100001-ubuntu.iso \
  --one-time-boot usb \
  --reboot true
```

### 3. Talos Factory

```bash
tds talos versions --output table

tds talos schematic \
  --extensions siderolabs/iscsi-tools,siderolabs/util-linux-tools,siderolabs/bnx2-bnx2x

tds talos upload-schematic \
  --extensions siderolabs/iscsi-tools,siderolabs/util-linux-tools,siderolabs/bnx2-bnx2x \
  --output json

tds talos artifacts \
  --version v1.13.0 \
  --arch amd64 \
  --platform metal
```

### 4. Deployer Access And Preparation

```bash
tds deployer access-test \
  --account 0000000 \
  --device 100001 \
  --access auto

tds deployer prepare \
  --account 0000000 \
  --device 100001 \
  --access auto
```

### 5. Deployment Spec Run

Start from [examples/deployment-spec.example.json](examples/deployment-spec.example.json), then keep real specs in ignored local state.

```bash
tds deploy plan --spec path/to/deployment-spec.json

tds deploy run \
  --spec path/to/deployment-spec.json \
  --dry-run true \
  --access auto

tds deploy run \
  --spec path/to/deployment-spec.json \
  --execute true \
  --access auto
```

### 6. Recovery

```bash
STATE="$HOME/Library/Application Support/tds/state/0000000/cluster.local/deployment-state.json"

tds deploy resume \
  --path "$STATE" \
  --execute true \
  --access auto

tds deploy reprovision \
  --state "$STATE" \
  --targets 100002,100003 \
  --execute true \
  --access auto

tds deploy disk-boot \
  --state "$STATE" \
  --targets 100002,100003 \
  --reboot true \
  --execute true

tds deploy verify --state "$STATE"
tds deploy maintenance-bundle --state "$STATE"
```

## UI To CLI Map

| UI Area | CLI Equivalent |
| --- | --- |
| Sign In | `tds login` |
| Inventory + Roles | `tds devices`, `tds facts`, deployment spec node roles |
| Bootstrap Deployer | `tds ubuntu snapshot`, `network-plan`, `build-iso`, `validate-iso`, `local-media-plan`, `oob-boot-url` |
| Talos Factory | `tds talos versions`, `schematic`, `upload-schematic`, `artifacts`, `oob-boot-url` |
| Deployer Ops | `tds deployer access-test`, `tds deployer prepare`, `tds deploy deployer plan` |
| Deployment Run | `tds deploy plan`, `tds deploy run` |
| Recovery | `tds deploy resume`, `reprovision`, `disk-boot`, `verify`, `maintenance-bundle` |
| Settings | Local app settings and CLI defaults loaded from the same settings model |

## Notes

- Dry-run first. Execute only after inventory, static networking, OOB media, and deployer access are known good.
- The Ubuntu deployer is not a Kubernetes node. It is the in-environment host that owns media, registry, generated config, and Talos bootstrap/health operations.
- DHCP can be used for live boot, but final Talos machine configs should use static management networking.
- Captures may contain secrets. Keep them under ignored local directories such as `captures/` or `~/tds-captures`.
