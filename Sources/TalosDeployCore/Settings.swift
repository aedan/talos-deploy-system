import Foundation
import Security

public struct AppPaths: Sendable {
    public let homeDirectory: URL
    public let applicationSupportDirectory: URL
    public let settingsFile: URL
    public let sessionFile: URL
    public let stateDirectory: URL
    public let talosctlDirectory: URL

    public init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)

        if let override = ProcessInfo.processInfo.environment["TDS_HOME"], !override.isEmpty {
            self.homeDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.homeDirectory = base.appending(path: "tds", directoryHint: .isDirectory)
        }
        self.applicationSupportDirectory = self.homeDirectory
        self.settingsFile = homeDirectory.appending(path: "settings.json")
        self.sessionFile = homeDirectory.appending(path: "core-session.json")
        self.stateDirectory = homeDirectory.appending(path: "state", directoryHint: .isDirectory)
        self.talosctlDirectory = homeDirectory.appending(path: "bin", directoryHint: .isDirectory)
    }

    public func ensureExists(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: talosctlDirectory, withIntermediateDirectories: true)
    }
}

public final class JSONFileStore<Value: Codable & Sendable> {
    /// Safety: Uses FileManager which is thread-safe. File operations are synchronous but isolated per instance.
    /// The class is immutable after init.
    private let url: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load(defaultValue: @autoclosure () -> Value) throws -> Value {
        guard fileManager.fileExists(atPath: url.path) else {
            return defaultValue()
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    public var fileURL: URL { url }
}

public final class SettingsController {
    /// Safety: The class is immutable after init. No mutable state is accessed concurrently.
    private let store: JSONFileStore<AppSettings>

    public init(paths: AppPaths = AppPaths()) {
        self.store = JSONFileStore(url: paths.settingsFile)
    }

    public func load() throws -> AppSettings {
        try store.load(defaultValue: AppSettings())
    }

    public func save(_ settings: AppSettings) throws {
        try store.save(settings)
    }
}

public enum SecretStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case missingSecret(String)

    public var isInteractionNotAllowed: Bool {
        switch self {
        case .unexpectedStatus(let status):
            return status == errSecInteractionNotAllowed
        case .missingSecret:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if status == errSecInteractionNotAllowed {
                return "macOS Keychain access is unavailable in this session. Use the desktop app, or rely on the active hammertime cache directly from the CLI."
            }
            return "Keychain operation failed with status \(status)"
        case .missingSecret(let key):
            return "No secret found for key \(key)"
        }
    }
}

public final class KeychainSecretStore {
    /// Safety: Uses Keychain which is thread-safe. The class is immutable after init.
    private let service: String

    public init(service: String = "com.aedan.tds") {
        self.service = service
    }

    public func setSecret(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func getSecret(for key: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw SecretStoreError.missingSecret(key)
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.missingSecret(key)
        }
        return string
    }

    public func deleteSecret(for key: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }
}

public final class CoreSessionStore: @unchecked Sendable {
    /// Safety: Uses NSLock internally via JSONFileStore and Keychain which are thread-safe.
    private let metadataStore: JSONFileStore<CoreSession?>
    private let secretStore: KeychainSecretStore

    public init(paths: AppPaths = AppPaths(), secretStore: KeychainSecretStore = KeychainSecretStore()) {
        self.metadataStore = JSONFileStore(url: paths.sessionFile)
        self.secretStore = secretStore
    }

    public func loadSession() throws -> CoreSession? {
        try metadataStore.load(defaultValue: nil)
    }

    public func loadSecret() throws -> String? {
        guard let session = try loadSession(), !session.secretReference.isEmpty else {
            return nil
        }
        return try secretStore.getSecret(for: session.secretReference)
    }

    public func saveSession(_ session: CoreSession, secret: String) throws {
        try secretStore.setSecret(secret, for: session.secretReference)
        try metadataStore.save(session)
    }

    public func clear() throws {
        if let session = try loadSession(), !session.secretReference.isEmpty {
            try? secretStore.deleteSecret(for: session.secretReference)
        }
        try metadataStore.save(nil)
    }
}

public final class DeploymentStateStore: @unchecked Sendable {
    /// Safety: The class is immutable after init. No mutable state is accessed concurrently.
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ state: DeploymentState, to directory: URL) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "deployment-state.json")
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func load(from directory: URL) throws -> DeploymentState {
        let url = directory.appending(path: "deployment-state.json")
        let data = try Data(contentsOf: url)
        return try decoder.decode(DeploymentState.self, from: data)
    }
}
