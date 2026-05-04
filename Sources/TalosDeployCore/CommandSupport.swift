import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct CommandResult: Sendable {
    public var executable: String
    public var arguments: [String]
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(executable: String, arguments: [String], stdout: String, stderr: String, exitCode: Int32) {
        self.executable = executable
        self.arguments = arguments
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CommandError: Error, LocalizedError {
    case executionFailed(CommandResult)
    case timedOut(String, [String], TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .executionFailed(let result):
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let output = [
                stderr.isEmpty ? nil : "stderr:\n\(stderr)",
                stdout.isEmpty ? nil : "stdout:\n\(stdout)",
            ].compactMap { $0 }.joined(separator: "\n")
            let suffix = output.isEmpty ? "" : "\n\(output)"
            return "Command failed (\(result.exitCode)): \(result.executable) \(result.arguments.joined(separator: " "))\(suffix)"
        case .timedOut(let executable, let arguments, let timeout):
            return "Command timed out after \(Int(timeout))s: \(executable) \(arguments.joined(separator: " "))"
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval?
    ) async throws -> CommandResult
}

public extension CommandRunning {
    func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            timeout: nil
        )
    }
}

public final class LocalCommandRunner: CommandRunning, @unchecked Sendable {
    public init() {}

    public func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var mergedEnvironment = ProcessInfo.processInfo.environment
        mergedEnvironment.merge(environment, uniquingKeysWith: { _, new in new })
        process.environment = mergedEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = LockedData()
        let stderrBuffer = LockedData()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }

        try process.run()

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                await terminate(process)
                closeReadHandlers(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
                throw CommandError.timedOut(executable, arguments, timeout)
            }
        } else {
            process.waitUntilExit()
        }

        closeReadHandlers(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let result = CommandResult(
            executable: executable,
            arguments: arguments,
            stdout: String(decoding: stdoutBuffer.data, as: UTF8.self),
            stderr: String(decoding: stderrBuffer.data, as: UTF8.self),
            exitCode: process.terminationStatus
        )
        guard result.exitCode == 0 else {
            throw CommandError.executionFailed(result)
        }
        return result
    }

    private func closeReadHandlers(stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func terminate(_ process: Process) async {
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

public struct SSHConnection: Codable, Equatable, Sendable {
    public var host: String
    public var user: String
    public var port: Int
    public var identityFile: String
    public var proxyJump: String

    public init(host: String, user: String, port: Int = 22, identityFile: String = "", proxyJump: String = "") {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }
}

extension SSHConnection {
    enum CodingKeys: String, CodingKey {
        case host
        case user
        case port
        case identityFile
        case proxyJump
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            host: try container.decode(String.self, forKey: .host),
            user: try container.decode(String.self, forKey: .user),
            port: try container.decodeIfPresent(Int.self, forKey: .port) ?? 22,
            identityFile: try container.decodeIfPresent(String.self, forKey: .identityFile) ?? "",
            proxyJump: try container.decodeIfPresent(String.self, forKey: .proxyJump) ?? ""
        )
    }
}

public final class SSHCommandRouter: @unchecked Sendable {
    private let runner: CommandRunning

    public init(runner: CommandRunning = LocalCommandRunner()) {
        self.runner = runner
    }

    public func validateAccess(_ connection: SSHConnection) async throws {
        _ = try await run(connection: connection, remoteCommand: "true")
    }

    public func ensureDirectory(_ path: String, connection: SSHConnection) async throws {
        let escaped = shellEscape(path)
        _ = try await run(connection: connection, remoteCommand: "mkdir -p \(escaped)")
    }

    public func sync(localPath: URL, remotePath: String, connection: SSHConnection, delete: Bool = false) async throws {
        var arguments = ["-az"]
        if delete {
            arguments.append("--delete")
        }
        var sshOptions = "-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"
        if !connection.proxyJump.isEmpty {
            sshOptions += " -J \(connection.proxyJump)"
        }
        if !connection.identityFile.isEmpty {
            arguments.append(contentsOf: ["-e", "ssh \(sshOptions) -i \(connection.identityFile) -p \(connection.port)"])
        } else {
            arguments.append(contentsOf: ["-e", "ssh \(sshOptions) -p \(connection.port)"])
        }
        arguments.append(localPath.path + "/")
        arguments.append("\(connection.user)@\(connection.host):\(remotePath)/")
        _ = try await runner.run("/usr/bin/rsync", arguments: arguments, environment: [:], currentDirectory: nil, timeout: 300)
    }

    @discardableResult
    public func run(connection: SSHConnection, remoteCommand: String, timeout: TimeInterval? = 60) async throws -> CommandResult {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=10",
            "-p", "\(connection.port)",
        ]
        if !connection.proxyJump.isEmpty {
            arguments.append(contentsOf: ["-J", connection.proxyJump])
        }
        if !connection.identityFile.isEmpty {
            arguments.append(contentsOf: ["-i", connection.identityFile])
        }
        arguments.append("\(connection.user)@\(connection.host)")
        arguments.append(remoteCommand)
        return try await runner.run("/usr/bin/ssh", arguments: arguments, environment: [:], currentDirectory: nil, timeout: timeout)
    }
}

public func shellEscape(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func tdsProgress(_ message: String) {
    guard ProcessInfo.processInfo.environment["TDS_PROGRESS"] != "0" else { return }
    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[tds] \(timestamp) \(message)\n".utf8))
}

public extension String {
    func expandingTildeInPath() -> String {
        (self as NSString).expandingTildeInPath
    }
}
