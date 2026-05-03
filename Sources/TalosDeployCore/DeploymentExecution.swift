import Foundation

public enum TalosDeploymentExecutionError: Error, LocalizedError, Equatable {
    case oobURLMediaDisconnected(deviceName: String, imageURL: String, status: String)

    public var errorDescription: String? {
        switch self {
        case .oobURLMediaDisconnected(let deviceName, let imageURL, let status):
            let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed.isEmpty ? "" : " Last media status: \(trimmed)"
            return "OOB URL media did not remain connected for \(deviceName) after retrying \(imageURL).\(suffix)"
        }
    }
}

public struct MaintenanceBundleBuilder {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func writeBundle(for state: DeploymentState, in directory: URL) throws -> MaintenanceBundleManifest {
        let maintenanceDirectory = directory.appending(path: "maintenance", directoryHint: .isDirectory)
        let inventoryDirectory = directory.appending(path: "inventory", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: maintenanceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inventoryDirectory, withIntermediateDirectories: true)

        let scripts: [(String, String)] = [
            ("tds-prepare-talos-media.sh", renderPrepareTalosMediaScript(state: state)),
            ("tds-run-talos-deploy.sh", renderTalosDeployScript(state: state)),
            ("health-check.sh", renderHealthCheckScript(state: state)),
            ("apply-node.sh", renderApplyNodeScript(state: state)),
            ("upgrade-talos.sh", renderUpgradeTalosScript(state: state)),
            ("upgrade-kubernetes.sh", renderUpgradeKubernetesScript(state: state)),
            ("rotate-configs.sh", renderRotateConfigsScript()),
            ("collect-logs.sh", renderCollectLogsScript(state: state)),
        ]

        for script in scripts {
            let url = maintenanceDirectory.appending(path: script.0)
            try script.1.write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let inventoryURL = inventoryDirectory.appending(path: "selected-devices.json")
        try JSONEncoder.pretty.encode(state.spec.nodes.map(\.device)).write(to: inventoryURL, options: .atomic)

        let networkURL = inventoryDirectory.appending(path: "networking-summary.json")
        try JSONEncoder.pretty.encode(state.plan.networkValidation).write(to: networkURL, options: .atomic)

        let manifest = MaintenanceBundleManifest(
            stateRoot: state.plan.durableStateDirectory,
            clusterName: state.spec.clusterName,
            scripts: scripts.map { "maintenance/\($0.0)" },
            files: [
                "deployment-state.json",
                "deployment-manifest.json",
                "cluster.yaml",
                "talos-artifacts.json",
                "talos-factory-schematic.yaml",
                "boot-node-patches/",
                "boot-network-meta/",
                "node-patches/",
                "inventory/selected-devices.json",
                "inventory/networking-summary.json",
            ]
        )
        try JSONEncoder.pretty.encode(manifest).write(to: directory.appending(path: "maintenance-bundle.json"), options: .atomic)
        return manifest
    }

    private func renderTalosDeployScript(state: DeploymentState) -> String {
        let controlPlanes = nodeRecords(state: state, role: .controlplane)
        let firstControlPlane = controlPlanes.first

        return """
        #!/usr/bin/env bash
        set -euo pipefail

        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        \(talosctlResolver(state: state))
        TDS_MEDIA_ROOT="${TDS_MEDIA_ROOT:-\(state.spec.deployerStateRoot)/media}"
        mkdir -p "$ROOT/logs"
        LOG_FILE="$ROOT/logs/talos-deploy-$(date -u +%Y%m%dT%H%M%SZ).log"
        exec > >(tee -a "$LOG_FILE") 2>&1

        log() {
          printf '[tds-deployer] %s %s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
        }

        diagnose_node() {
          local name="$1"
          local ip="$2"
          log "diagnostics for ${name} (${ip})"
          ip route get "$ip" || true
          ping -c1 -W1 "$ip" || true
          timeout 5 bash -c "</dev/tcp/$ip/50000" >/dev/null 2>&1 && echo "talos-api-port=open" || echo "talos-api-port=closed"
          "$TALOSCTL" --nodes "$ip" --endpoints "$ip" version --insecure || true
        }

        wait_for_configured_api() {
          local name="$1"
          local ip="$2"
          local attempts="$3"
          local context="$4"
          log "waiting for configured Talos API on $name ($ip) ${context}"
          for attempt in $(seq 1 "$attempts"); do
            if "$TALOSCTL" --talosconfig generated/talosconfig --nodes "$ip" --endpoints "$ip" version >/dev/null 2>&1; then
              log "configured Talos API is reachable on $name ($ip)"
              return 0
            fi
            if [ "$attempt" -eq "$attempts" ]; then
              echo "Timed out waiting for configured Talos API on $name ($ip)" >&2
              diagnose_node "$name" "$ip"
              return 1
            fi
            if [ $((attempt % 6)) -eq 0 ]; then
              log "still waiting for configured Talos API on $name ($ip), attempt $attempt/$attempts"
            fi
            sleep 10
          done
        }

        wait_for_live_api() {
          local name="$1"
          local ip="$2"
          local attempts="${3:-120}"
          log "waiting for Talos live maintenance API on $name ($ip)"
          for attempt in $(seq 1 "$attempts"); do
            if "$TALOSCTL" --nodes "$ip" --endpoints "$ip" version --insecure >/dev/null 2>&1; then
              log "Talos live maintenance API is reachable on $name ($ip)"
              return 0
            fi
            if [ "$attempt" -eq "$attempts" ]; then
              echo "Timed out waiting for Talos live boot on $name ($ip)" >&2
              diagnose_node "$name" "$ip"
              return 1
            fi
            if [ $((attempt % 6)) -eq 0 ]; then
              log "still waiting for Talos live maintenance API on $name ($ip), attempt $attempt/$attempts"
            fi
            sleep 10
          done
        }

        capture_live_links() {
          local name="$1"
          local ip="$2"
          local mode="${3:-configured}"
          mkdir -p inventory/talos-live
          if [ "$mode" = "insecure" ]; then
            "$TALOSCTL" get links --nodes "$ip" --endpoints "$ip" --insecure -o yaml > "inventory/talos-live/${name}-links.yaml" 2>"inventory/talos-live/${name}-links.stderr" || true
          else
            "$TALOSCTL" get links --talosconfig generated/talosconfig --nodes "$ip" --endpoints "$ip" -o yaml > "inventory/talos-live/${name}-links.yaml" 2>"inventory/talos-live/${name}-links.stderr" || true
          fi
        }

        apply_final_config() {
          local name="$1"
          local ip="$2"
          log "applying final static machine config to $name ($ip)"
          if ! "$TALOSCTL" --talosconfig generated/talosconfig --nodes "$ip" --endpoints "$ip" apply-config --file "machine-configs/${name}.yaml"; then
            "$TALOSCTL" --nodes "$ip" --endpoints "$ip" apply-config --insecure --file "machine-configs/${name}.yaml"
          fi
        }

        wait_for_time_sync() {
          local name="$1"
          local ip="$2"
          local attempts="${3:-30}"
          log "waiting for Talos time sync on $name ($ip)"
          for attempt in $(seq 1 "$attempts"); do
            if "$TALOSCTL" get timestatus --talosconfig generated/talosconfig --nodes "$ip" --endpoints "$ip" -o yaml 2>/dev/null | grep -q "synced: true"; then
              log "Talos time is synchronized on $name ($ip)"
              return 0
            fi
            if [ "$attempt" -eq "$attempts" ]; then
              echo "Timed out waiting for Talos time sync on $name ($ip)" >&2
              "$TALOSCTL" get timestatus --talosconfig generated/talosconfig --nodes "$ip" --endpoints "$ip" -o yaml || true
              return 1
            fi
            if [ $((attempt % 3)) -eq 0 ]; then
              log "still waiting for Talos time sync on $name ($ip), attempt $attempt/$attempts"
            fi
            sleep 20
          done
        }

        bootstrap_control_plane() {
          local ip="$1"
          local attempts="${2:-30}"
          for attempt in $(seq 1 "$attempts"); do
            out="$(mktemp)"
            if "$TALOSCTL" --talosconfig generated/talosconfig --nodes "$ip" --endpoints "$ip" bootstrap >"$out" 2>&1; then
              cat "$out"
              rm -f "$out"
              log "etcd bootstrap command completed on $ip"
              return 0
            fi
            cat "$out"
            if grep -Eiq "already.*bootstrap|bootstrap.*already" "$out"; then
              rm -f "$out"
              log "etcd bootstrap already completed on $ip"
              return 0
            fi
            rm -f "$out"
            if [ "$attempt" -eq "$attempts" ]; then
              echo "Timed out retrying etcd bootstrap on $ip" >&2
              return 1
            fi
            log "etcd bootstrap on $ip is not ready yet, attempt $attempt/$attempts"
            sleep 20
          done
        }

        log "starting Talos deployer-owned apply/bootstrap/health run; log=$LOG_FILE"
        "$ROOT/maintenance/tds-prepare-talos-media.sh"
        cd "$ROOT"

        configured_api_ready() {
          local ip="$1"
          "$TALOSCTL" --talosconfig generated/talosconfig --nodes "$ip" --endpoints "$ip" version >/dev/null 2>&1
        }

        live_api_ready() {
          local ip="$1"
          "$TALOSCTL" --nodes "$ip" --endpoints "$ip" version --insecure >/dev/null 2>&1
        }

        configure_node() {
          local name="$1"
          local role="$2"
          local ip="$3"
          local media_file="$4"
          local boot_mode="$5"
          local live_attempts="$6"
          local configured_attempts="$7"
          local embedded_media="${TDS_MEDIA_ROOT}/${media_file}"

          if configured_api_ready "$ip"; then
            log "configured Talos API is already reachable on $name ($ip); converging final config"
            apply_final_config "$name" "$ip"
            wait_for_configured_api "$name" "$ip" "$configured_attempts" "after final config convergence"
            capture_live_links "$name" "$ip"
            return 0
          fi

          if [ -f "$embedded_media" ] && [ "$boot_mode" = "meta" ]; then
            wait_for_live_api "$name" "$ip" "$live_attempts"
            capture_live_links "$name" "$ip" insecure
            log "applying static machine config to $name ($ip)"
            "$TALOSCTL" --nodes "$ip" --endpoints "$ip" apply-config --insecure --file "machine-configs/${name}.yaml"
            wait_for_configured_api "$name" "$ip" "$configured_attempts" "after static config apply"
          elif [ -f "$embedded_media" ]; then
            wait_for_configured_api "$name" "$ip" 180 "from boot ISO static networking config"
            capture_live_links "$name" "$ip"
            apply_final_config "$name" "$ip"
            wait_for_configured_api "$name" "$ip" "$configured_attempts" "after final config apply"
          else
            wait_for_live_api "$name" "$ip" "$live_attempts"
            log "applying static machine config to $name ($ip)"
            "$TALOSCTL" --nodes "$ip" --endpoints "$ip" apply-config --insecure --file "machine-configs/${name}.yaml"
            wait_for_configured_api "$name" "$ip" "$configured_attempts" "after static config apply"
          fi
        }

        SUCCESSFUL_NODE_IPS=()
        SUCCESSFUL_CONTROL_PLANE_IPS=()
        FAILED_NODES=()

        run_role_nodes() {
          local wanted_role="$1"
          local strict="$2"
          local live_attempts="$3"
          local configured_attempts="$4"

          while IFS='|' read -r name role ip patch boot_patch meta_path device_id media_file boot_mode; do
            [ -n "$name" ] || continue
            [ "$role" = "$wanted_role" ] || continue
            if configure_node "$name" "$role" "$ip" "$media_file" "$boot_mode" "$live_attempts" "$configured_attempts"; then
              SUCCESSFUL_NODE_IPS+=("$ip")
              if [ "$role" = "controlplane" ]; then
                SUCCESSFUL_CONTROL_PLANE_IPS+=("$ip")
              fi
            else
              FAILED_NODES+=("${name}(${ip})")
              log "node $name ($ip) failed Talos API/configuration validation"
              if [ "$strict" = "strict" ]; then
                return 1
              fi
            fi
          done < generated/nodes.tsv
        }

        log "configuring control-plane nodes before cluster bootstrap"
        run_role_nodes controlplane strict 120 90

        first_cp=\(shellEscape(firstControlPlane?.ip ?? ""))
        first_cp_name=\(shellEscape(firstControlPlane?.name ?? ""))
        if [ -n "$first_cp" ]; then
          log "bootstrapping etcd on first control plane $first_cp"
          wait_for_time_sync "${first_cp_name:-first-control-plane}" "$first_cp" 30
          bootstrap_control_plane "$first_cp" 30
          "$TALOSCTL" --talosconfig generated/talosconfig --nodes "$first_cp" --endpoints "$first_cp" kubeconfig . --force || true
        fi

        log "configuring worker nodes after control-plane bootstrap"
        run_role_nodes worker continue 60 60 || true

        join_by_comma() {
          local IFS=,
          printf '%s' "$*"
        }

        successful_nodes="$(join_by_comma "${SUCCESSFUL_NODE_IPS[@]}")"
        successful_controlplanes="$(join_by_comma "${SUCCESSFUL_CONTROL_PLANE_IPS[@]}")"

        health_failed=0
        if [ -n "$successful_nodes" ] && [ -n "$successful_controlplanes" ]; then
          log "running Talos health across all nodes"
          "$TALOSCTL" --talosconfig generated/talosconfig --nodes "$successful_nodes" --endpoints "$successful_controlplanes" health --wait-timeout 20m || health_failed=1
        fi
        if [ "${#FAILED_NODES[@]}" -gt 0 ]; then
          printf 'Nodes failed Talos API/configuration validation:\\n' >&2
          printf ' - %s\\n' "${FAILED_NODES[@]}" >&2
          exit 1
        fi
        if [ "$health_failed" -ne 0 ]; then
          echo "Talos health check failed" >&2
          exit 1
        fi
        log "Talos deployer-owned run completed"
        """
    }

    private func renderPrepareTalosMediaScript(state: DeploymentState) -> String {
        let controlPlanes = nodeRecords(state: state, role: .controlplane)
        let workers = nodeRecords(state: state, role: .worker)
        let allNodes = controlPlanes + workers
        let installerImage = state.plan.talosArtifacts.installerImage
        let nodeLines = allNodes.map {
            "\($0.name)|\($0.role.rawValue)|\($0.ip)|\($0.patchPath)|\($0.bootPatchPath)|\($0.metaPath)|\($0.deviceID)|\($0.mediaFileName)|meta"
        }.joined(separator: "\n")

        return """
        #!/usr/bin/env bash
        set -euo pipefail

        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        \(talosctlResolver(state: state))
        TDS_MEDIA_ROOT="${TDS_MEDIA_ROOT:-\(state.spec.deployerStateRoot)/media}"
        TDS_TALOS_VERSION=\(shellEscape(state.spec.talosVersion))
        TDS_BASE_TALOS_ISO="${TDS_BASE_TALOS_ISO:-${TDS_MEDIA_ROOT}/talos-${TDS_TALOS_VERSION}.iso}"
        TDS_TALOS_BOOT_ARGS_EXTRA="${TDS_TALOS_BOOT_ARGS_EXTRA:-console=ttyS1,115200n8}"

        mkdir -p "$ROOT/generated" "$ROOT/machine-configs" "$ROOT/boot-machine-configs" "$ROOT/logs" "$TDS_MEDIA_ROOT"
        cd "$ROOT"

        if [ ! -f generated/secrets.yaml ]; then
          "$TALOSCTL" gen secrets --output-file generated/secrets.yaml
        fi
        "$TALOSCTL" gen config \(shellEscape(state.spec.clusterName)) \(shellEscape(state.spec.clusterEndpoint)) \\
          --with-secrets generated/secrets.yaml \\
          --install-image \(shellEscape(installerImage)) \\
          --output-dir generated \\
          --force

        cat > generated/nodes.tsv <<'EOF_NODES'
        \(nodeLines)
        EOF_NODES

        while IFS='|' read -r name role ip patch boot_patch meta_path device_id media_file boot_mode; do
          [ -n "$name" ] || continue
          base="generated/controlplane.yaml"
          if [ "$role" = "worker" ]; then
            base="generated/worker.yaml"
          fi
          cp "$base" "machine-configs/${name}.yaml"
          patched="$(mktemp)"
          "$TALOSCTL" machineconfig patch "machine-configs/${name}.yaml" \\
            --patch "@${patch}" \\
            --output "$patched"
          mv "$patched" "machine-configs/${name}.yaml"
          "$TALOSCTL" validate --mode metal --config "machine-configs/${name}.yaml" --strict
          cp "$base" "boot-machine-configs/${name}.yaml"
          boot_patched="$(mktemp)"
          "$TALOSCTL" machineconfig patch "boot-machine-configs/${name}.yaml" \\
            --patch "@${boot_patch}" \\
            --output "$boot_patched"
          mv "$boot_patched" "boot-machine-configs/${name}.yaml"
          boot_no_install="$(mktemp)"
          awk '
            /^    install:[[:space:]]*$/ { skip=1; next }
            skip && (/^    [^ ].*:/ || /^cluster:/ || /^---/) { skip=0 }
            !skip { print }
          ' "boot-machine-configs/${name}.yaml" > "$boot_no_install"
          mv "$boot_no_install" "boot-machine-configs/${name}.yaml"
          "$TALOSCTL" validate --mode cloud --config "boot-machine-configs/${name}.yaml" --strict
          if [ -f "$TDS_BASE_TALOS_ISO" ]; then
            if ! command -v xorriso >/dev/null 2>&1; then
              echo "xorriso is required to build node-specific Talos ISO media" >&2
              exit 1
            fi
            work="$(mktemp -d)"
            out="${TDS_MEDIA_ROOT}/${media_file}"
            rm -f "$out" "$out.tmp"
            xorriso -osirrox on -indev "$TDS_BASE_TALOS_ISO" \\
              -extract /boot/grub/grub.cfg "$work/grub.cfg" >/dev/null 2>&1
            meta_payload="$( { printf '0xa='; cat "${meta_path}"; } | gzip -9 | base64 | tr -d '\\n' )"
            sed -i "s|talos.platform=metal |talos.platform=metal talos.environment=INSTALLER_META_BASE64=${meta_payload} ${TDS_TALOS_BOOT_ARGS_EXTRA} |g" "$work/grub.cfg"
            xorriso -indev "$TDS_BASE_TALOS_ISO" -outdev "$out.tmp" \\
              -volid metal-iso \\
              -map "$work/grub.cfg" /boot/grub/grub.cfg \\
              -boot_image any replay >/dev/null 2>&1
            mv "$out.tmp" "$out"

            wipe_out="${out%.iso}-wipe.iso"
            wipe_grub="$work/wipe-grub.cfg"
            cp "$work/grub.cfg" "$wipe_grub"
            sed -i "s/talos.config=metal-iso //g" "$wipe_grub"
            if grep -q "talos.experimental.wipe=system" "$wipe_grub"; then
              sed -i "s/^set default=.*/set default=1/" "$wipe_grub"
            else
              sed -i "s/^set default=.*/set default=0/" "$wipe_grub"
              sed -i "s/talos.platform=metal /talos.platform=metal talos.experimental.wipe=system /g" "$wipe_grub"
            fi
            rm -f "$wipe_out" "$wipe_out.tmp"
            xorriso -indev "$TDS_BASE_TALOS_ISO" -outdev "$wipe_out.tmp" \\
              -volid metal-iso \\
              -map "$wipe_grub" /boot/grub/grub.cfg \\
              -boot_image any replay >/dev/null 2>&1
            mv "$wipe_out.tmp" "$wipe_out"
            rm -rf "$work"
          fi
        done < generated/nodes.tsv
        """
    }
    private func talosctlResolver(state: DeploymentState) -> String {
        """
        TDS_DEPLOYER_STATE_ROOT=\(shellEscape(state.spec.deployerStateRoot))
        TALOSCTL="${ROOT}/bin/talosctl"
        if [ ! -x "$TALOSCTL" ] && [ -x "${TDS_DEPLOYER_STATE_ROOT}/bin/talosctl" ]; then
          TALOSCTL="${TDS_DEPLOYER_STATE_ROOT}/bin/talosctl"
        fi
        if [ ! -x "$TALOSCTL" ]; then
          TALOSCTL="$(command -v talosctl || true)"
        fi
        if [ -z "${TALOSCTL:-}" ] || [ ! -x "$TALOSCTL" ]; then
          echo "talosctl is not installed on the deployer" >&2
          exit 1
        fi
        """
    }

    private func renderHealthCheckScript(state: DeploymentState) -> String {
        let controlPlanes = nodeRecords(state: state, role: .controlplane)
        let allNodes = controlPlanes + nodeRecords(state: state, role: .worker)
        return """
        #!/usr/bin/env bash
        set -euo pipefail
        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        \(talosctlResolver(state: state))
        "$TALOSCTL" --talosconfig "$ROOT/generated/talosconfig" --nodes \(shellEscape(allNodes.map(\.ip).joined(separator: ","))) --endpoints \(shellEscape(controlPlanes.map(\.ip).joined(separator: ","))) health --wait-timeout 10m
        if [ -f "$ROOT/kubeconfig" ] && command -v kubectl >/dev/null 2>&1; then
          kubectl --kubeconfig "$ROOT/kubeconfig" get nodes -o wide
          kubectl --kubeconfig "$ROOT/kubeconfig" get pods -A
        elif [ -f "$ROOT/kubeconfig" ]; then
          echo "kubectl is not installed; Talos health passed, skipping Kubernetes object listing." >&2
        fi
        """
    }

    private func renderApplyNodeScript(state: DeploymentState) -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail
        if [ "$#" -lt 2 ]; then
          echo "usage: $0 NODE_IP MACHINE_CONFIG_PATH" >&2
          exit 2
        fi
        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        \(talosctlResolver(state: state))
        "$TALOSCTL" --nodes "$1" apply-config --insecure --file "$2"
        """
    }

    private func renderUpgradeTalosScript(state: DeploymentState) -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail
        if [ "$#" -lt 1 ]; then
          echo "usage: $0 INSTALLER_IMAGE" >&2
          exit 2
        fi
        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        \(talosctlResolver(state: state))
        "$TALOSCTL" --talosconfig "$ROOT/generated/talosconfig" upgrade --image "$1" --preserve
        """
    }

    private func renderUpgradeKubernetesScript(state: DeploymentState) -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail
        if [ "$#" -lt 1 ]; then
          echo "usage: $0 KUBERNETES_VERSION" >&2
          exit 2
        fi
        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        \(talosctlResolver(state: state))
        "$TALOSCTL" --talosconfig "$ROOT/generated/talosconfig" upgrade-k8s --to "$1"
        """
    }

    private func renderRotateConfigsScript() -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail
        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        ts="$(date -u +%Y%m%dT%H%M%SZ)"
        mkdir -p "$ROOT/archive/$ts"
        cp -a "$ROOT/generated" "$ROOT/machine-configs" "$ROOT/boot-machine-configs" "$ROOT/archive/$ts/" 2>/dev/null || true
        echo "Archived generated config material to $ROOT/archive/$ts"
        """
    }

    private func renderCollectLogsScript(state: DeploymentState) -> String {
        let allIPs = nodeRecords(state: state, role: .controlplane) + nodeRecords(state: state, role: .worker)
        let nodeList = allIPs.map(\.ip).map(shellEscape).joined(separator: " ")
        return """
        #!/usr/bin/env bash
        set -euo pipefail
        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        \(talosctlResolver(state: state))
        out="$ROOT/logs/collect-$(date -u +%Y%m%dT%H%M%SZ)"
        mkdir -p "$out"
        for node in \(nodeList); do
          "$TALOSCTL" --talosconfig "$ROOT/generated/talosconfig" --nodes "$node" logs > "$out/$node.log" 2>&1 || true
        done
        echo "$out"
        """
    }

    private func nodeRecords(state: DeploymentState, role: DeviceRole) -> [NodeRecord] {
        state.spec.nodes
            .filter { $0.assignment.role == role }
            .map { node in
                let config = StaticNetworkPlanner().config(for: node)
                return NodeRecord(
                    name: node.device.name,
                    role: node.assignment.role,
                    ip: config.managementAddressCIDR.split(separator: "/").first.map(String.init) ?? node.device.privateIP,
                    patchPath: "node-patches/\(node.device.name).yaml",
                    bootPatchPath: "boot-node-patches/\(node.device.name).yaml",
                    metaPath: "boot-network-meta/\(node.device.name).yaml",
                    deviceID: node.device.id,
                    mediaFileName: talosNodeMediaFileName(deviceID: node.device.id, talosVersion: state.spec.talosVersion)
                )
            }
    }

    private struct NodeRecord {
        var name: String
        var role: DeviceRole
        var ip: String
        var patchPath: String
        var bootPatchPath: String
        var metaPath: String
        var deviceID: String
        var mediaFileName: String
    }
}

public final class TalosDeploymentExecutor: @unchecked Sendable {
    private let settings: AppSettings
    private let oobBooter: any OOBNodeBooting
    private let wipeDelayNanoseconds: UInt64
    private let mediaRetryDelayNanoseconds: UInt64

    public init(
        settings: AppSettings = AppSettings(),
        oobBooter: (any OOBNodeBooting)? = nil,
        wipeDelayNanoseconds: UInt64 = 300_000_000_000,
        mediaRetryDelayNanoseconds: UInt64 = 15_000_000_000
    ) {
        self.settings = settings
        self.oobBooter = oobBooter ?? HammertimeOOBBooter(settings: settings.hammertime)
        self.wipeDelayNanoseconds = wipeDelayNanoseconds
        self.mediaRetryDelayNanoseconds = mediaRetryDelayNanoseconds
    }

    public func execute(state: DeploymentState, transport: any DeployerTransport, configuration: DeployerMediaServiceConfiguration) async throws -> (TalosProvisioningExecution, TalosBootstrapResult) {
        let mediaBaseURL = deployerMediaBaseURL(state: state, configuration: configuration)
        let talosInstalls = state.plan.installs.filter { $0.assignment.role == .controlplane || $0.assignment.role == .worker }
        let plannedActions = talosInstalls.map { plannedAction(for: $0, mediaBaseURL: mediaBaseURL, state: state) }

        var executedActions: [String] = []
        var warnings: [String] = []
        let talosISOPath = "\(configuration.mediaRoot)/talos-\(state.spec.talosVersion).iso"
        let registryInstallerImage = deployerRegistryInstallerImage(for: state.spec)
        let registryCacheCommand = renderRegistryCacheCommand(
            state: state,
            configuration: configuration,
            registryInstallerImage: registryInstallerImage
        )
        let nodeRouteCommand = renderTalosNodeRouteCommand(state: state)
        let startMediaCommand = """
        set -e
        mkdir -p \(shellEscape(configuration.mediaRoot)) \(shellEscape("\(configuration.stateRoot)/logs"))
        if command -v curl >/dev/null 2>&1 && [ ! -f \(shellEscape(talosISOPath)) ]; then
          curl -fL -o \(shellEscape(talosISOPath)) \(shellEscape(state.plan.talosArtifacts.isoURL)) || true
        fi
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files tds-media-http.service >/dev/null 2>&1; then
          sudo systemctl restart tds-media-http.service || true
        fi
        if [ -f \(shellEscape("\(configuration.stateRoot)/media-service.env")) ]; then
          . \(shellEscape("\(configuration.stateRoot)/media-service.env"))
          http_check_host="$HTTP_BIND"
          if [ "$http_check_host" = "0.0.0.0" ]; then
            http_check_host="127.0.0.1"
          fi
          if ! python3 -c 'import socket,sys; s=socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2); s.close()' "$http_check_host" "$HTTP_PORT" >/dev/null 2>&1; then
            sh -c "$START_COMMAND" || true
          fi
        fi
        """
        tdsProgress("Preparing deployer-hosted Talos ISO and media service")
        _ = try await transport.run(startMediaCommand, timeout: 900)
        tdsProgress("Deployer-hosted Talos media service is ready")
        executedActions.append("Prepared deployer-hosted Talos media at \(talosISOPath).")
        if !registryCacheCommand.isEmpty {
            tdsProgress("Caching Talos installer image in deployer registry")
            _ = try await transport.run(registryCacheCommand, timeout: 1800)
            tdsProgress("Talos installer image is cached in deployer registry")
            executedActions.append("Cached Talos installer image in deployer registry at \(registryInstallerImage ?? "configured registry").")
            if !state.spec.talosProvisioning.deployerRegistryAddressCIDR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                executedActions.append("Ensured deployer node-facing registry address \(state.spec.talosProvisioning.deployerRegistryAddressCIDR).")
            }
        }
        if !nodeRouteCommand.isEmpty {
            tdsProgress("Reconciling deployer host routes to Talos nodes")
            _ = try await transport.run(nodeRouteCommand, timeout: 120)
            tdsProgress("Deployer host routes to Talos nodes are reconciled")
            executedActions.append("Reconciled deployer host routes to Talos node management IPs.")
        }
        if mediaBaseURL.isEmpty {
            warnings.append("No deployer media address is configured; OOB boot URL actions must use PXE, direct virtual media, or operator local media.")
        }

        let prepareMediaCommand = """
        cd \(shellEscape(state.plan.durableStateDirectory)) && \\
        TDS_MEDIA_ROOT=\(shellEscape(configuration.mediaRoot)) \\
        TDS_TALOS_VERSION=\(shellEscape(state.spec.talosVersion)) \\
        ./maintenance/tds-prepare-talos-media.sh
        """
        tdsProgress("Generating node-specific Talos machine configs and boot media")
        _ = try await transport.run(prepareMediaCommand, timeout: 1800)
        tdsProgress("Node-specific Talos boot media generated")
        executedActions.append("Generated node-specific Talos boot media with embedded machine configs.")

        if state.spec.talosProvisioning.wipeSystemDiskBeforeInstall {
            var didRequestWipe = false
            for install in talosInstalls {
                tdsProgress("Requesting destructive Talos system-disk wipe for \(install.device.name) (\(install.device.id)) before install")
                let result = try await provisionTalosWipe(install, mediaBaseURL: mediaBaseURL, state: state)
                if !result.executedActions.isEmpty {
                    didRequestWipe = true
                }
                executedActions.append(contentsOf: result.executedActions)
                warnings.append(contentsOf: result.warnings)
            }
            if didRequestWipe {
                tdsProgress("Waiting for Talos wipe boots to reset system disks before normal install media boot")
                if wipeDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: wipeDelayNanoseconds)
                }
            }
        }

        for install in talosInstalls {
            tdsProgress("Provisioning \(install.device.name) (\(install.device.id)) as \(install.assignment.role.displayName) using \(install.method.rawValue)")
            let result = try await provisionTalosNode(install, mediaBaseURL: mediaBaseURL, state: state)
            tdsProgress("Provisioning request completed for \(install.device.name) (\(install.device.id))")
            executedActions.append(contentsOf: result.executedActions)
            warnings.append(contentsOf: result.warnings)
        }

        let bootstrapCommand = """
        cd \(shellEscape(state.plan.durableStateDirectory)) && \\
        TDS_MEDIA_ROOT=\(shellEscape(configuration.mediaRoot)) \\
        ./maintenance/tds-run-talos-deploy.sh
        """
        tdsProgress("Running deployer-owned Talos apply/bootstrap/health script")
        _ = try await transport.run(bootstrapCommand, timeout: 3600)
        tdsProgress("Deployer-owned Talos apply/bootstrap/health script completed")
        executedActions.append("Ran deployer-owned Talos apply/bootstrap/health script.")

        let firstControlPlane = state.spec.nodes.first { $0.assignment.role == .controlplane }
        let bootstrap = TalosBootstrapResult(
            bootstrapNode: firstControlPlane?.device.name ?? "",
            commands: [
                startMediaCommand,
                prepareMediaCommand,
                bootstrapCommand,
            ],
            succeeded: true,
            warnings: warnings
        )
        return (
            TalosProvisioningExecution(plannedActions: plannedActions, executedActions: executedActions, warnings: warnings),
            bootstrap
        )
    }

    public func resumeDeployerState(state: DeploymentState, transport: any DeployerTransport, configuration: DeployerMediaServiceConfiguration) async throws -> (TalosProvisioningExecution, TalosBootstrapResult) {
        var executedActions: [String] = []
        let warnings: [String] = []
        let talosISOPath = "\(configuration.mediaRoot)/talos-\(state.spec.talosVersion).iso"
        let registryInstallerImage = deployerRegistryInstallerImage(for: state.spec)
        let registryCacheCommand = renderRegistryCacheCommand(
            state: state,
            configuration: configuration,
            registryInstallerImage: registryInstallerImage
        )
        let nodeRouteCommand = renderTalosNodeRouteCommand(state: state)
        let startMediaCommand = """
        set -e
        mkdir -p \(shellEscape(configuration.mediaRoot)) \(shellEscape("\(configuration.stateRoot)/logs"))
        if command -v curl >/dev/null 2>&1 && [ ! -f \(shellEscape(talosISOPath)) ]; then
          curl -fL -o \(shellEscape(talosISOPath)) \(shellEscape(state.plan.talosArtifacts.isoURL)) || true
        fi
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files tds-media-http.service >/dev/null 2>&1; then
          sudo systemctl restart tds-media-http.service || true
        fi
        if [ -f \(shellEscape("\(configuration.stateRoot)/media-service.env")) ]; then
          . \(shellEscape("\(configuration.stateRoot)/media-service.env"))
          http_check_host="$HTTP_BIND"
          if [ "$http_check_host" = "0.0.0.0" ]; then
            http_check_host="127.0.0.1"
          fi
          if ! python3 -c 'import socket,sys; s=socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2); s.close()' "$http_check_host" "$HTTP_PORT" >/dev/null 2>&1; then
            sh -c "$START_COMMAND" || true
          fi
        fi
        """
        tdsProgress("Restarting deployer-hosted media service for resume")
        _ = try await transport.run(startMediaCommand, timeout: 900)
        executedActions.append("Restarted deployer-hosted Talos media service for resume.")
        if !registryCacheCommand.isEmpty {
            tdsProgress("Revalidating deployer registry cache for resume")
            _ = try await transport.run(registryCacheCommand, timeout: 1800)
            executedActions.append("Revalidated Talos installer image in deployer registry.")
        }
        if !nodeRouteCommand.isEmpty {
            tdsProgress("Reconciling deployer host routes for resume")
            _ = try await transport.run(nodeRouteCommand, timeout: 120)
            executedActions.append("Reconciled deployer host routes to Talos node management IPs.")
        }

        let bootstrapCommand = """
        cd \(shellEscape(state.plan.durableStateDirectory)) && \\
        TDS_MEDIA_ROOT=\(shellEscape(configuration.mediaRoot)) \\
        ./maintenance/tds-run-talos-deploy.sh
        """
        tdsProgress("Resuming deployer-owned Talos apply/bootstrap/health script")
        _ = try await transport.run(bootstrapCommand, timeout: 7200)
        tdsProgress("Deployer-owned Talos resume script completed")
        executedActions.append("Resumed deployer-owned Talos apply/bootstrap/health script.")

        let firstControlPlane = state.spec.nodes.first { $0.assignment.role == .controlplane }
        let bootstrap = TalosBootstrapResult(
            bootstrapNode: firstControlPlane?.device.name ?? "",
            commands: [startMediaCommand, bootstrapCommand],
            succeeded: true,
            warnings: warnings
        )
        return (
            TalosProvisioningExecution(
                plannedActions: ["Resume deployer-owned Talos apply/bootstrap/health without reissuing OOB boot requests."],
                executedActions: executedActions,
                warnings: warnings
            ),
            bootstrap
        )
    }

    private func plannedAction(for install: PlannedDeviceInstall, mediaBaseURL: String, state: DeploymentState) -> String {
        switch install.method {
        case .bootURL:
            let imageURL = firstNonEmpty(deployerNodeMediaURL(for: install, mediaBaseURL: mediaBaseURL, state: state), externalOOBMediaURL(state: state))
            return "Boot \(install.device.name) from OOB URL media \(imageURL)."
        case .pxe:
            return "Boot \(install.device.name) through deployer PXE services."
        case .virtualMedia:
            return "Boot \(install.device.name) through direct OOB virtual media with \(state.plan.talosArtifacts.isoURL)."
        case .operatorLocalMedia:
            return "Wait for guided operator local-media boot for \(install.device.name)."
        case .stagedOnly:
            return "Stage \(install.device.name) without booting."
        }
    }

    private func renderRegistryCacheCommand(
        state: DeploymentState,
        configuration: DeployerMediaServiceConfiguration,
        registryInstallerImage: String?
    ) -> String {
        guard let registryInstallerImage,
              let registryHost = deployerRegistryHost(for: state.spec)
        else {
            return ""
        }
        let localRegistry = "127.0.0.1:\(configuration.registryPort)"
        let registryRoot = "\(configuration.stateRoot)/registry"
        let targetPath = registryInstallerImage.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        guard !targetPath.isEmpty else { return "" }
        let localTarget = "\(localRegistry)/\(targetPath)"
        return """
        set -e
        if ! command -v skopeo >/dev/null 2>&1; then
          echo "skopeo is required to cache Talos installer image in the deployer registry" >&2
          exit 1
        fi
        \(renderRegistryAddressCommand(state: state))
        \(dockerRegistryWritableCommand(registryRoot: registryRoot))
        if command -v systemctl >/dev/null 2>&1; then
          sudo systemctl restart docker-registry || sudo systemctl start docker-registry || true
        fi
        for attempt in $(seq 1 30); do
          if curl -fsS \(shellEscape("http://\(localRegistry)/v2/")) >/dev/null 2>&1; then
            break
          fi
          if [ "$attempt" -eq 30 ]; then
            echo "Timed out waiting for deployer registry \(registryHost)" >&2
            exit 1
          fi
          sleep 2
        done
        skopeo copy --retry-times 3 --dest-tls-verify=false \(shellEscape("docker://\(state.plan.talosArtifacts.installerImage)")) \(shellEscape("docker://\(localTarget)"))
        """
    }

    private func renderRegistryAddressCommand(state: DeploymentState) -> String {
        let cidr = state.spec.talosProvisioning.deployerRegistryAddressCIDR.trimmingCharacters(in: .whitespacesAndNewlines)
        let interface = state.spec.talosProvisioning.deployerRegistryInterface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cidr.isEmpty || !interface.isEmpty else { return "" }
        guard !cidr.isEmpty && !interface.isEmpty else {
            return """
            echo "Both deployer registry address CIDR and interface are required when configuring a node-facing registry alias" >&2
            exit 1
            """
        }
        return """
        IP_BIN="$(command -v ip || true)"
        if [ -z "$IP_BIN" ]; then
          echo "iproute2 is required to configure the deployer registry address \(cidr)" >&2
          exit 1
        fi
        if ! "$IP_BIN" link show dev \(shellEscape(interface)) >/dev/null 2>&1; then
          echo "Deployer registry interface \(interface) does not exist" >&2
          exit 1
        fi
        for existing_dev in $("${IP_BIN}" -o addr show | awk '$4 == "\(cidr)" { print $2 }'); do
          if [ "$existing_dev" != \(shellEscape(interface)) ]; then
            sudo "$IP_BIN" addr del \(shellEscape(cidr)) dev "$existing_dev" 2>/dev/null || true
          fi
        done
        sudo "$IP_BIN" addr replace \(shellEscape(cidr)) dev \(shellEscape(interface))
        if command -v systemctl >/dev/null 2>&1; then
          cat > /tmp/tds-registry-address.service <<EOF
        [Unit]
        Description=TDS node-facing registry address
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=${IP_BIN} addr replace \(cidr) dev \(interface)
        ExecStop=${IP_BIN} addr del \(cidr) dev \(interface)

        [Install]
        WantedBy=multi-user.target
        EOF
          sudo mv /tmp/tds-registry-address.service /etc/systemd/system/tds-registry-address.service
          sudo systemctl daemon-reload
          sudo systemctl enable tds-registry-address.service
          sudo systemctl restart tds-registry-address.service
        fi
        """
    }

    private func renderTalosNodeRouteCommand(state: DeploymentState) -> String {
        let ips = talosNodeManagementIPs(state: state)
        guard !ips.isEmpty else { return "" }
        let interface = state.spec.talosProvisioning.deployerNodeRouteInterface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !interface.isEmpty else {
            let deleteRoutes = ips.map {
                "sudo \"$IP_BIN\" route del \(shellEscape("\($0)/32")) 2>/dev/null || true"
            }.joined(separator: "\n")
            return """
            set -e
            IP_BIN="$(command -v ip || true)"
            if [ -z "$IP_BIN" ]; then
              echo "iproute2 is required to reconcile deployer Talos node routes" >&2
              exit 1
            fi
            if command -v systemctl >/dev/null 2>&1; then
              sudo systemctl disable --now tds-node-routes.service 2>/dev/null || true
              sudo rm -f /etc/systemd/system/tds-node-routes.service
              sudo systemctl daemon-reload
            fi
            \(deleteRoutes)
            """
        }
        let sourceIP = state.spec.talosProvisioning.deployerNodeRouteSourceCIDR
            .split(separator: "/")
            .first
            .map(String.init) ?? ""
        let sourceArgument = sourceIP.isEmpty ? "" : " src \(shellEscape(sourceIP))"
        let systemdSourceArgument = sourceIP.isEmpty ? "" : " src \(sourceIP)"

        let replaceRoutes = ips.map {
            "sudo \"$IP_BIN\" route replace \(shellEscape("\($0)/32")) dev \(shellEscape(interface))\(sourceArgument)"
        }.joined(separator: "\n")
        let deleteRoutes = ips.map {
            "sudo \"$IP_BIN\" route del \(shellEscape("\($0)/32")) dev \(shellEscape(interface)) 2>/dev/null || true"
        }.joined(separator: "\n")
        let systemdStarts = ips.map {
            "ExecStart=${IP_BIN} route replace \($0)/32 dev \(interface)\(systemdSourceArgument)"
        }.joined(separator: "\n")
        let systemdStops = ips.map {
            "ExecStop=-${IP_BIN} route del \($0)/32 dev \(interface)"
        }.joined(separator: "\n")

        return """
        set -e
        IP_BIN="$(command -v ip || true)"
        if [ -z "$IP_BIN" ]; then
          echo "iproute2 is required to reconcile deployer Talos node routes" >&2
          exit 1
        fi
        if ! "$IP_BIN" link show dev \(shellEscape(interface)) >/dev/null 2>&1; then
          echo "Deployer Talos node route interface \(interface) does not exist" >&2
          exit 1
        fi
        \(replaceRoutes)
        if command -v systemctl >/dev/null 2>&1; then
          cat > /tmp/tds-node-routes.service <<EOF
        [Unit]
        Description=TDS Talos node management host routes
        After=network-online.target tds-registry-address.service
        Wants=network-online.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        \(systemdStarts)
        \(systemdStops)

        [Install]
        WantedBy=multi-user.target
        EOF
          sudo mv /tmp/tds-node-routes.service /etc/systemd/system/tds-node-routes.service
          sudo systemctl daemon-reload
          sudo systemctl enable --now tds-node-routes.service
        fi
        \(deleteRoutes)
        \(replaceRoutes)
        """
    }

    private func provisionTalosWipe(_ install: PlannedDeviceInstall, mediaBaseURL: String, state: DeploymentState) async throws -> TalosProvisioningExecution {
        switch install.method {
        case .bootURL:
            let imageURL = deployerNodeWipeMediaURL(for: install, mediaBaseURL: mediaBaseURL, state: state)
            guard !imageURL.isEmpty else {
                return TalosProvisioningExecution(warnings: ["Skipped Talos wipe boot for \(install.device.name): no deployer-hosted wipe media URL was available."])
            }
            let result = try await oobBooter.bootURL(
                OOBBootURLRequest(
                    deviceID: install.device.id,
                    imageURL: imageURL,
                    connectMedia: true,
                    bootOnce: true,
                    reboot: true,
                    proxyVia: settings.hammertime.deployerVia,
                    oobVendor: install.device.oob?.vendor ?? .unknown
                )
            )
            let status = result.connected ? "connected" : "requested"
            return TalosProvisioningExecution(executedActions: ["Destructive Talos wipe boot \(status) for \(install.device.name) using \(imageURL)."])
        case .pxe:
            return TalosProvisioningExecution(warnings: ["Skipped Talos wipe pre-boot for \(install.device.name): PXE wipe boot is not implemented yet."])
        case .virtualMedia:
            return TalosProvisioningExecution(warnings: ["Skipped Talos wipe pre-boot for \(install.device.name): direct external virtual-media wipe boot is not implemented yet."])
        case .operatorLocalMedia:
            return TalosProvisioningExecution(warnings: ["\(install.device.name) requires guided operator local-media wipe/install before the deployer apply script can finish."])
        case .stagedOnly:
            return TalosProvisioningExecution(warnings: ["Skipped Talos wipe pre-boot for \(install.device.name): device is staged only."])
        }
    }

    private func provisionTalosNode(_ install: PlannedDeviceInstall, mediaBaseURL: String, state: DeploymentState) async throws -> TalosProvisioningExecution {
        switch install.method {
        case .bootURL:
            let imageURL = firstNonEmpty(deployerNodeMediaURL(for: install, mediaBaseURL: mediaBaseURL, state: state), externalOOBMediaURL(state: state))
            guard !imageURL.isEmpty else {
                return TalosProvisioningExecution(warnings: ["Skipped OOB URL boot for \(install.device.name): no deployer or external media URL was available."])
            }
            let result = try await bootURLWithConnectedMediaRetry(
                deviceName: install.device.name,
                request: OOBBootURLRequest(
                    deviceID: install.device.id,
                    imageURL: imageURL,
                    connectMedia: true,
                    bootOnce: true,
                    reboot: true,
                    proxyVia: settings.hammertime.deployerVia,
                    oobVendor: install.device.oob?.vendor ?? .unknown
                )
            )
            let status = result.connected ? "connected" : "requested"
            return TalosProvisioningExecution(executedActions: ["OOB URL boot \(status) for \(install.device.name) using \(imageURL)."])
        case .virtualMedia:
            let result = try await bootURLWithConnectedMediaRetry(
                deviceName: install.device.name,
                request: OOBBootURLRequest(
                    deviceID: install.device.id,
                    imageURL: state.plan.talosArtifacts.isoURL,
                    connectMedia: true,
                    bootOnce: true,
                    reboot: true,
                    proxyVia: settings.hammertime.deployerVia,
                    oobVendor: install.device.oob?.vendor ?? .unknown
                )
            )
            let status = result.connected ? "connected" : "requested"
            return TalosProvisioningExecution(executedActions: ["Direct OOB virtual-media boot \(status) for \(install.device.name) using \(state.plan.talosArtifacts.isoURL)."])
        case .pxe:
            _ = try await oobBooter.bootPXE(
                OOBPXEBootRequest(
                    deviceID: install.device.id,
                    oneTimeBoot: "pxe",
                    reboot: true,
                    proxyVia: settings.hammertime.deployerVia
                )
            )
            return TalosProvisioningExecution(executedActions: ["PXE one-time boot requested for \(install.device.name)."])
        case .operatorLocalMedia:
            return TalosProvisioningExecution(warnings: ["\(install.device.name) requires guided operator local-media boot before the deployer apply script can finish."])
        case .stagedOnly:
            return TalosProvisioningExecution(executedActions: ["Staged \(install.device.name) without a boot request."])
        }
    }

    private func bootURLWithConnectedMediaRetry(deviceName: String, request: OOBBootURLRequest) async throws -> OOBBootURLResult {
        let maximumAttempts = 3
        var lastResult: OOBBootURLResult?
        for attempt in 1...maximumAttempts {
            var attemptRequest = request
            if attempt > 1 {
                attemptRequest.preferPowerReset = true
            }
            let result = try await oobBooter.bootURL(attemptRequest)
            if result.connected {
                return result
            }
            lastResult = result
            if attempt < maximumAttempts {
                tdsProgress("OOB URL boot for \(deviceName) did not report connected media after boot request; retrying attempt \(attempt + 1)/\(maximumAttempts)")
                if mediaRetryDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: mediaRetryDelayNanoseconds)
                }
            }
        }

        throw TalosDeploymentExecutionError.oobURLMediaDisconnected(
            deviceName: deviceName,
            imageURL: request.imageURL,
            status: lastResult?.steps.last?.stdout ?? ""
        )
    }

    private func deployerMediaBaseURL(state: DeploymentState, configuration: DeployerMediaServiceConfiguration) -> String {
        let host = firstNonEmpty(configurationHost(from: state), state.plan.deployer.device.privateIP, state.plan.deployer.device.primaryIP)
        guard !host.isEmpty else { return "" }
        return "http://\(host):\(configuration.httpPort)"
    }

    private func deployerNodeMediaURL(for install: PlannedDeviceInstall, mediaBaseURL: String, state: DeploymentState) -> String {
        guard !mediaBaseURL.isEmpty else { return "" }
        let fileName = talosNodeMediaFileName(deviceID: install.device.id, talosVersion: state.spec.talosVersion)
        return "\(mediaBaseURL)/\(fileName)"
    }

    private func deployerNodeWipeMediaURL(for install: PlannedDeviceInstall, mediaBaseURL: String, state: DeploymentState) -> String {
        guard !mediaBaseURL.isEmpty else { return "" }
        let fileName = talosNodeWipeMediaFileName(deviceID: install.device.id, talosVersion: state.spec.talosVersion)
        return "\(mediaBaseURL)/\(fileName)"
    }

    private func externalOOBMediaURL(state: DeploymentState) -> String {
        let base = state.spec.talosProvisioning.externalOOBMediaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        if base.localizedCaseInsensitiveContains(".iso") {
            return base
        }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/talos-\(state.spec.talosVersion).iso"
    }

    private func configurationHost(from state: DeploymentState) -> String {
        state.spec.deployerNode?.assignment.staticNetwork.managementAddressCIDR.split(separator: "/").first.map(String.init) ?? ""
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    private func talosNodeManagementIPs(state: DeploymentState) -> [String] {
        let planner = StaticNetworkPlanner()
        var seen: Set<String> = []
        return state.spec.nodes.compactMap { node in
            guard node.assignment.role == .controlplane || node.assignment.role == .worker else {
                return nil
            }
            let address = planner.config(for: node).managementAddressCIDR
            guard let ip = address.split(separator: "/").first.map(String.init),
                  !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !seen.contains(ip)
            else {
                return nil
            }
            seen.insert(ip)
            return ip
        }
    }
}

private func talosNodeMediaFileName(deviceID: String, talosVersion: String) -> String {
    "talos-\(sanitizeFileComponent(talosVersion))-\(sanitizeFileComponent(deviceID)).iso"
}

private func talosNodeWipeMediaFileName(deviceID: String, talosVersion: String) -> String {
    "talos-\(sanitizeFileComponent(talosVersion))-\(sanitizeFileComponent(deviceID))-wipe.iso"
}

private func sanitizeFileComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let sanitized = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    let result = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    return result.isEmpty ? "node" : result
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
