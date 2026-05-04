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
        case "talos":
            try await handleTalos(arguments: Array(arguments.dropFirst()))
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
        case "deployer":
            try await handleStandaloneDeployer(arguments: Array(arguments.dropFirst()))
        case "resume":
            try await handleResume(arguments: Array(arguments.dropFirst()))
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
            throw CLIError.missingRequired("login requires --username and --secret, or use --source hammertime on a workstation with an active hammertime session")
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
        case "bootstrap-deployer", "local-media-plan":
            try await handleUbuntuBootstrapDeployer(arguments: remaining)
        case "network-plan":
            try handleUbuntuNetworkPlan(arguments: remaining)
        case "oob-boot-url":
            try await handleUbuntuOOBBootURL(arguments: remaining)
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

    private static func handleTalos(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            printTalosUsage()
            return
        }
        let options = parseOptions(Array(arguments.dropFirst()))
        let settings = (try? SettingsController().load()) ?? AppSettings()
        var factory = settings.talos.factory
        if let value = options["factory-url"] { factory.baseURL = value }
        if let value = options["pxe-url"] { factory.pxeBaseURL = value }
        if let value = options["registry"] { factory.registryHost = value }
        if let value = options["arch"] { factory.architecture = value }
        if let value = options["platform"] { factory.platform = value }
        if let value = options["schematic-id"] { factory.schematicID = value }
        if let value = options["extensions"] {
            factory.selectedSystemExtensions = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let value = options["extra-kernel-args"] {
            factory.extraKernelArgs = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let version = options["version"] ?? settings.talos.talosVersion

        switch subcommand {
        case "schematic":
            print(TalosFactoryClient().renderSchematic(settings: factory))
        case "artifacts":
            let artifacts = TalosFactoryClient().artifactURLs(settings: factory, talosVersion: version)
            let data = try JSONEncoder.pretty.encode(artifacts)
            print(String(decoding: data, as: UTF8.self))
        case "versions":
            let catalog = try await TalosFactoryClient().fetchVersions(baseURL: factory.baseURL)
            if options["output"] == "json" {
                let data = try JSONEncoder.pretty.encode(catalog)
                print(String(decoding: data, as: UTF8.self))
                return
            }
            for version in catalog.versions {
                print(version.displayName)
            }
        case "oob-boot-url":
            try await handleOOBBootURL(arguments: Array(arguments.dropFirst()), commandName: "talos oob-boot-url")
        default:
            printTalosUsage()
        }
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

    private static func handleUbuntuBootstrapDeployer(arguments: [String]) async throws {
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
        let run = DeployerBootstrapRun(
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

    private static func handleUbuntuOOBBootURL(arguments: [String]) async throws {
        try await handleOOBBootURL(arguments: arguments, commandName: "ubuntu oob-boot-url")
    }

    private static func handleOOBBootURL(arguments: [String], commandName: String) async throws {
        let options = parseOptions(arguments)
        guard let deviceID = options["device"] ?? options["device-id"] else {
            throw CLIError.missingRequired("\(commandName) requires --device DEVICE_ID")
        }
        guard let imageURL = options["url"] ?? options["image-url"] ?? options["iso-url"] else {
            throw CLIError.missingRequired("\(commandName) requires --url IMAGE_URL")
        }
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let result = try await HammertimeOOBBooter(settings: settings.hammertime).bootURL(
            OOBBootURLRequest(
                deviceID: deviceID,
                imageURL: imageURL,
                connectMedia: parseBool(options["connect"]) ?? true,
                bootOnce: parseBool(options["boot-once"]) ?? true,
                oneTimeBoot: options["one-time-boot"],
                reboot: parseBool(options["reboot"]) ?? false,
                proxyVia: options["proxy-via"] ?? options["via"]
            )
        )
        let data = try JSONEncoder.pretty.encode(result)
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
        guard let subcommand = arguments.first, !subcommand.hasPrefix("--") else {
            printDeployUsage()
            return
        }
        let remaining = Array(arguments.dropFirst())
        switch subcommand {
        case "plan":
            try await handlePlan(arguments: remaining)
        case "run":
            try await handleDeployRun(arguments: remaining)
        case "resume":
            try await handleResume(arguments: remaining)
        case "reprovision":
            try await handleDeployReprovision(arguments: remaining)
        case "disk-boot":
            try await handleDeployDiskBoot(arguments: remaining)
        case "verify":
            try handleDeployVerify(arguments: remaining)
        case "maintenance-bundle":
            try handleDeployMaintenanceBundle(arguments: remaining)
        case "deployer":
            try await handleDeployDeployer(arguments: remaining)
        default:
            printDeployUsage()
        }
    }

    private static func handleDeployRun(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let spec = try loadSpec(from: options["spec"] ?? "examples/deployment-spec.example.json")
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let paths = AppPaths()
        try paths.ensureExists()
        let coreClient = ConfiguredCoreClient(
            coreSettings: settings.core,
            hammertimeSettings: settings.hammertime
        )
        let oobHardwareClient = makeOOBHardwareInventoryClient(settings: settings)
        let coordinator = DeploymentCoordinator(
            settings: settings,
            coreClient: coreClient,
            oobHardwareInventoryClient: oobHardwareClient
        )
        let state = try await coordinator.stage(spec: spec, at: paths.stateDirectory)
        let dryRun = parseBool(options["dry-run"]) ?? !(parseBool(options["execute"]) ?? false)
        let run = try await coordinator.run(
            state: state,
            connection: deployerConnection(options: options),
            access: deployerAccessRequest(options: options, settings: settings, deployerID: spec.deployerNode?.device.id ?? ""),
            dryRun: dryRun
        )
        let data = try JSONEncoder.pretty.encode(run)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func makeOOBHardwareInventoryClient(settings: AppSettings) -> (any OOBHardwareInventoryClient)? {
        guard settings.hammertime.enabled,
              settings.talos.provisioning.useOOBHardwareAddressSelectors
        else {
            return nil
        }
        return HammertimeOOBHardwareInventoryClient(settings: settings.hammertime)
    }

    private static func handleDeployVerify(arguments: [String]) throws {
        let options = parseOptions(arguments)
        let state = try loadState(path: options["state"] ?? options["path"])
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let result = DeploymentCoordinator(settings: settings).verify(state: state)
        let data = try JSONEncoder.pretty.encode(result)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleDeployReprovision(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let state = try loadState(path: options["state"] ?? options["path"])
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let coordinator = DeploymentCoordinator(settings: settings)
        let targets = parseTargetList(options["targets"] ?? options["target"] ?? options["devices"])
        let dryRun = parseBool(options["dry-run"]) ?? !(parseBool(options["execute"]) ?? false)
        let run = try await coordinator.reprovisionTalosNodes(
            state: state,
            targetDeviceIDs: targets,
            wipeFirst: parseBool(options["wipe"]) ?? false,
            connection: deployerConnection(options: options),
            access: deployerAccessRequest(options: options, settings: settings, deployerID: state.spec.deployerNode?.device.id ?? ""),
            dryRun: dryRun
        )
        let data = try JSONEncoder.pretty.encode(run)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleDeployDiskBoot(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let state = try loadState(path: options["state"] ?? options["path"])
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let targets = parseTargetList(options["targets"] ?? options["target"] ?? options["devices"])
        let dryRun = parseBool(options["dry-run"]) ?? !(parseBool(options["execute"]) ?? false)
        let execution = try await TalosDeploymentExecutor(settings: settings).prepareInstalledDiskBoot(
            state: state,
            targetDeviceIDs: targets,
            reboot: parseBool(options["reboot"]) ?? false,
            dryRun: dryRun
        )
        let data = try JSONEncoder.pretty.encode(execution)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleDeployMaintenanceBundle(arguments: [String]) throws {
        let options = parseOptions(arguments)
        let state = try loadState(path: options["state"] ?? options["path"])
        let localDirectory = URL(fileURLWithPath: state.localStateDirectory, isDirectory: true)
        let manifest = try MaintenanceBundleBuilder().writeBundle(for: state, in: localDirectory)
        let data = try JSONEncoder.pretty.encode(manifest)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func handleDeployDeployer(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            printDeployUsage()
            return
        }
        let options = parseOptions(Array(arguments.dropFirst()))
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let client = DefaultDeployerHostClient()
        var configuration = DeployerMediaServiceConfiguration(defaults: settings.deployer)
        if configuration.talosctlVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration.talosctlVersion = options["talos-version"] ?? settings.talos.talosVersion
        }
        switch subcommand {
        case "plan":
            let plan = client.planDeployerServices(configuration: configuration)
            let data = try JSONEncoder.pretty.encode(plan)
            print(String(decoding: data, as: UTF8.self))
        case "prepare":
            let device = DiscoveredDevice(
                id: options["device"] ?? options["deployer-device"] ?? "",
                accountNumber: options["account"] ?? "",
                name: options["device"] ?? options["deployer-device"] ?? "deployer"
            )
            let selection = try await DeployerTransportResolver(settings: settings).resolve(
                request: deployerAccessRequest(options: options, settings: settings, deployerID: device.id),
                deployer: device
            )
            let plan = try await client.prepareDeployerServices(configuration: configuration, transport: selection.transport)
            let data = try JSONEncoder.pretty.encode(plan)
            print(String(decoding: data, as: UTF8.self))
        case "access-test":
            let device = DiscoveredDevice(
                id: options["device"] ?? options["deployer-device"] ?? "",
                accountNumber: options["account"] ?? "",
                name: options["device"] ?? options["deployer-device"] ?? "deployer"
            )
            let selection = try await DeployerTransportResolver(settings: settings).resolve(
                request: deployerAccessRequest(options: options, settings: settings, deployerID: device.id),
                deployer: device
            )
            let data = try JSONEncoder.pretty.encode(selection.validation)
            print(String(decoding: data, as: UTF8.self))
        default:
            printDeployUsage()
        }
    }

    private static func handleStandaloneDeployer(arguments: [String]) async throws {
        guard !arguments.isEmpty else {
            printDeployerUsage()
            return
        }
        try await handleDeployDeployer(arguments: arguments)
    }

    private static func handleResume(arguments: [String]) async throws {
        let options = parseOptions(arguments)
        let state = try loadState(path: options["path"] ?? options["state"])
        let dryRun = parseBool(options["dry-run"]) ?? !(parseBool(options["execute"]) ?? false)
        guard parseBool(options["execute"]) == true || parseBool(options["dry-run"]) == true else {
            let data = try JSONEncoder.pretty.encode(state)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let settings = (try? SettingsController().load()) ?? AppSettings()
        let coordinator = DeploymentCoordinator(settings: settings)
        let run = try await coordinator.resumeDeployerExecution(
            state: state,
            connection: deployerConnection(options: options),
            access: deployerAccessRequest(options: options, settings: settings, deployerID: state.spec.deployerNode?.device.id ?? ""),
            dryRun: dryRun
        )
        let data = try JSONEncoder.pretty.encode(run)
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

    private static func loadState(path: String?) throws -> DeploymentState {
        let resolvedPath = path ?? AppPaths().stateDirectory.appending(path: "deployment-state.json").path
        let url = URL(fileURLWithPath: resolvedPath)
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        return try DeploymentStateStore().load(from: directory)
    }

    private static func deployerConnection(options: [String: String]) -> SSHConnection? {
        let host = options["deployer-host"]
        let user = options["deployer-user"]
        guard let host, let user else { return nil }
        return SSHConnection(
            host: host,
            user: user,
            port: Int(options["deployer-port"] ?? "22") ?? 22,
            identityFile: options["identity-file"] ?? "",
            proxyJump: options["proxy-jump"] ?? options["jump-host"] ?? ""
        )
    }

    private static func deployerAccessRequest(options: [String: String], settings: AppSettings, deployerID: String) -> DeployerAccessRequest {
        let method = DeployerAccessMethod(rawValue: options["access"] ?? options["access-method"] ?? settings.deployer.accessMethod.rawValue) ?? settings.deployer.accessMethod
        return DeployerAccessRequest(
            method: method,
            sshConnection: deployerConnection(options: options),
            hammertimeDeviceID: options["device"] ?? options["deployer-device"] ?? deployerID,
            hammertimeVia: options["via"] ?? options["hammertime-via"] ?? settings.hammertime.deployerVia,
            hammertimePrivate: parseBool(options["private"]) ?? settings.hammertime.deployerUsePrivate,
            passportReason: options["passport-reason"] ?? settings.hammertime.passportReason,
            copyMethod: options["copy-method"] ?? settings.hammertime.copyMethod
        )
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

    private static func parseTargetList(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
              talos schematic [--extensions ext1,ext2] [--extra-kernel-args arg1,arg2]
              talos artifacts [--version v1.13.0] [--schematic-id ID] [--arch amd64]
              talos versions [--factory-url URL] [--output table|json]
              talos oob-boot-url --device DEVICE_ID --url OOB_REACHABLE_IMAGE_URL [--reboot true]
              ubuntu snapshot --account ACCOUNT --device DEVICE [--source auto|core|hammertime] [--output-dir DIR]
              ubuntu build-iso --capture DIR_OR_SNAPSHOT --source-iso ISO --output-iso ISO [--rack-password-hash HASH]
              ubuntu validate-iso --iso ISO
              ubuntu bootstrap-deployer --capture DIR_OR_SNAPSHOT --source-iso ISO --output-iso ISO --oob-url URL
              ubuntu local-media-plan --capture DIR_OR_SNAPSHOT --source-iso ISO --output-iso ISO --oob-url URL
              ubuntu oob-boot-url --device DEVICE_ID --url OOB_REACHABLE_IMAGE_URL [--one-time-boot usb] [--reboot true]
              devices --account ACCOUNT [--source auto|core|hammertime] [--output table|json]
              facts --account ACCOUNT [--source auto|core|hammertime] [device-id...]
              snapshot --account ACCOUNT --device DEVICE [--source auto|core|hammertime] [--output-dir DIR]
              plan --spec path/to/spec.json
              deploy plan --spec path/to/spec.json
              deploy run --spec path/to/spec.json [--execute true] [--deployer-host HOST --deployer-user USER]
              deploy resume --path /path/to/deployment-state.json [--execute true] [--access auto|directSSH|proxyJumpSSH|hammertime]
              deploy reprovision --state /path/to/deployment-state.json --targets DEVICE_ID[,DEVICE_ID] [--wipe true] [--execute true]
              deploy disk-boot --state /path/to/deployment-state.json --targets DEVICE_ID[,DEVICE_ID] [--reboot true] [--execute true]
              deploy verify --state /path/to/deployment-state.json
              deploy maintenance-bundle --state /path/to/deployment-state.json
              deployer access-test --account ACCOUNT --device DEVICE [--access auto|directSSH|proxyJumpSSH|hammertime]
              deployer prepare --account ACCOUNT --device DEVICE [--access auto|directSSH|proxyJumpSSH|hammertime]
              deploy deployer plan
              deploy deployer access-test --account ACCOUNT --device DEVICE
              deploy deployer prepare --account ACCOUNT --device DEVICE
              resume --path /path/to/deployment-state.json [--execute true] [--access auto|directSSH|proxyJumpSSH|hammertime]
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
              bootstrap-deployer --capture DIR_OR_SNAPSHOT --source-iso ISO --output-iso ISO --oob-url https://ILO/
              local-media-plan --capture DIR_OR_SNAPSHOT --source-iso ISO --output-iso ISO --oob-url https://ILO/
              oob-boot-url --device DEVICE_ID --url http://oob-reachable-media/installer.iso [--one-time-boot usb] [--reboot true]

            Password hashes may also be supplied with TDS_RACK_PASSWORD_HASH and TDS_ROOT_PASSWORD_HASH.
            SSH public keys default to ~/.ssh/*.pub unless --no-default-ssh-keys true is set.
            oob-boot-url is for explicitly configured OOB-reachable media only; it is not the greenfield default.
            """
        )
    }

    private static func printTalosUsage() {
        print(
            """
            tds talos commands:
              schematic [--extensions ext1,ext2] [--extra-kernel-args arg1,arg2]
              artifacts [--version v1.13.0] [--schematic-id ID] [--arch amd64] [--platform metal]
              versions [--factory-url URL] [--output table|json]
              oob-boot-url --device DEVICE_ID --url http://oob-reachable-media/talos.iso [--reboot true]

            The artifact URLs follow the Talos Image Factory model. Extensions affect the image schematic;
            kernel modules are rendered into machine configs during deployment planning.
            """
        )
    }

    private static func printDeployUsage() {
        print(
            """
            tds deploy commands:
              plan --spec path/to/spec.json
              run --spec path/to/spec.json [--dry-run true|false] [--execute true] [--access auto|directSSH|proxyJumpSSH|hammertime] [--deployer-host HOST --deployer-user USER]
              resume --path /path/to/deployment-state.json
              reprovision --state /path/to/deployment-state.json --targets DEVICE_ID[,DEVICE_ID] [--wipe true] [--execute true] [--access auto|directSSH|proxyJumpSSH|hammertime]
              disk-boot --state /path/to/deployment-state.json --targets DEVICE_ID[,DEVICE_ID] [--reboot true] [--execute true]
              verify --state /path/to/deployment-state.json
              maintenance-bundle --state /path/to/deployment-state.json
              deployer plan
              deployer access-test --account ACCOUNT --device DEVICE [--access auto|directSSH|proxyJumpSSH|hammertime]
              deployer prepare --account ACCOUNT --device DEVICE [--access auto|directSSH|proxyJumpSSH|hammertime]

            Non-dry-run run and reprovision require --execute true plus a deployer access path. Resume re-syncs maintenance state and reruns the deployer-owned phase without reissuing OOB boots.
            Final Talos configs render only the management NIC/IP/default route/DNS for initial cluster bring-up; additional bridge/VLAN sections are intentionally omitted.
            disk-boot detaches virtual media where possible, restores installed-disk boot order, and can power-cycle selected nodes for recovery.
            """
        )
    }

    private static func printDeployerUsage() {
        print(
            """
            tds deployer commands:
              access-test --account ACCOUNT --device DEVICE [--access auto|directSSH|proxyJumpSSH|hammertime]
              prepare --account ACCOUNT --device DEVICE [--access auto|directSSH|proxyJumpSSH|hammertime]

            Hammertime access first validates cached SSO/session state, then uses ht command/copy/script with configured --no-checks and bounded SSH timeout behavior.
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
