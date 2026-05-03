# tds

`tds` is a macOS-first Rackspace bare-metal Talos deployment tool. The desktop app is the primary operator experience, and the CLI exists for testing, automation, and repeatable deployment runs from any Core-capable Mac workstation.

The deployer is a selected physical server that receives Ubuntu first and then manages Talos artifacts, PXE/media services, machine configs, cluster bootstrap, and health checks. The deployer is not a Talos node.

## Prerequisites

- macOS 14 or newer.
- Xcode or Xcode Command Line Tools for source builds.
- Git for source checkout and updates.
- Network access from the operator workstation to Core, Hammertime-backed Core auth, OOB/iLO/iDRAC access paths, and any configured proxy.
- `ht` when using Hammertime/Core bridge inventory or live facts.
- `xorriso` for Ubuntu autoinstall ISO rebuild and validation.
- Stock Ubuntu 24.04 server ISO for deployer bootstrap installs.
- SSH access to the Ubuntu deployer after install for service preparation and Talos execution.
- `TDS_RACK_PASSWORD_HASH` and `TDS_ROOT_PASSWORD_HASH`, or equivalent secure UI input, when building Ubuntu deployer media.
- Optional access-profile credentials for HTTP/SOCKS proxies or bastions that reach OOB networks.

Release artifacts are unsigned and not notarized during alpha. macOS may require opening the app from Finder with an explicit trust action or clearing quarantine for local testing.

## Components

- `tds.app`: SwiftUI desktop UI for Core session discovery, account lookup, physical-server filtering/search, role assignment, deployer bootstrap, OOB local media, static networking, Talos version selection, deployment staging, resume, and settings.
- `tds`: CLI for testing, automation, and repeatable runbooks.
- `TalosDeployCore`: shared Swift core for Core inventory, Hammertime integration, OOB planning, Ubuntu autoinstall media, deployer service planning, Talos artifact rendering, and deployment orchestration.
- Core bridge: bundled Python bridge used to query Core through an active hammertime-authenticated environment.

## Build And Run

```bash
swift test
swift build --product tds
swift build --product tds-app
scripts/build-tds-app-bundle.sh build-cache/tds.app
open build-cache/tds.app
```

For runtime validation on another workstation:

```bash
cd ~/Documents/GitHub/talos-deploy-system
git switch main
git pull --ff-only
swift build --product tds
.build/debug/tds devices --account 0000000 --source auto
```

Use fake account numbers in examples and docs. Real account numbers belong in operator input, local settings, environment variables, or ignored run state only.

## Operator Flow

1. Open `tds.app` from a workstation with a working Core/Hammertime/OOB access profile.
2. Use `Sign In` to refresh/import the active hammertime-backed Core session, or store a manual Core session in Keychain.
3. In `Inventory + Roles`, enter the account number and load devices. Non-server devices such as firewalls, load balancers, switches, and VMs are filtered out of cluster role assignment.
4. Use the inventory search field to find physical servers by name, ID, IP, OOB IP, platform/model, or role.
5. Select one physical device as `deployer`. If it needs Ubuntu reinstalled, leave install enabled and type the destructive confirmation.
6. Assign Talos nodes as `controlplane` or `worker`.
7. Review static networking for every Talos node. DHCP may be used for live boot only; final machine configs require static management IPs from Core, capture, or manual overrides.
8. In Settings, refresh Talos versions from Image Factory and select the version to deploy. Manual override remains available if Factory is unreachable.
9. Use `Bootstrap Deployer` to capture/build/validate Ubuntu media and attach it through the embedded iLO local-media WebView when the OOB network cannot fetch external media.
10. Stage and run deployment. After Ubuntu is online, `tds` installs deployer services, stages Talos artifacts, boots nodes, applies configs, bootstraps etcd, fetches kubeconfig, and verifies health.

## Settings

Access Profiles:

- `direct`: no proxy.
- `httpProxy`: HTTP CONNECT proxy for OOB WebView/Redfish paths.
- `socksProxy`: SOCKS proxy for OOB WebView paths.
- `sshDynamicSocks`: operator-managed SOCKS tunnel profile.
- `hammertimeProxy`: diagnostic routing hint only; deployment does not depend on `ht proxy`.

Core Session:

- Default account is optional and should usually be blank.
- Inventory source can be `auto`, `core`, or `hammertime`.
- Docs and service URLs point at Core documentation/API endpoints available from the runtime workstation.

Hammertime:

- Binary path defaults to `~/.local/bin/ht`.
- `--no-checks` is enabled by default so old OS records do not block pre-provision access attempts.
- Deployer automation can use `ht command`, `ht copy`, and `ht script` when direct SSH or SSH ProxyJump is not reachable.
- Live facts are optional enrichment and never block deployment.

Talos Defaults:

- Talos versions are loaded from Talos Image Factory `GET /versions`.
- Default extensions are `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`, and `siderolabs/bnx2-bnx2x`.
- Longhorn `machine.extraMounts` for `/var/lib/longhorn` are rendered by default.
- Kernel modules, extra kernel args, architecture, platform, and schematic ID are configurable.

Provisioning Priority:

- Deployer-hosted iLO URL media.
- Deployer PXE.
- Direct/external OOB URL media.
- Operator local media.

Bootstrap Media:

- Operator local media is the greenfield-safe default for the first Ubuntu deployer.
- External OOB media is valid only when the OOB network can fetch that URL.
- Existing OS media host is explicit opt-in because a brand-new environment may have no working OS anywhere.

Deployer Defaults:

- Access method, SSH user, optional SSH ProxyJump host, state root, hostname suffix, PXE address, HTTP bind/port, package cache, local mirror behavior, and pinned `talosctl` version are managed by `tds`.
- Generated deployer hostnames use `<deviceNumber>-deployer` plus an optional suffix, for example `100001-deployer-lab2`.

Deployer Ownership:

- `tds` validates the selected access path, prepares services, syncs generated state, boots Talos nodes, runs `talosctl` from the deployer, and leaves maintenance state under `/var/lib/talos-deploy/<account>/<cluster>/`.
- The deployer copy is the operational source for future maintenance. The workstation copy exists for UI resume and debugging.
- Maintenance scripts include health checks, per-node apply, Talos/Kubernetes upgrade helpers, config rotation, and log collection.

Safety:

- Reinstalling the deployer requires typed confirmation because it destroys the OS before the rest of the cluster can proceed.

## CLI Reference

```bash
tds login --source hammertime
tds devices --account 0000000 --source auto --output table
tds facts --account 0000000 100002 100003
tds ubuntu snapshot --account 0000000 --device 100001 --output-dir ~/tds-captures
tds ubuntu network-plan --capture ~/tds-captures/0000000/100001/snapshot.json --output yaml
tds ubuntu build-iso --capture ~/tds-captures/0000000/100001/snapshot.json --source-iso ~/iso/ubuntu-24.04-live-server-amd64.iso --output-iso ~/iso/tds-100001-ubuntu.iso
tds ubuntu validate-iso --iso ~/iso/tds-100001-ubuntu.iso
tds ubuntu bootstrap-deployer --capture ~/tds-captures/0000000/100001/snapshot.json --source-iso ~/iso/ubuntu-24.04-live-server-amd64.iso --output-iso ~/iso/tds-100001-ubuntu.iso --oob-url https://192.0.2.10
tds talos versions --output table
tds talos artifacts --version v1.13.0 --arch amd64
tds deploy plan --spec examples/deployment-spec.example.json
tds deploy run --spec examples/deployment-spec.example.json --dry-run true
tds deployer access-test --account 0000000 --device 100001 --access auto
tds deployer prepare --account 0000000 --device 100001 --access auto
tds deploy run --spec examples/deployment-spec.example.json --execute true --access auto
tds deploy verify --state ~/Library/Application\ Support/tds/state/0000000/cluster.local/deployment-state.json
tds deploy maintenance-bundle --state ~/Library/Application\ Support/tds/state/0000000/cluster.local/deployment-state.json
```

## Full Example

This example uses fake devices and a fake account. Replace values only in your local run state.

1. Build and open the app:

```bash
swift build --product tds
scripts/build-tds-app-bundle.sh build-cache/tds.app
open build-cache/tds.app
```

2. Confirm Core/hammertime auth:

```bash
tds login --source hammertime
tds devices --account 0000000 --source auto --output table
```

3. Refresh Talos versions and inspect artifacts:

```bash
tds talos versions --output table
tds talos artifacts --version v1.13.0 --arch amd64
```

4. Capture the deployer before destroying its OS:

```bash
tds ubuntu snapshot --account 0000000 --device 100001 --output-dir ~/tds-captures
tds ubuntu network-plan --capture ~/tds-captures/0000000/100001/snapshot.json --output yaml
```

5. Build and validate Ubuntu media:

```bash
tds ubuntu build-iso \
  --capture ~/tds-captures/0000000/100001/snapshot.json \
  --source-iso ~/iso/ubuntu-24.04-live-server-amd64.iso \
  --output-iso ~/iso/tds-100001-ubuntu.iso \
  --rack-password-hash "$TDS_RACK_PASSWORD_HASH" \
  --root-password-hash "$TDS_ROOT_PASSWORD_HASH"

tds ubuntu validate-iso --iso ~/iso/tds-100001-ubuntu.iso
```

6. Attach through `tds.app`:

- Open `Bootstrap Deployer`.
- Set the snapshot path, source ISO, output ISO, iLO URL, and iLO credentials.
- Click `Prepare Local Media Session`.
- Use the embedded iLO WebView to launch HTML5 console and attach local media.
- Boot once from virtual CD/DVD.
- Keep `tds.app` open until Ubuntu has finished copying media and the server reboots to disk.

7. Validate and prepare deployer access, then dry-run the Talos execution:

```bash
tds deployer access-test --account 0000000 --device 100001 --access auto
tds deployer prepare --account 0000000 --device 100001 --access auto
tds deploy plan --spec examples/deployment-spec.example.json
tds deploy run --spec examples/deployment-spec.example.json --dry-run true
```

8. Execute once the plan, networking, and warnings are clean:

```bash
tds deploy run \
  --spec examples/deployment-spec.example.json \
  --execute true \
  --access auto

tds deploy verify --state ~/Library/Application\ Support/tds/state/0000000/cluster.local/deployment-state.json
tds deploy maintenance-bundle --state ~/Library/Application\ Support/tds/state/0000000/cluster.local/deployment-state.json
```

## Lab2 End-To-End Acceptance Runbook

This is a real acceptance procedure, not a built-in product mode. Do not commit real account numbers, device IDs, generated specs, or captured evidence.

Inputs:

- `TDS_E2E_ACCOUNT`: runtime account number.
- `TDS_E2E_OUTPUT`: ignored evidence directory, for example `~/tds-e2e/lab2-$(date +%Y%m%d%H%M%S)`.
- Existing Lab2 director network capture, when per-node live facts are unavailable.

Procedure:

1. Build and test `tds`.
2. Refresh Talos versions from Image Factory and choose the target version.
3. Query Core inventory with `tds devices --account "$TDS_E2E_ACCOUNT" --source auto --output json`.
4. Confirm exactly 13 physical-server-eligible devices whose names contain `lab2`; fail the preflight otherwise.
5. Select the Lab2 director as `deployer`, 3 controller-named devices as `controlplane`, and every other Lab2 physical server as `worker`.
6. Save Core inventory, OOB metadata, and any reachable `ht raxfacts`/live facts under `$TDS_E2E_OUTPUT`.
7. If live facts are unavailable on some nodes, use the proven Lab2 director topology as the network template and override each node’s static management IP from Core.
8. Validate static management CIDR, gateway, DNS, VLANs, bridges, bridge ports, routes, and install disk for every Talos node before destructive actions.
9. Build and validate the Ubuntu deployer ISO, attach it through `tds.app` local media, and verify the deployer returns with Ubuntu, SSH, `rack`, `root`, and preserved networking.
10. Prepare deployer services, stage Talos artifacts, provision nodes, apply machine configs, bootstrap etcd, fetch kubeconfig, and verify Talos/Kubernetes health.

Evidence to keep in ignored local storage:

- Inventory JSON and generated deployment spec.
- Network topology summary and per-node static IP decisions.
- ISO validation output.
- Deployer service preparation logs.
- Talos apply/bootstrap logs.
- Kubeconfig fetch result and final health output.

## Release Packaging

Alpha releases are published as GitHub pre-releases. The first pre-alpha release is `v0.1.0-alpha.1`.

```bash
scripts/package-release.sh
```

The packaging script builds `tds.app`, builds the `tds` CLI, creates zip files, and writes SHA-256 checksums under `build-cache/release/`. Pushing a `v*` tag runs the release workflow and uploads the same artifacts to GitHub Releases.

## Ubuntu Autoinstall Notes

Ubuntu deployer media uses a NoCloud seed under `/nocloud` and GRUB `autoinstall ds=nocloud;s=/cdrom/nocloud/`. The generated installer:

- creates the `rack` admin user,
- sets the configured `rack` and `root` password hashes,
- enables SSH password and root login according to the operator-provided hashes,
- writes install evidence under `/var/log/installer/tds/`,
- preserves physical networking from the preinstall snapshot, including MAC mappings, bridges, bridge ports, VLANs, routes, DNS, and search domains.

VM smoke testing is development-only and is not part of the product UI or CLI.

## Talos Output

Generated Talos state includes:

- Image Factory schematic and artifact URLs.
- Cluster config and per-node patches.
- Static node networking from Core/capture/manual input.
- Selected system extensions and kernel modules.
- Longhorn bind mount configuration unless disabled.
- Deployment manifest and saved deployment state for resume.

Durable state is stored on the deployer under:

```text
/var/lib/talos-deploy/<account>/<cluster>/
```
