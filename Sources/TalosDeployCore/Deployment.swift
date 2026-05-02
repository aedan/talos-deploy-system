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

    public func syncState(localDirectory: URL, remoteStateRoot: String, connection: SSHConnection) async throws {
        try await router.ensureDirectory(remoteStateRoot, connection: connection)
        try await router.sync(localPath: localDirectory, remotePath: remoteStateRoot, connection: connection, delete: false)
    }
}

public protocol TalosBuilder: Sendable {
    func buildArtifacts(for spec: DeploymentSpec, plan: DeploymentPlan, in directory: URL) async throws -> URL
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
        return directory
    }

    private func renderNodePatch(node: DeploymentNodeSpec, spec: DeploymentSpec) -> String {
        let addresses = node.device.networkInterfaces.first?.addresses ?? (node.device.primaryIP.isEmpty ? [] : [node.device.primaryIP])
        let renderedAddresses = addresses.map { "      - \($0)" }.joined(separator: "\n")
        let interfaceName = node.device.networkInterfaces.first?.name ?? "eth0"
        return """
        machine:
          type: \(node.assignment.role == .worker ? "worker" : "controlplane")
          network:
            hostname: \(node.device.name)
            interfaces:
              - interface: \(interfaceName)
        \(renderedAddresses.isEmpty ? "" : "    addresses:\n\(renderedAddresses)\n")
          install:
            disk: \(node.device.installDisk.isEmpty ? "/dev/sda" : node.device.installDisk)
        """
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

    public var errorDescription: String? {
        switch self {
        case .missingHelper:
            return "Exactly one helper/overseer must be selected."
        case .multipleHelpers:
            return "Only one helper/overseer may be selected."
        case .invalidControlPlaneCount:
            return "The control plane count must be either 1 or 3."
        case .missingHelperConfirmation(let name):
            return "Typed confirmation is required before reinstalling helper \(name)."
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

        let planned = spec.nodes
            .filter { $0.assignment.role != .unassigned }
            .map { node in
                PlannedDeviceInstall(
                    device: node.device,
                    assignment: node.assignment,
                    method: selectInstallMethod(for: node)
                )
            }

        guard let helper = planned.first(where: { $0.assignment.role == .helper }) else {
            throw DeploymentPlannerError.missingHelper
        }

        let remotePath = "\(spec.helperStateRoot)/\(spec.accountNumber)/\(spec.clusterName)"
        let tempPath = "rax-temp/\(spec.accountNumber)/\(spec.clusterName)"
        var phases: [DeploymentPhase] = []

        if helper.assignment.shouldInstallOS && helper.assignment.helperMode == .bootstrap {
            phases.append(
                DeploymentPhase(
                    title: "Bootstrap Helper",
                    steps: [
                        "Persist temporary deployment state on rax at \(tempPath).",
                        "Install the helper \(helper.device.name) first using \(helper.method.rawValue).",
                        "Wait for helper SSH reachability and move durable state to \(remotePath).",
                    ]
                )
            )
        } else {
            phases.append(
                DeploymentPhase(
                    title: "Prepare Helper",
                    steps: [
                        "Validate SSH access to helper \(helper.device.name).",
                        "Create durable state root at \(remotePath).",
                    ]
                )
            )
        }

        let remainingInstalls = planned.filter { $0.device.id != helper.device.id && $0.assignment.shouldInstallOS }
        phases.append(
            DeploymentPhase(
                title: "Provision Cluster",
                steps: remainingInstalls.map {
                    "Provision \($0.device.name) as \($0.assignment.role.rawValue) using \($0.method.rawValue)."
                } + [
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
            tempStateDirectory: tempPath,
            durableStateDirectory: remotePath
        )
    }

    private func selectInstallMethod(for node: DeploymentNodeSpec) -> InstallMethod {
        switch node.assignment.preferredInstall {
        case .virtualMedia:
            return .virtualMedia
        case .pxe:
            return .pxe
        case .automatic:
            if node.assignment.role == .helper && node.assignment.shouldInstallOS {
                return .virtualMedia
            }
            if let oob = node.device.oob, oob.supportsVirtualMedia == true {
                return .virtualMedia
            }
            return .pxe
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
        try await helperHostClient.syncState(
            localDirectory: localDirectory,
            remoteStateRoot: state.plan.durableStateDirectory,
            connection: connection
        )
        var updated = state
        updated.helperSynchronized = true
        updated.events.append(DeploymentEvent(message: "Deployment state synchronized to helper \(connection.host)."))
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
    @Published public var statusMessage: String

    private let settingsController: SettingsController
    private let authProvider: AuthProvider
    private let coreClient: CoreClient
    private let environmentSessionProvider: EnvironmentCoreSessionProviding?
    private let hammertime: HammertimeAdapter
    private let paths: AppPaths
    private var hasBootstrappedSession = false

    public init(
        settingsController: SettingsController = SettingsController(),
        authProvider: AuthProvider = KeychainAuthProvider(),
        coreClient: CoreClient? = nil,
        hammertime: HammertimeAdapter? = nil,
        paths: AppPaths = AppPaths()
    ) {
        self.settingsController = settingsController
        self.paths = paths
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
        self.statusMessage = "Ready"
    }

    public func saveSettings() {
        do {
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
