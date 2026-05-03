import Foundation

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
                "inventory/selected-devices.json",
                "inventory/networking-summary.json",
            ]
        )
        try JSONEncoder.pretty.encode(manifest).write(to: directory.appending(path: "maintenance-bundle.json"), options: .atomic)
        return manifest
    }

    private func renderTalosDeployScript(state: DeploymentState) -> String {
        let controlPlanes = nodeRecords(state: state, role: .controlplane)
        let workers = nodeRecords(state: state, role: .worker)
        let firstControlPlane = controlPlanes.first
        let allNodes = controlPlanes + workers
        let installerImage = state.plan.talosArtifacts.installerImage
        let nodeLines = allNodes.map { "\($0.name)|\($0.role.rawValue)|\($0.ip)|\($0.patchPath)" }.joined(separator: "\n")
        let cpIPs = controlPlanes.map(\.ip).joined(separator: ",")
        let allIPs = allNodes.map(\.ip).joined(separator: ",")

        return """
        #!/usr/bin/env bash
        set -euo pipefail

        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        \(talosctlResolver(state: state))

        mkdir -p "$ROOT/generated" "$ROOT/machine-configs" "$ROOT/logs"
        cd "$ROOT"

        if [ ! -f generated/secrets.yaml ]; then
          "$TALOSCTL" gen secrets --output-file generated/secrets.yaml
        fi
        if [ ! -f generated/talosconfig ]; then
          "$TALOSCTL" gen config \(shellEscape(state.spec.clusterName)) \(shellEscape(state.spec.clusterEndpoint)) \\
            --with-secrets generated/secrets.yaml \\
            --install-image \(shellEscape(installerImage)) \\
            --output-dir generated \\
            --force
        fi

        cat > generated/nodes.tsv <<'EOF_NODES'
        \(nodeLines)
        EOF_NODES

        while IFS='|' read -r name role ip patch; do
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
          for attempt in $(seq 1 120); do
            if "$TALOSCTL" --nodes "$ip" version --insecure >/dev/null 2>&1; then
              break
            fi
            if [ "$attempt" -eq 120 ]; then
              echo "Timed out waiting for Talos live boot on $name ($ip)" >&2
              exit 1
            fi
            sleep 10
          done
          "$TALOSCTL" --nodes "$ip" apply-config --insecure --file "machine-configs/${name}.yaml"
        done < generated/nodes.tsv

        first_cp=\(shellEscape(firstControlPlane?.ip ?? ""))
        if [ -n "$first_cp" ]; then
          "$TALOSCTL" --talosconfig generated/talosconfig --nodes "$first_cp" --endpoints "$first_cp" bootstrap || true
          "$TALOSCTL" --talosconfig generated/talosconfig --nodes "$first_cp" --endpoints "$first_cp" kubeconfig . --force || true
        fi
        if [ -n "\(allIPs)" ] && [ -n "\(cpIPs)" ]; then
          "$TALOSCTL" --talosconfig generated/talosconfig --nodes \(shellEscape(allIPs)) --endpoints \(shellEscape(cpIPs)) health --wait-timeout 20m
        fi
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
        cp -a "$ROOT/generated" "$ROOT/machine-configs" "$ROOT/archive/$ts/" 2>/dev/null || true
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
                    patchPath: "node-patches/\(node.device.name).yaml"
                )
            }
    }

    private struct NodeRecord {
        var name: String
        var role: DeviceRole
        var ip: String
        var patchPath: String
    }
}

public final class TalosDeploymentExecutor: @unchecked Sendable {
    private let settings: AppSettings
    private let oobBooter: any OOBNodeBooting

    public init(settings: AppSettings = AppSettings(), oobBooter: (any OOBNodeBooting)? = nil) {
        self.settings = settings
        self.oobBooter = oobBooter ?? HammertimeOOBBooter(settings: settings.hammertime)
    }

    public func execute(state: DeploymentState, transport: any DeployerTransport, configuration: DeployerMediaServiceConfiguration) async throws -> (TalosProvisioningExecution, TalosBootstrapResult) {
        let mediaURL = deployerMediaURL(state: state, configuration: configuration)
        let talosInstalls = state.plan.installs.filter { $0.assignment.role == .controlplane || $0.assignment.role == .worker }
        let plannedActions = talosInstalls.map { plannedAction(for: $0, mediaURL: mediaURL, state: state) }

        var executedActions: [String] = []
        var warnings: [String] = []
        let talosISOPath = "\(configuration.mediaRoot)/talos-\(state.spec.talosVersion).iso"
        let startMediaCommand = """
        set -e
        mkdir -p \(shellEscape(configuration.mediaRoot)) \(shellEscape("\(configuration.stateRoot)/logs"))
        if command -v curl >/dev/null 2>&1 && [ ! -f \(shellEscape(talosISOPath)) ]; then
          curl -fL -o \(shellEscape(talosISOPath)) \(shellEscape(state.plan.talosArtifacts.isoURL)) || true
        fi
        if [ -f \(shellEscape("\(configuration.stateRoot)/media-service.env")) ]; then
          . \(shellEscape("\(configuration.stateRoot)/media-service.env"))
          sh -c "$START_COMMAND" || true
        fi
        """
        _ = try await transport.run(startMediaCommand, timeout: 900)
        executedActions.append("Prepared deployer-hosted Talos media at \(talosISOPath).")
        if mediaURL.isEmpty {
            warnings.append("No deployer media address is configured; OOB boot URL actions must use PXE, direct virtual media, or operator local media.")
        }

        for install in talosInstalls {
            let result = try await provisionTalosNode(install, mediaURL: mediaURL, state: state)
            executedActions.append(contentsOf: result.executedActions)
            warnings.append(contentsOf: result.warnings)
        }

        let bootstrapCommand = "cd \(shellEscape(state.plan.durableStateDirectory)) && ./maintenance/tds-run-talos-deploy.sh"
        _ = try await transport.run(bootstrapCommand, timeout: 3600)
        executedActions.append("Ran deployer-owned Talos apply/bootstrap/health script.")

        let firstControlPlane = state.spec.nodes.first { $0.assignment.role == .controlplane }
        let bootstrap = TalosBootstrapResult(
            bootstrapNode: firstControlPlane?.device.name ?? "",
            commands: [
                startMediaCommand,
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

    private func plannedAction(for install: PlannedDeviceInstall, mediaURL: String, state: DeploymentState) -> String {
        switch install.method {
        case .bootURL:
            return "Boot \(install.device.name) from OOB URL media \(firstNonEmpty(mediaURL, externalOOBMediaURL(state: state)))."
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

    private func provisionTalosNode(_ install: PlannedDeviceInstall, mediaURL: String, state: DeploymentState) async throws -> TalosProvisioningExecution {
        switch install.method {
        case .bootURL:
            let imageURL = firstNonEmpty(mediaURL, externalOOBMediaURL(state: state))
            guard !imageURL.isEmpty else {
                return TalosProvisioningExecution(warnings: ["Skipped OOB URL boot for \(install.device.name): no deployer or external media URL was available."])
            }
            let result = try await oobBooter.bootURL(
                OOBBootURLRequest(
                    deviceID: install.device.id,
                    imageURL: imageURL,
                    connectMedia: true,
                    bootOnce: true,
                    reboot: true,
                    proxyVia: settings.hammertime.deployerVia
                )
            )
            let status = result.connected ? "connected" : "requested"
            return TalosProvisioningExecution(executedActions: ["OOB URL boot \(status) for \(install.device.name) using \(imageURL)."])
        case .virtualMedia:
            let result = try await oobBooter.bootURL(
                OOBBootURLRequest(
                    deviceID: install.device.id,
                    imageURL: state.plan.talosArtifacts.isoURL,
                    connectMedia: true,
                    bootOnce: true,
                    reboot: true,
                    proxyVia: settings.hammertime.deployerVia
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

    private func deployerMediaURL(state: DeploymentState, configuration: DeployerMediaServiceConfiguration) -> String {
        let host = firstNonEmpty(configurationHost(from: state), state.plan.deployer.device.privateIP, state.plan.deployer.device.primaryIP)
        guard !host.isEmpty else { return "" }
        return "http://\(host):\(configuration.httpPort)/talos-\(state.spec.talosVersion).iso"
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
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
