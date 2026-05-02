import Foundation

public protocol AuthProvider: Sendable {
    func currentSession() throws -> CoreSession?
    func storeSession(_ session: CoreSession, secret: String) throws
    func clearSession() throws
}

public final class KeychainAuthProvider: AuthProvider, @unchecked Sendable {
    private let sessionStore: CoreSessionStore

    public init(sessionStore: CoreSessionStore = CoreSessionStore()) {
        self.sessionStore = sessionStore
    }

    public func currentSession() throws -> CoreSession? {
        try sessionStore.loadSession()
    }

    public func storeSession(_ session: CoreSession, secret: String) throws {
        try sessionStore.saveSession(session, secret: secret)
    }

    public func clearSession() throws {
        try sessionStore.clear()
    }
}

public protocol CoreClient: Sendable {
    func fetchDevices(accountNumber: String) async throws -> [DiscoveredDevice]
    func fetchDeviceDetails(accountNumber: String, deviceID: String) async throws -> DiscoveredDevice
}

public enum CoreClientError: Error, LocalizedError {
    case unauthenticated
    case noWorkingEndpoint
    case unableToParseResponse

    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "No Core session is configured."
        case .noWorkingEndpoint:
            return "The Core service did not return device data from any configured endpoint."
        case .unableToParseResponse:
            return "Unable to parse device data from the Core response."
        }
    }
}

public final class WSCoreClient: CoreClient, @unchecked Sendable {
    private let settings: CoreAPISettings
    private let sessionStore: CoreSessionStore
    private let urlSession: URLSession

    public init(
        settings: CoreAPISettings,
        sessionStore: CoreSessionStore = CoreSessionStore(),
        urlSession: URLSession = .shared
    ) {
        self.settings = settings
        self.sessionStore = sessionStore
        self.urlSession = urlSession
    }

    public func fetchDevices(accountNumber: String) async throws -> [DiscoveredDevice] {
        let headerValue = try sessionStore.loadSecret()
        guard let headerValue else {
            throw CoreClientError.unauthenticated
        }

        for template in settings.deviceCollectionPaths {
            let path = template.replacingOccurrences(of: "{account}", with: accountNumber)
            guard let url = URL(string: settings.serviceURL + path) else {
                continue
            }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(headerValue, forHTTPHeaderField: settings.sessionHeaderName)
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                continue
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                continue
            }
            if let devices = try parseDevices(data: data, accountNumber: accountNumber), !devices.isEmpty {
                return devices
            }
        }

        throw CoreClientError.noWorkingEndpoint
    }

    public func fetchDeviceDetails(accountNumber: String, deviceID: String) async throws -> DiscoveredDevice {
        let headerValue = try sessionStore.loadSecret()
        guard let headerValue else {
            throw CoreClientError.unauthenticated
        }

        for template in settings.deviceDetailPaths {
            let path = template
                .replacingOccurrences(of: "{account}", with: accountNumber)
                .replacingOccurrences(of: "{device}", with: deviceID)
            guard let url = URL(string: settings.serviceURL + path) else {
                continue
            }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(headerValue, forHTTPHeaderField: settings.sessionHeaderName)
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                continue
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                continue
            }
            if let devices = try parseDevices(data: data, accountNumber: accountNumber), let device = devices.first {
                return device
            }
        }

        throw CoreClientError.noWorkingEndpoint
    }

    private func parseDevices(data: Data, accountNumber: String) throws -> [DiscoveredDevice]? {
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [[String: Any]] {
            return array.map { mapDevice(dictionary: $0, accountNumber: accountNumber) }
        }
        if let dictionary = object as? [String: Any] {
            for key in ["devices", "servers", "results", "items", "data"] {
                if let array = dictionary[key] as? [[String: Any]] {
                    return array.map { mapDevice(dictionary: $0, accountNumber: accountNumber) }
                }
            }
            if dictionary["id"] != nil || dictionary["device_id"] != nil || dictionary["server"] != nil {
                return [mapDevice(dictionary: dictionary, accountNumber: accountNumber)]
            }
        }
        return nil
    }

    private func mapDevice(dictionary: [String: Any], accountNumber: String) -> DiscoveredDevice {
        let id = stringify(dictionary["id"] ?? dictionary["device_id"] ?? dictionary["server"] ?? dictionary["ddi"] ?? UUID().uuidString)
        let name = stringify(dictionary["name"] ?? dictionary["device"] ?? dictionary["nickname"] ?? id)
        let primaryIP = stringify(dictionary["primary_ip"] ?? dictionary["login_ip"])
        let privateIP = stringify(dictionary["private_ip"])
        let platformName = stringify(dictionary["platform_name"] ?? dictionary["platform"])
        let osType = stringify(dictionary["os_type"])
        let serviceLevel = stringify(dictionary["service_level"] ?? dictionary["service_level_name"])
        let installDisk = stringify(dictionary["install_disk"] ?? dictionary["disk"])
        let serviceTag = stringify(dictionary["service_tag"] ?? dictionary["serial"] ?? dictionary["serviceTag"])
        let memoryGiB = integer(dictionary["memory_gib"] ?? dictionary["memory"] ?? dictionary["ram"])
        let storageGiB = integer(dictionary["storage_gib"] ?? dictionary["storage"])

        let oobAddress = stringify(dictionary["drac_ip"] ?? dictionary["drac_public"] ?? dictionary["oob_address"])
        let oobVendor: OOBVendor = {
            let raw = stringify(dictionary["oob_type"] ?? dictionary["vendor"]).lowercased()
            if raw.contains("ilo") { return .ilo }
            if raw.contains("idrac") || raw.contains("drac") { return .idrac }
            if raw.contains("redfish") { return .redfish }
            return oobAddress.isEmpty ? .unknown : .redfish
        }()

        let interfaces = mapInterfaces(from: dictionary["networks"])
        let oob = oobAddress.isEmpty ? nil : OOBEndpoint(
            vendor: oobVendor,
            address: oobAddress,
            username: stringify(dictionary["drac_user"] ?? dictionary["oob_username"]),
            credentialReference: stringify(dictionary["drac_credentials_ref"] ?? dictionary["oob_credentials_ref"]),
            supportsVirtualMedia: dictionary["supports_virtual_media"] as? Bool,
            supportsPXE: dictionary["supports_pxe"] as? Bool
        )

        return DiscoveredDevice(
            id: id,
            accountNumber: stringify(dictionary["account_num"] ?? accountNumber),
            name: name,
            primaryIP: primaryIP,
            privateIP: privateIP,
            platformName: platformName,
            osType: osType,
            serviceLevel: serviceLevel,
            serviceTag: serviceTag,
            memoryGiB: memoryGiB,
            storageGiB: storageGiB,
            installDisk: installDisk,
            networkInterfaces: interfaces,
            oob: oob,
            credentialReference: stringify(dictionary["credential_ref"] ?? dictionary["admin_credentials_ref"])
        )
    }

    private func mapInterfaces(from value: Any?) -> [NetworkInterface] {
        if let entries = value as? [[String: Any]] {
            return entries.map { entry in
                NetworkInterface(
                    name: stringify(entry["name"] ?? entry["interface"] ?? "eth0"),
                    addresses: stringArray(entry["addresses"] ?? entry["ips"]),
                    macAddress: stringify(entry["mac"] ?? entry["mac_address"]),
                    vlanID: integer(entry["vlan"] ?? entry["vlan_id"]),
                    mtu: integer(entry["mtu"])
                )
            }
        }
        if let single = value as? [String: Any] {
            return [
                NetworkInterface(
                    name: stringify(single["name"] ?? single["interface"] ?? "eth0"),
                    addresses: stringArray(single["addresses"] ?? single["ips"]),
                    macAddress: stringify(single["mac"] ?? single["mac_address"]),
                    vlanID: integer(single["vlan"] ?? single["vlan_id"]),
                    mtu: integer(single["mtu"])
                )
            ]
        }
        return []
    }
}
