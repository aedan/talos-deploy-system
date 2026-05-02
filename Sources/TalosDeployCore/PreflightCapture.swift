import Foundation

public enum PreinstallSnapshotError: Error, LocalizedError {
    case deviceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let selector):
            return "No device matching \(selector) was found in inventory."
        }
    }
}

public final class PreinstallSnapshotCapturer: @unchecked Sendable {
    private let settings: AppSettings
    private let coreClient: CoreClient
    private let hammertime: HammertimeAdapter
    private let runner: CommandRunning
    private let fileManager: FileManager

    public init(
        settings: AppSettings,
        coreClient: CoreClient,
        hammertime: HammertimeAdapter,
        runner: CommandRunning = LocalCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.coreClient = coreClient
        self.hammertime = hammertime
        self.runner = runner
        self.fileManager = fileManager
    }

    public func capture(
        accountNumber: String,
        deviceSelector: String,
        source: InventorySource = .auto,
        baseDirectory: URL
    ) async throws -> NetworkPreservationSnapshot {
        let device = try await resolveDevice(accountNumber: accountNumber, selector: deviceSelector, source: source)
        let captureDirectory = try makeCaptureDirectory(baseDirectory: baseDirectory, accountNumber: accountNumber, deviceID: device.id)

        let captures = await collectCaptures(accountNumber: accountNumber, device: device)
        let summary = summarize(device: device, captures: captures)

        let snapshot = NetworkPreservationSnapshot(
            accountNumber: accountNumber,
            device: device,
            summary: summary,
            captures: captures,
            directory: captureDirectory.path
        )

        try writeArtifacts(for: snapshot, to: captureDirectory)
        return snapshot
    }

    private func resolveDevice(accountNumber: String, selector: String, source: InventorySource) async throws -> DiscoveredDevice {
        let devices: [DiscoveredDevice]
        switch source {
        case .core:
            devices = try await coreClient.fetchDevices(accountNumber: accountNumber)
        case .hammertime:
            devices = try await hammertime.inventory(accountNumber: accountNumber)
        case .auto:
            do {
                devices = try await coreClient.fetchDevices(accountNumber: accountNumber)
            } catch {
                devices = try await hammertime.inventory(accountNumber: accountNumber)
            }
        }

        let normalizedSelector = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let device = devices.first(where: {
            $0.id.lowercased() == normalizedSelector || $0.name.lowercased() == normalizedSelector
        }) else {
            throw PreinstallSnapshotError.deviceNotFound(selector)
        }
        return device
    }

    private func collectCaptures(accountNumber: String, device: DiscoveredDevice) async -> [CommandCapture] {
        var captures: [CommandCapture] = []
        let infoAttributes = [
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

        captures.append(
            await runCapture(
                label: "hammertime-info",
                executable: settings.hammertime.binaryPath.expandingTildeInPath(),
                arguments: commonArguments(prefix: ["--core-account", accountNumber]) + [
                    "info",
                    "--format", "json",
                    "--attributes", infoAttributes,
                    device.id,
                ]
            )
        )

        let factGroups = normalizeFactGroups(settings.hammertime.defaultFactGroups).joined(separator: ",")
        captures.append(
            await runCapture(
                label: "hammertime-raxfacts",
                executable: settings.hammertime.binaryPath.expandingTildeInPath(),
                arguments: commonArguments() + [
                    "raxfacts",
                    "--groups", factGroups,
                    "--format", "json",
                    device.name,
                ]
            )
        )

        for command in hostCaptureCommands {
            captures.append(
                await runCapture(
                    label: command.label,
                    executable: settings.hammertime.binaryPath.expandingTildeInPath(),
                    arguments: commonArguments() + [
                        "command",
                        "--format", "json",
                        "--command", command.command,
                        device.name,
                    ],
                    timeout: TimeInterval(max(settings.hammertime.timeoutSeconds, 120))
                )
            )
        }
        return captures
    }

    private func makeCaptureDirectory(baseDirectory: URL, accountNumber: String, deviceID: String) throws -> URL {
        let timestamp = Self.timestampFormatter.string(from: .now)
        let directory = baseDirectory
            .appending(path: "preinstall-snapshots", directoryHint: .isDirectory)
            .appending(path: accountNumber, directoryHint: .isDirectory)
            .appending(path: "\(deviceID)-\(timestamp)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeArtifacts(for snapshot: NetworkPreservationSnapshot, to directory: URL) throws {
        let encoder = JSONEncoder.pretty
        let snapshotData = try encoder.encode(snapshot)
        try snapshotData.write(to: directory.appending(path: "snapshot.json"), options: .atomic)
        try encoder.encode(snapshot.device).write(to: directory.appending(path: "device.json"), options: .atomic)
        try encoder.encode(snapshot.summary).write(to: directory.appending(path: "summary.json"), options: .atomic)

        let capturesDirectory = directory.appending(path: "captures", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)

        for capture in snapshot.captures {
            let baseName = sanitizeFileName(capture.label)
            try encoder.encode(capture).write(to: capturesDirectory.appending(path: "\(baseName).json"), options: .atomic)
            let rendered = renderCapture(capture)
            try rendered.write(
                to: capturesDirectory.appending(path: "\(baseName).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func runCapture(
        label: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async -> CommandCapture {
        do {
            let result = try await runner.run(
                executable,
                arguments: arguments,
                environment: [:],
                currentDirectory: nil,
                timeout: timeout
            )
            return CommandCapture(
                label: label,
                executable: result.executable,
                arguments: result.arguments,
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode
            )
        } catch let error as CommandError {
            switch error {
            case .executionFailed(let result):
                return CommandCapture(
                    label: label,
                    executable: result.executable,
                    arguments: result.arguments,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    exitCode: result.exitCode
                )
            case .timedOut(let executable, let arguments, let timeout):
                return CommandCapture(
                    label: label,
                    executable: executable,
                    arguments: arguments,
                    stdout: "",
                    stderr: "Timed out after \(Int(timeout)) seconds.",
                    exitCode: -1
                )
            }
        } catch {
            return CommandCapture(
                label: label,
                executable: executable,
                arguments: arguments,
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: -1
            )
        }
    }

    private func summarize(device: DiscoveredDevice, captures: [CommandCapture]) -> NetworkPreservationSummary {
        let hostnameText = stdout(for: "hostnamectl", in: captures)
        let interfaceText = stdout(for: "ip-brief-addresses", in: captures)
        let routeText = stdout(for: "ip-routes-all", in: captures)
        let resolverText = stdout(for: "resolver-state", in: captures)

        return NetworkPreservationSummary(
            hostname: match(firstGroupOf: #/Static hostname:\s+(.+)/#, in: hostnameText),
            osDescription: match(firstGroupOf: #/Operating System:\s+(.+)/#, in: hostnameText),
            primaryIP: device.primaryIP,
            privateIP: device.privateIP,
            oobIP: device.oob?.address ?? "",
            observedInterfaces: nonEmptyLines(in: interfaceText),
            observedRoutes: nonEmptyLines(in: routeText),
            dnsServers: resolverText
                .split(separator: "\n")
                .compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("nameserver ") else { return nil }
                    return String(trimmed.dropFirst("nameserver ".count))
                },
            searchDomains: extractSearchDomains(from: resolverText)
        )
    }

    private func stdout(for label: String, in captures: [CommandCapture]) -> String {
        captures.first(where: { $0.label == label })?.stdout ?? ""
    }

    private func match(firstGroupOf regex: Regex<(Substring, Substring)>, in value: String) -> String {
        guard let match = value.firstMatch(of: regex) else { return "" }
        return String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nonEmptyLines(in value: String) -> [String] {
        value
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func extractSearchDomains(from resolverText: String) -> [String] {
        resolverText
            .split(separator: "\n")
            .reduce(into: [String]()) { domains, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("search ") else { return }
                let values = trimmed.dropFirst("search ".count)
                domains.append(contentsOf: values.split(separator: " ").map(String.init))
            }
    }

    private func renderCapture(_ capture: CommandCapture) -> String {
        """
        Executable: \(capture.executable)
        Arguments: \(capture.arguments.joined(separator: " "))
        Exit Code: \(capture.exitCode)
        Captured At: \(capture.capturedAt.ISO8601Format())

        --- STDOUT ---
        \(capture.stdout)

        --- STDERR ---
        \(capture.stderr)
        """
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
        if settings.hammertime.skipDeviceChecks {
            arguments.append("--no-checks")
        }
        arguments.append(contentsOf: prefix)
        return arguments
    }

    private func sanitizeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce(into: "") { result, character in
            result.append(character)
        }
    }

    private var hostCaptureCommands: [(label: String, command: String)] {
        [
            ("hostnamectl", "hostnamectl"),
            ("ip-brief-addresses", "ip -br addr"),
            ("ip-detailed-links", "ip -d link"),
            ("ip-routes-all", "ip route show table all"),
            ("ip-rules", "ip rule"),
            ("bridge-links", "bridge link || true"),
            ("bridge-vlans", "bridge vlan show || true"),
            ("nmcli-connections", "nmcli -f all connection show 2>/dev/null || true"),
            ("nmcli-devices", "nmcli device show 2>/dev/null || true"),
            ("ovs-state", #"bash -lc 'ovs-vsctl show 2>/dev/null || true; ovs-vsctl list-br 2>/dev/null || true; for br in $(ovs-vsctl list-br 2>/dev/null); do echo "---OVS-PORTS:$br---"; ovs-vsctl list-ports "$br" 2>/dev/null || true; done'"#),
            ("resolver-state", #"bash -lc 'echo ---ETC-HOSTNAME---; cat /etc/hostname 2>/dev/null || true; echo ---ETC-HOSTS---; cat /etc/hosts 2>/dev/null || true; echo ---RESOLV---; cat /etc/resolv.conf 2>/dev/null || true'"#),
            ("network-scripts", #"bash -lc 'ls -la /etc/sysconfig/network-scripts 2>/dev/null || true; for file in /etc/sysconfig/network-scripts/ifcfg-* /etc/sysconfig/network-scripts/route-* /etc/sysconfig/network-scripts/rule-*; do [ -e "$file" ] || continue; echo "---FILE:$file---"; sed -n "1,240p" "$file"; done'"#),
            ("networkmanager-system-connections", #"bash -lc 'ls -la /etc/NetworkManager/system-connections 2>/dev/null || true; for file in /etc/NetworkManager/system-connections/*; do [ -f "$file" ] || continue; echo "---FILE:$file---"; sed -n "1,240p" "$file"; done'"#),
        ]
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
