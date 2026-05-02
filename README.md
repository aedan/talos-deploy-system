# tds

`tds` is a macOS-first Rackspace bare-metal Talos deployment tool. The desktop app is the primary operator experience, and the CLI exists for `rax`-side testing, automation, and repeatable end-to-end runs.

The deployer is a selected physical server that receives Ubuntu first and then manages Talos artifacts, PXE/media services, machine configs, cluster bootstrap, and health checks. The deployer is not a Talos node.

## Components

- `tds.app`: SwiftUI desktop UI for Core session discovery, account lookup, physical-server filtering, role assignment, deployer bootstrap, OOB local media, static networking, deployment staging, resume, and settings.
- `tds`: CLI for `rax` testing and automation.
- `TalosDeployCore`: shared Swift core for Core inventory, hammertime integration, OOB planning, Ubuntu autoinstall media, deployer service planning, Talos artifact rendering, and deployment orchestration.
- Core bridge: bundled Python bridge used on `rax` to query Core through the active hammertime-authenticated environment.

## Build And Run

Develop locally, commit on `main`, then pull the same repo path on `rax` for Core/OOB/hammertime validation.

```bash
swift test
swift build --product tds
swift build --product tds-app
scripts/build-tds-app-bundle.sh build-cache/tds.app
open build-cache/tds.app
```

On `rax`:

```bash
cd ~/Documents/GitHub/talos-deploy-system
git switch main
git pull --ff-only
swift build --product tds
.build/debug/tds devices --account 0000000 --source auto
```

Use fake account numbers in examples and docs. Real account numbers belong in operator input, local settings, or ignored run state only.

## Operator Flow

1. Open `tds.app` on `rax` or from a workstation with a working access profile.
2. Use `Sign In` to refresh/import the active hammertime-backed Core session. Manual Core session storage is available, but the normal `rax` path is automatic discovery.
3. In `Inventory + Roles`, enter the account number and load devices. Non-server devices such as firewalls, load balancers, switches, and VMs are filtered out of cluster role assignment.
4. Select one physical device as `deployer`. If it needs Ubuntu reinstalled, leave install enabled and type the destructive confirmation.
5. Assign Talos nodes as `controlplane` or `worker`. For lab-based end-to-end runs, use `Lab Auto Assignment`: enter a label such as `lab2`, choose the deployer device ID/name, and let `tds` assign controller-named devices as control-plane nodes and all other matching physical servers as workers.
6. Review static networking for every Talos node. DHCP may be used for live boot only; final machine configs require static management IPs from Core, capture, or manual overrides.
7. Use `Bootstrap Deployer` to capture/build/validate Ubuntu media and attach it through the embedded iLO local-media WebView when the OOB network cannot fetch external media.
8. Stage and run deployment. After Ubuntu is online, `tds` installs deployer services, stages Talos artifacts, boots nodes, applies configs, bootstraps etcd, fetches kubeconfig, and verifies health.

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
- Docs and service URLs point at Core documentation/API endpoints available from `rax`.

Hammertime:

- Binary path defaults to `ht`.
- `--no-checks` is enabled by default so old OS records do not block pre-provision access attempts.
- Live facts are optional enrichment and never block deployment.

Talos Defaults:

- Default extensions are `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`, and `siderolabs/bnx2-bnx2x`.
- Longhorn `machine.extraMounts` for `/var/lib/longhorn` are rendered by default.
- Kernel modules and extra kernel args are configurable.

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

- SSH user, state root, hostname suffix, PXE address, HTTP bind/port, package cache, and pinned `talosctl` version are managed by `tds`.
- Generated deployer hostnames use `<deviceNumber>-deployer` plus an optional suffix, for example `100001-deployer-lab2`.

Safety:

- Reinstalling the deployer requires typed confirmation because it destroys the OS before the rest of the cluster can proceed.

## CLI Reference

```bash
tds login --source hammertime
tds devices --account 0000000 --source auto --output table
tds devices --account 0000000 --lab lab2 --deployer 100001 --output json
tds facts --account 0000000 100002 100003
tds ubuntu snapshot --account 0000000 --device 100001 --output-dir ~/tds-captures
tds ubuntu network-plan --capture ~/tds-captures/0000000/100001/snapshot.json --output yaml
tds ubuntu build-iso --capture ~/tds-captures/0000000/100001/snapshot.json --source-iso ~/iso/ubuntu-24.04-live-server-amd64.iso --output-iso ~/iso/tds-100001-ubuntu.iso
tds ubuntu validate-iso --iso ~/iso/tds-100001-ubuntu.iso
tds ubuntu bootstrap-deployer --capture ~/tds-captures/0000000/100001/snapshot.json --source-iso ~/iso/ubuntu-24.04-live-server-amd64.iso --output-iso ~/iso/tds-100001-ubuntu.iso --oob-url https://192.0.2.10
tds talos schematic
tds talos artifacts --version v1.12.1 --arch amd64
tds deploy plan --spec examples/deployment-spec.example.json
tds deploy run --spec examples/deployment-spec.example.json --dry-run true
tds deploy run --spec examples/deployment-spec.example.json --execute true --deployer-host 192.0.2.20 --deployer-user rack
tds deploy verify --path ~/Library/Application\ Support/tds/state/0000000/cluster.local/deployment-state.json
```

## Full Example

This example uses fake devices and a fake account. Replace values only in your local run state.

1. Build and open the app:

```bash
swift build --product tds
scripts/build-tds-app-bundle.sh build-cache/tds.app
open build-cache/tds.app
```

2. Confirm Core/hammertime auth on `rax`:

```bash
tds login --source hammertime
tds devices --account 0000000 --source auto --output table
```

3. Use lab auto-assignment for an end-to-end test:

```bash
tds devices --account 0000000 --lab lab2 --deployer 100001 --output json
```

Expected role intent:

- `100001-lab2-deployer.example.test`: `deployer`
- `100002-lab2-controller01.example.test`: `controlplane`
- `100003-lab2-controller02.example.test`: `controlplane`
- `100004-lab2-controller03.example.test`: `controlplane`
- every other matching physical `lab2` server: `worker`

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

7. Prepare the deployer and dry-run the Talos execution:

```bash
tds deploy deployer prepare --deployer-host 192.0.2.20 --deployer-user rack
tds deploy plan --spec examples/deployment-spec.example.json
tds deploy run --spec examples/deployment-spec.example.json --dry-run true
```

8. Execute once the plan, networking, and warnings are clean:

```bash
tds deploy run \
  --spec examples/deployment-spec.example.json \
  --execute true \
  --deployer-host 192.0.2.20 \
  --deployer-user rack

tds deploy verify --path ~/Library/Application\ Support/tds/state/0000000/cluster.local/deployment-state.json
```

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
