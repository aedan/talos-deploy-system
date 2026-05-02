import Foundation

public struct EnvironmentCoreSession: Sendable {
    public var session: CoreSession
    public var secret: String?

    public init(session: CoreSession, secret: String?) {
        self.session = session
        self.secret = secret
    }
}

public protocol EnvironmentCoreSessionProviding: Sendable {
    func discoverEnvironmentSession(includeSecret: Bool) async throws -> EnvironmentCoreSession?
}

public enum CoreBridgeError: Error, LocalizedError {
    case bridgeScriptMissing
    case pythonNotConfigured(String)
    case invalidBridgeOutput
    case unauthenticated

    public var errorDescription: String? {
        switch self {
        case .bridgeScriptMissing:
            return "The bundled Core bridge script could not be located."
        case .pythonNotConfigured(let binaryPath):
            return "Unable to resolve a Python runtime for hammertime from \(binaryPath)."
        case .invalidBridgeOutput:
            return "The Core bridge returned invalid JSON."
        case .unauthenticated:
            return "No authenticated hammertime session was found in the local cache."
        }
    }
}

public final class HammertimeBackedCoreClient: CoreClient, EnvironmentCoreSessionProviding, @unchecked Sendable {
    private let settings: HammertimeSettings
    private let runner: CommandRunning
    private let decoder: JSONDecoder

    public init(settings: HammertimeSettings, runner: CommandRunning = LocalCommandRunner()) {
        self.settings = settings
        self.runner = runner
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func fetchDevices(accountNumber: String) async throws -> [DiscoveredDevice] {
        let result = try await runBridgeCommand(
            "account-devices",
            arguments: ["--account", accountNumber]
        )
        guard let data = result.stdout.data(using: .utf8) else {
            throw CoreBridgeError.invalidBridgeOutput
        }
        let payload = try decoder.decode(BridgeInventoryPayload.self, from: data)
        return payload.devices.map(\.discoveredDevice)
    }

    public func fetchDeviceDetails(accountNumber: String, deviceID: String) async throws -> DiscoveredDevice {
        let result = try await runBridgeCommand(
            "device-details",
            arguments: ["--account", accountNumber, "--device", deviceID]
        )
        guard let data = result.stdout.data(using: .utf8) else {
            throw CoreBridgeError.invalidBridgeOutput
        }
        let payload = try decoder.decode(BridgeDevicePayload.self, from: data)
        return payload.device.discoveredDevice
    }

    public func discoverEnvironmentSession(includeSecret: Bool) async throws -> EnvironmentCoreSession? {
        var arguments: [String] = []
        if includeSecret {
            arguments.append("--include-secret")
        }
        let result = try await runBridgeCommand("auth-status", arguments: arguments)
        guard let data = result.stdout.data(using: .utf8) else {
            throw CoreBridgeError.invalidBridgeOutput
        }
        let payload = try decoder.decode(BridgeSessionPayload.self, from: data)
        guard payload.authenticated else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = payload.expiresAt.flatMap { formatter.date(from: $0) }
            ?? payload.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }

        let session = CoreSession(
            username: payload.username,
            headerName: payload.headerName,
            secretReference: "hammertime-cache-\(payload.username)",
            createdAt: .now,
            expiresAt: expiresAt
        )
        return EnvironmentCoreSession(session: session, secret: payload.secret)
    }

    private func runBridgeCommand(_ command: String, arguments: [String]) async throws -> CommandResult {
        let executable = try resolvePythonPath()
        let scriptURL = try bridgeScriptURL()
        let cachePath = settings.sessionCachePath.expandingTildeInPath()
        do {
            return try await runner.run(
                executable,
                arguments: [scriptURL.path, "--cache", cachePath, command] + arguments,
                environment: ["PYTHONUNBUFFERED": "1"],
                currentDirectory: nil,
                timeout: TimeInterval(max(settings.timeoutSeconds, 90))
            )
        } catch let error as CommandError {
            if case .executionFailed(let result) = error,
               result.stderr.localizedCaseInsensitiveContains("No authenticated hammertime session") {
                throw CoreBridgeError.unauthenticated
            }
            throw error
        }
    }

    private func bridgeScriptURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "core_bridge", withExtension: "py") else {
            throw CoreBridgeError.bridgeScriptMissing
        }
        return url
    }

    private func resolvePythonPath() throws -> String {
        if !settings.pythonPath.isEmpty {
            return settings.pythonPath.expandingTildeInPath()
        }

        let binaryPath = settings.binaryPath.expandingTildeInPath()
        if let shebang = try? String(contentsOfFile: binaryPath, encoding: .utf8)
            .split(separator: "\n")
            .first,
           shebang.hasPrefix("#!")
        {
            let candidate = String(shebang.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw CoreBridgeError.pythonNotConfigured(binaryPath)
    }
}

public final class ConfiguredCoreClient: CoreClient, EnvironmentCoreSessionProviding, @unchecked Sendable {
    private let bridgeClient: HammertimeBackedCoreClient
    private let httpClient: WSCoreClient

    public init(
        coreSettings: CoreAPISettings,
        hammertimeSettings: HammertimeSettings,
        sessionStore: CoreSessionStore = CoreSessionStore(),
        urlSession: URLSession = .shared,
        runner: CommandRunning = LocalCommandRunner()
    ) {
        self.bridgeClient = HammertimeBackedCoreClient(settings: hammertimeSettings, runner: runner)
        self.httpClient = WSCoreClient(settings: coreSettings, sessionStore: sessionStore, urlSession: urlSession)
    }

    public func fetchDevices(accountNumber: String) async throws -> [DiscoveredDevice] {
        var bridgeError: Error?
        do {
            return try await bridgeClient.fetchDevices(accountNumber: accountNumber)
        } catch {
            bridgeError = error
        }

        do {
            return try await httpClient.fetchDevices(accountNumber: accountNumber)
        } catch {
            if let bridgeError {
                throw bridgeError
            }
            throw error
        }
    }

    public func fetchDeviceDetails(accountNumber: String, deviceID: String) async throws -> DiscoveredDevice {
        var bridgeError: Error?
        do {
            return try await bridgeClient.fetchDeviceDetails(accountNumber: accountNumber, deviceID: deviceID)
        } catch {
            bridgeError = error
        }

        do {
            return try await httpClient.fetchDeviceDetails(accountNumber: accountNumber, deviceID: deviceID)
        } catch {
            if let bridgeError {
                throw bridgeError
            }
            throw error
        }
    }

    public func renameDevice(accountNumber: String, deviceID: String, newName: String) async -> CoreRenameResult {
        let bridgeResult = await bridgeClient.renameDevice(accountNumber: accountNumber, deviceID: deviceID, newName: newName)
        if bridgeResult.didRename {
            return bridgeResult
        }

        let httpResult = await httpClient.renameDevice(accountNumber: accountNumber, deviceID: deviceID, newName: newName)
        if httpResult.didRename || bridgeResult.warning.isEmpty {
            return httpResult
        }

        return CoreRenameResult(
            requestedName: newName,
            didRename: false,
            warning: [bridgeResult.warning, httpResult.warning].filter { !$0.isEmpty }.joined(separator: " ")
        )
    }

    public func discoverEnvironmentSession(includeSecret: Bool) async throws -> EnvironmentCoreSession? {
        try await bridgeClient.discoverEnvironmentSession(includeSecret: includeSecret)
    }
}

private struct BridgeInventoryPayload: Decodable {
    let devices: [BridgeDevice]
}

private struct BridgeDevicePayload: Decodable {
    let device: BridgeDevice
}

private struct BridgeSessionPayload: Decodable {
    let authenticated: Bool
    let username: String
    let headerName: String
    let source: String
    let expiresAt: String?
    let secret: String?

    enum CodingKeys: String, CodingKey {
        case authenticated
        case username
        case headerName = "header_name"
        case source
        case expiresAt = "expires_at"
        case secret
    }
}

private struct BridgeDevice: Decodable {
    let id: String
    let accountNumber: String
    let name: String
    let primaryIP: String
    let privateIP: String
    let platformName: String?
    let osType: String?
    let serviceLevel: String?
    let serviceTag: String
    let memoryGiB: Int?
    let storageGiB: Int?
    let installDisk: String
    let networkInterfaces: [BridgeNetworkInterface]
    let oob: BridgeOOBEndpoint?
    let credentialReference: String

    enum CodingKeys: String, CodingKey {
        case id
        case accountNumber = "account_number"
        case name
        case primaryIP = "primary_ip"
        case privateIP = "private_ip"
        case platformName = "platform_name"
        case osType = "os_type"
        case serviceLevel = "service_level"
        case serviceTag = "service_tag"
        case memoryGiB = "memory_gib"
        case storageGiB = "storage_gib"
        case installDisk = "install_disk"
        case networkInterfaces = "network_interfaces"
        case oob
        case credentialReference = "credential_reference"
    }

    var discoveredDevice: DiscoveredDevice {
        DiscoveredDevice(
            id: id,
            accountNumber: accountNumber,
            name: name,
            primaryIP: primaryIP,
            privateIP: privateIP,
            platformName: platformName ?? "",
            osType: osType ?? "",
            serviceLevel: serviceLevel ?? "",
            serviceTag: serviceTag,
            memoryGiB: memoryGiB,
            storageGiB: storageGiB,
            installDisk: installDisk,
            networkInterfaces: networkInterfaces.map(\.networkInterface),
            oob: oob?.endpoint,
            credentialReference: credentialReference
        )
    }
}

private struct BridgeNetworkInterface: Decodable {
    let name: String
    let addresses: [String]
    let macAddress: String
    let vlanID: Int?
    let mtu: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case addresses
        case macAddress = "mac_address"
        case vlanID = "vlan_id"
        case mtu
    }

    var networkInterface: NetworkInterface {
        NetworkInterface(
            name: name,
            addresses: addresses,
            macAddress: macAddress,
            vlanID: vlanID,
            mtu: mtu
        )
    }
}

private struct BridgeOOBEndpoint: Decodable {
    let vendor: OOBVendor
    let address: String
    let username: String
    let credentialReference: String
    let supportsVirtualMedia: Bool?
    let supportsPXE: Bool?

    enum CodingKeys: String, CodingKey {
        case vendor
        case address
        case username
        case credentialReference = "credential_reference"
        case supportsVirtualMedia = "supports_virtual_media"
        case supportsPXE = "supports_pxe"
    }

    var endpoint: OOBEndpoint {
        OOBEndpoint(
            vendor: vendor,
            address: address,
            username: username,
            credentialReference: credentialReference,
            supportsVirtualMedia: supportsVirtualMedia,
            supportsPXE: supportsPXE
        )
    }
}
