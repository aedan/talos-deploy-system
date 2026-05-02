import Combine
import Foundation

public protocol AccessProfileManager: Sendable {
    func defaultProfile(from settings: AppSettings) -> AccessProfile
}

public struct DefaultAccessProfileManager: AccessProfileManager {
    public init() {}

    public func defaultProfile(from settings: AppSettings) -> AccessProfile {
        settings.accessProfiles.first(where: \.isDefault) ?? settings.accessProfiles.first ?? .directDefault
    }
}

public struct RedfishProbeResult: Codable, Equatable, Sendable {
    public var systemPath: String
    public var managerPath: String
    public var virtualMediaPath: String
    public var supportsVirtualMedia: Bool
    public var supportsBootURL: Bool

    public init(
        systemPath: String = "",
        managerPath: String = "",
        virtualMediaPath: String = "",
        supportsVirtualMedia: Bool = false,
        supportsBootURL: Bool = false
    ) {
        self.systemPath = systemPath
        self.managerPath = managerPath
        self.virtualMediaPath = virtualMediaPath
        self.supportsVirtualMedia = supportsVirtualMedia
        self.supportsBootURL = supportsBootURL
    }
}

public protocol RedfishClient: Sendable {
    func probe(device: DiscoveredDevice, accessProfile: AccessProfile?) async throws -> RedfishProbeResult
}

public final class DefaultRedfishClient: RedfishClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func probe(device: DiscoveredDevice, accessProfile: AccessProfile?) async throws -> RedfishProbeResult {
        guard let endpoint = device.oob, !endpoint.address.isEmpty else {
            return RedfishProbeResult()
        }
        let url = URL(string: "https://\(endpoint.address)/redfish/v1")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return RedfishProbeResult()
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let systemsPath = ((object?["Systems"] as? [String: Any])?["@odata.id"] as? String) ?? ""
        let managersPath = ((object?["Managers"] as? [String: Any])?["@odata.id"] as? String) ?? ""
        return RedfishProbeResult(
            systemPath: systemsPath,
            managerPath: managersPath,
            virtualMediaPath: managersPath.isEmpty ? "" : managersPath + "/1/VirtualMedia",
            supportsVirtualMedia: !managersPath.isEmpty,
            supportsBootURL: !systemsPath.isEmpty
        )
    }
}

public protocol HelperHostClient: Sendable {
    func validate(connection: SSHConnection) async throws
    func prepareMediaServices(configuration: HelperMediaServiceConfiguration, connection: SSHConnection) async throws -> HelperMediaServicePlan
    func syncState(localDirectory: URL, remoteStateRoot: String, connection: SSHConnection) async throws
}

public final class DefaultHelperHostClient: HelperHostClient, @unchecked Sendable {
    private let router: SSHCommandRouter

    public init(router: SSHCommandRouter = SSHCommandRouter()) {
        self.router = router
    }

    public func validate(connection: SSHConnection) async throws {
        try await router.validateAccess(connection)
    }

    public func prepareMediaServices(configuration: HelperMediaServiceConfiguration, connection: SSHConnection) async throws -> HelperMediaServicePlan {
        let mediaRoot = configuration.mediaRoot
        let pxeRoot = configuration.pxeRoot
        let binRoot = "\(configuration.stateRoot)/bin"
        let logRoot = "\(configuration.stateRoot)/logs"
        let runRoot = "\(configuration.stateRoot)/run"
        let scriptPath = "\(binRoot)/tds-range-http-server.py"
        let logPath = "\(logRoot)/media-http.log"
        let pidPath = "\(runRoot)/media-http.pid"
        let startCommand = "nohup python3 \(shellEscape(scriptPath)) --bind \(shellEscape(configuration.httpBindAddress)) --port \(configuration.httpPort) --directory \(shellEscape(mediaRoot)) > \(shellEscape(logPath)) 2>&1 & echo $! > \(shellEscape(pidPath))"

        let remoteCommand = """
        set -e
        mkdir -p \(shellEscape(mediaRoot)) \(shellEscape(pxeRoot)) \(shellEscape(binRoot)) \(shellEscape(logRoot)) \(shellEscape(runRoot))
        cat > \(shellEscape(scriptPath)) <<'PY'
        #!/usr/bin/env python3
        import argparse
        import os
        import posixpath
        import re
        from http.server import SimpleHTTPRequestHandler, HTTPServer
        from socketserver import ThreadingMixIn
        from urllib.parse import unquote

        class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
            daemon_threads = True

        class RangeRequestHandler(SimpleHTTPRequestHandler):
            directory = os.getcwd()

            def translate_path(self, path):
                path = path.split('?', 1)[0].split('#', 1)[0]
                path = posixpath.normpath(unquote(path))
                words = [w for w in path.split('/') if w]
                target = type(self).directory
                for word in words:
                    drive, word = os.path.splitdrive(word)
                    head, word = os.path.split(word)
                    if word in (os.curdir, os.pardir):
                        continue
                    target = os.path.join(target, word)
                return target

            def send_head(self):
                path = self.translate_path(self.path)
                if os.path.isdir(path):
                    return super().send_head()
                try:
                    file_obj = open(path, 'rb')
                except OSError:
                    self.send_error(404, 'File not found')
                    return None
                size = os.fstat(file_obj.fileno()).st_size
                range_header = self.headers.get('Range')
                if not range_header:
                    self.send_response(200)
                    self.send_header('Content-type', 'application/octet-stream')
                    self.send_header('Content-Length', str(size))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.end_headers()
                    return file_obj
                match = re.match(r'bytes=(\\d+)-(\\d*)$', range_header)
                if not match:
                    self.send_error(416, 'Invalid range')
                    file_obj.close()
                    return None
                start = int(match.group(1))
                end = int(match.group(2)) if match.group(2) else size - 1
                if start >= size:
                    self.send_error(416, 'Requested range not satisfiable')
                    file_obj.close()
                    return None
                end = min(end, size - 1)
                self.range = (start, end)
                file_obj.seek(start)
                self.send_response(206)
                self.send_header('Content-type', 'application/octet-stream')
                self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
                self.send_header('Content-Length', str(end - start + 1))
                self.send_header('Accept-Ranges', 'bytes')
                self.end_headers()
                return file_obj

            def copyfile(self, source, outputfile):
                if hasattr(self, 'range'):
                    start, end = self.range
                    remaining = end - start + 1
                    while remaining > 0:
                        chunk = source.read(min(1024 * 1024, remaining))
                        if not chunk:
                            break
                        try:
                            outputfile.write(chunk)
                        except BrokenPipeError:
                            break
                        remaining -= len(chunk)
                    del self.range
                    return
                return super().copyfile(source, outputfile)

        def main():
            parser = argparse.ArgumentParser()
            parser.add_argument('--bind', default='0.0.0.0')
            parser.add_argument('--port', type=int, default=8080)
            parser.add_argument('--directory', required=True)
            args = parser.parse_args()
            RangeRequestHandler.directory = args.directory
            ThreadingHTTPServer((args.bind, args.port), RangeRequestHandler).serve_forever()

        if __name__ == '__main__':
            main()
        PY
        chmod 0755 \(shellEscape(scriptPath))
        cat > \(shellEscape("\(configuration.stateRoot)/media-service.env")) <<'EOF'
        MEDIA_ROOT=\(mediaRoot)
        PXE_ROOT=\(pxeRoot)
        HTTP_BIND=\(configuration.httpBindAddress)
        HTTP_PORT=\(configuration.httpPort)
        START_COMMAND=\(startCommand)
        EOF
        """
        _ = try await router.run(connection: connection, remoteCommand: remoteCommand)

        return HelperMediaServicePlan(
            mediaRoot: mediaRoot,
            pxeRoot: pxeRoot,
            httpBindAddress: configuration.httpBindAddress,
            httpPort: configuration.httpPort,
            serviceCommand: startCommand,
            notes: [
                "tds prepared the media/PXE directories and range-capable HTTP helper script on the selected existing deployer/overseer.",
                "Start the service after media is staged, or let a deployment runner start it when executing the install.",
            ]
        )
    }

    public func syncState(localDirectory: URL, remoteStateRoot: String, connection: SSHConnection) async throws {
        try await router.ensureDirectory(remoteStateRoot, connection: connection)
        try await router.sync(localPath: localDirectory, remotePath: remoteStateRoot, connection: connection, delete: false)
    }
}

public protocol TalosBuilder: Sendable {
    func buildArtifacts(for spec: DeploymentSpec, plan: DeploymentPlan, in directory: URL) async throws -> URL
}

public struct TalosFactoryClient: Sendable {
    public init() {}

    public func renderSchematic(settings: TalosImageFactorySettings) -> String {
        var lines = ["customization:"]
        if !settings.extraKernelArgs.isEmpty {
            lines.append("  extraKernelArgs:")
            lines.append(contentsOf: settings.extraKernelArgs.map { "    - \(yamlScalar($0))" })
        }
        if !settings.selectedSystemExtensions.isEmpty {
            lines.append("  systemExtensions:")
            lines.append("    officialExtensions:")
            lines.append(contentsOf: settings.selectedSystemExtensions.map { "      - \(yamlScalar($0))" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func artifactURLs(settings: TalosImageFactorySettings, talosVersion: String) -> TalosFactoryArtifacts {
        let baseURL = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pxeBaseURL = settings.pxeBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model = "\(settings.platform)-\(settings.architecture)"
        return TalosFactoryArtifacts(
            schematicID: settings.schematicID,
            schematicYAML: renderSchematic(settings: settings),
            isoURL: "\(baseURL)/image/\(settings.schematicID)/\(talosVersion)/\(model).iso",
            pxeURL: "\(pxeBaseURL)/pxe/\(settings.schematicID)/\(talosVersion)/\(model)",
            installerImage: "\(settings.registryHost)/installer/\(settings.schematicID):\(talosVersion)"
        )
    }
}

public final class DefaultTalosBuilder: TalosBuilder, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func buildArtifacts(for spec: DeploymentSpec, plan: DeploymentPlan, in directory: URL) async throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appending(path: "deployment-manifest.json")
        let manifestData = try JSONEncoder.pretty.encode(plan)
        try manifestData.write(to: manifestURL, options: .atomic)

        let nodesDirectory = directory.appending(path: "node-patches", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
        for node in spec.nodes where node.assignment.role != .unassigned {
            let yaml = renderNodePatch(node: node, spec: spec)
            try yaml.write(
                to: nodesDirectory.appending(path: "\(node.device.name).yaml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let clusterURL = directory.appending(path: "cluster.yaml")
        try renderClusterFile(spec: spec).write(to: clusterURL, atomically: true, encoding: .utf8)

        let factoryURL = directory.appending(path: "talos-factory-schematic.yaml")
        try plan.talosArtifacts.schematicYAML.write(to: factoryURL, atomically: true, encoding: .utf8)

        let artifactsURL = directory.appending(path: "talos-artifacts.json")
        let artifactsData = try JSONEncoder.pretty.encode(plan.talosArtifacts)
        try artifactsData.write(to: artifactsURL, options: .atomic)
        return directory
    }

    private func renderNodePatch(node: DeploymentNodeSpec, spec: DeploymentSpec) -> String {
        let addresses = node.device.networkInterfaces.first?.addresses ?? (node.device.primaryIP.isEmpty ? [] : [node.device.primaryIP])
        let renderedAddresses = addresses.map { "      - \($0)" }.joined(separator: "\n")
        let interfaceName = node.device.networkInterfaces.first?.name ?? "eth0"
        let moduleBlock = renderKernelModules(spec.talosKernelModules)
        let extraKernelArgsBlock = renderExtraKernelArgs(spec.talosFactory.extraKernelArgs)
        let installerImage = TalosFactoryClient().artifactURLs(settings: spec.talosFactory, talosVersion: spec.talosVersion).installerImage
        return """
        machine:
          type: \(node.assignment.role == .worker ? "worker" : "controlplane")
        \(moduleBlock)
          network:
            hostname: \(node.device.name)
            interfaces:
              - interface: \(interfaceName)
        \(renderedAddresses.isEmpty ? "" : "    addresses:\n\(renderedAddresses)\n")
          install:
            disk: \(node.device.installDisk.isEmpty ? "/dev/sda" : node.device.installDisk)
            image: \(installerImage)
        \(extraKernelArgsBlock)
        """
    }

    private func renderKernelModules(_ modules: [TalosKernelModule]) -> String {
        guard !modules.isEmpty else { return "" }
        var lines = ["  kernel:", "    modules:"]
        for module in modules {
            lines.append("      - name: \(module.name)")
            if !module.parameters.isEmpty {
                lines.append("        parameters:")
                lines.append(contentsOf: module.parameters.map { "          - \(yamlScalar($0))" })
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderExtraKernelArgs(_ args: [String]) -> String {
        guard !args.isEmpty else { return "" }
        return "    extraKernelArgs:\n" + args.map { "      - \(yamlScalar($0))" }.joined(separator: "\n")
    }

    private func renderClusterFile(spec: DeploymentSpec) -> String {
        """
        cluster:
          name: \(spec.clusterName)
          endpoint: \(spec.clusterEndpoint)
          talosVersion: \(spec.talosVersion)
          kubernetesVersion: \(spec.kubernetesVersion)
        """
    }
}

private func yamlScalar(_ value: String) -> String {
    let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@+"))
    if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
        return value
    }
    return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

public protocol Provisioner: Sendable {
    func prepare(plan: DeploymentPlan) async throws
}

public struct NoOpProvisioner: Provisioner {
    public init() {}
    public func prepare(plan: DeploymentPlan) async throws {}
}

public enum DeploymentPlannerError: Error, LocalizedError {
    case missingHelper
    case multipleHelpers
    case invalidControlPlaneCount
    case missingHelperConfirmation(String)
    case existingMediaHostNotExplicitlyAllowed
    case pxeCannotBootstrapFirstOverseer
    case missingOOBReachableMediaURL

    public var errorDescription: String? {
        switch self {
        case .missingHelper:
            return "Exactly one deployer/overseer must be selected."
        case .multipleHelpers:
            return "Only one deployer/overseer may be selected."
        case .invalidControlPlaneCount:
            return "The control plane count must be either 1 or 3."
        case .missingHelperConfirmation(let name):
            return "Typed confirmation is required before reinstalling deployer/overseer \(name)."
        case .existingMediaHostNotExplicitlyAllowed:
            return "Existing OS media host delivery is disabled. Use operator local media for greenfield installs, or explicitly allow an existing media host in Settings."
        case .pxeCannotBootstrapFirstOverseer:
            return "PXE cannot bootstrap the first deployer/overseer unless an external PXE service already exists."
        case .missingOOBReachableMediaURL:
            return "OOB-reachable URL media delivery requires an external media base URL in Settings."
        }
    }
}

public struct DeploymentPlanner: Sendable {
    private let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public func makePlan(spec: DeploymentSpec) throws -> DeploymentPlan {
        let helpers = spec.nodes.filter { $0.assignment.role == .helper }
        guard !helpers.isEmpty else { throw DeploymentPlannerError.missingHelper }
        guard helpers.count == 1 else { throw DeploymentPlannerError.multipleHelpers }
        let controlPlanes = spec.nodes.filter { $0.assignment.role == .controlplane }
        guard controlPlanes.count == 1 || controlPlanes.count == 3 else {
            throw DeploymentPlannerError.invalidControlPlaneCount
        }

        let helperNode = helpers[0]
        if helperNode.assignment.shouldInstallOS && settings.safety.requireTypedConfirmationForHelperReinstall {
            let expected = "\(settings.safety.destructiveConfirmationTextPrefix) \(helperNode.device.name)"
            guard helperNode.assignment.typedConfirmation == expected else {
                throw DeploymentPlannerError.missingHelperConfirmation(helperNode.device.name)
            }
        }
        try validateBootstrapMediaDelivery(for: helperNode)

        let planned = spec.nodes
            .filter { $0.assignment.role != .unassigned }
            .map { node in
                PlannedDeviceInstall(
                    device: node.device,
                    assignment: node.assignment,
                    method: selectInstallMethod(for: node, spec: spec)
                )
            }

        guard let helper = planned.first(where: { $0.assignment.role == .helper }) else {
            throw DeploymentPlannerError.missingHelper
        }

        let remotePath = "\(spec.helperStateRoot)/\(spec.accountNumber)/\(spec.clusterName)"
        let tempPath = "rax-temp/\(spec.accountNumber)/\(spec.clusterName)"
        let talosArtifacts = TalosFactoryClient().artifactURLs(settings: spec.talosFactory, talosVersion: spec.talosVersion)
        var phases: [DeploymentPhase] = []

        phases.append(
            DeploymentPhase(
                title: "Prepare Talos Artifacts",
                steps: [
                    "Render Image Factory schematic for \(spec.talosFactory.selectedSystemExtensions.isEmpty ? "vanilla Talos" : spec.talosFactory.selectedSystemExtensions.joined(separator: ", ")).",
                    "Use ISO \(talosArtifacts.isoURL).",
                    "Use PXE endpoint \(talosArtifacts.pxeURL).",
                    "Set machine install image to \(talosArtifacts.installerImage).",
                ]
            )
        )

        if helper.assignment.shouldInstallOS && helper.assignment.helperMode == .bootstrap {
            phases.append(
                DeploymentPhase(
                    title: "Bootstrap Deployer/Overseer",
                    steps: bootstrapOverseerSteps(helper: helper, tempPath: tempPath, remotePath: remotePath)
                )
            )
        } else {
            phases.append(
                DeploymentPhase(
                    title: "Prepare Existing Deployer/Overseer",
                    steps: [
                        "Validate SSH access to deployer/overseer \(helper.device.name).",
                        "Create durable state root at \(remotePath).",
                        "tds prepares media and PXE directories plus a range-capable HTTP media service on the selected existing device.",
                        "Stage generated Talos/Ubuntu media through tds before booting any dependent nodes.",
                    ]
                )
            )
        }

        let remainingInstalls = planned.filter { $0.device.id != helper.device.id && $0.assignment.shouldInstallOS }
        phases.append(
            DeploymentPhase(
                title: "Provision Cluster",
                steps: remainingInstalls.map {
                    provisioningStep(for: $0, talosArtifacts: talosArtifacts)
                } + [
                    "Generate machine configs with preserved/manual network settings and selected kernel modules.",
                    "Run talosctl from the deployer/overseer to apply configs, bootstrap etcd, fetch kubeconfig, and verify cluster health.",
                    "Persist generated state under \(remotePath).",
                ]
            )
        )

        return DeploymentPlan(
            accountNumber: spec.accountNumber,
            clusterName: spec.clusterName,
            helper: helper,
            installs: planned,
            phases: phases,
            talosArtifacts: talosArtifacts,
            tempStateDirectory: tempPath,
            durableStateDirectory: remotePath
        )
    }

    private func selectInstallMethod(for node: DeploymentNodeSpec, spec: DeploymentSpec) -> InstallMethod {
        if node.assignment.role == .helper && node.assignment.helperMode == .bootstrap && node.assignment.shouldInstallOS {
            switch settings.bootstrapMedia.deliveryMode {
            case .operatorLocalMedia:
                return .operatorLocalMedia
            case .oobReachableURL, .existingOSMediaHost:
                return .bootURL
            case .pxeAfterOverseerOnline:
                return .pxe
            }
        }

        switch node.assignment.preferredInstall {
        case .virtualMedia:
            return .virtualMedia
        case .pxe:
            return .pxe
        case .automatic:
            if node.assignment.role == .helper && node.assignment.shouldInstallOS {
                return .virtualMedia
            }
            if node.assignment.role != .helper {
                return selectAutomaticTalosMethod(for: node, spec: spec)
            }
            if let oob = node.device.oob, oob.supportsVirtualMedia == true {
                return .virtualMedia
            }
            return .pxe
        }
    }

    private func selectAutomaticTalosMethod(for node: DeploymentNodeSpec, spec: DeploymentSpec) -> InstallMethod {
        for strategy in spec.talosProvisioning.preferredStrategies {
            switch strategy {
            case .automatic:
                continue
            case .overseerHostedMedia:
                if spec.talosProvisioning.allowOverseerHostedMedia {
                    return .bootURL
                }
            case .overseerPXE:
                if spec.talosProvisioning.allowOverseerPXE {
                    return .pxe
                }
            case .directVirtualMedia:
                if node.device.oob != nil {
                    return .virtualMedia
                }
            case .operatorLocalMedia:
                return .operatorLocalMedia
            case .externalOOBURL:
                if spec.talosProvisioning.allowExternalOOBURL,
                   !spec.talosProvisioning.externalOOBMediaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .bootURL
                }
            }
        }
        return node.device.oob == nil ? .pxe : .virtualMedia
    }

    private func provisioningStep(for install: PlannedDeviceInstall, talosArtifacts: TalosFactoryArtifacts) -> String {
        switch install.method {
        case .operatorLocalMedia:
            return "Provision \(install.device.name) as \(install.assignment.role.rawValue) using operator-attached local media through tds OOB WebView."
        case .virtualMedia:
            return "Provision \(install.device.name) as \(install.assignment.role.rawValue) using direct OOB virtual media with \(talosArtifacts.isoURL)."
        case .bootURL:
            return "Provision \(install.device.name) as \(install.assignment.role.rawValue) using OOB boot URL media; prefer overseer-hosted ISO, otherwise configured external OOB URL."
        case .pxe:
            return "Provision \(install.device.name) as \(install.assignment.role.rawValue) using overseer PXE/DHCP/TFTP/HTTP services."
        case .stagedOnly:
            return "Stage config for \(install.device.name) as \(install.assignment.role.rawValue) without booting it."
        }
    }

    private func validateBootstrapMediaDelivery(for helperNode: DeploymentNodeSpec) throws {
        guard helperNode.assignment.role == .helper,
              helperNode.assignment.helperMode == .bootstrap,
              helperNode.assignment.shouldInstallOS
        else { return }

        switch settings.bootstrapMedia.deliveryMode {
        case .operatorLocalMedia:
            return
        case .oobReachableURL:
            guard !settings.bootstrapMedia.externalMediaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeploymentPlannerError.missingOOBReachableMediaURL
            }
        case .existingOSMediaHost:
            guard settings.bootstrapMedia.allowExistingOSMediaHost else {
                throw DeploymentPlannerError.existingMediaHostNotExplicitlyAllowed
            }
        case .pxeAfterOverseerOnline:
            throw DeploymentPlannerError.pxeCannotBootstrapFirstOverseer
        }
    }

    private func bootstrapOverseerSteps(helper: PlannedDeviceInstall, tempPath: String, remotePath: String) -> [String] {
        let commonTail = [
            "Install \(helper.device.name) first and wait for SSH reachability.",
            "Move durable deployment state from rax to \(remotePath).",
            "Only after the deployer/overseer is online may PXE-dependent control-plane and worker nodes proceed.",
        ]

        switch settings.bootstrapMedia.deliveryMode {
        case .operatorLocalMedia:
            return [
                "Persist temporary deployment state on rax at \(tempPath).",
                "Open the configured OOB access profile in the embedded tds WebView.",
                "Attach the selected Ubuntu or Talos ISO as operator local media; do not depend on another target node having an OS.",
            ] + commonTail
        case .oobReachableURL:
            return [
                "Persist temporary deployment state on rax at \(tempPath).",
                "Attach media from the configured OOB-reachable URL \(settings.bootstrapMedia.externalMediaBaseURL).",
                "This requires infrastructure outside the selected bare-metal nodes to serve the ISO on the OOB network.",
            ] + commonTail
        case .existingOSMediaHost:
            return [
                "Persist temporary deployment state on rax at \(tempPath).",
                "Use the explicitly allowed existing OS media host \(settings.bootstrapMedia.mediaHostDeviceID) to serve installation media.",
                "This is not greenfield-safe; every run must document which existing host is being used.",
            ] + commonTail
        case .pxeAfterOverseerOnline:
            return [
                "PXE is deferred until after the deployer/overseer is installed.",
            ] + commonTail
        }
    }
}

public final class DeploymentCoordinator: @unchecked Sendable {
    private let settings: AppSettings
    private let builder: TalosBuilder
    private let helperHostClient: HelperHostClient
    private let stateStore: DeploymentStateStore
    private let fileManager: FileManager

    public init(
        settings: AppSettings,
        builder: TalosBuilder = DefaultTalosBuilder(),
        helperHostClient: HelperHostClient = DefaultHelperHostClient(),
        stateStore: DeploymentStateStore = DeploymentStateStore(),
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.builder = builder
        self.helperHostClient = helperHostClient
        self.stateStore = stateStore
        self.fileManager = fileManager
    }

    public func stage(spec: DeploymentSpec, at baseDirectory: URL) async throws -> DeploymentState {
        let planner = DeploymentPlanner(settings: settings)
        let plan = try planner.makePlan(spec: spec)
        let localStateDirectory = baseDirectory.appending(path: spec.accountNumber).appending(path: spec.clusterName)
        try fileManager.createDirectory(at: localStateDirectory, withIntermediateDirectories: true)
        _ = try await builder.buildArtifacts(for: spec, plan: plan, in: localStateDirectory)
        let state = DeploymentState(
            spec: spec,
            plan: plan,
            events: [DeploymentEvent(message: "Deployment staged locally.")],
            localStateDirectory: localStateDirectory.path,
            helperSynchronized: false
        )
        _ = try stateStore.save(state, to: localStateDirectory)
        return state
    }

    public func synchronizeToHelper(_ state: DeploymentState, connection: SSHConnection) async throws -> DeploymentState {
        let localDirectory = URL(fileURLWithPath: state.localStateDirectory, isDirectory: true)
        try await helperHostClient.validate(connection: connection)
        let mediaPlan = try await helperHostClient.prepareMediaServices(
            configuration: HelperMediaServiceConfiguration(defaults: settings.helper),
            connection: connection
        )
        try await helperHostClient.syncState(
            localDirectory: localDirectory,
            remoteStateRoot: state.plan.durableStateDirectory,
            connection: connection
        )
        var updated = state
        updated.helperSynchronized = true
        updated.events.append(DeploymentEvent(message: "Prepared existing deployer/overseer media services on \(connection.host) at \(mediaPlan.mediaRoot)."))
        updated.events.append(DeploymentEvent(message: "Deployment state synchronized to deployer/overseer \(connection.host)."))
        _ = try stateStore.save(updated, to: localDirectory)
        return updated
    }
}

@MainActor
public final class AppController: ObservableObject {
    @Published public var settings: AppSettings
    @Published public var session: CoreSession?
    @Published public var accountNumber: String
    @Published public var devices: [DiscoveredDevice]
    @Published public var assignments: [String: DeviceAssignment]
    @Published public var liveFactsErrors: [String: String]
    @Published public var lastPlan: DeploymentPlan?
    @Published public var lastState: DeploymentState?
    @Published public var ubuntuCapturePath: String
    @Published public var ubuntuSourceISOPath: String
    @Published public var ubuntuOutputISOPath: String
    @Published public var ubuntuWorkDirectoryPath: String
    @Published public var ubuntuRackPasswordHash: String
    @Published public var ubuntuRootPasswordHash: String
    @Published public var ubuntuSSHKeyFiles: String
    @Published public var ubuntuOOBURL: String
    @Published public var ubuntuOOBUsername: String
    @Published public var ubuntuLastArtifacts: UbuntuAutoinstallArtifacts?
    @Published public var ubuntuLastValidation: UbuntuIsoValidationResult?
    @Published public var ubuntuNetworkPlan: NetworkRebuildPlan?
    @Published public var ubuntuLocalMediaState: LocalMediaSessionState?
    @Published public var accessProfileProxyPasswords: [UUID: String]
    @Published public var statusMessage: String

    private let settingsController: SettingsController
    private let authProvider: AuthProvider
    private let coreClient: CoreClient
    private let environmentSessionProvider: EnvironmentCoreSessionProviding?
    private let hammertime: HammertimeAdapter
    private let secretStore: KeychainSecretStore
    private let paths: AppPaths
    private var hasBootstrappedSession = false

    public init(
        settingsController: SettingsController = SettingsController(),
        authProvider: AuthProvider = KeychainAuthProvider(),
        secretStore: KeychainSecretStore = KeychainSecretStore(),
        coreClient: CoreClient? = nil,
        hammertime: HammertimeAdapter? = nil,
        paths: AppPaths = AppPaths()
    ) {
        self.settingsController = settingsController
        self.paths = paths
        self.secretStore = secretStore
        let loadedSettings = (try? settingsController.load()) ?? AppSettings()
        self.settings = loadedSettings
        self.authProvider = authProvider
        self.coreClient = coreClient ?? ConfiguredCoreClient(
            coreSettings: loadedSettings.core,
            hammertimeSettings: loadedSettings.hammertime
        )
        self.environmentSessionProvider = self.coreClient as? EnvironmentCoreSessionProviding
        self.hammertime = hammertime ?? DefaultHammertimeAdapter(settings: loadedSettings.hammertime)
        self.session = try? authProvider.currentSession()
        self.accountNumber = loadedSettings.core.defaultAccountNumber
        self.devices = []
        self.assignments = [:]
        self.liveFactsErrors = [:]
        self.ubuntuCapturePath = ""
        self.ubuntuSourceISOPath = ""
        self.ubuntuOutputISOPath = ""
        self.ubuntuWorkDirectoryPath = ""
        self.ubuntuRackPasswordHash = ""
        self.ubuntuRootPasswordHash = ""
        self.ubuntuSSHKeyFiles = ""
        self.ubuntuOOBURL = ""
        self.ubuntuOOBUsername = ""
        self.accessProfileProxyPasswords = Self.loadProxyPasswords(for: loadedSettings.accessProfiles, secretStore: secretStore)
        self.statusMessage = "Ready"
    }

    public func saveSettings() {
        do {
            try saveAccessProfileProxyPasswords()
            try settingsController.save(settings)
            statusMessage = "Settings saved."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func addAccessProfile(kind: AccessProfileKind = .httpProxy, scope: AccessScope = .oob) {
        let shouldBecomeDefault = settings.accessProfiles.allSatisfy { !$0.isDefault || $0.kind == .direct }
        settings.accessProfiles.append(
            AccessProfile(
                name: kind == .socksProxy ? "OOB SOCKS Proxy" : "OOB HTTP Proxy",
                kind: kind,
                scope: scope,
                isDefault: shouldBecomeDefault
            )
        )
        statusMessage = "Added \(kind.rawValue) access profile."
    }

    public func setAccessProfileDefault(id: UUID, isDefault: Bool) {
        for index in settings.accessProfiles.indices {
            settings.accessProfiles[index].isDefault = settings.accessProfiles[index].id == id ? isDefault : false
        }
    }

    public func proxyPassword(for profile: AccessProfile?) -> String {
        guard let profile else { return "" }
        return accessProfileProxyPasswords[profile.id] ?? ""
    }

    private static func loadProxyPasswords(for profiles: [AccessProfile], secretStore: KeychainSecretStore) -> [UUID: String] {
        var passwords: [UUID: String] = [:]
        for profile in profiles where !profile.proxyCredentialReference.isEmpty {
            if let password = try? secretStore.getSecret(for: profile.proxyCredentialReference) {
                passwords[profile.id] = password
            }
        }
        return passwords
    }

    private func saveAccessProfileProxyPasswords() throws {
        for profile in settings.accessProfiles where !profile.proxyCredentialReference.isEmpty {
            let password = accessProfileProxyPasswords[profile.id] ?? ""
            if password.isEmpty {
                try? secretStore.deleteSecret(for: profile.proxyCredentialReference)
            } else {
                try secretStore.setSecret(password, for: profile.proxyCredentialReference)
            }
        }
    }

    public func importSession(username: String, headerName: String, secret: String) {
        let secretReference = "core-session-\(UUID().uuidString)"
        let session = CoreSession(username: username, headerName: headerName, secretReference: secretReference)
        do {
            try authProvider.storeSession(session, secret: secret)
            self.session = session
            statusMessage = "Core session stored."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func clearSession() {
        do {
            try authProvider.clearSession()
            session = nil
            statusMessage = "Stored Core session cleared. Refresh to detect the active hammertime-backed session on rax."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func bootstrapSessionStatusIfNeeded() async {
        guard !hasBootstrappedSession else { return }
        hasBootstrappedSession = true
        await refreshSessionStatus()
    }

    public func refreshSessionStatus() async {
        do {
            if let storedSession = try authProvider.currentSession() {
                session = storedSession
                statusMessage = "Loaded stored Core session for \(storedSession.username)."
                return
            }
            if let detectedSession = try await environmentSessionProvider?.discoverEnvironmentSession(includeSecret: false) {
                session = detectedSession.session
                statusMessage = "Detected active Core session for \(detectedSession.session.username) from hammertime cache."
                return
            }
            session = nil
            statusMessage = "No Core session is currently available."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func importDetectedSession() async {
        do {
            guard let detectedSession = try await environmentSessionProvider?.discoverEnvironmentSession(includeSecret: true),
                  let secret = detectedSession.secret,
                  !secret.isEmpty
            else {
                statusMessage = "No importable hammertime-backed Core session was detected."
                return
            }

            var session = detectedSession.session
            session.secretReference = "core-session-\(UUID().uuidString)"
            try authProvider.storeSession(session, secret: secret)
            self.session = session
            statusMessage = "Imported the active hammertime-backed Core session into the local store."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func refreshInventory() async {
        let resolvedAccountNumber = accountNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedAccountNumber.isEmpty else {
            statusMessage = "Enter an account number before loading devices."
            return
        }
        do {
            let source = settings.core.inventorySource
            let loadedDevices: [DiscoveredDevice]
            switch source {
            case .core:
                loadedDevices = try await coreClient.fetchDevices(accountNumber: resolvedAccountNumber)
            case .hammertime:
                loadedDevices = try await hammertime.inventory(accountNumber: resolvedAccountNumber)
            case .auto:
                do {
                    loadedDevices = try await coreClient.fetchDevices(accountNumber: resolvedAccountNumber)
                } catch {
                    loadedDevices = try await hammertime.inventory(accountNumber: resolvedAccountNumber)
                }
            }
            devices = loadedDevices
            for device in loadedDevices where assignments[device.id] == nil {
                assignments[device.id] = defaultAssignment(for: device.id)
            }
            for device in loadedDevices where !device.isClusterEligible {
                var assignment = assignments[device.id] ?? defaultAssignment(for: device.id)
                assignment.role = .unassigned
                assignment.shouldInstallOS = false
                assignments[device.id] = assignment
            }
            statusMessage = "Loaded \(loadedDevices.count) devices for account \(resolvedAccountNumber), \(clusterEligibleDevices.count) eligible for cluster roles."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func refreshLiveFacts(for selectedIDs: [String]? = nil) async {
        let sourceDevices = selectedIDs == nil ? clusterEligibleDevices : devices
        let targetDevices = sourceDevices.filter { selectedIDs == nil || selectedIDs?.contains($0.id) == true }
        let results = await hammertime.refreshLiveFacts(devices: targetDevices, groups: settings.hammertime.defaultFactGroups)
        liveFactsErrors.removeAll()
        devices = devices.map { device in
            guard let result = results[device.id] else { return device }
            switch result {
            case .success(let snapshot):
                var updated = device
                updated.liveFacts = snapshot
                return updated
            case .failure(let error):
                liveFactsErrors[device.id] = error.localizedDescription
                return device
            }
        }
        statusMessage = "Live facts refreshed for \(targetDevices.count) devices."
    }

    public func binding(for device: DiscoveredDevice) -> DeviceAssignment {
        assignments[device.id] ?? defaultAssignment(for: device.id)
    }

    public var clusterEligibleDevices: [DiscoveredDevice] {
        devices.filter(\.isClusterEligible)
    }

    public var filteredDevices: [DiscoveredDevice] {
        devices.filter { !$0.isClusterEligible }
    }

    public func updateAssignment(_ assignment: DeviceAssignment) {
        assignments[assignment.deviceID] = assignment
    }

    private func defaultAssignment(for deviceID: String) -> DeviceAssignment {
        DeviceAssignment(
            deviceID: deviceID,
            preferredInstall: settings.talos.installerPreference
        )
    }

    public func typedConfirmationText(for device: DiscoveredDevice) -> String {
        "\(settings.safety.destructiveConfirmationTextPrefix) \(device.name)"
    }

    public func stageDeployment() async {
        let spec = DeploymentSpec(
            accountNumber: accountNumber,
            clusterName: settings.talos.clusterName,
            clusterEndpoint: settings.talos.clusterEndpoint,
            talosVersion: settings.talos.talosVersion,
            kubernetesVersion: settings.talos.kubernetesVersion,
            helperStateRoot: settings.helper.stateRoot,
            talosFactory: settings.talos.factory,
            talosProvisioning: settings.talos.provisioning,
            talosKernelModules: settings.talos.kernelModules,
            nodes: clusterEligibleDevices.compactMap { device in
                guard let assignment = assignments[device.id], assignment.role != .unassigned else {
                    return nil
                }
                return DeploymentNodeSpec(device: device, assignment: assignment)
            }
        )
        let coordinator = DeploymentCoordinator(settings: settings)
        do {
            try? paths.ensureExists()
            let state = try await coordinator.stage(spec: spec, at: paths.stateDirectory)
            lastState = state
            lastPlan = state.plan
            statusMessage = "Deployment staged at \(state.localStateDirectory)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func refreshUbuntuNetworkPlan() {
        do {
            let spec = try ubuntuInstallSpec()
            let plan = try UbuntuAutoinstallBuilder().makeNetworkPlan(fromCapturePath: spec.capturePath)
            ubuntuNetworkPlan = plan
            statusMessage = "Parsed Ubuntu network preservation plan from \(spec.capturePath)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func buildUbuntuISO() async {
        do {
            let spec = try ubuntuInstallSpec()
            let builder = UbuntuAutoinstallBuilder()
            let plan = try builder.makeNetworkPlan(fromCapturePath: spec.capturePath)
            ubuntuNetworkPlan = plan
            let artifacts = try await builder.buildISO(spec: spec, networkPlan: plan)
            ubuntuLastArtifacts = artifacts
            ubuntuLastValidation = artifacts.validation
            statusMessage = "Ubuntu autoinstall ISO built at \(artifacts.outputISOPath)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func validateUbuntuISO() async {
        let isoPath = firstNonEmptyForController(
            ubuntuOutputISOPath,
            ubuntuLastArtifacts?.outputISOPath ?? ""
        )
        guard !isoPath.isEmpty else {
            statusMessage = "Choose or build an Ubuntu ISO before validating."
            return
        }
        do {
            let validation = try await UbuntuAutoinstallBuilder().validateISO(at: isoPath)
            ubuntuLastValidation = validation
            statusMessage = validation.isValid ? "Ubuntu ISO validation passed." : "Ubuntu ISO validation found \(validation.failures.count) issue(s)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func planUbuntuLocalMediaSession() {
        let isoPath = firstNonEmptyForController(
            ubuntuOutputISOPath,
            ubuntuLastArtifacts?.outputISOPath ?? ""
        )
        do {
            ubuntuLocalMediaState = try Ilo4LocalMediaSession().planSession(
                request: LocalMediaSessionRequest(
                    oobURL: ubuntuOOBURL,
                    username: ubuntuOOBUsername,
                    isoPath: isoPath,
                    vendor: .ilo
                )
            )
            statusMessage = "Prepared embedded iLO local-media session."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func ubuntuInstallSpec() throws -> UbuntuInstallSpec {
        let environment = ProcessInfo.processInfo.environment
        let rackHash = firstNonEmptyForController(ubuntuRackPasswordHash, environment["TDS_RACK_PASSWORD_HASH"] ?? "")
        let rootHash = firstNonEmptyForController(ubuntuRootPasswordHash, environment["TDS_ROOT_PASSWORD_HASH"] ?? "", rackHash)
        guard !ubuntuCapturePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UbuntuBootstrapError.missingRequired("Choose a preinstall capture directory or snapshot.json.")
        }
        guard !ubuntuSourceISOPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UbuntuBootstrapError.missingRequired("Choose the source Ubuntu ISO.")
        }
        guard !ubuntuOutputISOPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UbuntuBootstrapError.missingRequired("Choose where to write the customized Ubuntu ISO.")
        }

        return UbuntuInstallSpec(
            accountNumber: accountNumber,
            deviceID: clusterEligibleDevices.first(where: { binding(for: $0).role == .helper })?.id ?? "",
            sourceISOPath: ubuntuSourceISOPath.expandingTildeInPath(),
            outputISOPath: ubuntuOutputISOPath.expandingTildeInPath(),
            workDirectoryPath: ubuntuWorkDirectoryPath.expandingTildeInPath(),
            capturePath: ubuntuCapturePath.expandingTildeInPath(),
            rackPasswordHash: rackHash,
            rootPasswordHash: rootHash,
            authorizedSSHKeys: loadUbuntuAuthorizedKeys()
        )
    }

    private func loadUbuntuAuthorizedKeys() -> [String] {
        let explicitFiles = ubuntuSSHKeyFiles
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var keys: [String] = []
        for file in explicitFiles {
            if let content = try? String(contentsOf: URL(fileURLWithPath: file.expandingTildeInPath()), encoding: .utf8) {
                keys.append(contentsOf: content.split(separator: "\n").map(String.init))
            }
        }
        if keys.isEmpty {
            let sshDirectory = URL(fileURLWithPath: "~/.ssh".expandingTildeInPath(), isDirectory: true)
            if let contents = try? FileManager.default.contentsOfDirectory(at: sshDirectory, includingPropertiesForKeys: nil) {
                for url in contents where url.pathExtension == "pub" {
                    if let content = try? String(contentsOf: url, encoding: .utf8) {
                        keys.append(contentsOf: content.split(separator: "\n").map(String.init))
                    }
                }
            }
        }
        return Array(Set(keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

private func firstNonEmptyForController(_ values: String...) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
