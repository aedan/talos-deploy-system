import Foundation
import TalosDeployCore

@main
struct TalosDeployCLI {
    static func main() async {
        do {
            try AppPaths().ensureExists()
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "login":
            try await handleLogin(arguments: Array(arguments.dropFirst()))
        case "ubuntu":
            try await handleUbuntu(arguments: Array(arguments.dropFirst()))
        case "devices":
            try await handleDevices(arguments: Array(arguments.dropFirst()))
        case "facts":
            try await handleFacts(arguments: Array(arguments.dropFirst()))
        case "snapshot":
            try await handleSnapshot(arguments: Array(arguments.dropFirst()))
        case "plan":
            try await handlePlan(arguments: Array(arguments.dropFirst()))
        case "deploy":
            try await handleDeploy(arguments: Array(arguments.dropFirst()))
        case "resume":
            try handleResume(arguments: Array(arguments.dropFirst()))
        default:
            printUsage()
        }
    }

    private static func handleLogin(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let source = options["source"] ?? "auto"
        if source == "hammertime" || (options["username"] == nil && options["secret"] == nil) {
            let settings = (try? SettingsController().load()) ?? AppSettings()
            let coreClient = ConfiguredCoreClient(
                coreSettings: settings.core,
                hammertimeSettings: settings.hammertime
            )
            guard let detectedSession = try await coreClient.discoverEnvironmentSession(includeSecret: true),
                  let secret = detectedSession.secret,
                  !secret.isEmpty
            else {
                throw CLIError.missingRequired("No hammertime-backed Core session could be detected on this host")
            }

            var session = detectedSession.session
            session.secretReference = "core-session-\(UUID().uuidString)"
            do {
                try KeychainAuthProvider().storeSession(session, secret: secret)
                print("Imported Core session for \(session.username) from hammertime cache.")
            } catch let error as SecretStoreError where error.isInteractionNotAllowed {
                print("Detected Core session for \(session.username), but skipped Keychain import because this shell does not have GUI Keychain access. The CLI can still use the active hammertime cache directly.")
            }
            return
        }

        guard let username = options["username"], let secret = options["secret"] else {
            throw CLIError.missingRequired("login requires --username and --secret, or use --source hammertime on rax")
        }
        let headerName = options["header-name"] ?? "Cookie"
        let session = CoreSession(
            username: username,
            headerName: headerName,
            secretReference: "core-session-\(UUID().uuidString)"
        )
        try KeychainAuthProvider().storeSession(session, secret: secret)
        print("Stored Core session for \(username).")
    }

    private static func handleDevices(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let accountNumber = try resolveAccountNumber(options: options, settings: settings, command: "devices")
        let output = options["output"] ?? "table"
        let source = InventorySource(rawValue: options["source"] ?? settings.core.inventorySource.rawValue) ?? .auto
        let coreClient = ConfiguredCoreClient(
            coreSettings: settings.core,
            hammertimeSettings: settings.hammertime
        )
        let hammertime = DefaultHammertimeAdapter(settings: settings.hammertime)

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

        if output == "json" {
            let data = try JSONEncoder.pretty.encode(devices)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        for device in devices {
            print("\(device.id)\t\(device.name)\t\(device.primaryIP)\t\(device.oob?.address ?? "-")")
        }
    }

    private static func handleFacts(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let source = InventorySource(rawValue: options["source"] ?? "auto") ?? .auto
        let targets = parsePositionals(arguments).filter { !$0.hasPrefix("--") }
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let accountNumber = try resolveAccountNumber(options: options, settings: settings, command: "facts")
        let coreClient = ConfiguredCoreClient(
            coreSettings: settings.core,
            hammertimeSettings: settings.hammertime
        )
        let hammertime = DefaultHammertimeAdapter(settings: settings.hammertime)
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
        let selected = targets.isEmpty ? devices : devices.filter { targets.contains($0.id) || targets.contains($0.name) }
        let results = await hammertime.refreshLiveFacts(devices: selected, groups: settings.hammertime.defaultFactGroups)
        var rendered: [String: String] = [:]
        for device in selected {
            switch results[device.id] {
            case .success(let snapshot):
                rendered[device.name] = "os=\(snapshot.osDescription) memoryGiB=\(snapshot.memoryGiB.map(String.init) ?? "?") storageCount=\(snapshot.storageDevices.count)"
            case .failure(let error):
                rendered[device.name] = "error=\(error.localizedDescription)"
            case .none:
                rendered[device.name] = "error=no-result"
            }
        }
        let data = try JSONEncoder.pretty.encode(rendered)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleSnapshot(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let accountNumber = try resolveAccountNumber(options: options, settings: settings, command: "snapshot")
        guard let deviceSelector = options["device"] ?? parsePositionals(arguments).first else {
            throw CLIError.missingRequired("snapshot requires --device DEVICE_ID_OR_NAME")
        }

        let source = InventorySource(rawValue: options["source"] ?? settings.core.inventorySource.rawValue) ?? .auto
        let coreClient = ConfiguredCoreClient(
            coreSettings: settings.core,
            hammertimeSettings: settings.hammertime
        )
        let hammertime = DefaultHammertimeAdapter(settings: settings.hammertime)
        let capturer = PreinstallSnapshotCapturer(
            settings: settings,
            coreClient: coreClient,
            hammertime: hammertime
        )

        let outputDirectory: URL
        if let explicitDirectory = options["output-dir"], !explicitDirectory.isEmpty {
            outputDirectory = URL(fileURLWithPath: explicitDirectory, isDirectory: true)
        } else {
            outputDirectory = AppPaths().stateDirectory
        }

        let snapshot = try await capturer.capture(
            accountNumber: accountNumber,
            deviceSelector: deviceSelector,
            source: source,
            baseDirectory: outputDirectory
        )
        let data = try JSONEncoder.pretty.encode(snapshot)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleUbuntu(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            printUbuntuUsage()
            return
        }
        let remaining = Array(arguments.dropFirst())
        switch subcommand {
        case "snapshot":
            try await handleSnapshot(arguments: remaining)
        case "build-iso":
            try await handleUbuntuBuildISO(arguments: remaining)
        case "validate-iso":
            try await handleUbuntuValidateISO(arguments: remaining)
        case "bootstrap-helper":
            try await handleUbuntuBootstrapHelper(arguments: remaining)
        case "network-plan":
            try handleUbuntuNetworkPlan(arguments: remaining)
        default:
            printUbuntuUsage()
        }
    }

    private static func handleUbuntuBuildISO(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let builder = UbuntuAutoinstallBuilder()
        let spec = try ubuntuInstallSpec(from: options, arguments: arguments)
        let plan = try builder.makeNetworkPlan(fromCapturePath: spec.capturePath)
        let artifacts = try await builder.buildISO(spec: spec, networkPlan: plan)
        let data = try JSONEncoder.pretty.encode(artifacts)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleUbuntuValidateISO(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let isoPath = options["iso"] ?? options["iso-path"] ?? parsePositionals(arguments).first
        guard let isoPath, !isoPath.isEmpty else {
            throw CLIError.missingRequired("ubuntu validate-iso requires --iso /path/to.iso")
        }
        let result = try await UbuntuAutoinstallBuilder().validateISO(at: isoPath)
        let data = try JSONEncoder.pretty.encode(result)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleUbuntuBootstrapHelper(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let builder = UbuntuAutoinstallBuilder()
        let spec = try ubuntuInstallSpec(from: options, arguments: arguments)
        let plan = try builder.makeNetworkPlan(fromCapturePath: spec.capturePath)
        let artifacts = try await builder.buildISO(spec: spec, networkPlan: plan)
        let localMedia = try Ilo4LocalMediaSession().planSession(
            request: LocalMediaSessionRequest(
                oobURL: options["oob-url"] ?? options["ilo-url"] ?? "",
                username: options["oob-user"] ?? options["ilo-user"] ?? "",
                isoPath: artifacts.outputISOPath,
                vendor: .ilo
            )
        )
        let run = HelperBootstrapRun(
            installSpec: spec,
            networkPlan: plan,
            isoArtifacts: artifacts,
            localMediaState: localMedia
        )
        let data = try JSONEncoder.pretty.encode(run)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleUbuntuNetworkPlan(arguments: [String]) throws {
        let options = parseOptions(arguments)
        guard let capture = options["capture"] ?? options["snapshot"] ?? options["capture-dir"] ?? parsePositionals(arguments).first else {
            throw CLIError.missingRequired("ubuntu network-plan requires --capture /path/to/snapshot-or-capture-dir")
        }
        let plan = try UbuntuAutoinstallBuilder().makeNetworkPlan(fromCapturePath: capture)
        if options["output"] == "yaml" {
            print(plan.renderNetplanYAML())
            return
        }
        let data = try JSONEncoder.pretty.encode(plan)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handlePlan(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let spec = try loadSpec(from: options["spec"] ?? "examples/deployment-spec.example.json")
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let plan = try DeploymentPlanner(settings: settings).makePlan(spec: spec)
        let data = try JSONEncoder.pretty.encode(plan)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleDeploy(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let spec = try loadSpec(from: options["spec"] ?? "examples/deployment-spec.example.json")
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let paths = AppPaths()
        try paths.ensureExists()
        let coordinator = DeploymentCoordinator(settings: settings)
        let state = try await coordinator.stage(spec: spec, at: paths.stateDirectory)

        if let helperHost = options["helper-host"], let helperUser = options["helper-user"] {
            let connection = SSHConnection(
                host: helperHost,
                user: helperUser,
                port: Int(options["helper-port"] ?? "22") ?? 22,
                identityFile: options["identity-file"] ?? ""
            )
            let synchronized = try await coordinator.synchronizeToHelper(state, connection: connection)
            let data = try JSONEncoder.pretty.encode(synchronized)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        let data = try JSONEncoder.pretty.encode(state)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleResume(arguments: [String]) throws {
        let options = parseOptions(arguments)
        let path = options["path"] ?? AppPaths().stateDirectory.appending(path: "deployment-state.json").path
        let url = URL(fileURLWithPath: path)
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let state = try DeploymentStateStore().load(from: directory)
        let data = try JSONEncoder.pretty.encode(state)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func resolveAccountNumber(options: [String: String], settings: AppSettings, command: String) throws -> String {
        let candidate = options["account"] ?? options["core-account"] ?? settings.core.defaultAccountNumber
        let accountNumber = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountNumber.isEmpty else {
            throw CLIError.missingRequired("\(command) requires --account ACCOUNT or a saved default account in Settings")
        }
        return accountNumber
    }

    private static func loadSpec(from path: String) throws -> DeploymentSpec {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        return try decoder.decode(DeploymentSpec.self, from: data)
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { continue }
            let key = String(argument.dropFirst(2))
            if let next = iterator.next(), !next.hasPrefix("--") {
                options[key] = next
            } else {
                options[key] = "true"
            }
        }
        return options
    }

    private static func parsePositionals(_ arguments: [String]) -> [String] {
        var positionals: [String] = []
        var skipNext = false
        for (index, argument) in arguments.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if argument.hasPrefix("--") {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    skipNext = true
                }
            } else {
                positionals.append(argument)
            }
        }
        return positionals
    }

    private static func ubuntuInstallSpec(from options: [String: String], arguments: [String]) throws -> UbuntuInstallSpec {
        guard let sourceISO = options["source-iso"] ?? options["source"] else {
            throw CLIError.missingRequired("ubuntu build requires --source-iso /path/to/ubuntu.iso")
        }
        guard let outputISO = options["output-iso"] ?? options["output"] else {
            throw CLIError.missingRequired("ubuntu build requires --output-iso /path/to/output.iso")
        }
        guard let capturePath = options["capture"] ?? options["snapshot"] ?? options["capture-dir"] else {
            throw CLIError.missingRequired("ubuntu build requires --capture /path/to/snapshot-or-capture-dir")
        }

        let environment = ProcessInfo.processInfo.environment
        let rackHash = options["rack-password-hash"] ?? environment["TDS_RACK_PASSWORD_HASH"] ?? ""
        let rootHash = options["root-password-hash"] ?? environment["TDS_ROOT_PASSWORD_HASH"] ?? rackHash
        let keys = try loadAuthorizedKeys(options: options)

        return UbuntuInstallSpec(
            accountNumber: options["account"] ?? "",
            deviceID: options["device"] ?? "",
            sourceISOPath: sourceISO,
            outputISOPath: outputISO,
            workDirectoryPath: options["workdir"] ?? "",
            capturePath: capturePath,
            hostname: options["hostname"] ?? "",
            fqdn: options["fqdn"] ?? "",
            installDiskSerial: options["install-disk-serial"] ?? options["disk-serial"] ?? "",
            installDiskPath: options["install-disk"] ?? "",
            rackPasswordHash: rackHash,
            rootPasswordHash: rootHash,
            authorizedSSHKeys: keys,
            extraKernelArguments: splitCommaList(options["extra-kernel-args"] ?? "")
        )
    }

    private static func loadAuthorizedKeys(options: [String: String]) throws -> [String] {
        var keys = splitCommaList(options["ssh-key"] ?? options["authorized-key"] ?? "")
        let explicitFiles = splitCommaList(options["ssh-key-file"] ?? options["authorized-key-file"] ?? "")
        for file in explicitFiles {
            let content = try String(contentsOf: URL(fileURLWithPath: file.expandingTildeInPath()), encoding: .utf8)
            keys.append(contentsOf: content.split(separator: "\n").map(String.init))
        }
        if keys.isEmpty, parseBool(options["no-default-ssh-keys"]) != true {
            let sshDirectory = URL(fileURLWithPath: "~/.ssh".expandingTildeInPath(), isDirectory: true)
            if let contents = try? FileManager.default.contentsOfDirectory(at: sshDirectory, includingPropertiesForKeys: nil) {
                for url in contents where url.pathExtension == "pub" {
                    if let content = try? String(contentsOf: url, encoding: .utf8) {
                        keys.append(contentsOf: content.split(separator: "\n").map(String.init))
                    }
                }
            }
        }
        return Array(Set(keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private static func splitCommaList(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "yes", "1", "on":
            return true
        case "false", "no", "0", "off":
            return false
        default:
            return nil
        }
    }

    private static func printUsage() {
        print(
            """
            tds commands:
              login [--source hammertime] | --username USER --secret VALUE [--header-name Cookie]
              ubuntu snapshot --account ACCOUNT --device DEVICE [--source auto|core|hammertime] [--output-dir DIR]
              ubuntu build-iso --capture DIR_OR_SNAPSHOT --source-iso ISO --output-iso ISO [--rack-password-hash HASH]
              ubuntu validate-iso --iso ISO
              ubuntu bootstrap-helper --capture DIR_OR_SNAPSHOT --source-iso ISO --output-iso ISO --oob-url URL
              devices --account ACCOUNT [--source auto|core|hammertime] [--output table|json]
              facts --account ACCOUNT [--source auto|core|hammertime] [device-id...]
              snapshot --account ACCOUNT --device DEVICE [--source auto|core|hammertime] [--output-dir DIR]
              plan --spec path/to/spec.json
              deploy --spec path/to/spec.json [--helper-host HOST --helper-user USER]
              resume --path /path/to/deployment-state.json
            """
        )
    }

    private static func printUbuntuUsage() {
        print(
            """
            tds ubuntu commands:
              snapshot --account ACCOUNT --device DEVICE [--source auto|core|hammertime] [--output-dir DIR]
              network-plan --capture DIR_OR_SNAPSHOT [--output json|yaml]
              build-iso --capture DIR_OR_SNAPSHOT --source-iso ISO --output-iso ISO [--rack-password-hash HASH] [--root-password-hash HASH]
              validate-iso --iso ISO
              bootstrap-helper --capture DIR_OR_SNAPSHOT --source-iso ISO --output-iso ISO --oob-url https://ILO/

            Password hashes may also be supplied with TDS_RACK_PASSWORD_HASH and TDS_ROOT_PASSWORD_HASH.
            SSH public keys default to ~/.ssh/*.pub unless --no-default-ssh-keys true is set.
            """
        )
    }
}

enum CLIError: Error, LocalizedError {
    case missingRequired(String)

    var errorDescription: String? {
        switch self {
        case .missingRequired(let message):
            return message
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
