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
    case deployer
    case controlplane
    case worker
}

public extension DeviceRole {
    var isDeployer: Bool {
        self == .deployer
    }

    var displayName: String {
        switch self {
        case .unassigned: "unassigned"
        case .deployer: "deployer"
        case .controlplane: "controlplane"
        case .worker: "worker"
        }
    }

    static var selectableRoles: [DeviceRole] {
        [.unassigned, .deployer, .controlplane, .worker]
    }
}

public enum DeployerMode: String, Codable, CaseIterable, Sendable {
    case existing
    case bootstrap
}

public enum InstallPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case virtualMedia
    case pxe
}

public enum InstallMethod: String, Codable, CaseIterable, Sendable {
    case operatorLocalMedia
    case virtualMedia
    case bootURL
    case pxe
    case stagedOnly
}

public enum TalosProvisioningStrategy: String, Codable, CaseIterable, Sendable {
    case automatic
    case operatorLocalMedia
    case deployerHostedMedia
    case deployerPXE
    case externalOOBURL
    case directVirtualMedia
}

public enum DeployerAccessMethod: String, Codable, CaseIterable, Sendable {
    case auto
    case directSSH
    case proxyJumpSSH
    case hammertime

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .directSSH: "Direct SSH"
        case .proxyJumpSSH: "SSH ProxyJump"
        case .hammertime: "Hammertime"
        }
    }
}

public enum BootstrapMediaDeliveryMode: String, Codable, CaseIterable, Sendable {
    case operatorLocalMedia
    case oobReachableURL
    case existingOSMediaHost
    case pxeAfterDeployerOnline
}

public enum NetworkConfigurationSource: String, Codable, CaseIterable, Sendable {
    case core
    case liveSnapshot
    case manual
    case unavailable
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
    public var proxyUsername: String
    public var proxyCredentialReference: String
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
        proxyUsername: String = "",
        proxyCredentialReference: String = "",
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
        self.proxyUsername = proxyUsername
        self.proxyCredentialReference = proxyCredentialReference.isEmpty
            ? Self.defaultProxyCredentialReference(for: id)
            : proxyCredentialReference
        self.ssh = ssh
        self.hammertimeVia = hammertimeVia
        self.notes = notes
    }

    public static func defaultProxyCredentialReference(for id: UUID) -> String {
        "access-profile-\(id.uuidString)-proxy-password"
    }

    public static let directDefault = AccessProfile(
        name: "Direct",
        kind: .direct,
        scope: .both,
        isDefault: true
    )
}

extension AccessProfile {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case scope
        case isDefault
        case proxyURL
        case proxyUsername
        case proxyCredentialReference
        case ssh
        case hammertimeVia
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.id = id
        self.name = try container.decode(String.self, forKey: .name)
        self.kind = try container.decode(AccessProfileKind.self, forKey: .kind)
        self.scope = try container.decodeIfPresent(AccessScope.self, forKey: .scope) ?? .both
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        self.proxyURL = try container.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
        self.proxyUsername = try container.decodeIfPresent(String.self, forKey: .proxyUsername) ?? ""
        self.proxyCredentialReference = try container.decodeIfPresent(String.self, forKey: .proxyCredentialReference)
            ?? Self.defaultProxyCredentialReference(for: id)
        self.ssh = try container.decodeIfPresent(SSHProxyConfiguration.self, forKey: .ssh)
        self.hammertimeVia = try container.decodeIfPresent(String.self, forKey: .hammertimeVia) ?? ""
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

public struct NetworkInterface: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var addresses: [String]
    public var macAddress: String
    public var vlanID: Int?
    public var mtu: Int?
    public var parentInterface: String
    public var bridgePorts: [String]
    public var routes: [StaticNetworkRoute]

    public init(
        id: UUID = UUID(),
        name: String,
        addresses: [String] = [],
        macAddress: String = "",
        vlanID: Int? = nil,
        mtu: Int? = nil,
        parentInterface: String = "",
        bridgePorts: [String] = [],
        routes: [StaticNetworkRoute] = []
    ) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.macAddress = macAddress
        self.vlanID = vlanID
        self.mtu = mtu
        self.parentInterface = parentInterface
        self.bridgePorts = bridgePorts
        self.routes = routes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case addresses
        case macAddress
        case vlanID
        case mtu
        case parentInterface
        case bridgePorts
        case routes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            addresses: try container.decodeIfPresent([String].self, forKey: .addresses) ?? [],
            macAddress: try container.decodeIfPresent(String.self, forKey: .macAddress) ?? "",
            vlanID: try container.decodeIfPresent(Int.self, forKey: .vlanID),
            mtu: try container.decodeIfPresent(Int.self, forKey: .mtu),
            parentInterface: try container.decodeIfPresent(String.self, forKey: .parentInterface) ?? "",
            bridgePorts: try container.decodeIfPresent([String].self, forKey: .bridgePorts) ?? [],
            routes: try container.decodeIfPresent([StaticNetworkRoute].self, forKey: .routes) ?? []
        )
    }
}

public struct StaticNetworkRoute: Codable, Equatable, Sendable {
    public var to: String
    public var via: String
    public var metric: Int?

    public init(to: String, via: String, metric: Int? = nil) {
        self.to = to
        self.via = via
        self.metric = metric
    }
}

public struct StaticNetworkConfig: Codable, Equatable, Sendable {
    public var managementInterface: String
    public var managementHardwareAddress: String
    public var managementAddressCIDR: String
    public var gateway: String
    public var nameservers: [String]
    public var searchDomains: [String]
    public var routes: [StaticNetworkRoute]
    public var vlans: [NetworkInterface]
    public var bridges: [NetworkInterface]

    public init(
        managementInterface: String = "",
        managementHardwareAddress: String = "",
        managementAddressCIDR: String = "",
        gateway: String = "",
        nameservers: [String] = [],
        searchDomains: [String] = [],
        routes: [StaticNetworkRoute] = [],
        vlans: [NetworkInterface] = [],
        bridges: [NetworkInterface] = []
    ) {
        self.managementInterface = managementInterface
        self.managementHardwareAddress = managementHardwareAddress
        self.managementAddressCIDR = managementAddressCIDR
        self.gateway = gateway
        self.nameservers = nameservers
        self.searchDomains = searchDomains
        self.routes = routes
        self.vlans = vlans
        self.bridges = bridges
    }

    public var isEmpty: Bool {
        managementInterface.isEmpty
            && managementHardwareAddress.isEmpty
            && managementAddressCIDR.isEmpty
            && gateway.isEmpty
            && nameservers.isEmpty
            && searchDomains.isEmpty
            && routes.isEmpty
            && vlans.isEmpty
            && bridges.isEmpty
    }
}

extension StaticNetworkConfig {
    enum CodingKeys: String, CodingKey {
        case managementInterface
        case managementHardwareAddress
        case managementAddressCIDR
        case gateway
        case nameservers
        case searchDomains
        case routes
        case vlans
        case bridges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            managementInterface: try container.decodeIfPresent(String.self, forKey: .managementInterface) ?? "",
            managementHardwareAddress: try container.decodeIfPresent(String.self, forKey: .managementHardwareAddress) ?? "",
            managementAddressCIDR: try container.decodeIfPresent(String.self, forKey: .managementAddressCIDR) ?? "",
            gateway: try container.decodeIfPresent(String.self, forKey: .gateway) ?? "",
            nameservers: try container.decodeIfPresent([String].self, forKey: .nameservers) ?? [],
            searchDomains: try container.decodeIfPresent([String].self, forKey: .searchDomains) ?? [],
            routes: try container.decodeIfPresent([StaticNetworkRoute].self, forKey: .routes) ?? [],
            vlans: try container.decodeIfPresent([NetworkInterface].self, forKey: .vlans) ?? [],
            bridges: try container.decodeIfPresent([NetworkInterface].self, forKey: .bridges) ?? []
        )
    }
}

public struct StaticNetworkValidationResult: Codable, Equatable, Sendable {
    public var deviceID: String
    public var isValid: Bool
    public var config: StaticNetworkConfig
    public var errors: [String]
    public var warnings: [String]

    public init(
        deviceID: String,
        isValid: Bool,
        config: StaticNetworkConfig = StaticNetworkConfig(),
        errors: [String] = [],
        warnings: [String] = []
    ) {
        self.deviceID = deviceID
        self.isValid = isValid
        self.config = config
        self.errors = errors
        self.warnings = warnings
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

extension DiscoveredDevice {
    enum CodingKeys: String, CodingKey {
        case id
        case accountNumber
        case name
        case primaryIP
        case privateIP
        case platformName
        case osType
        case serviceLevel
        case serviceTag
        case memoryGiB
        case storageGiB
        case installDisk
        case networkInterfaces
        case oob
        case credentialReference
        case liveFacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.accountNumber = try container.decodeIfPresent(String.self, forKey: .accountNumber) ?? ""
        self.name = try container.decode(String.self, forKey: .name)
        self.primaryIP = try container.decodeIfPresent(String.self, forKey: .primaryIP) ?? ""
        self.privateIP = try container.decodeIfPresent(String.self, forKey: .privateIP) ?? ""
        self.platformName = try container.decodeIfPresent(String.self, forKey: .platformName) ?? ""
        self.osType = try container.decodeIfPresent(String.self, forKey: .osType) ?? ""
        self.serviceLevel = try container.decodeIfPresent(String.self, forKey: .serviceLevel) ?? ""
        self.serviceTag = try container.decodeIfPresent(String.self, forKey: .serviceTag) ?? ""
        self.memoryGiB = try container.decodeIfPresent(Int.self, forKey: .memoryGiB)
        self.storageGiB = try container.decodeIfPresent(Int.self, forKey: .storageGiB)
        self.installDisk = try container.decodeIfPresent(String.self, forKey: .installDisk) ?? ""
        self.networkInterfaces = try container.decodeIfPresent([NetworkInterface].self, forKey: .networkInterfaces) ?? []
        self.oob = try container.decodeIfPresent(OOBEndpoint.self, forKey: .oob)
        self.credentialReference = try container.decodeIfPresent(String.self, forKey: .credentialReference) ?? ""
        self.liveFacts = try container.decodeIfPresent(LiveFactSnapshot.self, forKey: .liveFacts)
    }
}

public struct DeviceAssignment: Codable, Equatable, Sendable {
    public var deviceID: String
    public var role: DeviceRole
    public var deployerMode: DeployerMode
    public var shouldInstallOS: Bool
    public var preferredInstall: InstallPreference
    public var networkSource: NetworkConfigurationSource
    public var staticNetwork: StaticNetworkConfig
    public var manualNetworkPlanPath: String
    public var typedConfirmation: String

    public init(
        deviceID: String,
        role: DeviceRole = .unassigned,
        deployerMode: DeployerMode = .existing,
        shouldInstallOS: Bool = false,
        preferredInstall: InstallPreference = .automatic,
        networkSource: NetworkConfigurationSource = .core,
        staticNetwork: StaticNetworkConfig = StaticNetworkConfig(),
        manualNetworkPlanPath: String = "",
        typedConfirmation: String = ""
    ) {
        self.deviceID = deviceID
        self.role = role
        self.deployerMode = deployerMode
        self.shouldInstallOS = shouldInstallOS
        self.preferredInstall = preferredInstall
        self.networkSource = networkSource
        self.staticNetwork = staticNetwork
        self.manualNetworkPlanPath = manualNetworkPlanPath
        self.typedConfirmation = typedConfirmation
    }
}

public struct TalosKernelModule: Codable, Equatable, Sendable {
    public var name: String
    public var parameters: [String]

    public init(name: String, parameters: [String] = []) {
        self.name = name
        self.parameters = parameters
    }
}

public struct TalosImageFactorySettings: Codable, Equatable, Sendable {
    public var baseURL: String
    public var pxeBaseURL: String
    public var registryHost: String
    public var architecture: String
    public var platform: String
    public var schematicID: String
    public var selectedSystemExtensions: [String]
    public var extraKernelArgs: [String]

    public init(
        baseURL: String = "https://factory.talos.dev",
        pxeBaseURL: String = "https://pxe.factory.talos.dev",
        registryHost: String = "factory.talos.dev",
        architecture: String = "amd64",
        platform: String = "metal",
        schematicID: String = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba",
        selectedSystemExtensions: [String] = [
            "siderolabs/iscsi-tools",
            "siderolabs/util-linux-tools",
            "siderolabs/bnx2-bnx2x",
        ],
        extraKernelArgs: [String] = []
    ) {
        self.baseURL = baseURL
        self.pxeBaseURL = pxeBaseURL
        self.registryHost = registryHost
        self.architecture = architecture
        self.platform = platform
        self.schematicID = schematicID
        self.selectedSystemExtensions = selectedSystemExtensions
        self.extraKernelArgs = extraKernelArgs
    }
}

public struct TalosProvisioningDefaults: Codable, Equatable, Sendable {
    public var preferredStrategies: [TalosProvisioningStrategy]
    public var allowDeployerHostedMedia: Bool
    public var allowDeployerPXE: Bool
    public var allowExternalOOBURL: Bool
    public var externalOOBMediaBaseURL: String
    public var wipeSystemDiskBeforeInstall: Bool
    public var legacyBIOSSupport: Bool
    public var managementNetworkOnly: Bool
    public var useOOBHardwareAddressSelectors: Bool
    public var allowDeployerRegistry: Bool
    public var deployerRegistryHost: String
    public var deployerRegistryAddressCIDR: String
    public var deployerRegistryInterface: String
    public var deployerNodeRouteInterface: String
    public var deployerNodeRouteSourceCIDR: String
    public var deployerRegistryPort: Int
    public var deployerRegistryMirrorHosts: [String]

    public init(
        preferredStrategies: [TalosProvisioningStrategy] = [
            .deployerHostedMedia,
            .deployerPXE,
            .directVirtualMedia,
            .externalOOBURL,
            .operatorLocalMedia,
        ],
        allowDeployerHostedMedia: Bool = true,
        allowDeployerPXE: Bool = true,
        allowExternalOOBURL: Bool = false,
        externalOOBMediaBaseURL: String = "",
        wipeSystemDiskBeforeInstall: Bool = true,
        legacyBIOSSupport: Bool = true,
        managementNetworkOnly: Bool = false,
        useOOBHardwareAddressSelectors: Bool = true,
        allowDeployerRegistry: Bool = true,
        deployerRegistryHost: String = "",
        deployerRegistryAddressCIDR: String = "",
        deployerRegistryInterface: String = "",
        deployerNodeRouteInterface: String = "",
        deployerNodeRouteSourceCIDR: String = "",
        deployerRegistryPort: Int = 5000,
        deployerRegistryMirrorHosts: [String] = ["ghcr.io", "registry.k8s.io"]
    ) {
        self.preferredStrategies = preferredStrategies
        self.allowDeployerHostedMedia = allowDeployerHostedMedia
        self.allowDeployerPXE = allowDeployerPXE
        self.allowExternalOOBURL = allowExternalOOBURL
        self.externalOOBMediaBaseURL = externalOOBMediaBaseURL
        self.wipeSystemDiskBeforeInstall = wipeSystemDiskBeforeInstall
        self.legacyBIOSSupport = legacyBIOSSupport
        self.managementNetworkOnly = managementNetworkOnly
        self.useOOBHardwareAddressSelectors = useOOBHardwareAddressSelectors
        self.allowDeployerRegistry = allowDeployerRegistry
        self.deployerRegistryHost = deployerRegistryHost
        self.deployerRegistryAddressCIDR = deployerRegistryAddressCIDR
        self.deployerRegistryInterface = deployerRegistryInterface
        self.deployerNodeRouteInterface = deployerNodeRouteInterface
        self.deployerNodeRouteSourceCIDR = deployerNodeRouteSourceCIDR
        self.deployerRegistryPort = deployerRegistryPort
        self.deployerRegistryMirrorHosts = deployerRegistryMirrorHosts
    }
}

extension TalosProvisioningDefaults {
    enum CodingKeys: String, CodingKey {
        case preferredStrategies
        case allowDeployerHostedMedia
        case allowDeployerPXE
        case allowExternalOOBURL
        case externalOOBMediaBaseURL
        case wipeSystemDiskBeforeInstall
        case legacyBIOSSupport
        case managementNetworkOnly
        case useOOBHardwareAddressSelectors
        case allowDeployerRegistry
        case deployerRegistryHost
        case deployerRegistryAddressCIDR
        case deployerRegistryInterface
        case deployerNodeRouteInterface
        case deployerNodeRouteSourceCIDR
        case deployerRegistryPort
        case deployerRegistryMirrorHosts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TalosProvisioningDefaults()
        self.init(
            preferredStrategies: try container.decodeIfPresent([TalosProvisioningStrategy].self, forKey: .preferredStrategies) ?? defaults.preferredStrategies,
            allowDeployerHostedMedia: try container.decodeIfPresent(Bool.self, forKey: .allowDeployerHostedMedia) ?? defaults.allowDeployerHostedMedia,
            allowDeployerPXE: try container.decodeIfPresent(Bool.self, forKey: .allowDeployerPXE) ?? defaults.allowDeployerPXE,
            allowExternalOOBURL: try container.decodeIfPresent(Bool.self, forKey: .allowExternalOOBURL) ?? defaults.allowExternalOOBURL,
            externalOOBMediaBaseURL: try container.decodeIfPresent(String.self, forKey: .externalOOBMediaBaseURL) ?? defaults.externalOOBMediaBaseURL,
            wipeSystemDiskBeforeInstall: try container.decodeIfPresent(Bool.self, forKey: .wipeSystemDiskBeforeInstall) ?? defaults.wipeSystemDiskBeforeInstall,
            legacyBIOSSupport: try container.decodeIfPresent(Bool.self, forKey: .legacyBIOSSupport) ?? defaults.legacyBIOSSupport,
            managementNetworkOnly: try container.decodeIfPresent(Bool.self, forKey: .managementNetworkOnly) ?? defaults.managementNetworkOnly,
            useOOBHardwareAddressSelectors: try container.decodeIfPresent(Bool.self, forKey: .useOOBHardwareAddressSelectors) ?? defaults.useOOBHardwareAddressSelectors,
            allowDeployerRegistry: try container.decodeIfPresent(Bool.self, forKey: .allowDeployerRegistry) ?? defaults.allowDeployerRegistry,
            deployerRegistryHost: try container.decodeIfPresent(String.self, forKey: .deployerRegistryHost) ?? defaults.deployerRegistryHost,
            deployerRegistryAddressCIDR: try container.decodeIfPresent(String.self, forKey: .deployerRegistryAddressCIDR) ?? defaults.deployerRegistryAddressCIDR,
            deployerRegistryInterface: try container.decodeIfPresent(String.self, forKey: .deployerRegistryInterface) ?? defaults.deployerRegistryInterface,
            deployerNodeRouteInterface: try container.decodeIfPresent(String.self, forKey: .deployerNodeRouteInterface) ?? defaults.deployerNodeRouteInterface,
            deployerNodeRouteSourceCIDR: try container.decodeIfPresent(String.self, forKey: .deployerNodeRouteSourceCIDR) ?? defaults.deployerNodeRouteSourceCIDR,
            deployerRegistryPort: try container.decodeIfPresent(Int.self, forKey: .deployerRegistryPort) ?? defaults.deployerRegistryPort,
            deployerRegistryMirrorHosts: try container.decodeIfPresent([String].self, forKey: .deployerRegistryMirrorHosts) ?? defaults.deployerRegistryMirrorHosts
        )
    }
}

public struct TalosFactoryArtifacts: Codable, Equatable, Sendable {
    public var schematicID: String
    public var schematicYAML: String
    public var isoURL: String
    public var pxeURL: String
    public var installerImage: String

    public init(schematicID: String, schematicYAML: String, isoURL: String, pxeURL: String, installerImage: String) {
        self.schematicID = schematicID
        self.schematicYAML = schematicYAML
        self.isoURL = isoURL
        self.pxeURL = pxeURL
        self.installerImage = installerImage
    }
}

extension DeviceAssignment {
    enum CodingKeys: String, CodingKey {
        case deviceID
        case role
        case deployerMode
        case shouldInstallOS
        case preferredInstall
        case networkSource
        case staticNetwork
        case manualNetworkPlanPath
        case typedConfirmation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID = try container.decode(String.self, forKey: .deviceID)
        self.role = try container.decodeIfPresent(DeviceRole.self, forKey: .role) ?? .unassigned
        self.deployerMode = try container.decodeIfPresent(DeployerMode.self, forKey: .deployerMode) ?? .existing
        self.shouldInstallOS = try container.decodeIfPresent(Bool.self, forKey: .shouldInstallOS) ?? false
        self.preferredInstall = try container.decodeIfPresent(InstallPreference.self, forKey: .preferredInstall) ?? .automatic
        self.networkSource = try container.decodeIfPresent(NetworkConfigurationSource.self, forKey: .networkSource) ?? .core
        self.staticNetwork = try container.decodeIfPresent(StaticNetworkConfig.self, forKey: .staticNetwork) ?? StaticNetworkConfig()
        self.manualNetworkPlanPath = try container.decodeIfPresent(String.self, forKey: .manualNetworkPlanPath) ?? ""
        self.typedConfirmation = try container.decodeIfPresent(String.self, forKey: .typedConfirmation) ?? ""
    }
}

public struct TalosDefaults: Codable, Equatable, Sendable {
    public var talosVersion: String
    public var kubernetesVersion: String
    public var clusterName: String
    public var clusterEndpoint: String
    public var extensions: [String]
    public var kernelModules: [TalosKernelModule]
    public var factory: TalosImageFactorySettings
    public var provisioning: TalosProvisioningDefaults
    public var installerPreference: InstallPreference
    public var enableLonghornExtraMounts: Bool

    public init(
        talosVersion: String = "v1.13.0",
        kubernetesVersion: String = "v1.34.1",
        clusterName: String = "cluster.local",
        clusterEndpoint: String = "https://talos-api.example.com:6443",
        extensions: [String] = [
            "siderolabs/iscsi-tools",
            "siderolabs/util-linux-tools",
            "siderolabs/bnx2-bnx2x",
        ],
        kernelModules: [TalosKernelModule] = [],
        factory: TalosImageFactorySettings = TalosImageFactorySettings(),
        provisioning: TalosProvisioningDefaults = TalosProvisioningDefaults(),
        installerPreference: InstallPreference = .virtualMedia,
        enableLonghornExtraMounts: Bool = true
    ) {
        self.talosVersion = talosVersion
        self.kubernetesVersion = kubernetesVersion
        self.clusterName = clusterName
        self.clusterEndpoint = clusterEndpoint
        self.extensions = extensions
        self.kernelModules = kernelModules
        var normalizedFactory = factory
        if normalizedFactory.selectedSystemExtensions.isEmpty {
            normalizedFactory.selectedSystemExtensions = extensions
        }
        self.factory = normalizedFactory
        self.provisioning = provisioning
        self.installerPreference = installerPreference
        self.enableLonghornExtraMounts = enableLonghornExtraMounts
    }
}

extension TalosDefaults {
    enum CodingKeys: String, CodingKey {
        case talosVersion
        case kubernetesVersion
        case clusterName
        case clusterEndpoint
        case extensions
        case kernelModules
        case factory
        case provisioning
        case installerPreference
        case enableLonghornExtraMounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? [
            "siderolabs/iscsi-tools",
            "siderolabs/util-linux-tools",
            "siderolabs/bnx2-bnx2x",
        ]
        let factory = try container.decodeIfPresent(TalosImageFactorySettings.self, forKey: .factory)
            ?? TalosImageFactorySettings(selectedSystemExtensions: extensions)
        self.init(
            talosVersion: try container.decodeIfPresent(String.self, forKey: .talosVersion) ?? "v1.13.0",
            kubernetesVersion: try container.decodeIfPresent(String.self, forKey: .kubernetesVersion) ?? "v1.34.1",
            clusterName: try container.decodeIfPresent(String.self, forKey: .clusterName) ?? "cluster.local",
            clusterEndpoint: try container.decodeIfPresent(String.self, forKey: .clusterEndpoint) ?? "https://talos-api.example.com:6443",
            extensions: extensions,
            kernelModules: try container.decodeIfPresent([TalosKernelModule].self, forKey: .kernelModules) ?? [],
            factory: factory,
            provisioning: try container.decodeIfPresent(TalosProvisioningDefaults.self, forKey: .provisioning) ?? TalosProvisioningDefaults(),
            installerPreference: try container.decodeIfPresent(InstallPreference.self, forKey: .installerPreference) ?? .virtualMedia,
            enableLonghornExtraMounts: try container.decodeIfPresent(Bool.self, forKey: .enableLonghornExtraMounts) ?? true
        )
    }
}

public struct DeployerDefaults: Codable, Equatable, Sendable {
    public var accessMethod: DeployerAccessMethod
    public var sshUser: String
    public var proxyJumpHost: String
    public var stateRoot: String
    public var pxeAddress: String
    public var httpPort: Int
    public var httpBindAddress: String
    public var mediaDirectoryName: String
    public var pxeDirectoryName: String
    public var hostnameSuffix: String
    public var packageCacheRoot: String
    public var talosctlVersion: String
    public var registryPort: Int
    public var keepLocalMirror: Bool

    public init(
        accessMethod: DeployerAccessMethod = .auto,
        sshUser: String = "root",
        proxyJumpHost: String = "",
        stateRoot: String = "/var/lib/talos-deploy",
        pxeAddress: String = "",
        httpPort: Int = 8080,
        httpBindAddress: String = "0.0.0.0",
        mediaDirectoryName: String = "media",
        pxeDirectoryName: String = "pxe",
        hostnameSuffix: String = "",
        packageCacheRoot: String = "/var/cache/tds",
        talosctlVersion: String = "",
        registryPort: Int = 5000,
        keepLocalMirror: Bool = true
    ) {
        self.accessMethod = accessMethod
        self.sshUser = sshUser
        self.proxyJumpHost = proxyJumpHost
        self.stateRoot = stateRoot
        self.pxeAddress = pxeAddress
        self.httpPort = httpPort
        self.httpBindAddress = httpBindAddress
        self.mediaDirectoryName = mediaDirectoryName
        self.pxeDirectoryName = pxeDirectoryName
        self.hostnameSuffix = hostnameSuffix
        self.packageCacheRoot = packageCacheRoot
        self.talosctlVersion = talosctlVersion
        self.registryPort = registryPort
        self.keepLocalMirror = keepLocalMirror
    }
}

extension DeployerDefaults {
    enum CodingKeys: String, CodingKey {
        case accessMethod
        case sshUser
        case proxyJumpHost
        case stateRoot
        case pxeAddress
        case httpPort
        case httpBindAddress
        case mediaDirectoryName
        case pxeDirectoryName
        case hostnameSuffix
        case packageCacheRoot
        case talosctlVersion
        case registryPort
        case keepLocalMirror
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessMethod = try container.decodeIfPresent(DeployerAccessMethod.self, forKey: .accessMethod) ?? .auto
        self.sshUser = try container.decodeIfPresent(String.self, forKey: .sshUser) ?? "root"
        self.proxyJumpHost = try container.decodeIfPresent(String.self, forKey: .proxyJumpHost) ?? ""
        self.stateRoot = try container.decodeIfPresent(String.self, forKey: .stateRoot) ?? "/var/lib/talos-deploy"
        self.pxeAddress = try container.decodeIfPresent(String.self, forKey: .pxeAddress) ?? ""
        self.httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? 8080
        self.httpBindAddress = try container.decodeIfPresent(String.self, forKey: .httpBindAddress) ?? "0.0.0.0"
        self.mediaDirectoryName = try container.decodeIfPresent(String.self, forKey: .mediaDirectoryName) ?? "media"
        self.pxeDirectoryName = try container.decodeIfPresent(String.self, forKey: .pxeDirectoryName) ?? "pxe"
        self.hostnameSuffix = try container.decodeIfPresent(String.self, forKey: .hostnameSuffix) ?? ""
        self.packageCacheRoot = try container.decodeIfPresent(String.self, forKey: .packageCacheRoot) ?? "/var/cache/tds"
        self.talosctlVersion = try container.decodeIfPresent(String.self, forKey: .talosctlVersion) ?? ""
        self.registryPort = try container.decodeIfPresent(Int.self, forKey: .registryPort) ?? 5000
        self.keepLocalMirror = try container.decodeIfPresent(Bool.self, forKey: .keepLocalMirror) ?? true
    }
}

public struct BootstrapMediaDefaults: Codable, Equatable, Sendable {
    public var deliveryMode: BootstrapMediaDeliveryMode
    public var allowExistingOSMediaHost: Bool
    public var externalMediaBaseURL: String
    public var mediaHostDeviceID: String
    public var requireOperatorLocalMediaForGreenfield: Bool

    public init(
        deliveryMode: BootstrapMediaDeliveryMode = .operatorLocalMedia,
        allowExistingOSMediaHost: Bool = false,
        externalMediaBaseURL: String = "",
        mediaHostDeviceID: String = "",
        requireOperatorLocalMediaForGreenfield: Bool = true
    ) {
        self.deliveryMode = deliveryMode
        self.allowExistingOSMediaHost = allowExistingOSMediaHost
        self.externalMediaBaseURL = externalMediaBaseURL
        self.mediaHostDeviceID = mediaHostDeviceID
        self.requireOperatorLocalMediaForGreenfield = requireOperatorLocalMediaForGreenfield
    }
}

public struct DeployerMediaServiceConfiguration: Codable, Equatable, Sendable {
    public var stateRoot: String
    public var mediaDirectoryName: String
    public var pxeDirectoryName: String
    public var httpBindAddress: String
    public var httpPort: Int
    public var dnsListenAddresses: [String]
    public var registryPort: Int
    public var packageCacheRoot: String
    public var talosctlVersion: String

    public init(
        stateRoot: String = "/var/lib/talos-deploy",
        mediaDirectoryName: String = "media",
        pxeDirectoryName: String = "pxe",
        httpBindAddress: String = "0.0.0.0",
        httpPort: Int = 8080,
        dnsListenAddresses: [String] = [],
        registryPort: Int = 5000,
        packageCacheRoot: String = "/var/cache/tds",
        talosctlVersion: String = ""
    ) {
        self.stateRoot = stateRoot
        self.mediaDirectoryName = mediaDirectoryName
        self.pxeDirectoryName = pxeDirectoryName
        self.httpBindAddress = httpBindAddress
        self.httpPort = httpPort
        self.dnsListenAddresses = dnsListenAddresses
        self.registryPort = registryPort
        self.packageCacheRoot = packageCacheRoot
        self.talosctlVersion = talosctlVersion
    }

    public init(defaults: DeployerDefaults) {
        self.init(
            stateRoot: defaults.stateRoot,
            mediaDirectoryName: defaults.mediaDirectoryName,
            pxeDirectoryName: defaults.pxeDirectoryName,
            httpBindAddress: defaults.httpBindAddress,
            httpPort: defaults.httpPort,
            registryPort: defaults.registryPort,
            packageCacheRoot: defaults.packageCacheRoot,
            talosctlVersion: defaults.talosctlVersion
        )
    }

    public var mediaRoot: String {
        "\(stateRoot)/\(mediaDirectoryName)"
    }

    public var pxeRoot: String {
        "\(stateRoot)/\(pxeDirectoryName)"
    }
}

public struct DeployerMediaServicePlan: Codable, Equatable, Sendable {
    public var mediaRoot: String
    public var pxeRoot: String
    public var httpBindAddress: String
    public var httpPort: Int
    public var serviceCommand: String
    public var notes: [String]

    public init(
        mediaRoot: String,
        pxeRoot: String,
        httpBindAddress: String,
        httpPort: Int,
        serviceCommand: String,
        notes: [String] = []
    ) {
        self.mediaRoot = mediaRoot
        self.pxeRoot = pxeRoot
        self.httpBindAddress = httpBindAddress
        self.httpPort = httpPort
        self.serviceCommand = serviceCommand
        self.notes = notes
    }
}

public struct CoreRenameResult: Codable, Equatable, Sendable {
    public var requestedName: String
    public var didRename: Bool
    public var warning: String

    public init(requestedName: String, didRename: Bool, warning: String = "") {
        self.requestedName = requestedName
        self.didRename = didRename
        self.warning = warning
    }
}

public struct DeployerServicePlan: Codable, Equatable, Sendable {
    public var packages: [String]
    public var onlineInstallCommands: [String]
    public var cacheFallbackCommands: [String]
    public var systemdUnits: [String]
    public var notes: [String]

    public init(
        packages: [String] = [],
        onlineInstallCommands: [String] = [],
        cacheFallbackCommands: [String] = [],
        systemdUnits: [String] = [],
        notes: [String] = []
    ) {
        self.packages = packages
        self.onlineInstallCommands = onlineInstallCommands
        self.cacheFallbackCommands = cacheFallbackCommands
        self.systemdUnits = systemdUnits
        self.notes = notes
    }
}

public struct TalosExecutionRun: Codable, Equatable, Sendable {
    public var state: DeploymentState
    public var deployerHostname: String
    public var coreRename: CoreRenameResult?
    public var deployerServices: DeployerServicePlan
    public var networkValidation: [StaticNetworkValidationResult]
    public var accessValidation: DeployerAccessValidation?
    public var provisioningExecution: TalosProvisioningExecution?
    public var bootstrapResult: TalosBootstrapResult?
    public var maintenanceBundle: MaintenanceBundleManifest?
    public var dryRun: Bool

    public init(
        state: DeploymentState,
        deployerHostname: String,
        coreRename: CoreRenameResult? = nil,
        deployerServices: DeployerServicePlan = DeployerServicePlan(),
        networkValidation: [StaticNetworkValidationResult] = [],
        accessValidation: DeployerAccessValidation? = nil,
        provisioningExecution: TalosProvisioningExecution? = nil,
        bootstrapResult: TalosBootstrapResult? = nil,
        maintenanceBundle: MaintenanceBundleManifest? = nil,
        dryRun: Bool = true
    ) {
        self.state = state
        self.deployerHostname = deployerHostname
        self.coreRename = coreRename
        self.deployerServices = deployerServices
        self.networkValidation = networkValidation
        self.accessValidation = accessValidation
        self.provisioningExecution = provisioningExecution
        self.bootstrapResult = bootstrapResult
        self.maintenanceBundle = maintenanceBundle
        self.dryRun = dryRun
    }
}

public struct DeployerAccessValidation: Codable, Equatable, Sendable {
    public var method: DeployerAccessMethod
    public var target: String
    public var succeeded: Bool
    public var message: String
    public var attempts: [String]

    public init(
        method: DeployerAccessMethod,
        target: String,
        succeeded: Bool,
        message: String,
        attempts: [String] = []
    ) {
        self.method = method
        self.target = target
        self.succeeded = succeeded
        self.message = message
        self.attempts = attempts
    }
}

public struct TalosProvisioningExecution: Codable, Equatable, Sendable {
    public var plannedActions: [String]
    public var executedActions: [String]
    public var warnings: [String]

    public init(plannedActions: [String] = [], executedActions: [String] = [], warnings: [String] = []) {
        self.plannedActions = plannedActions
        self.executedActions = executedActions
        self.warnings = warnings
    }
}

public struct TalosBootstrapResult: Codable, Equatable, Sendable {
    public var bootstrapNode: String
    public var commands: [String]
    public var succeeded: Bool
    public var warnings: [String]

    public init(bootstrapNode: String = "", commands: [String] = [], succeeded: Bool = false, warnings: [String] = []) {
        self.bootstrapNode = bootstrapNode
        self.commands = commands
        self.succeeded = succeeded
        self.warnings = warnings
    }
}

public struct MaintenanceBundleManifest: Codable, Equatable, Sendable {
    public var stateRoot: String
    public var clusterName: String
    public var generatedAt: Date
    public var scripts: [String]
    public var files: [String]

    public init(
        stateRoot: String,
        clusterName: String,
        generatedAt: Date = .now,
        scripts: [String],
        files: [String]
    ) {
        self.stateRoot = stateRoot
        self.clusterName = clusterName
        self.generatedAt = generatedAt
        self.scripts = scripts
        self.files = files
    }
}

public struct ClusterHealthResult: Codable, Equatable, Sendable {
    public var talosNodesReady: Bool
    public var kubernetesReady: Bool
    public var checkedCommands: [String]
    public var warnings: [String]

    public init(
        talosNodesReady: Bool = false,
        kubernetesReady: Bool = false,
        checkedCommands: [String] = [],
        warnings: [String] = []
    ) {
        self.talosNodesReady = talosNodesReady
        self.kubernetesReady = kubernetesReady
        self.checkedCommands = checkedCommands
        self.warnings = warnings
    }
}

public struct HammertimeSettings: Codable, Equatable, Sendable {
    public var binaryPath: String
    public var pythonPath: String
    public var sessionCachePath: String
    public var enabled: Bool
    public var skipDeviceChecks: Bool
    public var deployerVia: String
    public var deployerUsePrivate: Bool
    public var passportReason: String
    public var copyMethod: String
    public var commandTimeoutSeconds: Int
    public var authPreflightTimeoutSeconds: Int
    public var deployerSSHArgs: String
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
        deployerVia: String = "",
        deployerUsePrivate: Bool = false,
        passportReason: String = "",
        copyMethod: String = "rsync",
        commandTimeoutSeconds: Int = 300,
        authPreflightTimeoutSeconds: Int = 30,
        deployerSSHArgs: String = "-o ConnectTimeout=20 -o ServerAliveInterval=10 -o ServerAliveCountMax=3",
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
        self.deployerVia = deployerVia
        self.deployerUsePrivate = deployerUsePrivate
        self.passportReason = passportReason
        self.copyMethod = copyMethod
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.authPreflightTimeoutSeconds = authPreflightTimeoutSeconds
        self.deployerSSHArgs = deployerSSHArgs
        self.defaultFactGroups = defaultFactGroups
        self.preferredTerminal = preferredTerminal
        self.saveExpectScripts = saveExpectScripts
        self.timeoutSeconds = timeoutSeconds
    }
}

extension HammertimeSettings {
    enum CodingKeys: String, CodingKey {
        case binaryPath
        case pythonPath
        case sessionCachePath
        case enabled
        case skipDeviceChecks
        case deployerVia
        case deployerUsePrivate
        case passportReason
        case copyMethod
        case commandTimeoutSeconds
        case authPreflightTimeoutSeconds
        case deployerSSHArgs
        case defaultFactGroups
        case preferredTerminal
        case saveExpectScripts
        case timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HammertimeSettings()
        self.init(
            binaryPath: try container.decodeIfPresent(String.self, forKey: .binaryPath) ?? defaults.binaryPath,
            pythonPath: try container.decodeIfPresent(String.self, forKey: .pythonPath) ?? defaults.pythonPath,
            sessionCachePath: try container.decodeIfPresent(String.self, forKey: .sessionCachePath) ?? defaults.sessionCachePath,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled,
            skipDeviceChecks: try container.decodeIfPresent(Bool.self, forKey: .skipDeviceChecks) ?? defaults.skipDeviceChecks,
            deployerVia: try container.decodeIfPresent(String.self, forKey: .deployerVia) ?? defaults.deployerVia,
            deployerUsePrivate: try container.decodeIfPresent(Bool.self, forKey: .deployerUsePrivate) ?? defaults.deployerUsePrivate,
            passportReason: try container.decodeIfPresent(String.self, forKey: .passportReason) ?? defaults.passportReason,
            copyMethod: try container.decodeIfPresent(String.self, forKey: .copyMethod) ?? defaults.copyMethod,
            commandTimeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .commandTimeoutSeconds) ?? defaults.commandTimeoutSeconds,
            authPreflightTimeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .authPreflightTimeoutSeconds) ?? defaults.authPreflightTimeoutSeconds,
            deployerSSHArgs: try container.decodeIfPresent(String.self, forKey: .deployerSSHArgs) ?? defaults.deployerSSHArgs,
            defaultFactGroups: try container.decodeIfPresent([String].self, forKey: .defaultFactGroups) ?? defaults.defaultFactGroups,
            preferredTerminal: try container.decodeIfPresent(String.self, forKey: .preferredTerminal) ?? defaults.preferredTerminal,
            saveExpectScripts: try container.decodeIfPresent(Bool.self, forKey: .saveExpectScripts) ?? defaults.saveExpectScripts,
            timeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        )
    }
}

public struct SafetySettings: Codable, Equatable, Sendable {
    public var requireTypedConfirmationForDeployerReinstall: Bool
    public var destructiveConfirmationTextPrefix: String

    public init(
        requireTypedConfirmationForDeployerReinstall: Bool = true,
        destructiveConfirmationTextPrefix: String = "INSTALL"
    ) {
        self.requireTypedConfirmationForDeployerReinstall = requireTypedConfirmationForDeployerReinstall
        self.destructiveConfirmationTextPrefix = destructiveConfirmationTextPrefix
    }
}

public struct CoreAPISettings: Codable, Equatable, Sendable {
    public var docsURL: String
    public var serviceURL: String
    public var loginURL: String
    public var deviceCollectionPaths: [String]
    public var deviceDetailPaths: [String]
    public var deviceRenamePaths: [String]
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
        deviceRenamePaths: [String] = [
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
        self.deviceRenamePaths = deviceRenamePaths
        self.inventorySource = inventorySource
        self.defaultAccountNumber = defaultAccountNumber
        self.sessionHeaderName = sessionHeaderName
    }
}

extension CoreAPISettings {
    enum CodingKeys: String, CodingKey {
        case docsURL
        case serviceURL
        case loginURL
        case deviceCollectionPaths
        case deviceDetailPaths
        case deviceRenamePaths
        case inventorySource
        case defaultAccountNumber
        case sessionHeaderName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CoreAPISettings()
        self.init(
            docsURL: try container.decodeIfPresent(String.self, forKey: .docsURL) ?? defaults.docsURL,
            serviceURL: try container.decodeIfPresent(String.self, forKey: .serviceURL) ?? defaults.serviceURL,
            loginURL: try container.decodeIfPresent(String.self, forKey: .loginURL) ?? defaults.loginURL,
            deviceCollectionPaths: try container.decodeIfPresent([String].self, forKey: .deviceCollectionPaths) ?? defaults.deviceCollectionPaths,
            deviceDetailPaths: try container.decodeIfPresent([String].self, forKey: .deviceDetailPaths) ?? defaults.deviceDetailPaths,
            deviceRenamePaths: try container.decodeIfPresent([String].self, forKey: .deviceRenamePaths) ?? defaults.deviceRenamePaths,
            inventorySource: try container.decodeIfPresent(InventorySource.self, forKey: .inventorySource) ?? defaults.inventorySource,
            defaultAccountNumber: try container.decodeIfPresent(String.self, forKey: .defaultAccountNumber) ?? "",
            sessionHeaderName: try container.decodeIfPresent(String.self, forKey: .sessionHeaderName) ?? defaults.sessionHeaderName
        )
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
    public var deployer: DeployerDefaults
    public var bootstrapMedia: BootstrapMediaDefaults
    public var safety: SafetySettings
    public var accessProfiles: [AccessProfile]

    public init(
        core: CoreAPISettings = CoreAPISettings(),
        hammertime: HammertimeSettings = HammertimeSettings(),
        talos: TalosDefaults = TalosDefaults(),
        deployer: DeployerDefaults = DeployerDefaults(),
        bootstrapMedia: BootstrapMediaDefaults = BootstrapMediaDefaults(),
        safety: SafetySettings = SafetySettings(),
        accessProfiles: [AccessProfile] = [.directDefault]
    ) {
        self.core = core
        self.hammertime = hammertime
        self.talos = talos
        self.deployer = deployer
        self.bootstrapMedia = bootstrapMedia
        self.safety = safety
        self.accessProfiles = accessProfiles
    }
}

extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case core
        case hammertime
        case talos
        case deployer
        case bootstrapMedia
        case safety
        case accessProfiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.core = try container.decodeIfPresent(CoreAPISettings.self, forKey: .core) ?? CoreAPISettings()
        self.hammertime = try container.decodeIfPresent(HammertimeSettings.self, forKey: .hammertime) ?? HammertimeSettings()
        self.talos = try container.decodeIfPresent(TalosDefaults.self, forKey: .talos) ?? TalosDefaults()
        self.deployer = try container.decodeIfPresent(DeployerDefaults.self, forKey: .deployer) ?? DeployerDefaults()
        self.bootstrapMedia = try container.decodeIfPresent(BootstrapMediaDefaults.self, forKey: .bootstrapMedia) ?? BootstrapMediaDefaults()
        self.safety = try container.decodeIfPresent(SafetySettings.self, forKey: .safety) ?? SafetySettings()
        self.accessProfiles = try container.decodeIfPresent([AccessProfile].self, forKey: .accessProfiles) ?? [.directDefault]
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
    public var deployerStateRoot: String
    public var talosFactory: TalosImageFactorySettings
    public var talosProvisioning: TalosProvisioningDefaults
    public var talosKernelModules: [TalosKernelModule]
    public var enableLonghornExtraMounts: Bool
    public var nodes: [DeploymentNodeSpec]

    public init(
        accountNumber: String,
        clusterName: String,
        clusterEndpoint: String,
        talosVersion: String,
        kubernetesVersion: String,
        deployerStateRoot: String,
        talosFactory: TalosImageFactorySettings = TalosImageFactorySettings(),
        talosProvisioning: TalosProvisioningDefaults = TalosProvisioningDefaults(),
        talosKernelModules: [TalosKernelModule] = [],
        enableLonghornExtraMounts: Bool = true,
        nodes: [DeploymentNodeSpec]
    ) {
        self.accountNumber = accountNumber
        self.clusterName = clusterName
        self.clusterEndpoint = clusterEndpoint
        self.talosVersion = talosVersion
        self.kubernetesVersion = kubernetesVersion
        self.deployerStateRoot = deployerStateRoot
        self.talosFactory = talosFactory
        self.talosProvisioning = talosProvisioning
        self.talosKernelModules = talosKernelModules
        self.enableLonghornExtraMounts = enableLonghornExtraMounts
        self.nodes = nodes
    }
}

extension DeploymentSpec {
    enum CodingKeys: String, CodingKey {
        case accountNumber
        case clusterName
        case clusterEndpoint
        case talosVersion
        case kubernetesVersion
        case deployerStateRoot
        case talosFactory
        case talosProvisioning
        case talosKernelModules
        case enableLonghornExtraMounts
        case nodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            accountNumber: try container.decode(String.self, forKey: .accountNumber),
            clusterName: try container.decode(String.self, forKey: .clusterName),
            clusterEndpoint: try container.decode(String.self, forKey: .clusterEndpoint),
            talosVersion: try container.decode(String.self, forKey: .talosVersion),
            kubernetesVersion: try container.decodeIfPresent(String.self, forKey: .kubernetesVersion) ?? "v1.34.1",
            deployerStateRoot: try container.decodeIfPresent(String.self, forKey: .deployerStateRoot) ?? "/var/lib/talos-deploy",
            talosFactory: try container.decodeIfPresent(TalosImageFactorySettings.self, forKey: .talosFactory) ?? TalosImageFactorySettings(),
            talosProvisioning: try container.decodeIfPresent(TalosProvisioningDefaults.self, forKey: .talosProvisioning) ?? TalosProvisioningDefaults(),
            talosKernelModules: try container.decodeIfPresent([TalosKernelModule].self, forKey: .talosKernelModules) ?? [],
            enableLonghornExtraMounts: try container.decodeIfPresent(Bool.self, forKey: .enableLonghornExtraMounts) ?? true,
            nodes: try container.decode([DeploymentNodeSpec].self, forKey: .nodes)
        )
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
    public var deployer: PlannedDeviceInstall
    public var installs: [PlannedDeviceInstall]
    public var phases: [DeploymentPhase]
    public var talosArtifacts: TalosFactoryArtifacts
    public var networkValidation: [StaticNetworkValidationResult]
    public var tempStateDirectory: String
    public var durableStateDirectory: String

    public init(
        accountNumber: String,
        clusterName: String,
        deployer: PlannedDeviceInstall,
        installs: [PlannedDeviceInstall],
        phases: [DeploymentPhase],
        talosArtifacts: TalosFactoryArtifacts = TalosFactoryArtifacts(
            schematicID: TalosImageFactorySettings().schematicID,
            schematicYAML: "customization:\n",
            isoURL: "",
            pxeURL: "",
            installerImage: ""
        ),
        networkValidation: [StaticNetworkValidationResult] = [],
        tempStateDirectory: String,
        durableStateDirectory: String
    ) {
        self.accountNumber = accountNumber
        self.clusterName = clusterName
        self.deployer = deployer
        self.installs = installs
        self.phases = phases
        self.talosArtifacts = talosArtifacts
        self.networkValidation = networkValidation
        self.tempStateDirectory = tempStateDirectory
        self.durableStateDirectory = durableStateDirectory
    }
}

extension DeploymentPlan {
    enum CodingKeys: String, CodingKey {
        case accountNumber
        case clusterName
        case deployer
        case installs
        case phases
        case talosArtifacts
        case networkValidation
        case tempStateDirectory
        case durableStateDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            accountNumber: try container.decode(String.self, forKey: .accountNumber),
            clusterName: try container.decode(String.self, forKey: .clusterName),
            deployer: try container.decode(PlannedDeviceInstall.self, forKey: .deployer),
            installs: try container.decode([PlannedDeviceInstall].self, forKey: .installs),
            phases: try container.decode([DeploymentPhase].self, forKey: .phases),
            talosArtifacts: try container.decodeIfPresent(TalosFactoryArtifacts.self, forKey: .talosArtifacts) ?? TalosFactoryClient().artifactURLs(settings: TalosImageFactorySettings(), talosVersion: "v1.13.0"),
            networkValidation: try container.decodeIfPresent([StaticNetworkValidationResult].self, forKey: .networkValidation) ?? [],
            tempStateDirectory: try container.decode(String.self, forKey: .tempStateDirectory),
            durableStateDirectory: try container.decode(String.self, forKey: .durableStateDirectory)
        )
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
    public var deployerSynchronized: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        spec: DeploymentSpec,
        plan: DeploymentPlan,
        events: [DeploymentEvent],
        localStateDirectory: String,
        deployerSynchronized: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.spec = spec
        self.plan = plan
        self.events = events
        self.localStateDirectory = localStateDirectory
        self.deployerSynchronized = deployerSynchronized
    }
}

public extension DeploymentSpec {
    var deployerNode: DeploymentNodeSpec? {
        nodes.first(where: { $0.assignment.role.isDeployer })
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
