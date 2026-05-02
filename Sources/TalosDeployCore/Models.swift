import Foundation

public enum AccessScope: String, Codable, CaseIterable, Sendable {
    case core
    case oob
    case both
}

public enum AccessProfileKind: String, Codable, CaseIterable, Sendable {
    case direct
    case httpProxy
    case socksProxy
    case sshDynamicSocks
    case hammertimeProxy
}

public enum InventorySource: String, Codable, CaseIterable, Sendable {
    case auto
    case core
    case hammertime
}

public enum DeviceRole: String, Codable, CaseIterable, Sendable {
    case unassigned
    case helper
    case controlplane
    case worker
}

public enum HelperMode: String, Codable, CaseIterable, Sendable {
    case existing
    case bootstrap
}

public enum InstallPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case virtualMedia
    case pxe
}

public enum InstallMethod: String, Codable, CaseIterable, Sendable {
    case virtualMedia
    case bootURL
    case pxe
    case stagedOnly
}

public enum OOBVendor: String, Codable, CaseIterable, Sendable {
    case ilo
    case idrac
    case redfish
    case unknown
}

public struct SSHProxyConfiguration: Codable, Equatable, Sendable {
    public var host: String
    public var user: String
    public var port: Int
    public var identityFile: String
    public var extraArguments: [String]

    public init(
        host: String = "",
        user: String = "",
        port: Int = 22,
        identityFile: String = "",
        extraArguments: [String] = []
    ) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.extraArguments = extraArguments
    }
}

public struct AccessProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AccessProfileKind
    public var scope: AccessScope
    public var isDefault: Bool
    public var proxyURL: String
    public var ssh: SSHProxyConfiguration?
    public var hammertimeVia: String
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: AccessProfileKind,
        scope: AccessScope = .both,
        isDefault: Bool = false,
        proxyURL: String = "",
        ssh: SSHProxyConfiguration? = nil,
        hammertimeVia: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scope = scope
        self.isDefault = isDefault
        self.proxyURL = proxyURL
        self.ssh = ssh
        self.hammertimeVia = hammertimeVia
        self.notes = notes
    }

    public static let directDefault = AccessProfile(
        name: "Direct",
        kind: .direct,
        scope: .both,
        isDefault: true
    )
}

public struct NetworkInterface: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var addresses: [String]
    public var macAddress: String
    public var vlanID: Int?
    public var mtu: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        addresses: [String] = [],
        macAddress: String = "",
        vlanID: Int? = nil,
        mtu: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.macAddress = macAddress
        self.vlanID = vlanID
        self.mtu = mtu
    }
}

public struct OOBEndpoint: Codable, Equatable, Sendable {
    public var vendor: OOBVendor
    public var address: String
    public var username: String
    public var credentialReference: String
    public var supportsVirtualMedia: Bool?
    public var supportsPXE: Bool?

    public init(
        vendor: OOBVendor = .unknown,
        address: String = "",
        username: String = "",
        credentialReference: String = "",
        supportsVirtualMedia: Bool? = nil,
        supportsPXE: Bool? = nil
    ) {
        self.vendor = vendor
        self.address = address
        self.username = username
        self.credentialReference = credentialReference
        self.supportsVirtualMedia = supportsVirtualMedia
        self.supportsPXE = supportsPXE
    }
}

public struct StorageDevice: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sizeGiB: Int?

    public init(id: UUID = UUID(), name: String, sizeGiB: Int? = nil) {
        self.id = id
        self.name = name
        self.sizeGiB = sizeGiB
    }
}

public struct LiveFactSnapshot: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var osDescription: String
    public var memoryGiB: Int?
    public var storageDevices: [StorageDevice]
    public var attributes: [String: String]

    public init(
        fetchedAt: Date = .now,
        osDescription: String = "",
        memoryGiB: Int? = nil,
        storageDevices: [StorageDevice] = [],
        attributes: [String: String] = [:]
    ) {
        self.fetchedAt = fetchedAt
        self.osDescription = osDescription
        self.memoryGiB = memoryGiB
        self.storageDevices = storageDevices
        self.attributes = attributes
    }
}

public struct DiscoveredDevice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var accountNumber: String
    public var name: String
    public var primaryIP: String
    public var privateIP: String
    public var platformName: String
    public var osType: String
    public var serviceLevel: String
    public var serviceTag: String
    public var memoryGiB: Int?
    public var storageGiB: Int?
    public var installDisk: String
    public var networkInterfaces: [NetworkInterface]
    public var oob: OOBEndpoint?
    public var credentialReference: String
    public var liveFacts: LiveFactSnapshot?

    public init(
        id: String,
        accountNumber: String,
        name: String,
        primaryIP: String = "",
        privateIP: String = "",
        platformName: String = "",
        osType: String = "",
        serviceLevel: String = "",
        serviceTag: String = "",
        memoryGiB: Int? = nil,
        storageGiB: Int? = nil,
        installDisk: String = "",
        networkInterfaces: [NetworkInterface] = [],
        oob: OOBEndpoint? = nil,
        credentialReference: String = "",
        liveFacts: LiveFactSnapshot? = nil
    ) {
        self.id = id
        self.accountNumber = accountNumber
        self.name = name
        self.primaryIP = primaryIP
        self.privateIP = privateIP
        self.platformName = platformName
        self.osType = osType
        self.serviceLevel = serviceLevel
        self.serviceTag = serviceTag
        self.memoryGiB = memoryGiB
        self.storageGiB = storageGiB
        self.installDisk = installDisk
        self.networkInterfaces = networkInterfaces
        self.oob = oob
        self.credentialReference = credentialReference
        self.liveFacts = liveFacts
    }

    public var isClusterEligible: Bool {
        clusterIneligibilityReason == nil
    }

    public var clusterIneligibilityReason: String? {
        let haystack = [platformName, osType, name]
            .joined(separator: " ")
            .lowercased()

        let exclusions: [(String, String)] = [
            ("firewall", "Firewall devices are not Talos cluster nodes."),
            ("load-balancer", "Load balancers are not Talos cluster nodes."),
            ("load balancer", "Load balancers are not Talos cluster nodes."),
            ("switch", "Switches are not Talos cluster nodes."),
            ("private cloud environment", "Private cloud appliance entries are not install targets."),
            ("virtual machine", "Virtual machines are not physical Talos install targets."),
            ("vmware", "Virtual machines are not physical Talos install targets."),
            ("router", "Routers are not Talos cluster nodes."),
        ]
        for (marker, reason) in exclusions where haystack.contains(marker) {
            return reason
        }

        if !serviceTag.isEmpty {
            return nil
        }

        let physicalMarkers = [
            "dl360",
            "dl380",
            "proliant",
            "poweredge",
            "supermicro",
            "bare metal",
            "dedicated server",
            "openstack",
            "rack server",
        ]
        if physicalMarkers.contains(where: { haystack.contains($0) }) {
            return nil
        }

        let roleMarkers = ["compute", "controller", "worker", "undercloud", "overcloud", "node", "director"]
        if roleMarkers.contains(where: { name.lowercased().contains($0) }) && !haystack.contains("virtual machine") {
            return nil
        }

        return "Filtered out because the platform does not look like a physical server."
    }

    public var clusterEligibilitySummary: String {
        isClusterEligible ? "Eligible physical server" : (clusterIneligibilityReason ?? "Filtered out")
    }
}

public struct DeviceAssignment: Codable, Equatable, Sendable {
    public var deviceID: String
    public var role: DeviceRole
    public var helperMode: HelperMode
    public var shouldInstallOS: Bool
    public var preferredInstall: InstallPreference
    public var typedConfirmation: String

    public init(
        deviceID: String,
        role: DeviceRole = .unassigned,
        helperMode: HelperMode = .existing,
        shouldInstallOS: Bool = false,
        preferredInstall: InstallPreference = .automatic,
        typedConfirmation: String = ""
    ) {
        self.deviceID = deviceID
        self.role = role
        self.helperMode = helperMode
        self.shouldInstallOS = shouldInstallOS
        self.preferredInstall = preferredInstall
        self.typedConfirmation = typedConfirmation
    }
}

public struct TalosDefaults: Codable, Equatable, Sendable {
    public var talosVersion: String
    public var kubernetesVersion: String
    public var clusterName: String
    public var clusterEndpoint: String
    public var extensions: [String]
    public var installerPreference: InstallPreference

    public init(
        talosVersion: String = "v1.11.3",
        kubernetesVersion: String = "v1.34.1",
        clusterName: String = "cluster.local",
        clusterEndpoint: String = "https://talos-api.example.com:6443",
        extensions: [String] = [
            "siderolabs/iscsi-tools",
            "siderolabs/util-linux-tools",
        ],
        installerPreference: InstallPreference = .virtualMedia
    ) {
        self.talosVersion = talosVersion
        self.kubernetesVersion = kubernetesVersion
        self.clusterName = clusterName
        self.clusterEndpoint = clusterEndpoint
        self.extensions = extensions
        self.installerPreference = installerPreference
    }
}

public struct HelperDefaults: Codable, Equatable, Sendable {
    public var sshUser: String
    public var stateRoot: String
    public var pxeAddress: String
    public var httpPort: Int

    public init(
        sshUser: String = "root",
        stateRoot: String = "/var/lib/talos-deploy",
        pxeAddress: String = "",
        httpPort: Int = 8080
    ) {
        self.sshUser = sshUser
        self.stateRoot = stateRoot
        self.pxeAddress = pxeAddress
        self.httpPort = httpPort
    }
}

public struct HammertimeSettings: Codable, Equatable, Sendable {
    public var binaryPath: String
    public var pythonPath: String
    public var sessionCachePath: String
    public var enabled: Bool
    public var skipDeviceChecks: Bool
    public var defaultFactGroups: [String]
    public var preferredTerminal: String
    public var saveExpectScripts: Bool
    public var timeoutSeconds: Int

    public init(
        binaryPath: String = "~/.local/bin/ht",
        pythonPath: String = "",
        sessionCachePath: String = "~/.rackspace/hammertime/cache/sessions.db",
        enabled: Bool = true,
        skipDeviceChecks: Bool = true,
        defaultFactGroups: [String] = ["hardware", "storage", "setup", "routes"],
        preferredTerminal: String = "iterm",
        saveExpectScripts: Bool = false,
        timeoutSeconds: Int = 30
    ) {
        self.binaryPath = binaryPath
        self.pythonPath = pythonPath
        self.sessionCachePath = sessionCachePath
        self.enabled = enabled
        self.skipDeviceChecks = skipDeviceChecks
        self.defaultFactGroups = defaultFactGroups
        self.preferredTerminal = preferredTerminal
        self.saveExpectScripts = saveExpectScripts
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct SafetySettings: Codable, Equatable, Sendable {
    public var requireTypedConfirmationForHelperReinstall: Bool
    public var destructiveConfirmationTextPrefix: String

    public init(
        requireTypedConfirmationForHelperReinstall: Bool = true,
        destructiveConfirmationTextPrefix: String = "INSTALL"
    ) {
        self.requireTypedConfirmationForHelperReinstall = requireTypedConfirmationForHelperReinstall
        self.destructiveConfirmationTextPrefix = destructiveConfirmationTextPrefix
    }
}

public struct CoreAPISettings: Codable, Equatable, Sendable {
    public var docsURL: String
    public var serviceURL: String
    public var loginURL: String
    public var deviceCollectionPaths: [String]
    public var deviceDetailPaths: [String]
    public var inventorySource: InventorySource
    public var defaultAccountNumber: String
    public var sessionHeaderName: String

    public init(
        docsURL: String = "https://ws.core.rackspace.com/py/index.pt",
        serviceURL: String = "https://ws.core.rackspace.com",
        loginURL: String = "https://core.rackspace.com",
        deviceCollectionPaths: [String] = [
            "/api/accounts/{account}/devices",
            "/accounts/{account}/devices",
            "/api/devices?account={account}",
            "/devices?account={account}",
        ],
        deviceDetailPaths: [String] = [
            "/api/accounts/{account}/devices/{device}",
            "/accounts/{account}/devices/{device}",
            "/api/devices/{device}?account={account}",
        ],
        inventorySource: InventorySource = .auto,
        defaultAccountNumber: String = "",
        sessionHeaderName: String = "Cookie"
    ) {
        self.docsURL = docsURL
        self.serviceURL = serviceURL
        self.loginURL = loginURL
        self.deviceCollectionPaths = deviceCollectionPaths
        self.deviceDetailPaths = deviceDetailPaths
        self.inventorySource = inventorySource
        self.defaultAccountNumber = defaultAccountNumber
        self.sessionHeaderName = sessionHeaderName
    }
}

public struct CoreSession: Codable, Equatable, Sendable {
    public var username: String
    public var headerName: String
    public var secretReference: String
    public var createdAt: Date
    public var expiresAt: Date?

    public init(
        username: String = "",
        headerName: String = "Cookie",
        secretReference: String = "",
        createdAt: Date = .now,
        expiresAt: Date? = nil
    ) {
        self.username = username
        self.headerName = headerName
        self.secretReference = secretReference
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var core: CoreAPISettings
    public var hammertime: HammertimeSettings
    public var talos: TalosDefaults
    public var helper: HelperDefaults
    public var safety: SafetySettings
    public var accessProfiles: [AccessProfile]

    public init(
        core: CoreAPISettings = CoreAPISettings(),
        hammertime: HammertimeSettings = HammertimeSettings(),
        talos: TalosDefaults = TalosDefaults(),
        helper: HelperDefaults = HelperDefaults(),
        safety: SafetySettings = SafetySettings(),
        accessProfiles: [AccessProfile] = [.directDefault]
    ) {
        self.core = core
        self.hammertime = hammertime
        self.talos = talos
        self.helper = helper
        self.safety = safety
        self.accessProfiles = accessProfiles
    }
}

public struct DeploymentNodeSpec: Identifiable, Codable, Equatable, Sendable {
    public var id: String { device.id }
    public var device: DiscoveredDevice
    public var assignment: DeviceAssignment

    public init(device: DiscoveredDevice, assignment: DeviceAssignment) {
        self.device = device
        self.assignment = assignment
    }
}

public struct DeploymentSpec: Codable, Equatable, Sendable {
    public var accountNumber: String
    public var clusterName: String
    public var clusterEndpoint: String
    public var talosVersion: String
    public var kubernetesVersion: String
    public var helperStateRoot: String
    public var nodes: [DeploymentNodeSpec]

    public init(
        accountNumber: String,
        clusterName: String,
        clusterEndpoint: String,
        talosVersion: String,
        kubernetesVersion: String,
        helperStateRoot: String,
        nodes: [DeploymentNodeSpec]
    ) {
        self.accountNumber = accountNumber
        self.clusterName = clusterName
        self.clusterEndpoint = clusterEndpoint
        self.talosVersion = talosVersion
        self.kubernetesVersion = kubernetesVersion
        self.helperStateRoot = helperStateRoot
        self.nodes = nodes
    }
}

public struct PlannedDeviceInstall: Codable, Equatable, Sendable {
    public var device: DiscoveredDevice
    public var assignment: DeviceAssignment
    public var method: InstallMethod
    public var warnings: [String]

    public init(
        device: DiscoveredDevice,
        assignment: DeviceAssignment,
        method: InstallMethod,
        warnings: [String] = []
    ) {
        self.device = device
        self.assignment = assignment
        self.method = method
        self.warnings = warnings
    }
}

public struct DeploymentPhase: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var steps: [String]

    public init(id: UUID = UUID(), title: String, steps: [String]) {
        self.id = id
        self.title = title
        self.steps = steps
    }
}

public struct DeploymentPlan: Codable, Equatable, Sendable {
    public var accountNumber: String
    public var clusterName: String
    public var helper: PlannedDeviceInstall
    public var installs: [PlannedDeviceInstall]
    public var phases: [DeploymentPhase]
    public var tempStateDirectory: String
    public var durableStateDirectory: String

    public init(
        accountNumber: String,
        clusterName: String,
        helper: PlannedDeviceInstall,
        installs: [PlannedDeviceInstall],
        phases: [DeploymentPhase],
        tempStateDirectory: String,
        durableStateDirectory: String
    ) {
        self.accountNumber = accountNumber
        self.clusterName = clusterName
        self.helper = helper
        self.installs = installs
        self.phases = phases
        self.tempStateDirectory = tempStateDirectory
        self.durableStateDirectory = durableStateDirectory
    }
}

public struct DeploymentEvent: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var message: String

    public init(timestamp: Date = .now, message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

public struct DeploymentState: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var spec: DeploymentSpec
    public var plan: DeploymentPlan
    public var events: [DeploymentEvent]
    public var localStateDirectory: String
    public var helperSynchronized: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        spec: DeploymentSpec,
        plan: DeploymentPlan,
        events: [DeploymentEvent],
        localStateDirectory: String,
        helperSynchronized: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.spec = spec
        self.plan = plan
        self.events = events
        self.localStateDirectory = localStateDirectory
        self.helperSynchronized = helperSynchronized
    }
}

public extension DeploymentSpec {
    var helperNode: DeploymentNodeSpec? {
        nodes.first(where: { $0.assignment.role == .helper })
    }
}

public struct CommandCapture: Codable, Equatable, Sendable {
    public var label: String
    public var executable: String
    public var arguments: [String]
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var capturedAt: Date

    public init(
        label: String,
        executable: String,
        arguments: [String],
        stdout: String,
        stderr: String,
        exitCode: Int32,
        capturedAt: Date = .now
    ) {
        self.label = label
        self.executable = executable
        self.arguments = arguments
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.capturedAt = capturedAt
    }

    public var succeeded: Bool {
        exitCode == 0
    }
}

public struct NetworkPreservationSummary: Codable, Equatable, Sendable {
    public var hostname: String
    public var osDescription: String
    public var primaryIP: String
    public var privateIP: String
    public var oobIP: String
    public var observedInterfaces: [String]
    public var observedRoutes: [String]
    public var dnsServers: [String]
    public var searchDomains: [String]

    public init(
        hostname: String = "",
        osDescription: String = "",
        primaryIP: String = "",
        privateIP: String = "",
        oobIP: String = "",
        observedInterfaces: [String] = [],
        observedRoutes: [String] = [],
        dnsServers: [String] = [],
        searchDomains: [String] = []
    ) {
        self.hostname = hostname
        self.osDescription = osDescription
        self.primaryIP = primaryIP
        self.privateIP = privateIP
        self.oobIP = oobIP
        self.observedInterfaces = observedInterfaces
        self.observedRoutes = observedRoutes
        self.dnsServers = dnsServers
        self.searchDomains = searchDomains
    }
}

public struct NetworkPreservationSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var accountNumber: String
    public var device: DiscoveredDevice
    public var summary: NetworkPreservationSummary
    public var captures: [CommandCapture]
    public var directory: String

    public init(
        capturedAt: Date = .now,
        accountNumber: String,
        device: DiscoveredDevice,
        summary: NetworkPreservationSummary,
        captures: [CommandCapture],
        directory: String
    ) {
        self.capturedAt = capturedAt
        self.accountNumber = accountNumber
        self.device = device
        self.summary = summary
        self.captures = captures
        self.directory = directory
    }
}
