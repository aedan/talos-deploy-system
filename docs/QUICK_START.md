# TDS Quick Start And Operator Guide

This guide explains how to start using `tds`, what each major feature does, and how the deployment engine works end to end. It uses fake account numbers, device IDs, hostnames, and IPs. Put real account data, credentials, generated specs, kubeconfigs, and run captures only in local ignored state.

For the short UI-and-CLI operator walkthrough, see [../QUICKSTART.md](../QUICKSTART.md). This file is the full reference guide.

## What TDS Does

`tds` is a macOS-first Rackspace bare-metal Talos deployment system. It has two operator surfaces:

- `tds.app`: the primary desktop UI for inventory, role assignment, settings, Ubuntu deployer bootstrap, Talos Factory work, deployer operations, deployment execution, and recovery.
- `tds`: a CLI for validation, automation, repeatable tests, and runbooks.

The core idea is simple:

1. Pick one physical server as the Ubuntu deployer.
2. Pick the remaining physical servers as Talos control-plane or worker nodes.
3. Bring up or validate Ubuntu 24.04 on the deployer.
4. Let the deployer host media, cache registry images, generate Talos configs, boot nodes, apply configs, bootstrap etcd, fetch kubeconfig, and run health checks.

The deployer is not a Talos node. It is the in-environment machine that owns the risky and network-sensitive parts of the Talos deployment.

## Fastest Useful Start

Open the released `tds.app` for the normal desktop workflow. Use the released `tds` CLI for repeatable checks and automation.

Validate inventory access with fake placeholders replaced locally:

```bash
tds login --source hammertime
tds devices --account 0000000 --source auto --output table
```

Inspect Talos Image Factory versions and artifact URLs:

```bash
tds talos versions --output table
tds talos artifacts --version v1.13.0 --arch amd64 --platform metal
```

Dry-run a deployment spec before doing anything destructive:

```bash
tds deploy plan --spec examples/deployment-spec.example.json
tds deploy run --spec examples/deployment-spec.example.json --dry-run true --access auto
```

Run only when the plan, static networking, deployer access, and OOB media path are known good:

```bash
tds deploy run \
  --spec path/to/local-deployment-spec.json \
  --execute true \
  --access auto
```

## Prerequisites

Operator workstation:

- macOS 14 or newer.
- Network access to Core, Hammertime-backed Core auth, OOB/iLO/iDRAC paths, and any required proxy or bastion.
- `ht` when using Hammertime inventory, OOB commands, or Hammertime deployer transport.
- `xorriso` when building or validating Ubuntu autoinstall ISO media.

Deployer:

- Ubuntu 24.04, either preexisting or installed by generated TDS media.
- SSH reachable by direct SSH, SSH ProxyJump, or Hammertime.
- Network reachability to Talos node management IPs on the final management network.
- Package access or cached packages for deployer-managed tools: `dnsmasq`, `python3`, `openssh-client`, `xorriso`, `docker-registry`, `skopeo`, `chrony`, `curl`, `talosctl`, and `kubectl`.
- Ability to host HTTP media on the address the OOB controllers can fetch.
- Ability to host an OCI registry on an address Talos nodes can reach, if Talos nodes do not have Internet access.

Secrets:

- `TDS_RACK_PASSWORD_HASH` and `TDS_ROOT_PASSWORD_HASH` for Ubuntu media builds, or equivalent secure UI input.
- OOB credentials and proxy credentials stored through local settings/keychain paths.
- Do not commit generated specs, captures, kubeconfigs, Talos secrets, SSH keys, or real account/device identifiers.

## Desktop App Quick Start

1. Open `tds.app`.
2. In Settings, configure access profiles, Hammertime path, deployer access defaults, Talos defaults, registry behavior, and bootstrap media defaults.
3. Sign in or import the active Hammertime/Core session.
4. Load inventory for an account.
5. Assign exactly one `deployer`.
6. Assign one or more `controlplane` nodes and any `worker` nodes.
7. Review static networking and per-node install preference for every Talos node. Use `stagedOnly` for cloud-image or already-booted Talos nodes.
8. If the deployer needs Ubuntu, use `Bootstrap Deployer` to capture a preinstall snapshot, build local media, validate it, and attach it through the embedded OOB WebView.
9. Use `Talos Factory` to refresh versions, render/upload schematics, compute artifacts, or direct-boot an OOB-reachable Talos image.
10. After Ubuntu is reachable, use `Deployer Ops` to plan services, test deployer access, and prepare the deployer.
11. Stage and run the deployment from selected inventory, or run an explicit deployment spec JSON.
12. Use `Recovery` for state loading, resume, reprovision, installed-disk boot prep, verify, maintenance-bundle rewrite, and direct OOB URL boot.

The app is intentionally stateful. It keeps the workstation-side deployment state so you can inspect, resume, or collect evidence without rebuilding the entire spec from scratch.

## Desktop Capability Map

The desktop app is intended to cover the same operator capabilities as the CLI:

- `Sign In`: `login`.
- `Inventory + Roles`: `devices`, `facts`, role assignment, per-node install preference, and static networking.
- `Bootstrap Deployer`: `ubuntu snapshot`, `ubuntu network-plan`, `ubuntu build-iso`, `ubuntu validate-iso`, `ubuntu local-media-plan`, and `ubuntu oob-boot-url`.
- `Talos Factory`: `talos versions`, `talos schematic`, `talos upload-schematic`, `talos artifacts`, and `talos oob-boot-url`.
- `Deployment Run`: `deploy plan` and `deploy run`, both from selected inventory and from an explicit spec file.
- `Deployer Ops`: `deployer plan`, `deployer access-test`, and `deployer prepare`.
- `Recovery`: `deploy resume`, `deploy reprovision`, `deploy disk-boot`, `deploy verify`, and `deploy maintenance-bundle`.
- `Settings`: access profiles, Core/Hammertime defaults, Talos defaults, Image Factory settings, provisioning strategy, registry, route, bootstrap media, deployer defaults, and safety settings.

## CLI Quick Start

Inventory:

```bash
tds login --source hammertime
tds devices --account 0000000 --source auto --output table
tds facts --account 0000000 --source auto 100002 100003
```

Ubuntu deployer media:

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

Deployer access and preparation:

```bash
tds deployer access-test --account 0000000 --device 100001 --access auto
tds deployer prepare --account 0000000 --device 100001 --access auto
```

Deployment:

```bash
tds deploy plan --spec path/to/deployment-spec.json
tds deploy run --spec path/to/deployment-spec.json --dry-run true --access auto
tds deploy run --spec path/to/deployment-spec.json --execute true --access auto
```

Recovery and maintenance:

```bash
STATE="$HOME/Library/Application Support/tds/state/0000000/cluster.local/deployment-state.json"

tds deploy reprovision --state "$STATE" --targets 100002,100003 --execute true --access auto
tds deploy reprovision --state "$STATE" --targets 100002 --wipe true --execute true --access auto
tds deploy resume --path "$STATE" --execute true --access auto
tds deploy disk-boot --state "$STATE" --targets 100002,100003 --reboot true --execute true
tds deploy verify --state "$STATE"
tds deploy maintenance-bundle --state "$STATE"
```

## How TDS Works

### 1. Inventory And Session Resolution

TDS can load physical-device inventory from:

- `auto`: prefer Core when available, fall back as configured.
- `core`: use the Core bridge/session path.
- `hammertime`: use Hammertime output directly.

Inventory is normalized into `DiscoveredDevice` records. Non-server records such as firewalls, load balancers, switches, routers, VMware entries, and private-cloud appliance records are filtered out of cluster role assignment.

Hammertime inventory parsing handles both normal records and device-keyed records with `{name, value}` attributes. It normalizes `None` and `null` values to empty strings and extracts network addresses, VLAN IDs, MTU values, and OOB endpoints when available.

### 2. Role Assignment

Every selected device gets a `DeviceAssignment`.

Roles:

- `unassigned`: visible inventory, not part of the deployment.
- `deployer`: Ubuntu host that runs deployment services and Talos commands.
- `controlplane`: Talos control-plane node.
- `worker`: Talos worker node.

There must be exactly one deployer in a deployment plan. The deployer can be:

- `existing`: Ubuntu is already installed and SSH is available.
- `bootstrap`: TDS builds Ubuntu autoinstall media and the operator installs the deployer first.

Talos nodes can be installed or staged:

- `automatic`: planner chooses the best available install strategy.
- `virtualMedia`: boot through OOB virtual media.
- `pxe`: boot through deployer PXE where implemented.
- `stagedOnly`: do not boot or reinstall the node; include it in readiness, apply, bootstrap, and health. This is used for cloud-image/OpenStack Talos nodes.

### 3. Static Network Planning

Final Talos machine configs use static networking. The planner derives networking from:

- Core private or primary IPs.
- Captured live snapshots.
- Manual static network overrides.
- OOB hardware enrichment.

Network source values:

- `core`: use Core/device inventory values.
- `liveSnapshot`: use a captured OS network snapshot.
- `manual`: use operator-provided static values.
- `unavailable`: block deployment until static networking is provided.

Static config fields:

- `managementInterface`: interface name such as `eno1`. If this is known, TDS renders it explicitly.
- `managementHardwareAddress`: NIC MAC. TDS stores it for validation and can use it as a Talos `deviceSelector` only when no interface name is known.
- `managementAddressCIDR`: final Talos management address, including prefix.
- `gateway`: default gateway.
- `nameservers`: DNS server list.
- `searchDomains`: DNS search list.
- `routes`: static routes. Use `to: "default"` for the default route.
- `vlans`: VLAN interfaces and optional routes/MTU.
- `bridges`: bridge interfaces, bridge ports, routes, and MTU.

MTU is rendered from inventory/interface data when known. If no MTU is known, bare-metal configs preserve the current default behavior.

### 4. Ubuntu Deployer Bootstrap

When the deployer does not already have Ubuntu, TDS generates Ubuntu 24.04 NoCloud autoinstall media.

The generated media:

- Preserves physical networking from the preinstall snapshot.
- Writes NoCloud seed data under `/nocloud`.
- Adds GRUB autoinstall arguments.
- Creates the `rack` admin user.
- Sets operator-provided `rack` and `root` password hashes.
- Installs SSH access.
- Writes install evidence under `/var/log/installer/tds/`.

The greenfield-safe media path is operator local media through the desktop app. External OOB URL media is only valid when the OOB network can fetch that URL.

### 5. Deployer Service Preparation

After Ubuntu is reachable, TDS prepares deployer services:

- HTTP media server for Talos ISO/PXE artifacts.
- Optional `dnsmasq` PXE service.
- `docker-registry` for local installer/cluster image caching.
- `skopeo` for copying images into the deployer registry.
- `chrony` so Talos nodes can sync time from the deployer.
- Pinned or configured `talosctl`.
- `kubectl`, installed under the TDS state root and symlinked into `/usr/local/bin`.
- A root shell PATH profile snippet so `/var/lib/talos-deploy/bin` tools can be run by name after login.

Deployer state is stored under:

```text
/var/lib/talos-deploy/<account>/<cluster>/
```

Local workstation state is stored under:

```text
~/Library/Application Support/tds/state/<account>/<cluster>/
```

### 6. Talos Artifact Generation

TDS uses Talos Image Factory settings to generate:

- Schematic YAML.
- ISO URL.
- PXE URL.
- Installer image reference.

Default Talos settings:

- Talos `v1.13.0`.
- Kubernetes `v1.34.1`.
- Architecture `amd64`.
- Platform `metal`.
- Default extensions: `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`, `siderolabs/bnx2-bnx2x`.
- Longhorn extra mount support enabled.
- Optional kernel modules and extra kernel args.

For OpenStack/cloud-image nodes, staged configs omit `machine.install` so Talos is configured in place instead of reinstalling.

### 7. Node-Specific Media

For bare-metal install nodes, TDS generates per-node media:

- `talos-<version>-<device>.iso`: normal boot media.
- `talos-<version>-<device>-wipe.iso`: destructive wipe media.

The normal media uses one of two boot modes:

- `meta`: embeds initial static network metadata in the boot args and waits for Talos live maintenance API. This is the default when an interface name is known.
- `config`: maps a boot machine config to `/config.yaml` and uses `talos.config=metal-iso`. This is reserved for hardware-address-only networking where Talos must select the NIC by MAC.

### 8. OOB Provisioning

Supported install methods:

- `bootURL`: OOB/iLO fetches deployer-hosted media by URL.
- `virtualMedia`: OOB fetches a direct/external Factory ISO URL.
- `pxe`: one-time PXE boot request.
- `operatorLocalMedia`: operator handles local media.
- `stagedOnly`: no boot request.

For boot-managed bare-metal Talos nodes, TDS normally:

1. Boots the per-node wipe ISO.
2. Waits for the wipe pass.
3. Boots the normal per-node ISO.
4. Waits for live or configured Talos API.
5. Detaches virtual media and restores installed-disk boot order.

### 9. Readiness Diagnostics

During readiness checks, nodes are classified as:

- `configured-api`: Talos API works with generated `talosconfig`.
- `live-api`: Talos maintenance API works with `--insecure`.
- `kubelet-only`: kubelet port is open but Talos API is not ready.
- `ping-only`: host responds to ping only.
- `down`: no useful response.

This makes it easier to separate media boot problems, TLS/config transitions, partial Kubernetes boots, routing issues, and dead hardware/network paths.

### 10. Apply, Bootstrap, And Health

The deployer-owned script runs from the deployer, not the operator workstation.

It:

1. Regenerates Talos secrets and base configs if needed.
2. Applies node-specific patches.
3. Validates machine configs.
4. Configures control planes first.
5. Selects the first reachable control plane for etcd bootstrap.
6. Waits for time sync.
7. Runs `talosctl bootstrap`.
8. Fetches kubeconfig.
9. Configures workers.
10. Runs `talosctl health`.

If the run is interrupted after OOB boot, use `deploy resume`. Resume re-syncs state and reruns the deployer-owned phase without reissuing OOB boot requests.

## Feature And Option Reference

### Access Profiles

Access profile kinds:

- `direct`: no proxy.
- `httpProxy`: HTTP CONNECT proxy for OOB/WebView paths.
- `socksProxy`: SOCKS proxy for OOB/WebView paths.
- `sshDynamicSocks`: operator-managed dynamic SOCKS tunnel profile.
- `hammertimeProxy`: diagnostic routing hint.

Access scopes:

- `core`: Core/session access.
- `oob`: OOB/iLO/iDRAC access.
- `both`: both Core and OOB.

### Deployer Access Methods

`--access` accepts:

- `auto`: try configured access paths.
- `directSSH`: SSH directly to deployer.
- `proxyJumpSSH`: SSH through a ProxyJump host.
- `hammertime`: use `ht command`, `ht copy`, and `ht script`.

Hammertime access validates cached SSO first and uses bounded SSH connect/keepalive options so failed paths do not hang indefinitely.

### Bootstrap Media Options

Bootstrap delivery modes:

- `operatorLocalMedia`: safest default for a greenfield deployer.
- `oobReachableURL`: OOB can fetch an HTTP URL directly.
- `existingOSMediaHost`: explicit opt-in because greenfield environments may have no OS media host.
- `pxeAfterDeployerOnline`: PXE path after deployer services exist.

Ubuntu CLI options:

- `snapshot`: captures device/network information before destructive changes.
- `network-plan`: renders captured network plan as JSON or YAML.
- `build-iso`: creates autoinstall ISO from a stock Ubuntu ISO.
- `validate-iso`: validates generated media structure.
- `bootstrap-deployer`: prepares a local-media plan for app-assisted OOB bootstrap.
- `local-media-plan`: produces the same local-media plan without running the full bootstrap command.
- `oob-boot-url`: direct OOB boot of an explicit OOB-reachable Ubuntu image URL.

Password hashes can be supplied by CLI flags or by `TDS_RACK_PASSWORD_HASH` and `TDS_ROOT_PASSWORD_HASH`.

### Talos Options

Talos CLI:

- `talos schematic`: render Image Factory schematic YAML.
- `talos upload-schematic`: upload schematic to Image Factory.
- `talos artifacts`: print ISO, PXE, and installer image references.
- `talos versions`: list deployable Talos versions.
- `talos oob-boot-url`: direct OOB boot of an explicit Talos image URL.

Talos Factory settings:

- `baseURL`: Factory API/image base URL.
- `pxeBaseURL`: Factory PXE base URL.
- `registryHost`: image registry host.
- `architecture`: usually `amd64`.
- `platform`: `metal` for bare metal, `openstack` for OpenStack images.
- `schematicID`: existing Factory schematic ID.
- `selectedSystemExtensions`: official extension list.
- `extraKernelArgs`: extra Factory kernel args.

Talos provisioning settings:

- `preferredStrategies`: ordered strategy list.
- `allowDeployerHostedMedia`: enable deployer-hosted OOB URL media.
- `allowDeployerPXE`: enable deployer PXE planning.
- `allowExternalOOBURL`: allow external OOB media URL fallback or OOB-reachable deployer alias.
- `externalOOBMediaBaseURL`: either an ISO URL or a base URL where per-node media can be fetched.
- `wipeSystemDiskBeforeInstall`: boot a destructive wipe ISO before normal media.
- `legacyBIOSSupport`: render Talos legacy BIOS install support.
- `useOOBHardwareAddressSelectors`: enrich static networking with OOB NIC MACs.
- `allowDeployerRegistry`: cache installer and cluster images in deployer registry.
- `deployerRegistryHost`: override registry host rendered into Talos configs.
- `deployerRegistryAddressCIDR`: add a node-facing address alias to deployer.
- `deployerRegistryInterface`: interface that carries the registry alias.
- `deployerNodeRouteInterface`: force deployer routes to Talos management IPs through this interface.
- `deployerNodeRouteSourceCIDR`: source CIDR for those host routes.
- `deployerRegistryPort`: default `5000`.
- `deployerRegistryMirrorHosts`: registry hosts mirrored through the deployer, default `ghcr.io` and `registry.k8s.io`.

### Deployment Spec Fields

Top-level deployment spec:

- `accountNumber`: account for inventory/state grouping.
- `clusterName`: Talos/Kubernetes cluster name.
- `clusterEndpoint`: Talos cluster endpoint, usually `https://<first-control-plane-ip>:6443`.
- `talosVersion`: Talos version.
- `kubernetesVersion`: Kubernetes version.
- `deployerStateRoot`: deployer durable state root.
- `talosFactory`: Factory settings.
- `talosProvisioning`: provisioning/service settings.
- `talosKernelModules`: machine kernel modules to render.
- `enableLonghornExtraMounts`: render Longhorn `/var/lib/longhorn` bind mount support.
- `nodes`: selected devices and role assignments.

Node spec:

- `device`: normalized inventory record.
- `assignment`: role, install preferences, network source, static network, and typed confirmation.

Device fields:

- `id`, `accountNumber`, `name`.
- `primaryIP`, `privateIP`.
- `platformName`, `osType`, `serviceLevel`, `serviceTag`.
- `memoryGiB`, `storageGiB`, `installDisk`.
- `networkInterfaces`.
- `oob`.
- `credentialReference`.
- `liveFacts`.

OOB endpoint:

- `vendor`: `ilo`, `idrac`, `redfish`, or `unknown`.
- `address`.
- `username`.
- `credentialReference`.
- `supportsVirtualMedia`.
- `supportsPXE`.

### Deployment Commands

`deploy plan`

- Reads a spec.
- Validates role assignment and static networking.
- Plans deployer and Talos install actions.
- Does not execute anything destructive.

`deploy run`

- Stages local state and maintenance bundle.
- Validates deployer access.
- Prepares deployer services.
- Syncs state to deployer.
- Generates media/configs.
- Boots Talos nodes unless staged-only.
- Runs deployer-owned apply/bootstrap/health.
- Requires `--execute true` unless dry-run.

`deploy resume`

- Re-syncs state.
- Restarts/revalidates deployer services.
- Regenerates media/configs.
- Reconciles routes.
- Runs readiness, disk boot prep, and deployer-owned apply/bootstrap/health.
- Does not reissue OOB boot requests.

`deploy reprovision`

- Reissues OOB boot requests for selected Talos nodes from saved state.
- Supports `--wipe true`.
- Waits for selected nodes to expose live/configured API.
- Follow with `deploy resume`.

`deploy disk-boot`

- Detaches virtual media where possible.
- Restores installed-disk boot order.
- Optionally power-cycles selected nodes.

`deploy verify`

- Verifies saved deployment state without changing infrastructure.

`deploy maintenance-bundle`

- Rewrites the maintenance bundle from saved state.

### Maintenance Bundle

The deployer maintenance bundle includes:

- `maintenance/tds-prepare-talos-media.sh`
- `maintenance/tds-run-talos-deploy.sh`
- `maintenance/health-check.sh`
- `maintenance/apply-node.sh`
- `maintenance/upgrade-talos.sh`
- `maintenance/upgrade-kubernetes.sh`
- `maintenance/rotate-configs.sh`
- `maintenance/collect-logs.sh`
- `node-patches/`
- `boot-node-patches/`
- `boot-network-meta/`
- `inventory/`
- `deployment-state.json`
- `deployment-manifest.json`
- `talos-artifacts.json`

This bundle is the practical runbook on the deployer. It is useful for debugging and for future maintenance after the initial deployment.

To inspect the cluster from the deployer after bootstrap, log in to the deployer and use the kubeconfig in the durable state directory:

```bash
cd /var/lib/talos-deploy/<account>/<cluster>
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
kubectl get pods -A
```

TDS adds the deployer bin directory to root shell startup files, so a fresh root login can run `kubectl` and `talosctl` by name.

## OpenStack Lab Harness

The OpenStack harness is for repeatable validation before returning to bare metal. It uses `ssh ord-deployer openstack --os-cloud default ...` for OpenStack operations and stores ignored run state under `captures/openstack-lab/<run-id>/`.

Commands:

- `prepare-image`: upload/cache the Talos OpenStack image.
- `up`: create an Ubuntu deployer VM, 3 Talos control-plane VMs, and 1 Talos worker VM.
- `run-tds`: generate a deployment spec and run the deployer-owned TDS flow.
- `collect`: collect OpenStack console logs and deployer state.
- `down`: remove ephemeral servers, ports, floating IPs, and keypair.
- `e2e`: run prepare-image, up, run-tds, collect, and down.

Common usage:

```bash
scripts/tds-openstack-lab.sh e2e --cleanup always
```

Useful environment overrides:

- `TDS_OPENSTACK_HOST`
- `TDS_OPENSTACK_CLOUD`
- `TDS_OPENSTACK_NETWORK`
- `TDS_OPENSTACK_FLOATING_NETWORK`
- `TDS_OPENSTACK_UBUNTU_IMAGE`
- `TDS_OPENSTACK_UBUNTU_FLAVOR`
- `TDS_OPENSTACK_TALOS_FLAVOR`
- `TDS_TALOS_VERSION`
- `TDS_KUBERNETES_VERSION`
- `TDS_TALOS_EXTENSIONS`
- `TDS_OPENSTACK_TALOS_IMAGE_FORMAT`
- `TDS_OPENSTACK_TALOS_IMAGE_USE_IMPORT`

OpenStack Talos nodes use `stagedOnly` so TDS configures the already-booted cloud image instead of reinstalling it.

## Safety Model

TDS is intentionally conservative around destructive actions:

- Deployer reinstall requires typed confirmation.
- Non-dry-run deploy commands require `--execute true`.
- Staged-only nodes skip OOB boot, wipe, and disk-boot prep.
- Generated captures and state may contain secrets and must stay ignored.
- Resume and reprovision are separate: resume reruns deployer-owned config/bootstrap, reprovision reboots selected nodes.
- Hardware selectors are not used when an interface name is already known.

## Troubleshooting

OOB media URL is accepted but the node never boots Talos:

- Confirm the OOB controller can fetch the URL.
- Check whether the URL uses a deployer address reachable from the OOB network.
- Use `externalOOBMediaBaseURL` with `allowExternalOOBURL` when the deployer has a separate OOB-reachable alias.
- Collect console logs or OOB virtual media status.

Talos node is `down` from deployer:

- Check deployer routes to node management IPs.
- Configure `deployerNodeRouteInterface` and `deployerNodeRouteSourceCIDR` if the deployer must reach nodes through a bridge/VLAN.
- Confirm Talos was booted with the expected node-specific media.
- Check ARP from the deployer.

Node is `live-api` but not `configured-api`:

- The node booted Talos maintenance mode.
- Run or resume the deployer-owned apply flow.
- Check `logs/talos-deploy-*.log` on the deployer.

Config ISO produces no network but meta mode works:

- Prefer explicit interface networking when the interface name is known.
- Use hardware selectors only when inventory has no reliable interface name.
- Verify the OOB-reported MAC belongs to the OS-visible management NIC.

Registry/image pulls fail:

- Confirm `allowDeployerRegistry` is enabled.
- Confirm the registry host rendered into Talos configs is reachable from Talos nodes.
- Use `deployerRegistryAddressCIDR` and `deployerRegistryInterface` for node-facing registry aliases.
- Confirm mirror hosts include every upstream registry used by generated configs.

Health fails after bootstrap:

- Inspect `/var/lib/talos-deploy/<account>/<cluster>/logs/talos-deploy-*.log`.
- Run `maintenance/health-check.sh` on the deployer.
- Confirm all intended control planes are in etcd.
- Confirm kubelet, static pods, coredns, and kube-proxy readiness.

## Evidence To Keep

Keep this locally under ignored paths such as `captures/`:

- Inventory JSON.
- Generated deployment spec.
- Network topology decisions.
- Ubuntu ISO validation output.
- Deployer service preparation logs.
- OOB boot logs and virtual media status.
- Talos readiness logs.
- Talos apply/bootstrap/health logs.
- `kubeconfig`.
- `talosconfig`.

Do not commit this evidence unless it has been scrubbed and intentionally converted into a generic fixture.
