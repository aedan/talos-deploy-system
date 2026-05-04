import Foundation

public struct DeployerAccessRequest: Codable, Equatable, Sendable {
    public var method: DeployerAccessMethod
    public var sshConnection: SSHConnection?
    public var hammertimeDeviceID: String
    public var hammertimeVia: String
    public var hammertimePrivate: Bool
    public var passportReason: String
    public var copyMethod: String

    public init(
        method: DeployerAccessMethod = .auto,
        sshConnection: SSHConnection? = nil,
        hammertimeDeviceID: String = "",
        hammertimeVia: String = "",
        hammertimePrivate: Bool = false,
        passportReason: String = "",
        copyMethod: String = "rsync"
    ) {
        self.method = method
        self.sshConnection = sshConnection
        self.hammertimeDeviceID = hammertimeDeviceID
        self.hammertimeVia = hammertimeVia
        self.hammertimePrivate = hammertimePrivate
        self.passportReason = passportReason
        self.copyMethod = copyMethod
    }
}

public protocol DeployerTransport: Sendable {
    var method: DeployerAccessMethod { get }
    var targetDescription: String { get }

    func validate() async throws -> DeployerAccessValidation
    func run(_ remoteCommand: String, timeout: TimeInterval?) async throws -> CommandResult
    func copy(localPath: URL, remotePath: String, delete: Bool) async throws
    func runScript(_ script: String, arguments: [String], asRoot: Bool, timeout: TimeInterval?) async throws -> CommandResult
}

public extension DeployerTransport {
    func run(_ remoteCommand: String) async throws -> CommandResult {
        try await run(remoteCommand, timeout: nil)
    }
}

public final class DirectSSHDeployerTransport: DeployerTransport, @unchecked Sendable {
    public let method: DeployerAccessMethod
    public var targetDescription: String {
        "\(connection.user)@\(connection.host)"
    }

    private let connection: SSHConnection
    private let router: SSHCommandRouter

    public init(connection: SSHConnection, method: DeployerAccessMethod = .directSSH, router: SSHCommandRouter = SSHCommandRouter()) {
        self.connection = connection
        self.method = method
        self.router = router
    }

    public func validate() async throws -> DeployerAccessValidation {
        _ = try await run("true", timeout: 60)
        return DeployerAccessValidation(
            method: method,
            target: targetDescription,
            succeeded: true,
            message: "Validated deployer command execution over \(method.displayName).",
            attempts: [targetDescription]
        )
    }

    public func run(_ remoteCommand: String, timeout: TimeInterval? = nil) async throws -> CommandResult {
        try await router.run(connection: connection, remoteCommand: remoteCommand, timeout: timeout ?? 60)
    }

    public func copy(localPath: URL, remotePath: String, delete: Bool) async throws {
        try await router.ensureDirectory(remotePath, connection: connection)
        try await router.sync(localPath: localPath, remotePath: remotePath, connection: connection, delete: delete)
    }

    public func runScript(_ script: String, arguments: [String] = [], asRoot: Bool = false, timeout: TimeInterval? = nil) async throws -> CommandResult {
        let escapedArguments = arguments.map(shellEscape).joined(separator: " ")
        let command = """
        set -e
        tmp="$(mktemp /tmp/tds-script.XXXXXX)"
        cat > "$tmp" <<'TDS_SCRIPT'
        \(script)
        TDS_SCRIPT
        chmod 0700 "$tmp"
        \(asRoot ? "sudo" : "") "$tmp" \(escapedArguments)
        rc=$?
        rm -f "$tmp"
        exit $rc
        """
        return try await run(command, timeout: timeout ?? 300)
    }
}

public final class HammertimeDeployerTransport: DeployerTransport, @unchecked Sendable {
    public let method: DeployerAccessMethod = .hammertime
    public var targetDescription: String { "hammertime:\(deviceID)" }

    private let settings: HammertimeSettings
    private let deviceID: String
    private let via: String
    private let usePrivate: Bool
    private let passportReason: String
    private let copyMethod: String
    private let validationRetryDelaySeconds: Int
    private let runner: CommandRunning

    public init(
        settings: HammertimeSettings,
        deviceID: String,
        via: String = "",
        usePrivate: Bool = false,
        passportReason: String = "",
        copyMethod: String = "rsync",
        validationRetryDelaySeconds: Int = 5,
        runner: CommandRunning = LocalCommandRunner()
    ) {
        self.settings = settings
        self.deviceID = deviceID
        self.via = via.isEmpty ? settings.deployerVia : via
        self.usePrivate = usePrivate || settings.deployerUsePrivate
        self.passportReason = passportReason.isEmpty ? settings.passportReason : passportReason
        self.copyMethod = copyMethod.isEmpty ? settings.copyMethod : copyMethod
        self.validationRetryDelaySeconds = validationRetryDelaySeconds
        self.runner = runner
    }

    public func validate() async throws -> DeployerAccessValidation {
        try await validateAuthentication()

        let maximumAttempts = 3
        var lastError: Error?

        for attempt in 1...maximumAttempts {
            do {
                _ = try await run("true", timeout: TimeInterval(min(settings.commandTimeoutSeconds, 75)))
                return DeployerAccessValidation(
                    method: .hammertime,
                    target: targetDescription,
                    succeeded: true,
                    message: "Validated deployer command execution through Hammertime.",
                    attempts: [targetDescription]
                )
            } catch {
                lastError = error
                if attempt < maximumAttempts {
                    tdsProgress("Hammertime deployer validation attempt \(attempt) failed for \(deviceID); retrying")
                    if validationRetryDelaySeconds > 0 {
                        try await Task.sleep(for: .seconds(attempt * validationRetryDelaySeconds))
                    }
                }
            }
        }

        if let lastError {
            if case CommandError.timedOut = lastError {
                throw HammertimeTransportError.validationTimedOut(deviceID)
            }
            throw lastError
        }

        throw HammertimeTransportError.validationTimedOut(deviceID)
    }

    public func run(_ remoteCommand: String, timeout: TimeInterval? = nil) async throws -> CommandResult {
        try await runner.run(
            settings.binaryPath.expandingTildeInPath(),
            arguments: commonArguments() + ["command"] + commandOptions() + copyMethodOptions() + ["--command", remoteCommand, deviceID],
            environment: [:],
            currentDirectory: nil,
            timeout: timeout ?? TimeInterval(settings.commandTimeoutSeconds)
        )
    }

    public func copy(localPath: URL, remotePath: String, delete: Bool) async throws {
        tdsProgress("Ensuring remote deployer state directory \(remotePath)")
        _ = try await run("mkdir -p \(shellEscape(remotePath))", timeout: TimeInterval(settings.commandTimeoutSeconds))
        tdsProgress("Preparing Hammertime-safe copy source for \(localPath.path)")
        let source = try hammertimeSafeSource(for: localPath)
        defer {
            if let cleanupURL = source.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
        var arguments = commonArguments() + [
            "copy",
        ] + commandOptions() + [
            "--src", source.path + (source.isDirectory ? "/" : ""),
            "--dest", "\(deviceID):\(remotePath)/",
            "--method", copyMethod,
        ]
        if delete, copyMethod == "rsync" {
            arguments.append(contentsOf: ["--rsync-args=-rvt --delete"])
        }
        tdsProgress("Copying deployment state to \(targetDescription):\(remotePath)")
        _ = try await runner.run(
            settings.binaryPath.expandingTildeInPath(),
            arguments: arguments,
            environment: [:],
            currentDirectory: nil,
            timeout: TimeInterval(max(settings.commandTimeoutSeconds, 300))
        )
        tdsProgress("Deployment state copy completed for \(targetDescription)")
    }

    public func runScript(_ script: String, arguments: [String] = [], asRoot: Bool = false, timeout: TimeInterval? = nil) async throws -> CommandResult {
        let scriptURL = FileManager.default.temporaryDirectory.appending(path: "tds-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        var htArguments = commonArguments() + [
            "script",
        ] + commandOptions() + [
            "--file", scriptURL.path,
            "--format", "raw",
        ] + copyMethodOptions()
        if asRoot {
            htArguments.append("--root")
        }
        if !arguments.isEmpty {
            htArguments.append(contentsOf: ["--args", arguments.map(shellEscape).joined(separator: " ")])
        }
        htArguments.append(deviceID)
        return try await runner.run(
            settings.binaryPath.expandingTildeInPath(),
            arguments: htArguments,
            environment: [:],
            currentDirectory: nil,
            timeout: timeout ?? TimeInterval(settings.commandTimeoutSeconds)
        )
    }

    private func commonArguments() -> [String] {
        var arguments = ["--batch", "--no-colors"]
        if settings.skipDeviceChecks {
            arguments.append("--no-checks")
        }
        return arguments
    }

    private func validateAuthentication() async throws {
        do {
            _ = try await runner.run(
                settings.binaryPath.expandingTildeInPath(),
                arguments: commonArguments() + [
                    "credentials",
                    "--identity",
                    "--validate",
                    "--format",
                    "tokenonly",
                ],
                environment: [:],
                currentDirectory: nil,
                timeout: TimeInterval(settings.authPreflightTimeoutSeconds)
            )
        } catch {
            if case CommandError.timedOut = error {
                throw HammertimeTransportError.authenticationTimedOut(settings.authPreflightTimeoutSeconds)
            }
            if let commandError = error as? CommandError,
               case .executionFailed(let result) = commandError {
                let output = [result.stderr, result.stdout].joined(separator: "\n")
                if output.localizedCaseInsensitiveContains("password missing") ||
                    output.localizedCaseInsensitiveContains("can't prompt") ||
                    output.localizedCaseInsensitiveContains("saml") {
                    throw HammertimeTransportError.authenticationUnavailable(output)
                }
            }
            throw error
        }
    }

    private func commandOptions() -> [String] {
        var arguments: [String] = []
        if !via.isEmpty {
            arguments.append(contentsOf: ["--via", via])
        }
        if usePrivate {
            arguments.append("--private")
        }
        if !passportReason.isEmpty {
            arguments.append(contentsOf: ["--passport-reason", passportReason])
        }
        if !settings.deployerSSHArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--ssh-args", settings.deployerSSHArgs])
        }
        if settings.saveExpectScripts {
            arguments.append("--save-expect")
        }
        return arguments
    }

    private func copyMethodOptions() -> [String] {
        copyMethod.isEmpty ? [] : ["--method", copyMethod]
    }

    private func hammertimeSafeSource(for localPath: URL) throws -> HammertimeCopySource {
        guard localPath.path.contains(" ") else {
            return HammertimeCopySource(path: localPath.path, isDirectory: localPath.hasDirectoryPath, cleanupURL: nil)
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "tds-ht-copy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let linkURL = temporaryDirectory.appending(path: localPath.lastPathComponent, directoryHint: localPath.hasDirectoryPath ? .isDirectory : .notDirectory)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: localPath)
        return HammertimeCopySource(path: linkURL.path, isDirectory: localPath.hasDirectoryPath, cleanupURL: temporaryDirectory)
    }

    private struct HammertimeCopySource {
        var path: String
        var isDirectory: Bool
        var cleanupURL: URL?
    }
}

public enum HammertimeTransportError: Error, LocalizedError {
    case authenticationTimedOut(Int)
    case authenticationUnavailable(String)
    case validationTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationTimedOut(let seconds):
            return "Hammertime authentication preflight timed out after \(seconds)s before deployer access was attempted. Refresh Hammertime/Core SSO on the runtime host in an interactive terminal, for example `ht --no-checks login <deployer-device>`, then retry."
        case .authenticationUnavailable(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "" : " Hammertime reported: \(trimmed)"
            return "Hammertime authentication is not available in batch mode.\(detail) Refresh Hammertime/Core SSO on the runtime host in an interactive terminal, then retry."
        case .validationTimedOut(let deviceID):
            return "Hammertime access to \(deviceID) timed out while validating deployer command execution. Refresh Hammertime/Core SSO on the runtime host, for example by running `ht --no-checks login \(deviceID)` interactively, then retry."
        }
    }
}

public struct DeployerTransportSelection: Sendable {
    public var transport: any DeployerTransport
    public var validation: DeployerAccessValidation
    public var failedAttempts: [String]

    public init(transport: any DeployerTransport, validation: DeployerAccessValidation, failedAttempts: [String]) {
        self.transport = transport
        self.validation = validation
        self.failedAttempts = failedAttempts
    }
}

public enum DeployerTransportError: Error, LocalizedError {
    case missingAccessTarget
    case noReachableTransport([String])

    public var errorDescription: String? {
        switch self {
        case .missingAccessTarget:
            return "No deployer access target was configured. Provide a deployer host or Hammertime device ID."
        case .noReachableTransport(let attempts):
            return "No deployer transport could be validated. Attempts: \(attempts.joined(separator: " | "))"
        }
    }
}

public final class DeployerTransportResolver: @unchecked Sendable {
    private let settings: AppSettings
    private let runner: CommandRunning

    public init(settings: AppSettings, runner: CommandRunning = LocalCommandRunner()) {
        self.settings = settings
        self.runner = runner
    }

    public func resolve(request: DeployerAccessRequest, deployer: DiscoveredDevice) async throws -> DeployerTransportSelection {
        let candidates = makeCandidates(request: request, deployer: deployer)
        guard !candidates.isEmpty else {
            throw DeployerTransportError.missingAccessTarget
        }

        var failures: [String] = []
        for candidate in candidates {
            do {
                let validation = try await candidate.validate()
                return DeployerTransportSelection(transport: candidate, validation: validation, failedAttempts: failures)
            } catch {
                failures.append("\(candidate.method.rawValue) \(candidate.targetDescription): \(error.localizedDescription)")
            }
        }
        throw DeployerTransportError.noReachableTransport(failures)
    }

    private func makeCandidates(request: DeployerAccessRequest, deployer: DiscoveredDevice) -> [any DeployerTransport] {
        var candidates: [any DeployerTransport] = []
        let requested = request.method
        let hammertimeDeviceID = firstNonEmpty(request.hammertimeDeviceID, deployer.id)

        if requested == .auto || requested == .directSSH {
            if let connection = request.sshConnection {
                var directConnection = connection
                directConnection.proxyJump = ""
                candidates.append(DirectSSHDeployerTransport(connection: directConnection, method: .directSSH, router: SSHCommandRouter(runner: runner)))
            }
        }

        if requested == .auto || requested == .proxyJumpSSH {
            if var connection = request.sshConnection {
                let proxyJump = firstNonEmpty(connection.proxyJump, settings.deployer.proxyJumpHost)
                if !proxyJump.isEmpty {
                    connection.proxyJump = proxyJump
                    candidates.append(DirectSSHDeployerTransport(connection: connection, method: .proxyJumpSSH, router: SSHCommandRouter(runner: runner)))
                }
            }
        }

        if requested == .auto || requested == .hammertime {
            if settings.hammertime.enabled, !hammertimeDeviceID.isEmpty {
                candidates.append(
                    HammertimeDeployerTransport(
                        settings: settings.hammertime,
                        deviceID: hammertimeDeviceID,
                        via: firstNonEmpty(request.hammertimeVia, settings.hammertime.deployerVia),
                        usePrivate: request.hammertimePrivate || settings.hammertime.deployerUsePrivate,
                        passportReason: firstNonEmpty(request.passportReason, settings.hammertime.passportReason),
                        copyMethod: firstNonEmpty(request.copyMethod, settings.hammertime.copyMethod),
                        runner: runner
                    )
                )
            }
        }

        if requested == .directSSH || requested == .proxyJumpSSH || requested == .hammertime {
            return candidates.filter { $0.method == requested }
        }
        return candidates
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
}
