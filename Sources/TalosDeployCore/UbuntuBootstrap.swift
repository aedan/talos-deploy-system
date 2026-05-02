import Foundation

public enum UbuntuBootstrapError: Error, LocalizedError {
    case missingRequired(String)
    case invalidCapture(String)
    case validationFailed([String])

    public var errorDescription: String? {
        switch self {
        case .missingRequired(let message):
            return message
        case .invalidCapture(let message):
            return message
        case .validationFailed(let failures):
            return "Ubuntu ISO validation failed: \(failures.joined(separator: "; "))"
        }
    }
}

public struct UbuntuInstallSpec: Codable, Equatable, Sendable {
    public var accountNumber: String
    public var deviceID: String
    public var sourceISOPath: String
    public var outputISOPath: String
    public var workDirectoryPath: String
    public var capturePath: String
    public var hostname: String
    public var fqdn: String
    public var installDiskSerial: String
    public var installDiskPath: String
    public var rackPasswordHash: String
    public var rootPasswordHash: String
    public var authorizedSSHKeys: [String]
    public var extraKernelArguments: [String]

    public init(
        accountNumber: String = "",
        deviceID: String = "",
        sourceISOPath: String,
        outputISOPath: String,
        workDirectoryPath: String = "",
        capturePath: String = "",
        hostname: String = "",
        fqdn: String = "",
        installDiskSerial: String = "",
        installDiskPath: String = "",
        rackPasswordHash: String = "",
        rootPasswordHash: String = "",
        authorizedSSHKeys: [String] = [],
        extraKernelArguments: [String] = []
    ) {
        self.accountNumber = accountNumber
        self.deviceID = deviceID
        self.sourceISOPath = sourceISOPath
        self.outputISOPath = outputISOPath
        self.workDirectoryPath = workDirectoryPath
        self.capturePath = capturePath
        self.hostname = hostname
        self.fqdn = fqdn
        self.installDiskSerial = installDiskSerial
        self.installDiskPath = installDiskPath
        self.rackPasswordHash = rackPasswordHash
        self.rootPasswordHash = rootPasswordHash
        self.authorizedSSHKeys = authorizedSSHKeys
        self.extraKernelArguments = extraKernelArguments
    }
}

public struct NetplanRoute: Codable, Equatable, Sendable {
    public var to: String
    public var via: String

    public init(to: String, via: String) {
        self.to = to
        self.via = via
    }
}

public struct NetplanEthernet: Codable, Equatable, Sendable {
    public var name: String
    public var macAddress: String
    public var matchName: String
    public var dhcp4: Bool
    public var addresses: [String]
    public var routes: [NetplanRoute]
    public var nameservers: [String]
    public var searchDomains: [String]

    public init(
        name: String,
        macAddress: String = "",
        matchName: String = "",
        dhcp4: Bool = false,
        addresses: [String] = [],
        routes: [NetplanRoute] = [],
        nameservers: [String] = [],
        searchDomains: [String] = []
    ) {
        self.name = name
        self.macAddress = macAddress
        self.matchName = matchName
        self.dhcp4 = dhcp4
        self.addresses = addresses
        self.routes = routes
        self.nameservers = nameservers
        self.searchDomains = searchDomains
    }
}

public struct NetplanVLAN: Codable, Equatable, Sendable {
    public var name: String
    public var id: Int
    public var link: String

    public init(name: String, id: Int, link: String) {
        self.name = name
        self.id = id
        self.link = link
    }
}

public struct NetplanBridge: Codable, Equatable, Sendable {
    public var name: String
    public var interfaces: [String]
    public var addresses: [String]
    public var routes: [NetplanRoute]

    public init(
        name: String,
        interfaces: [String] = [],
        addresses: [String] = [],
        routes: [NetplanRoute] = []
    ) {
        self.name = name
        self.interfaces = interfaces
        self.addresses = addresses
        self.routes = routes
    }
}

public struct NetworkRebuildPlan: Codable, Equatable, Sendable {
    public var hostname: String
    public var fqdn: String
    public var ethernets: [NetplanEthernet]
    public var vlans: [NetplanVLAN]
    public var bridges: [NetplanBridge]

    public init(
        hostname: String = "",
        fqdn: String = "",
        ethernets: [NetplanEthernet] = [],
        vlans: [NetplanVLAN] = [],
        bridges: [NetplanBridge] = []
    ) {
        self.hostname = hostname
        self.fqdn = fqdn
        self.ethernets = ethernets
        self.vlans = vlans
        self.bridges = bridges
    }

    public func renderNetplanYAML() -> String {
        var lines: [String] = [
            "network:",
            "  version: 2",
            "  renderer: networkd",
        ]

        if !ethernets.isEmpty {
            lines.append("  ethernets:")
            for ethernet in ethernets.sorted(by: { $0.name < $1.name }) {
                lines.append("    \(ethernet.name):")
                if !ethernet.macAddress.isEmpty {
                    lines.append("      match:")
                    lines.append("        macaddress: \(yamlQuote(ethernet.macAddress.lowercased()))")
                    lines.append("      set-name: \(ethernet.name)")
                } else if !ethernet.matchName.isEmpty {
                    lines.append("      match:")
                    lines.append("        name: \(yamlQuote(ethernet.matchName))")
                }
                lines.append("      optional: true")
                lines.append("      dhcp4: \(ethernet.dhcp4 ? "true" : "false")")
                appendStringArray(ethernet.addresses, key: "addresses", indent: "      ", to: &lines)
                appendRoutes(ethernet.routes, indent: "      ", to: &lines)
                appendNameservers(addresses: ethernet.nameservers, search: ethernet.searchDomains, indent: "      ", to: &lines)
            }
        }

        if !vlans.isEmpty {
            lines.append("  vlans:")
            for vlan in vlans.sorted(by: { $0.name < $1.name }) {
                lines.append("    \(vlan.name):")
                lines.append("      id: \(vlan.id)")
                lines.append("      link: \(vlan.link)")
                lines.append("      optional: true")
            }
        }

        if !bridges.isEmpty {
            lines.append("  bridges:")
            for bridge in bridges.sorted(by: { $0.name < $1.name }) {
                lines.append("    \(bridge.name):")
                appendStringArray(bridge.interfaces, key: "interfaces", indent: "      ", to: &lines)
                lines.append("      optional: true")
                appendStringArray(bridge.addresses, key: "addresses", indent: "      ", to: &lines)
                appendRoutes(bridge.routes, indent: "      ", to: &lines)
                lines.append("      parameters:")
                lines.append("        stp: false")
                lines.append("        forward-delay: 0")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

}

public struct UbuntuIsoValidationResult: Codable, Equatable, Sendable {
    public var isoPath: String
    public var checkedAt: Date
    public var hasNoCloudUserData: Bool
    public var hasNoCloudMetaData: Bool
    public var grubUsesNoCloud: Bool
    public var userDataHasAutoinstall: Bool
    public var userDataCreatesRack: Bool
    public var userDataConfiguresRoot: Bool
    public var userDataWritesTDSArtifacts: Bool
    public var warnings: [String]
    public var failures: [String]

    public init(
        isoPath: String,
        checkedAt: Date = .now,
        hasNoCloudUserData: Bool = false,
        hasNoCloudMetaData: Bool = false,
        grubUsesNoCloud: Bool = false,
        userDataHasAutoinstall: Bool = false,
        userDataCreatesRack: Bool = false,
        userDataConfiguresRoot: Bool = false,
        userDataWritesTDSArtifacts: Bool = false,
        warnings: [String] = [],
        failures: [String] = []
    ) {
        self.isoPath = isoPath
        self.checkedAt = checkedAt
        self.hasNoCloudUserData = hasNoCloudUserData
        self.hasNoCloudMetaData = hasNoCloudMetaData
        self.grubUsesNoCloud = grubUsesNoCloud
        self.userDataHasAutoinstall = userDataHasAutoinstall
        self.userDataCreatesRack = userDataCreatesRack
        self.userDataConfiguresRoot = userDataConfiguresRoot
        self.userDataWritesTDSArtifacts = userDataWritesTDSArtifacts
        self.warnings = warnings
        self.failures = failures
    }

    public var isValid: Bool {
        failures.isEmpty
    }
}

public struct UbuntuAutoinstallArtifacts: Codable, Equatable, Sendable {
    public var seedDirectory: String
    public var userDataPath: String
    public var metaDataPath: String
    public var netplanPath: String
    public var outputISOPath: String
    public var validation: UbuntuIsoValidationResult?

    public init(
        seedDirectory: String,
        userDataPath: String,
        metaDataPath: String,
        netplanPath: String,
        outputISOPath: String,
        validation: UbuntuIsoValidationResult? = nil
    ) {
        self.seedDirectory = seedDirectory
        self.userDataPath = userDataPath
        self.metaDataPath = metaDataPath
        self.netplanPath = netplanPath
        self.outputISOPath = outputISOPath
        self.validation = validation
    }
}

public final class UbuntuAutoinstallBuilder: @unchecked Sendable {
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let scriptPath: String

    public init(
        runner: CommandRunning = LocalCommandRunner(),
        fileManager: FileManager = .default,
        scriptPath: String = "scripts/build-ubuntu-autoinstall-iso.sh"
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.scriptPath = scriptPath
    }

    public func makeNetworkPlan(from snapshot: NetworkPreservationSnapshot) throws -> NetworkRebuildPlan {
        let parser = NetworkCaptureParser(snapshot: snapshot)
        return try parser.makePlan()
    }

    public func makeNetworkPlan(fromCapturePath capturePath: String) throws -> NetworkRebuildPlan {
        let loader = UbuntuCaptureLoader(fileManager: fileManager)
        let snapshot = try loader.load(from: URL(fileURLWithPath: capturePath))
        return try makeNetworkPlan(from: snapshot)
    }

    public func renderUserData(spec: UbuntuInstallSpec, networkPlan: NetworkRebuildPlan) throws -> String {
        guard !spec.rackPasswordHash.isEmpty else {
            throw UbuntuBootstrapError.missingRequired("rack password hash is required. Pass --rack-password-hash or set TDS_RACK_PASSWORD_HASH.")
        }
        guard !spec.rootPasswordHash.isEmpty else {
            throw UbuntuBootstrapError.missingRequired("root password hash is required. Pass --root-password-hash or set TDS_ROOT_PASSWORD_HASH.")
        }

        let fqdn = firstNonEmpty(spec.fqdn, networkPlan.fqdn, spec.hostname)
        let shortHostname = shortHostName(firstNonEmpty(spec.hostname, networkPlan.hostname, fqdn, "tds-deployer"))
        let netplan = networkPlan.renderNetplanYAML()
        let netplanBlock = indentBlock(netplan, spaces: 10)
        let installerSSHKeys = renderYAMLListField(key: "authorized-keys", values: spec.authorizedSSHKeys, indent: "    ")
        let userSSHKeys = renderYAMLListField(key: "ssh_authorized_keys", values: spec.authorizedSSHKeys, indent: "        ")
        let rackHash = yamlSingleQuote(spec.rackPasswordHash)
        let rootHash = yamlSingleQuote(spec.rootPasswordHash)
        let rackHashShell = shellSingleQuote(spec.rackPasswordHash)
        let rootHashShell = shellSingleQuote(spec.rootPasswordHash)

        var storageLines = [
            "  storage:",
            "    layout:",
            "      name: direct",
        ]
        if !spec.installDiskSerial.isEmpty {
            storageLines.append("      match:")
            storageLines.append("        serial: \(yamlQuote(spec.installDiskSerial))")
        }

        return """
        #cloud-config
        autoinstall:
          version: 1
          locale: en_US.UTF-8
          keyboard:
            layout: us
          timezone: Etc/UTC
          source:
            search_drivers: false
            id: ubuntu-server
          drivers:
            install: false
          oem:
            install: false
          apt:
            fallback: offline-install
            geoip: false
          identity:
            hostname: \(shortHostname)
            username: rack
            password: \(rackHash)
          ssh:
            install-server: true
            allow-pw: true
        \(installerSSHKeys)
        \(storageLines.joined(separator: "\n"))
        \(indentBlock(netplan, spaces: 2))
          user-data:
            preserve_hostname: false
            hostname: \(shortHostname)
            fqdn: \(fqdn)
            disable_root: false
            ssh_pwauth: true
            users:
              - default
              - name: rack
                gecos: Rackspace Support User
                groups: adm,sudo
                shell: /bin/bash
                sudo: ALL=(ALL) NOPASSWD:ALL
                lock_passwd: false
                passwd: \(rackHash)
        \(userSSHKeys)
              - name: root
                lock_passwd: false
                passwd: \(rootHash)
        \(userSSHKeys)
            write_files:
              - path: /etc/ssh/sshd_config.d/60-tds-root.conf
                permissions: "0644"
                content: |
                  PermitRootLogin yes
                  PasswordAuthentication yes
                  KbdInteractiveAuthentication yes
              - path: /etc/netplan/90-tds-preserved.yaml
                permissions: "0644"
                content: |
        \(netplanBlock)
            runcmd:
              - systemctl reload ssh || systemctl reload sshd || systemctl restart ssh || systemctl restart sshd
          late-commands:
            - mkdir -p /target/var/log/installer/tds
            - cp /cdrom/nocloud/user-data /target/var/log/installer/tds/user-data || true
            - cp /cdrom/nocloud/meta-data /target/var/log/installer/tds/meta-data || true
            - curtin in-target --target=/target -- mkdir -p /etc/ssh/sshd_config.d /etc/netplan /var/log/installer/tds
            - cp /cdrom/nocloud/90-tds-preserved.yaml /target/etc/netplan/90-tds-preserved.yaml || true
            - curtin in-target --target=/target -- usermod --password \(rackHashShell) rack
            - curtin in-target --target=/target -- usermod --password \(rootHashShell) root
            - curtin in-target --target=/target -- usermod -aG sudo rack
            - curtin in-target --target=/target -- install -m 0644 /etc/netplan/90-tds-preserved.yaml /var/log/installer/tds/90-tds-preserved.yaml
            - curtin in-target --target=/target -- bash -lc 'sshd -t || sshd -t -f /etc/ssh/sshd_config'
            - curtin in-target --target=/target -- netplan generate
            - cp -a /var/log/installer /target/var/log/installer/tds/live-installer-logs || true
          shutdown: reboot
        """
    }

    public func renderMetaData(spec: UbuntuInstallSpec, networkPlan: NetworkRebuildPlan) -> String {
        let hostname = shortHostName(firstNonEmpty(spec.hostname, networkPlan.hostname, spec.deviceID, "tds-deployer"))
        let instanceParts = ["tds", spec.accountNumber, spec.deviceID, hostname].filter { !$0.isEmpty }
        return """
        instance-id: \(instanceParts.joined(separator: "-"))
        local-hostname: \(hostname)
        """
    }

    public func writeSeed(spec: UbuntuInstallSpec, networkPlan: NetworkRebuildPlan) throws -> UbuntuAutoinstallArtifacts {
        let outputISO = URL(fileURLWithPath: spec.outputISOPath)
        let seedDirectory = outputISO.deletingPathExtension().appendingPathExtension("seed")
        try fileManager.createDirectory(at: seedDirectory, withIntermediateDirectories: true)

        let userDataURL = seedDirectory.appending(path: "user-data")
        let metaDataURL = seedDirectory.appending(path: "meta-data")
        let netplanURL = seedDirectory.appending(path: "90-tds-preserved.yaml")
        let userData = try renderUserData(spec: spec, networkPlan: networkPlan)
        let metaData = renderMetaData(spec: spec, networkPlan: networkPlan)
        let netplan = networkPlan.renderNetplanYAML()

        try userData.write(to: userDataURL, atomically: true, encoding: .utf8)
        try metaData.write(to: metaDataURL, atomically: true, encoding: .utf8)
        try netplan.write(to: netplanURL, atomically: true, encoding: .utf8)

        return UbuntuAutoinstallArtifacts(
            seedDirectory: seedDirectory.path,
            userDataPath: userDataURL.path,
            metaDataPath: metaDataURL.path,
            netplanPath: netplanURL.path,
            outputISOPath: spec.outputISOPath
        )
    }

    public func buildISO(spec: UbuntuInstallSpec, networkPlan: NetworkRebuildPlan) async throws -> UbuntuAutoinstallArtifacts {
        var artifacts = try writeSeed(spec: spec, networkPlan: networkPlan)
        var arguments = [
            scriptPath,
            "--source-iso", spec.sourceISOPath,
            "--seed-dir", artifacts.seedDirectory,
            "--output-iso", spec.outputISOPath,
        ]
        if !spec.workDirectoryPath.isEmpty {
            arguments.append(contentsOf: ["--workdir", spec.workDirectoryPath])
        }
        for extra in spec.extraKernelArguments {
            arguments.append(contentsOf: ["--extra-kernel-arg", extra])
        }

        _ = try await runner.run(
            "/bin/bash",
            arguments: arguments,
            environment: [:],
            currentDirectory: nil,
            timeout: nil
        )
        artifacts.validation = try await validateISO(at: spec.outputISOPath)
        if let validation = artifacts.validation, !validation.isValid {
            throw UbuntuBootstrapError.validationFailed(validation.failures)
        }
        return artifacts
    }

    public func validateISO(at isoPath: String) async throws -> UbuntuIsoValidationResult {
        let temp = fileManager.temporaryDirectory.appending(path: "tds-iso-validate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }

        let userDataURL = temp.appending(path: "user-data")
        let metaDataURL = temp.appending(path: "meta-data")
        let grubURL = temp.appending(path: "grub.cfg")
        var warnings: [String] = []

        let extract: [(String, URL)] = [
            ("/nocloud/user-data", userDataURL),
            ("/nocloud/meta-data", metaDataURL),
            ("/boot/grub/grub.cfg", grubURL),
        ]
        for (source, destination) in extract {
            do {
                _ = try await runner.run(
                    "/usr/bin/env",
                    arguments: ["xorriso", "-osirrox", "on", "-indev", isoPath, "-extract", source, destination.path],
                    environment: [:],
                    currentDirectory: nil,
                    timeout: TimeInterval(60)
                )
            } catch {
                warnings.append("Could not extract \(source): \(error.localizedDescription)")
            }
        }

        let userData = (try? String(contentsOf: userDataURL, encoding: .utf8)) ?? ""
        let metaData = (try? String(contentsOf: metaDataURL, encoding: .utf8)) ?? ""
        let grub = (try? String(contentsOf: grubURL, encoding: .utf8)) ?? ""

        var result = UbuntuIsoValidationResult(
            isoPath: isoPath,
            hasNoCloudUserData: !userData.isEmpty,
            hasNoCloudMetaData: !metaData.isEmpty,
            grubUsesNoCloud: grub.contains("ds=nocloud\\;s=/cdrom/nocloud/"),
            userDataHasAutoinstall: userData.contains("autoinstall:"),
            userDataCreatesRack: userData.contains("name: rack"),
            userDataConfiguresRoot: userData.contains("name: root") && userData.contains("PermitRootLogin yes"),
            userDataWritesTDSArtifacts: userData.contains("/var/log/installer/tds"),
            warnings: warnings
        )

        if !result.hasNoCloudUserData {
            result.failures.append("missing /nocloud/user-data")
        }
        if !result.hasNoCloudMetaData {
            result.failures.append("missing /nocloud/meta-data")
        }
        if !result.grubUsesNoCloud {
            result.failures.append("GRUB does not include autoinstall ds=nocloud\\;s=/cdrom/nocloud/")
        }
        if !result.userDataHasAutoinstall {
            result.failures.append("user-data does not contain autoinstall")
        }
        if !result.userDataCreatesRack {
            result.failures.append("user-data does not create rack")
        }
        if !result.userDataConfiguresRoot {
            result.failures.append("user-data does not configure root SSH/password access")
        }
        if !result.userDataWritesTDSArtifacts {
            result.failures.append("user-data does not preserve tds installer evidence")
        }
        return result
    }
}

public struct LocalMediaSessionRequest: Codable, Equatable, Sendable {
    public var oobURL: String
    public var username: String
    public var isoPath: String
    public var vendor: OOBVendor

    public init(oobURL: String, username: String = "", isoPath: String, vendor: OOBVendor = .ilo) {
        self.oobURL = oobURL
        self.username = username
        self.isoPath = isoPath
        self.vendor = vendor
    }
}

public struct LocalMediaSessionState: Codable, Equatable, Sendable {
    public var request: LocalMediaSessionRequest
    public var steps: [String]
    public var warnings: [String]

    public init(request: LocalMediaSessionRequest, steps: [String], warnings: [String] = []) {
        self.request = request
        self.steps = steps
        self.warnings = warnings
    }
}

public protocol LocalMediaSession: Sendable {
    func planSession(request: LocalMediaSessionRequest) throws -> LocalMediaSessionState
}

public struct Ilo4LocalMediaSession: LocalMediaSession {
    public init() {}

    public func planSession(request: LocalMediaSessionRequest) throws -> LocalMediaSessionState {
        guard request.vendor == .ilo || request.vendor == .unknown else {
            throw UbuntuBootstrapError.missingRequired("iLO local media session only supports HPE iLO in v1.")
        }
        guard !request.oobURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UbuntuBootstrapError.missingRequired("OOB URL is required.")
        }
        guard !request.isoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UbuntuBootstrapError.missingRequired("ISO path is required.")
        }
        return LocalMediaSessionState(
            request: request,
            steps: [
                "Open the iLO 4 web UI in the embedded tds WebKit session.",
                "Accept the self-signed certificate for this OOB endpoint only.",
                "Sign in with the supplied iLO credentials.",
                "Open the HTML5 remote console.",
                "Use Virtual Drives or local media attach and select \(request.isoPath).",
                "Keep tds open so the browser-backed media stream remains available until install completes.",
            ],
            warnings: [
                "If WebKit blocks file selection, tds will ask for one guided click inside the embedded browser instead of switching to an external browser.",
            ]
        )
    }
}

public struct DeployerBootstrapRun: Codable, Equatable, Sendable {
    public var installSpec: UbuntuInstallSpec
    public var networkPlan: NetworkRebuildPlan
    public var isoArtifacts: UbuntuAutoinstallArtifacts?
    public var localMediaState: LocalMediaSessionState?

    public init(
        installSpec: UbuntuInstallSpec,
        networkPlan: NetworkRebuildPlan,
        isoArtifacts: UbuntuAutoinstallArtifacts? = nil,
        localMediaState: LocalMediaSessionState? = nil
    ) {
        self.installSpec = installSpec
        self.networkPlan = networkPlan
        self.isoArtifacts = isoArtifacts
        self.localMediaState = localMediaState
    }
}

public final class BootstrapDeployerInstaller: @unchecked Sendable {
    private let builder: UbuntuAutoinstallBuilder
    private let localMediaSession: LocalMediaSession

    public init(
        builder: UbuntuAutoinstallBuilder = UbuntuAutoinstallBuilder(),
        localMediaSession: LocalMediaSession = Ilo4LocalMediaSession()
    ) {
        self.builder = builder
        self.localMediaSession = localMediaSession
    }

    public func buildRun(installSpec: UbuntuInstallSpec, oobURL: String = "", oobUsername: String = "") async throws -> DeployerBootstrapRun {
        let networkPlan = try builder.makeNetworkPlan(fromCapturePath: installSpec.capturePath)
        let artifacts = try await builder.buildISO(spec: installSpec, networkPlan: networkPlan)
        let localMediaState = try localMediaSession.planSession(
            request: LocalMediaSessionRequest(
                oobURL: oobURL,
                username: oobUsername,
                isoPath: artifacts.outputISOPath,
                vendor: .ilo
            )
        )
        return DeployerBootstrapRun(
            installSpec: installSpec,
            networkPlan: networkPlan,
            isoArtifacts: artifacts,
            localMediaState: localMediaState
        )
    }
}

public struct UbuntuCaptureLoader {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func load(from url: URL) throws -> NetworkPreservationSnapshot {
        let targetURL = try resolveSnapshotURL(url)
        let data = try Data(contentsOf: targetURL)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(NetworkPreservationSnapshot.self, from: data)
        } catch {
            throw UbuntuBootstrapError.invalidCapture("Expected a tds snapshot.json generated by `tds ubuntu snapshot`: \(error.localizedDescription)")
        }
    }

    private func resolveSnapshotURL(_ url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let nested = url.appending(path: "snapshot.json")
            if fileManager.fileExists(atPath: nested.path) {
                return nested
            }
            throw UbuntuBootstrapError.invalidCapture("No snapshot.json found in \(url.path)")
        }
        return url
    }
}

private struct NetworkCaptureParser {
    let snapshot: NetworkPreservationSnapshot

    func makePlan() throws -> NetworkRebuildPlan {
        let text = combinedCaptureText()
        let ifcfgFiles = parseIfcfgFiles(from: text)
        let macs = parseMACAddresses(from: text)
        let bridgeLinks = parseBridgeLinks(from: text)

        var ethernetsByName: [String: NetplanEthernet] = [:]
        var vlansByName: [String: NetplanVLAN] = [:]
        var bridgesByName: [String: NetplanBridge] = [:]

        for (fileName, values) in ifcfgFiles {
            let device = values["DEVICE"] ?? fileName
            guard !device.isEmpty, shouldManageInterface(device) else { continue }
            let type = (values["TYPE"] ?? "").lowercased()
            let bridgeName = values["BRIDGE"] ?? ""
            let ipAddress = values["IPADDR"] ?? ""
            let prefix = values["PREFIX"] ?? ""
            let gateway = values["GATEWAY"] ?? ""
            let routes = gateway.isEmpty ? [] : [NetplanRoute(to: "default", via: gateway)]
            let nameservers = dnsServers(from: values)
            let search = searchDomains(from: values)

            if type == "bridge" || device.hasPrefix("br-") {
                bridgesByName[device] = NetplanBridge(
                    name: device,
                    interfaces: bridgesByName[device]?.interfaces ?? [],
                    addresses: address(ipAddress, prefix),
                    routes: routes
                )
                continue
            }

            if values["VLAN"]?.lowercased() == "yes" || device.contains(".") {
                let parts = device.split(separator: ".", maxSplits: 1).map(String.init)
                guard parts.count == 2, let vlanID = Int(parts[1]) else { continue }
                vlansByName[device] = NetplanVLAN(name: device, id: vlanID, link: parts[0])
                if !bridgeName.isEmpty {
                    appendInterface(device, toBridge: bridgeName, bridges: &bridgesByName)
                }
                ensureEthernet(parts[0], macs: macs, ethernets: &ethernetsByName)
                continue
            }

            var ethernet = ethernetsByName[device] ?? NetplanEthernet(name: device, macAddress: macs[device] ?? "")
            ethernet.addresses = address(ipAddress, prefix)
            ethernet.routes = routes
            ethernet.nameservers = nameservers
            ethernet.searchDomains = search
            ethernetsByName[device] = ethernet
            if !bridgeName.isEmpty {
                appendInterface(device, toBridge: bridgeName, bridges: &bridgesByName)
            }
        }

        for (name, mac) in macs where shouldManageEthernet(name) && !name.contains(".") {
            if var ethernet = ethernetsByName[name] {
                if ethernet.macAddress.isEmpty {
                    ethernet.macAddress = mac
                    ethernetsByName[name] = ethernet
                }
            } else {
                ethernetsByName[name] = NetplanEthernet(name: name, macAddress: mac)
            }
        }

        for (bridge, members) in bridgeLinks {
            for member in members where shouldManageInterface(member) {
                appendInterface(member, toBridge: bridge, bridges: &bridgesByName)
            }
        }

        for (bridgeName, routes) in parseRouteFiles(from: text) {
            var bridge = bridgesByName[bridgeName] ?? NetplanBridge(name: bridgeName)
            bridge.routes = mergeRoutes(bridge.routes, routes)
            bridgesByName[bridgeName] = bridge
        }

        attachDNSFallback(to: &ethernetsByName)

        let plan = NetworkRebuildPlan(
            hostname: snapshot.summary.hostname,
            fqdn: snapshot.summary.hostname,
            ethernets: Array(ethernetsByName.values).filter { shouldManageEthernet($0.name) },
            vlans: Array(vlansByName.values),
            bridges: Array(bridgesByName.values).filter { !$0.interfaces.isEmpty || !$0.addresses.isEmpty }
        )
        guard !plan.ethernets.isEmpty || !plan.bridges.isEmpty else {
            throw UbuntuBootstrapError.invalidCapture("No reusable physical network configuration could be parsed from \(snapshot.directory)")
        }
        return plan
    }

    private func combinedCaptureText() -> String {
        var values = snapshot.captures.map(\.stdout)
        let directory = URL(fileURLWithPath: snapshot.directory, isDirectory: true)
        for candidate in ["host-networking.txt", "network-topology.txt"] {
            if let content = try? String(contentsOf: directory.appending(path: candidate), encoding: .utf8) {
                values.append(content)
            }
        }
        return values.joined(separator: "\n")
    }

    private func attachDNSFallback(to ethernetsByName: inout [String: NetplanEthernet]) {
        guard let targetName = ethernetsByName.values.sorted(by: { lhs, rhs in
            if lhs.routes.isEmpty != rhs.routes.isEmpty { return !lhs.routes.isEmpty }
            return lhs.name < rhs.name
        }).first?.name else { return }
        guard var target = ethernetsByName[targetName] else { return }
        target.nameservers = snapshot.summary.dnsServers.isEmpty ? target.nameservers : snapshot.summary.dnsServers
        target.searchDomains = snapshot.summary.searchDomains.isEmpty ? target.searchDomains : snapshot.summary.searchDomains
        ethernetsByName[targetName] = target
    }
}

private func parseIfcfgFiles(from text: String) -> [String: [String: String]] {
    let pattern = #"---FILE:[^\n]*/(?:ifcfg-)([^\n/]+)---\n([\s\S]*?)(?=\n---FILE:|\n---NM-SYSTEM-CONNECTIONS-LIST---|\n---OVS---|\z)"#
    var files: [String: [String: String]] = [:]
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return files }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    for match in regex.matches(in: text, range: range) {
        guard match.numberOfRanges >= 3 else { continue }
        let fileName = nsText.substring(with: match.range(at: 1))
        let body = nsText.substring(with: match.range(at: 2))
        var values: [String: String] = [:]
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator])
            var value = String(trimmed[trimmed.index(after: separator)...])
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }
        files[fileName] = values
    }
    return files
}

private func parseRouteFiles(from text: String) -> [String: [NetplanRoute]] {
    let pattern = #"---FILE:[^\n]*/route-([^\n/]+)---\n([\s\S]*?)(?=\n---FILE:|\n---NM-SYSTEM-CONNECTIONS-LIST---|\z)"#
    var files: [String: [NetplanRoute]] = [:]
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return files }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    for match in regex.matches(in: text, range: range) {
        guard match.numberOfRanges >= 3 else { continue }
        let bridgeName = nsText.substring(with: match.range(at: 1))
        let body = nsText.substring(with: match.range(at: 2))
        let routes = body.split(separator: "\n").compactMap { line -> NetplanRoute? in
            let tokens = line.split(separator: " ").map(String.init)
            guard tokens.count >= 3, tokens[1] == "via" else { return nil }
            return NetplanRoute(to: tokens[0], via: tokens[2])
        }
        files[bridgeName] = routes
    }
    return files
}

private func parseMACAddresses(from text: String) -> [String: String] {
    var macs: [String: String] = [:]
    var currentName = ""
    for line in text.split(separator: "\n").map(String.init) {
        if let name = firstRegexGroup(#"^\d+:\s+([^:@\s]+)"#, in: line).nilIfEmpty {
            currentName = name
            continue
        }
        guard !currentName.isEmpty, shouldManageEthernet(currentName) else { continue }
        if let mac = firstRegexGroup(#"\blink/ether\s+([0-9a-fA-F:]{17})\b"#, in: line).nilIfEmpty {
            macs[currentName] = mac
        }
    }
    return macs
}

private func parseBridgeLinks(from text: String) -> [String: [String]] {
    var links: [String: [String]] = [:]
    for line in text.split(separator: "\n") {
        let value = String(line)
        guard value.contains(" master ") else { continue }
        guard let name = firstRegexGroup(#"^\d+:\s+([^:@\s]+)"#, in: value).nilIfEmpty,
              let bridge = firstRegexGroup(#"\smaster\s+([^\s]+)"#, in: value).nilIfEmpty
        else { continue }
        appendUnique(name, to: &links[bridge, default: []])
    }
    return links
}

private func dnsServers(from values: [String: String]) -> [String] {
    values
        .filter { $0.key.hasPrefix("DNS") }
        .sorted { $0.key < $1.key }
        .map(\.value)
        .filter { !$0.isEmpty }
}

private func searchDomains(from values: [String: String]) -> [String] {
    guard let domain = values["DOMAIN"] else { return [] }
    return domain
        .split(separator: " ")
        .map(String.init)
        .filter { !$0.isEmpty }
}

private func address(_ ipAddress: String, _ prefix: String) -> [String] {
    guard !ipAddress.isEmpty else { return [] }
    guard !prefix.isEmpty else { return [ipAddress] }
    return ["\(ipAddress)/\(prefix)"]
}

private func appendInterface(_ interface: String, toBridge bridgeName: String, bridges: inout [String: NetplanBridge]) {
    var bridge = bridges[bridgeName] ?? NetplanBridge(name: bridgeName)
    appendUnique(interface, to: &bridge.interfaces)
    bridges[bridgeName] = bridge
}

private func ensureEthernet(_ name: String, macs: [String: String], ethernets: inout [String: NetplanEthernet]) {
    guard shouldManageEthernet(name), ethernets[name] == nil else { return }
    ethernets[name] = NetplanEthernet(name: name, macAddress: macs[name] ?? "")
}

private func mergeRoutes(_ lhs: [NetplanRoute], _ rhs: [NetplanRoute]) -> [NetplanRoute] {
    var result = lhs
    for route in rhs where !result.contains(route) {
        result.append(route)
    }
    return result
}

private func shouldManageInterface(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    let lowered = name.lowercased()
    if lowered == "lo" { return false }
    if lowered.hasPrefix("vnet") || lowered.hasPrefix("virbr") { return false }
    if lowered.hasPrefix("docker") || lowered.hasPrefix("cni") { return false }
    return true
}

private func shouldManageEthernet(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return shouldManageInterface(name) && !lowered.hasPrefix("br-") && !name.contains(".")
}

private func appendStringArray(_ values: [String], key: String, indent: String, to lines: inout [String]) {
    guard !values.isEmpty else { return }
    lines.append("\(indent)\(key):")
    for value in values {
        lines.append("\(indent)  - \(value)")
    }
}

private func appendRoutes(_ routes: [NetplanRoute], indent: String, to lines: inout [String]) {
    guard !routes.isEmpty else { return }
    lines.append("\(indent)routes:")
    for route in routes {
        lines.append("\(indent)  - to: \(route.to)")
        lines.append("\(indent)    via: \(route.via)")
    }
}

private func appendNameservers(addresses: [String], search: [String], indent: String, to lines: inout [String]) {
    guard !addresses.isEmpty || !search.isEmpty else { return }
    lines.append("\(indent)nameservers:")
    appendStringArray(addresses, key: "addresses", indent: indent + "  ", to: &lines)
    appendStringArray(search, key: "search", indent: indent + "  ", to: &lines)
}

private func appendUnique(_ value: String, to values: inout [String]) {
    guard !values.contains(value) else { return }
    values.append(value)
}

private func renderYAMLListField(key: String, values: [String], indent: String) -> String {
    guard !values.isEmpty else {
        return "\(indent)\(key): []"
    }
    let lines = ["\(indent)\(key):"] + values.map { "\(indent)  - \($0)" }
    return lines.joined(separator: "\n")
}

private func indentBlock(_ value: String, spaces: Int) -> String {
    let indent = String(repeating: " ", count: spaces)
    return value.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "\(indent)\($0)" }
        .joined(separator: "\n")
}

private func yamlQuote(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
}

private func yamlSingleQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

private func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func shortHostName(_ value: String) -> String {
    let short = value.split(separator: ".").first.map(String.init) ?? ""
    return short.isEmpty ? "tds-deployer" : short
}

private func firstNonEmpty(_ values: String...) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
}

private func firstRegexGroup(_ pattern: String, in text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
        return ""
    }
    return nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func lines(between start: String, and end: String, in text: String) -> [String] {
    guard let startRange = text.range(of: start) else { return [] }
    let rest = text[startRange.upperBound...]
    let body: Substring
    if let endRange = rest.range(of: end) {
        body = rest[..<endRange.lowerBound]
    } else {
        body = rest[...]
    }
    return body
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func parseSearchDomains(from text: String) -> [String] {
    let domains = text
        .split(separator: "\n")
        .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("search ") }
        .map {
            $0.trimmingCharacters(in: .whitespaces)
                .dropFirst("search ".count)
                .split(separator: " ")
                .map(String.init)
        } ?? []
    var unique: [String] = []
    for domain in domains {
        appendUnique(domain, to: &unique)
    }
    return unique
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
