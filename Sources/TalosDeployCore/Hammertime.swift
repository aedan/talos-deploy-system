import Foundation

public protocol HammertimeAdapter: Sendable {
    func inventory(accountNumber: String) async throws -> [DiscoveredDevice]
    func refreshLiveFacts(devices: [DiscoveredDevice], groups: [String]) async -> [String: Result<LiveFactSnapshot, Error>]
    func establishProxy(profile: AccessProfile, targetDeviceID: String?) async throws -> CommandResult
    func openOOB(deviceID: String, via: String?) async throws -> CommandResult
}

public final class DefaultHammertimeAdapter: HammertimeAdapter {
    /// Safety: The class is immutable after init. No mutable state is accessed concurrently.
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
            timeout: TimeInterval(max(settings.timeoutSeconds, 90))
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
            let keyedDevices = dictionary.compactMap { key, value -> DiscoveredDevice? in
                guard let device = value as? [String: Any],
                      device["name"] != nil || device["device_id"] != nil || device["device"] != nil
                else { return nil }
                return mapInventoryDevice(device, accountNumber: accountNumber, fallbackID: key)
            }
            if !keyedDevices.isEmpty {
                return keyedDevices.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            }
        }
        throw HammertimeError.invalidOutput
    }

    private func mapInventoryDevice(_ value: [String: Any], accountNumber: String, fallbackID: String? = nil) -> DiscoveredDevice {
        let rawDeviceID = firstNonEmpty(
            cleanHammertimeString(value["device_id"]),
            cleanHammertimeString(value["server"]),
            fallbackID ?? ""
        )
        let deviceID = normalizeDeviceID(rawDeviceID, fallbackID: fallbackID)
        let oobAddress = cleanHammertimeString(value["drac_ip"])
        let oob = oobAddress.isEmpty ? nil : OOBEndpoint(
            vendor: .redfish,
            address: oobAddress,
            username: cleanHammertimeString(value["drac_user"]),
            credentialReference: ""
        )
        let interfaces: [NetworkInterface]
        if let networks = hammertimeAttributeValue(value["networks"]) as? [[String: Any]] {
            interfaces = networks.map(mapInventoryNetwork)
        } else {
            interfaces = []
        }
        return DiscoveredDevice(
            id: deviceID,
            accountNumber: firstNonEmpty(cleanHammertimeString(value["account_num"]), accountNumber),
            name: firstNonEmpty(cleanHammertimeString(value["name"]), cleanHammertimeString(value["device"]), deviceID),
            primaryIP: cleanHammertimeString(value["primary_ip"]),
            privateIP: cleanHammertimeString(value["private_ip"]),
            platformName: firstNonEmpty(cleanHammertimeString(value["platform_name"]), cleanHammertimeString(value["platform"])),
            osType: cleanHammertimeString(value["os_type"]),
            serviceLevel: cleanHammertimeString(value["service_level"]),
            serviceTag: "",
            networkInterfaces: interfaces,
            oob: oob
        )
    }

    private func mapInventoryNetwork(_ value: [String: Any]) -> NetworkInterface {
        let ipAddress = cleanHammertimeString(value["ip_address"])
        let cidr = cleanHammertimeString(value["ip_block_cidr"])
        var addresses = stringArray(hammertimeAttributeValue(value["addresses"] ?? value["ips"]))
            .map { cleanHammertimeLiteral($0) }
            .filter { !$0.isEmpty }
        if !ipAddress.isEmpty {
            let address = cidrPrefix(from: cidr).map { "\(ipAddress)/\($0)" } ?? ipAddress
            if !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return NetworkInterface(
            name: firstNonEmpty(
                cleanHammertimeString(value["name"]),
                cleanHammertimeString(value["device"]),
                cleanHammertimeString(value["label"]),
                cleanHammertimeString(value["network_type"]),
                cleanHammertimeString(value["network_name"]),
                "eth0"
            ),
            addresses: addresses,
            macAddress: firstNonEmpty(cleanHammertimeString(value["mac"]), cleanHammertimeString(value["mac_address"])),
            vlanID: integer(hammertimeAttributeValue(value["vlan_number"] ?? value["vlanID"])),
            mtu: integer(hammertimeAttributeValue(value["mtu"]))
        )
    }

    private func hammertimeAttributeValue(_ value: Any?) -> Any? {
        if let dictionary = value as? [String: Any],
           dictionary.keys.contains("value")
        {
            return dictionary["value"]
        }
        return value
    }

    private func cleanHammertimeString(_ value: Any?) -> String {
        cleanHammertimeLiteral(stringify(hammertimeAttributeValue(value)))
    }

    private func cleanHammertimeLiteral(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("none") == .orderedSame || trimmed.caseInsensitiveCompare("null") == .orderedSame {
            return ""
        }
        return trimmed
    }

    private func normalizeDeviceID(_ value: String, fallbackID: String?) -> String {
        let candidate = firstNonEmpty(value, fallbackID ?? "")
        if let firstToken = candidate.split(whereSeparator: \.isWhitespace).first,
           firstToken.allSatisfy(\.isNumber)
        {
            return String(firstToken)
        }
        let numericPrefix = candidate.prefix(while: \.isNumber)
        if !numericPrefix.isEmpty {
            return String(numericPrefix)
        }
        return candidate.isEmpty ? UUID().uuidString : candidate
    }

    private func cidrPrefix(from cidr: String) -> String? {
        guard let slash = cidr.lastIndex(of: "/") else { return nil }
        let prefix = cidr[cidr.index(after: slash)...]
        return prefix.isEmpty ? nil : String(prefix)
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
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

public struct OOBBootURLRequest: Codable, Equatable, Sendable {
    public var deviceID: String
    public var imageURL: String
    public var connectMedia: Bool
    public var bootOnce: Bool
    public var oneTimeBoot: String?
    public var reboot: Bool
    public var proxyVia: String?
    public var oobVendor: OOBVendor
    public var preferPowerReset: Bool

    public init(
        deviceID: String,
        imageURL: String,
        connectMedia: Bool = true,
        bootOnce: Bool = true,
        oneTimeBoot: String? = nil,
        reboot: Bool = false,
        proxyVia: String? = nil,
        oobVendor: OOBVendor = .unknown,
        preferPowerReset: Bool = false
    ) {
        self.deviceID = deviceID
        self.imageURL = imageURL
        self.connectMedia = connectMedia
        self.bootOnce = bootOnce
        self.oneTimeBoot = oneTimeBoot
        self.reboot = reboot
        self.proxyVia = proxyVia
        self.oobVendor = oobVendor
        self.preferPowerReset = preferPowerReset
    }
}

public struct OOBBootURLStep: Codable, Equatable, Sendable {
    public var name: String
    public var stdout: String

    public init(name: String, stdout: String) {
        self.name = name
        self.stdout = stdout
    }
}

public struct OOBBootURLResult: Codable, Equatable, Sendable {
    public var deviceID: String
    public var imageURL: String
    public var connected: Bool
    public var bootOnce: Bool
    public var rebooted: Bool
    public var steps: [OOBBootURLStep]

    public init(
        deviceID: String,
        imageURL: String,
        connected: Bool,
        bootOnce: Bool,
        rebooted: Bool,
        steps: [OOBBootURLStep]
    ) {
        self.deviceID = deviceID
        self.imageURL = imageURL
        self.connected = connected
        self.bootOnce = bootOnce
        self.rebooted = rebooted
        self.steps = steps
    }
}

public struct OOBPXEBootRequest: Codable, Equatable, Sendable {
    public var deviceID: String
    public var oneTimeBoot: String
    public var reboot: Bool
    public var proxyVia: String?

    public init(deviceID: String, oneTimeBoot: String = "pxe", reboot: Bool = true, proxyVia: String? = nil) {
        self.deviceID = deviceID
        self.oneTimeBoot = oneTimeBoot
        self.reboot = reboot
        self.proxyVia = proxyVia
    }
}

public struct OOBPXEBootResult: Codable, Equatable, Sendable {
    public var deviceID: String
    public var oneTimeBoot: String
    public var rebooted: Bool
    public var steps: [OOBBootURLStep]

    public init(deviceID: String, oneTimeBoot: String, rebooted: Bool, steps: [OOBBootURLStep]) {
        self.deviceID = deviceID
        self.oneTimeBoot = oneTimeBoot
        self.rebooted = rebooted
        self.steps = steps
    }
}

public struct OOBDiskBootRequest: Codable, Equatable, Sendable {
    public var deviceID: String
    public var reboot: Bool
    public var proxyVia: String?
    public var oobVendor: OOBVendor
    public var preferPowerReset: Bool

    public init(
        deviceID: String,
        reboot: Bool = false,
        proxyVia: String? = nil,
        oobVendor: OOBVendor = .unknown,
        preferPowerReset: Bool = false
    ) {
        self.deviceID = deviceID
        self.reboot = reboot
        self.proxyVia = proxyVia
        self.oobVendor = oobVendor
        self.preferPowerReset = preferPowerReset
    }
}

public struct OOBDiskBootResult: Codable, Equatable, Sendable {
    public var deviceID: String
    public var diskBootSource: String
    public var rebooted: Bool
    public var steps: [OOBBootURLStep]

    public init(deviceID: String, diskBootSource: String, rebooted: Bool, steps: [OOBBootURLStep]) {
        self.deviceID = deviceID
        self.diskBootSource = diskBootSource
        self.rebooted = rebooted
        self.steps = steps
    }
}

public protocol OOBNodeBooting: Sendable {
    func bootURL(_ request: OOBBootURLRequest) async throws -> OOBBootURLResult
    func bootPXE(_ request: OOBPXEBootRequest) async throws -> OOBPXEBootResult
    func prepareDiskBoot(_ request: OOBDiskBootRequest) async throws -> OOBDiskBootResult
}

public final class HammertimeOOBBooter: OOBNodeBooting {
    /// Safety: The class is immutable after init. No mutable state is accessed concurrently.
    private let settings: HammertimeSettings
    private let runner: CommandRunning
    private let clpResetDelayNanoseconds: UInt64
    private let clpPowerOffDelayNanoseconds: UInt64
    private let clpPowerOnDelayNanoseconds: UInt64

    public init(
        settings: HammertimeSettings = HammertimeSettings(),
        runner: CommandRunning = LocalCommandRunner(),
        clpResetDelayNanoseconds: UInt64 = 90_000_000_000,
        clpPowerOffDelayNanoseconds: UInt64 = 20_000_000_000,
        clpPowerOnDelayNanoseconds: UInt64 = 15_000_000_000
    ) {
        self.settings = settings
        self.runner = runner
        self.clpResetDelayNanoseconds = clpResetDelayNanoseconds
        self.clpPowerOffDelayNanoseconds = clpPowerOffDelayNanoseconds
        self.clpPowerOnDelayNanoseconds = clpPowerOnDelayNanoseconds
    }

    public func bootURL(_ request: OOBBootURLRequest) async throws -> OOBBootURLResult {
        guard !request.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HammertimeError.missingDeviceID
        }
        guard !request.imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HammertimeError.missingImageURL
        }

        var steps: [OOBBootURLStep] = []
        steps.append(try await runOOBCommand(name: "insert-url", command: "vm cdrom insert \(request.imageURL)", request: request))
        if request.connectMedia {
            steps.append(try await runOOBCommand(name: "connect-media", command: "vm cdrom set connect", request: request))
        }
        let bootSource = await discoverCDBootSource(request: request, steps: &steps)
        steps.append(await runBestEffortOOBCommand(name: "cd-boot-order", command: "set \(bootSource) bootorder=1", request: request))
        if request.bootOnce {
            steps.append(try await runOOBCommand(name: "boot-once", command: "vm cdrom set boot_once", request: request))
        }
        if let oneTimeBoot = request.oneTimeBoot, !oneTimeBoot.isEmpty {
            steps.append(try await runOOBCommand(name: "one-time-boot", command: "onetimeboot \(oneTimeBoot)", request: request))
        }
        steps.append(try await runOOBCommand(name: "media-status", command: "vm cdrom get", request: request))
        if request.reboot {
            steps.append(contentsOf: try await rebootSteps(for: request))
            steps.append(await runBestEffortOOBCommand(name: "post-boot-media-status", command: "vm cdrom get", request: request))
        }

        let status = steps.last(where: { $0.name == "post-boot-media-status" })?.stdout
            ?? steps.last(where: { $0.name == "post-reset-media-status" })?.stdout
            ?? steps.last(where: { $0.name == "media-status" })?.stdout
            ?? ""
        return OOBBootURLResult(
            deviceID: request.deviceID,
            imageURL: request.imageURL,
            connected: status.localizedCaseInsensitiveContains("Image Connected = Yes"),
            bootOnce: status.localizedCaseInsensitiveContains("Boot Option = BOOT_ONCE"),
            rebooted: request.reboot,
            steps: steps
        )
    }

    private func discoverCDBootSource(request: OOBBootURLRequest, steps: inout [OOBBootURLStep]) async -> String {
        let fallback = "/system1/bootconfig1/bootsource1"
        let bootSources = await runBestEffortOOBCommand(name: "boot-sources", command: "show /system1/bootconfig1", request: request)
        steps.append(bootSources)

        for target in parseBootSourceTargets(from: bootSources.stdout) {
            let detail = await runBestEffortOOBCommand(
                name: "boot-source-\(target)",
                command: "show /system1/bootconfig1/\(target)",
                request: request
            )
            steps.append(detail)
            if isCDBootSource(detail.stdout) {
                return "/system1/bootconfig1/\(target)"
            }
        }

        return fallback
    }

    private func discoverDiskBootSource(request: OOBBootURLRequest, steps: inout [OOBBootURLStep]) async -> String {
        let fallback = "/system1/bootconfig1/bootsource2"
        let bootSources = await runBestEffortOOBCommand(name: "boot-sources", command: "show /system1/bootconfig1", request: request)
        steps.append(bootSources)

        for target in parseBootSourceTargets(from: bootSources.stdout) {
            let detail = await runBestEffortOOBCommand(
                name: "boot-source-\(target)",
                command: "show /system1/bootconfig1/\(target)",
                request: request
            )
            steps.append(detail)
            if isDiskBootSource(detail.stdout) {
                return "/system1/bootconfig1/\(target)"
            }
        }

        return fallback
    }

    private func parseBootSourceTargets(from output: String) -> [String] {
        let targets = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("bootsource") || trimmed.hasPrefix("oemhp_uefibootsource") else { return nil }
                return trimmed.split(separator: " ").first.map(String.init)
            }
        return targets
    }

    private func isCDBootSource(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("bootdevice=bootfmcd")
            || normalized.contains("bootdevice=cd")
            || normalized.contains("cd/dvd")
            || normalized.contains("dvd")
            || normalized.contains("cdrom")
            || normalized.contains("virtual usb")
            || normalized.contains("virtual cd")
    }

    private func isDiskBootSource(_ output: String) -> Bool {
        let normalized = output.lowercased()
        let excluded = [
            "bootfmcd",
            "cd/dvd",
            "dvd",
            "cdrom",
            "virtual usb",
            "virtual cd",
            "bootfmnetwork",
            "network",
            "pxe",
            "floppy",
        ]
        guard excluded.allSatisfy({ !normalized.contains($0) }) else { return false }
        return normalized.contains("bootdevice=bootfmhdd")
            || normalized.contains("bootdevice=bootfmdisk")
            || normalized.contains("bootdevice=hdd")
            || normalized.contains("bootdevice=disk")
            || normalized.contains("hard drive")
            || normalized.contains("hard disk")
            || normalized.contains("local disk")
            || normalized.contains("logical drive")
            || normalized.contains("smart array")
    }

    public func bootPXE(_ request: OOBPXEBootRequest) async throws -> OOBPXEBootResult {
        guard !request.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HammertimeError.missingDeviceID
        }

        var steps: [OOBBootURLStep] = []
        steps.append(try await runOOBCommand(name: "one-time-pxe", command: "onetimeboot \(request.oneTimeBoot)", request: request.asURLRequest()))
        if request.reboot {
            steps.append(contentsOf: try await rebootSteps(for: request.asURLRequest()))
        }
        return OOBPXEBootResult(
            deviceID: request.deviceID,
            oneTimeBoot: request.oneTimeBoot,
            rebooted: request.reboot,
            steps: steps
        )
    }

    public func prepareDiskBoot(_ request: OOBDiskBootRequest) async throws -> OOBDiskBootResult {
        guard !request.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HammertimeError.missingDeviceID
        }

        let urlRequest = request.asURLRequest()
        var steps: [OOBBootURLStep] = []
        steps.append(await runBestEffortOOBCommand(name: "media-no-boot", command: "vm cdrom set no_boot", request: urlRequest))
        steps.append(await runBestEffortOOBCommand(name: "disconnect-media", command: "vm cdrom set disconnect", request: urlRequest))
        steps.append(await runBestEffortOOBCommand(name: "eject-media", command: "vm cdrom eject", request: urlRequest))
        let bootSource = await discoverDiskBootSource(request: urlRequest, steps: &steps)
        steps.append(try await runOOBCommand(name: "disk-boot-order", command: "set \(bootSource) bootorder=1", request: urlRequest))
        steps.append(await runBestEffortOOBCommand(name: "media-status", command: "vm cdrom get", request: urlRequest))
        if request.reboot {
            steps.append(contentsOf: try await rebootSteps(for: urlRequest))
        }

        return OOBDiskBootResult(
            deviceID: request.deviceID,
            diskBootSource: bootSource,
            rebooted: request.reboot,
            steps: steps
        )
    }

    private func runOOBCommand(name: String, command: String, request: OOBBootURLRequest) async throws -> OOBBootURLStep {
        tdsProgress("OOB \(request.deviceID) \(name): \(command)")
        var arguments = ["--batch", "--no-colors"]
        if settings.skipDeviceChecks {
            arguments.append("--no-checks")
        }
        arguments.append("oobm")
        if let proxyVia = request.proxyVia, !proxyVia.isEmpty {
            arguments.append(contentsOf: ["--proxy-via", proxyVia])
        }
        arguments.append(contentsOf: ["--command", command, request.deviceID])
        let result = try await runner.run(
            settings.binaryPath.expandingTildeInPath(),
            arguments: arguments,
            environment: [:],
            currentDirectory: nil,
            timeout: TimeInterval(max(settings.timeoutSeconds, 120))
        )
        tdsProgress("OOB \(request.deviceID) \(name) completed")
        return OOBBootURLStep(name: name, stdout: result.stdout)
    }

    private func rebootSteps(for request: OOBBootURLRequest) async throws -> [OOBBootURLStep] {
        var steps: [OOBBootURLStep] = []
        if request.preferPowerReset {
            steps.append(try await runOOBCommand(name: "power-reset", command: "power reset", request: request))
            tdsProgress("OOB \(request.deviceID) waiting after power reset")
            await sleepIfNeeded(clpResetDelayNanoseconds)
            return steps
        }
        steps.append(await runBestEffortOOBCommand(name: "clp-power-off", command: "stop /system1", request: request))
        tdsProgress("OOB \(request.deviceID) waiting after power off")
        await sleepIfNeeded(clpPowerOffDelayNanoseconds)
        steps.append(await runBestEffortOOBCommand(name: "clp-power-on", command: "start /system1", request: request))
        tdsProgress("OOB \(request.deviceID) waiting after power on")
        await sleepIfNeeded(clpPowerOnDelayNanoseconds)
        if steps.allSatisfy({ $0.stdout.contains("Best-effort OOB command failed") }) {
            steps.append(try await runOOBCommand(name: "power-reset", command: "power reset", request: request))
        }
        return steps
    }

    private func sleepIfNeeded(_ nanoseconds: UInt64) async {
        guard nanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func runBestEffortOOBCommand(name: String, command: String, request: OOBBootURLRequest) async -> OOBBootURLStep {
        do {
            return try await runOOBCommand(name: name, command: command, request: request)
        } catch {
            let message = "Best-effort OOB command failed: \(error.localizedDescription)"
            tdsProgress("OOB \(request.deviceID) \(name) warning: \(message)")
            return OOBBootURLStep(name: name, stdout: message)
        }
    }
}

private extension OOBPXEBootRequest {
    func asURLRequest() -> OOBBootURLRequest {
        OOBBootURLRequest(
            deviceID: deviceID,
            imageURL: "pxe",
            connectMedia: false,
            bootOnce: false,
            oneTimeBoot: oneTimeBoot,
            reboot: reboot,
            proxyVia: proxyVia,
            oobVendor: .unknown,
            preferPowerReset: false
        )
    }
}

private extension OOBDiskBootRequest {
    func asURLRequest() -> OOBBootURLRequest {
        OOBBootURLRequest(
            deviceID: deviceID,
            imageURL: "disk",
            connectMedia: false,
            bootOnce: false,
            reboot: reboot,
            proxyVia: proxyVia,
            oobVendor: oobVendor,
            preferPowerReset: preferPowerReset
        )
    }
}

public enum HammertimeError: Error, LocalizedError {
    case disabled
    case invalidOutput
    case missingFacts(String)
    case missingDeviceID
    case missingImageURL

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Hammertime integration is disabled."
        case .invalidOutput:
            return "Unexpected hammertime output."
        case .missingFacts(let name):
            return "No live facts were returned for \(name)."
        case .missingDeviceID:
            return "OOB boot requires --device DEVICE_ID."
        case .missingImageURL:
            return "OOB boot requires --url IMAGE_URL."
        }
    }
}
