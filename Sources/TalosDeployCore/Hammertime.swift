import Foundation

public protocol HammertimeAdapter: Sendable {
    func inventory(accountNumber: String) async throws -> [DiscoveredDevice]
    func refreshLiveFacts(devices: [DiscoveredDevice], groups: [String]) async -> [String: Result<LiveFactSnapshot, Error>]
    func establishProxy(profile: AccessProfile, targetDeviceID: String?) async throws -> CommandResult
    func openOOB(deviceID: String, via: String?) async throws -> CommandResult
}

public final class DefaultHammertimeAdapter: HammertimeAdapter, @unchecked Sendable {
    private let settings: HammertimeSettings
    private let runner: CommandRunning

    public init(settings: HammertimeSettings, runner: CommandRunning = LocalCommandRunner()) {
        self.settings = settings
        self.runner = runner
    }

    public func inventory(accountNumber: String) async throws -> [DiscoveredDevice] {
        let attributes = [
            "name",
            "device_id",
            "primary_ip",
            "private_ip",
            "drac_ip",
            "drac_user",
            "drac_json",
            "networks",
            "account_num",
            "platform_name",
            "os_type",
            "service_level",
        ].joined(separator: ",")
        let result = try await runner.run(
            settings.binaryPath.expandingTildeInPath(),
            arguments: commonArguments(prefix: ["--core-account", accountNumber]) + [
                "info",
                "--format", "json",
                "--attributes", attributes,
            ],
            environment: [:],
            currentDirectory: nil,
            timeout: TimeInterval(settings.timeoutSeconds)
        )
        return try parseInventory(stdout: result.stdout, accountNumber: accountNumber)
    }

    public func refreshLiveFacts(devices: [DiscoveredDevice], groups: [String]) async -> [String: Result<LiveFactSnapshot, Error>] {
        guard settings.enabled else {
            return Dictionary(uniqueKeysWithValues: devices.map { ($0.id, .failure(HammertimeError.disabled)) })
        }
        guard !devices.isEmpty else { return [:] }
        let resolvedGroups = normalizeFactGroups(groups)
        do {
            let result = try await runner.run(
                settings.binaryPath.expandingTildeInPath(),
                arguments: commonArguments() + [
                    "raxfacts",
                    "--groups", resolvedGroups.joined(separator: ","),
                    "--format", "json",
                ] + devices.map(\.name),
                environment: [:],
                currentDirectory: nil,
                timeout: TimeInterval(settings.timeoutSeconds)
            )
            return try parseFacts(stdout: result.stdout, devices: devices)
        } catch {
            return Dictionary(uniqueKeysWithValues: devices.map { ($0.id, .failure(error)) })
        }
    }

    public func establishProxy(profile: AccessProfile, targetDeviceID: String?) async throws -> CommandResult {
        var arguments = commonArguments() + ["proxy"]
        if !profile.hammertimeVia.isEmpty {
            arguments.append(contentsOf: ["--via", profile.hammertimeVia])
        }
        if let targetDeviceID, !targetDeviceID.isEmpty {
            arguments.append(targetDeviceID)
        }
        return try await runner.run(
            settings.binaryPath.expandingTildeInPath(),
            arguments: arguments,
            environment: [:],
            currentDirectory: nil
        )
    }

    public func openOOB(deviceID: String, via: String?) async throws -> CommandResult {
        var arguments = commonArguments() + ["oobm"]
        if let via, !via.isEmpty {
            arguments.append(contentsOf: ["--proxy-via", via])
        }
        arguments.append(deviceID)
        return try await runner.run(
            settings.binaryPath.expandingTildeInPath(),
            arguments: arguments,
            environment: [:],
            currentDirectory: nil
        )
    }

    private func parseInventory(stdout: String, accountNumber: String) throws -> [DiscoveredDevice] {
        guard let data = stdout.data(using: .utf8) else {
            throw HammertimeError.invalidOutput
        }
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [[String: Any]] {
            return array.map { mapInventoryDevice($0, accountNumber: accountNumber) }
        }
        if let dictionary = object as? [String: Any] {
            if let items = dictionary["results"] as? [[String: Any]] {
                return items.map { mapInventoryDevice($0, accountNumber: accountNumber) }
            }
            if dictionary["device_id"] != nil || dictionary["device"] != nil {
                return [mapInventoryDevice(dictionary, accountNumber: accountNumber)]
            }
        }
        throw HammertimeError.invalidOutput
    }

    private func mapInventoryDevice(_ value: [String: Any], accountNumber: String) -> DiscoveredDevice {
        let deviceID = stringify(value["device_id"] ?? value["server"] ?? UUID().uuidString)
        let oobAddress = stringify(value["drac_ip"])
        let oob = oobAddress.isEmpty ? nil : OOBEndpoint(
            vendor: .redfish,
            address: oobAddress,
            username: stringify(value["drac_user"]),
            credentialReference: ""
        )
        let interfaces: [NetworkInterface]
        if let networks = value["networks"] as? [[String: Any]] {
            interfaces = networks.map {
                NetworkInterface(
                    name: stringify($0["name"] ?? $0["device"] ?? "eth0"),
                    addresses: stringArray($0["addresses"] ?? $0["ips"]),
                    macAddress: stringify($0["mac"] ?? $0["mac_address"])
                )
            }
        } else {
            interfaces = []
        }
        return DiscoveredDevice(
            id: deviceID,
            accountNumber: stringify(value["account_num"] ?? accountNumber),
            name: stringify(value["name"] ?? value["device"] ?? deviceID),
            primaryIP: stringify(value["primary_ip"]),
            privateIP: stringify(value["private_ip"]),
            platformName: stringify(value["platform_name"] ?? value["platform"]),
            osType: stringify(value["os_type"]),
            serviceLevel: stringify(value["service_level"]),
            serviceTag: "",
            networkInterfaces: interfaces,
            oob: oob
        )
    }

    private func parseFacts(stdout: String, devices: [DiscoveredDevice]) throws -> [String: Result<LiveFactSnapshot, Error>] {
        guard let data = stdout.data(using: .utf8) else {
            throw HammertimeError.invalidOutput
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw HammertimeError.invalidOutput
        }

        var results: [String: Result<LiveFactSnapshot, Error>] = [:]
        for device in devices {
            if let item = dictionary[device.name] as? [String: Any] ?? dictionary[device.id] as? [String: Any] {
                let storageDevices = (item["storage_devices"] as? [[String: Any]] ?? []).map {
                    StorageDevice(name: stringify($0["name"] ?? $0["device"]), sizeGiB: integer($0["size_gib"] ?? $0["size"]))
                }
                let attributes = item.reduce(into: [String: String]()) { partialResult, pair in
                    partialResult[pair.key] = stringify(pair.value)
                }
                let snapshot = LiveFactSnapshot(
                    fetchedAt: .now,
                    osDescription: stringify(item["os"] ?? item["os_description"]),
                    memoryGiB: integer(item["memory_gib"] ?? item["memory"]),
                    storageDevices: storageDevices,
                    attributes: attributes
                )
                results[device.id] = .success(snapshot)
            } else {
                results[device.id] = .failure(HammertimeError.missingFacts(device.name))
            }
        }
        return results
    }

    private func normalizeFactGroups(_ groups: [String]) -> [String] {
        let aliases: [String: String] = [
            "networking": "routes",
            "network": "routes",
            "os": "setup",
        ]

        var resolved: [String] = []
        for group in groups {
            let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = aliases[trimmed.lowercased()] ?? trimmed
            if !resolved.contains(normalized) {
                resolved.append(normalized)
            }
        }
        return resolved.isEmpty ? ["hardware", "storage", "setup", "routes"] : resolved
    }

    private func commonArguments(prefix: [String] = []) -> [String] {
        var arguments = ["--batch", "--no-colors"]
        if settings.skipDeviceChecks {
            arguments.append("--no-checks")
        }
        arguments.append(contentsOf: prefix)
        return arguments
    }
}

public enum HammertimeError: Error, LocalizedError {
    case disabled
    case invalidOutput
    case missingFacts(String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Hammertime integration is disabled."
        case .invalidOutput:
            return "Unexpected hammertime output."
        case .missingFacts(let name):
            return "No live facts were returned for \(name)."
        }
    }
}
