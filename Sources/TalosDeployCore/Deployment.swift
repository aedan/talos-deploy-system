import Combine
import Foundation

public protocol AccessProfileManager: Sendable {
    func defaultProfile(from settings: AppSettings) -> AccessProfile
}

public struct DefaultAccessProfileManager: AccessProfileManager {
    public init() {}

    public func defaultProfile(from settings: AppSettings) -> AccessProfile {
        settings.accessProfiles.first(where: \.isDefault) ?? settings.accessProfiles.first ?? .directDefault
    }
}

public struct RedfishProbeResult: Codable, Equatable, Sendable {
    public var systemPath: String
    public var managerPath: String
    public var virtualMediaPath: String
    public var supportsVirtualMedia: Bool
    public var supportsBootURL: Bool

    public init(
        systemPath: String = "",
        managerPath: String = "",
        virtualMediaPath: String = "",
        supportsVirtualMedia: Bool = false,
        supportsBootURL: Bool = false
    ) {
        self.systemPath = systemPath
        self.managerPath = managerPath
        self.virtualMediaPath = virtualMediaPath
        self.supportsVirtualMedia = supportsVirtualMedia
        self.supportsBootURL = supportsBootURL
    }
}

public protocol RedfishClient: Sendable {
    func probe(device: DiscoveredDevice, accessProfile: AccessProfile?) async throws -> RedfishProbeResult
}

public final class DefaultRedfishClient: RedfishClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func probe(device: DiscoveredDevice, accessProfile: AccessProfile?) async throws -> RedfishProbeResult {
        guard let endpoint = device.oob, !endpoint.address.isEmpty else {
            return RedfishProbeResult()
        }
        let url = URL(string: "https://\(endpoint.address)/redfish/v1")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return RedfishProbeResult()
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let systemsPath = ((object?["Systems"] as? [String: Any])?["@odata.id"] as? String) ?? ""
        let managersPath = ((object?["Managers"] as? [String: Any])?["@odata.id"] as? String) ?? ""
        return RedfishProbeResult(
            systemPath: systemsPath,
            managerPath: managersPath,
            virtualMediaPath: managersPath.isEmpty ? "" : managersPath + "/1/VirtualMedia",
            supportsVirtualMedia: !managersPath.isEmpty,
            supportsBootURL: !systemsPath.isEmpty
        )
    }
}

public protocol DeployerHostClient: Sendable {
    func validate(connection: SSHConnection) async throws
    func validate(transport: any DeployerTransport) async throws -> DeployerAccessValidation
    func setHostname(_ hostname: String, connection: SSHConnection) async throws
    func setHostname(_ hostname: String, transport: any DeployerTransport) async throws
    func planDeployerServices(configuration: DeployerMediaServiceConfiguration) -> DeployerServicePlan
    func prepareDeployerServices(configuration: DeployerMediaServiceConfiguration, connection: SSHConnection) async throws -> DeployerServicePlan
    func prepareDeployerServices(configuration: DeployerMediaServiceConfiguration, transport: any DeployerTransport) async throws -> DeployerServicePlan
    func prepareMediaServices(configuration: DeployerMediaServiceConfiguration, connection: SSHConnection) async throws -> DeployerMediaServicePlan
    func prepareMediaServices(configuration: DeployerMediaServiceConfiguration, transport: any DeployerTransport) async throws -> DeployerMediaServicePlan
    func syncState(localDirectory: URL, remoteStateRoot: String, connection: SSHConnection) async throws
    func syncState(localDirectory: URL, remoteStateRoot: String, transport: any DeployerTransport) async throws
}

public final class DefaultDeployerHostClient: DeployerHostClient, @unchecked Sendable {
    private let router: SSHCommandRouter

    public init(router: SSHCommandRouter = SSHCommandRouter()) {
        self.router = router
    }

    public func validate(connection: SSHConnection) async throws {
        _ = try await validate(transport: DirectSSHDeployerTransport(connection: connection, router: router))
    }

    public func validate(transport: any DeployerTransport) async throws -> DeployerAccessValidation {
        try await transport.validate()
    }

    public func setHostname(_ hostname: String, connection: SSHConnection) async throws {
        try await setHostname(hostname, transport: DirectSSHDeployerTransport(connection: connection, router: router))
    }

    public func setHostname(_ hostname: String, transport: any DeployerTransport) async throws {
        let escaped = shellEscape(hostname)
        _ = try await transport.run("sudo hostnamectl set-hostname \(escaped) || hostnamectl set-hostname \(escaped)", timeout: 120)
    }

    public func planDeployerServices(configuration: DeployerMediaServiceConfiguration) -> DeployerServicePlan {
        let packages = ["ca-certificates", "curl", "dnsmasq", "python3", "openssh-client", "xorriso", "docker-registry", "skopeo", "chrony"]
        let talosctlVersion = configuration.talosctlVersion.isEmpty ? "configured Talos version" : configuration.talosctlVersion
        return DeployerServicePlan(
            packages: packages,
            onlineInstallCommands: [
                "apt-get update",
                "apt-get install -y \(packages.joined(separator: " "))",
                "install pinned talosctl \(talosctlVersion) into \(configuration.stateRoot)/bin/talosctl",
            ],
            cacheFallbackCommands: [
                "dpkg -i \(configuration.packageCacheRoot)/apt/*.deb || apt-get -f install -y",
                "install cached talosctl from \(configuration.packageCacheRoot)/talosctl/",
            ],
            systemdUnits: [
                "tds-media-http.service",
                "tds-dnsmasq.service",
                "chrony.service",
            ],
            notes: [
                "Use online package/tool sources first.",
                "Fall back to the tds-managed cache when the deployer has limited internet access.",
            ]
        )
    }

    private func renderDnsmasqConfig(configuration: DeployerMediaServiceConfiguration) -> String {
        let listenAddresses = uniqueNonEmpty(configuration.dnsListenAddresses)
        var lines = [
            "# Managed by tds. Final DHCP/PXE ranges are rendered per deployment run.",
            "log-dhcp",
            "enable-tftp",
        ]
        guard !listenAddresses.isEmpty else {
            lines.insert("port=0", at: 1)
            return lines.joined(separator: "\n")
        }

        lines.insert("port=53", at: 1)
        lines.append("bind-interfaces")
        lines.append("no-dhcp-interface=lo")
        lines.append(contentsOf: listenAddresses.map { "listen-address=\($0)" })
        return lines.joined(separator: "\n")
    }

    public func prepareDeployerServices(configuration: DeployerMediaServiceConfiguration, connection: SSHConnection) async throws -> DeployerServicePlan {
        try await prepareDeployerServices(
            configuration: configuration,
            transport: DirectSSHDeployerTransport(connection: connection, router: router)
        )
    }

    public func prepareDeployerServices(configuration: DeployerMediaServiceConfiguration, transport: any DeployerTransport) async throws -> DeployerServicePlan {
        let plan = planDeployerServices(configuration: configuration)
        let packageList = plan.packages.joined(separator: " ")
        let binRoot = "\(configuration.stateRoot)/bin"
        let dnsmasqRoot = "\(configuration.stateRoot)/dnsmasq"
        let mediaRoot = configuration.mediaRoot
        let logRoot = "\(configuration.stateRoot)/logs"
        let cacheRoot = configuration.packageCacheRoot
        let registryRoot = "\(configuration.stateRoot)/registry"
        let talosctlVersion = configuration.talosctlVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let dnsmasqConfig = renderDnsmasqConfig(configuration: configuration)
        let remoteCommand = """
        set -e
        sudo mkdir -p \(shellEscape(binRoot)) \(shellEscape(dnsmasqRoot)) \(shellEscape(mediaRoot)) \(shellEscape(logRoot)) \(shellEscape(registryRoot)) \(shellEscape(cacheRoot))/apt \(shellEscape(cacheRoot))/talosctl
        sudo mkdir -p \(shellEscape("\(configuration.stateRoot)/maintenance")) \(shellEscape("\(configuration.stateRoot)/machine-configs")) \(shellEscape("\(configuration.stateRoot)/generated")) \(shellEscape("\(configuration.stateRoot)/run"))
        sudo chown -R "$(id -un):$(id -gn)" \(shellEscape(configuration.stateRoot)) \(shellEscape(cacheRoot)) || true
        if command -v apt-get >/dev/null 2>&1; then
          sudo apt-get update || true
          sudo apt-get install -y \(packageList) || sudo dpkg -i \(shellEscape(cacheRoot))/apt/*.deb || true
        fi
        TALOSCTL_VERSION=\(shellEscape(talosctlVersion))
        ARCH="$(uname -m)"
        case "$ARCH" in
          x86_64|amd64) TDS_TALOS_ARCH=amd64 ;;
          aarch64|arm64) TDS_TALOS_ARCH=arm64 ;;
          *) TDS_TALOS_ARCH=amd64 ;;
        esac
        if [ -n "$TALOSCTL_VERSION" ] && command -v curl >/dev/null 2>&1; then
          curl -fsSL -o \(shellEscape("\(binRoot)/talosctl")) "https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-${TDS_TALOS_ARCH}" || true
          chmod 0755 \(shellEscape("\(binRoot)/talosctl")) || true
        elif [ -x \(shellEscape("\(cacheRoot)/talosctl/talosctl")) ]; then
          cp \(shellEscape("\(cacheRoot)/talosctl/talosctl")) \(shellEscape("\(binRoot)/talosctl"))
          chmod 0755 \(shellEscape("\(binRoot)/talosctl"))
        fi
        cat > \(shellEscape("\(dnsmasqRoot)/tds-dnsmasq.conf")) <<'EOF'
        \(dnsmasqConfig)
        EOF
        cat > /tmp/tds-media-http.service <<'EOF'
        [Unit]
        Description=TDS range-capable media HTTP service
        After=network-online.target

        [Service]
        Type=simple
        ExecStart=\(binRoot)/tds-range-http-server.py --bind \(configuration.httpBindAddress) --port \(configuration.httpPort) --directory \(mediaRoot)
        Restart=on-failure
        StandardOutput=append:\(logRoot)/media-http.log
        StandardError=append:\(logRoot)/media-http.log

        [Install]
        WantedBy=multi-user.target
        EOF
        cat > /tmp/tds-dnsmasq.service <<'EOF'
        [Unit]
        Description=TDS dnsmasq PXE service
        After=network-online.target

        [Service]
        Type=simple
        ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=\(dnsmasqRoot)/tds-dnsmasq.conf
        Restart=on-failure

        [Install]
        WantedBy=multi-user.target
        EOF
        sudo mv /tmp/tds-media-http.service /etc/systemd/system/tds-media-http.service || true
        sudo mv /tmp/tds-dnsmasq.service /etc/systemd/system/tds-dnsmasq.service || true
        if command -v docker-registry >/dev/null 2>&1 || command -v registry >/dev/null 2>&1; then
          sudo mkdir -p /etc/docker/registry \(shellEscape(registryRoot))
          cat > /tmp/tds-docker-registry.yml <<'EOF'
        version: 0.1
        log:
          fields:
            service: tds-registry
        storage:
          cache:
            blobdescriptor: inmemory
          filesystem:
            rootdirectory: \(registryRoot)
        http:
          addr: :\(configuration.registryPort)
          headers:
            X-Content-Type-Options: [nosniff]
        EOF
          sudo mv /tmp/tds-docker-registry.yml /etc/docker/registry/config.yml || true
        \(dockerRegistryWritableCommand(registryRoot: registryRoot))
          sudo systemctl enable --now docker-registry || sudo systemctl restart docker-registry || true
        fi
        if command -v chronyd >/dev/null 2>&1; then
          sudo mkdir -p /etc/chrony/conf.d
          cat > /tmp/tds-chrony-server.conf <<'EOF'
        # Managed by tds. Allows Talos nodes to sync time from the deployer.
        server ntp.ubuntu.com iburst
        server time.cloudflare.com iburst
        port 123
        local stratum 10
        allow 10.0.0.0/8
        allow 172.16.0.0/12
        allow 192.168.0.0/16
        EOF
          sudo mv /tmp/tds-chrony-server.conf /etc/chrony/conf.d/tds-server.conf || true
          sudo systemctl enable --now chrony || sudo systemctl restart chrony || true
        fi
        sudo systemctl daemon-reload || true
        """
        _ = try await transport.run(remoteCommand, timeout: 900)
        return plan
    }

    public func prepareMediaServices(configuration: DeployerMediaServiceConfiguration, connection: SSHConnection) async throws -> DeployerMediaServicePlan {
        try await prepareMediaServices(
            configuration: configuration,
            transport: DirectSSHDeployerTransport(connection: connection, router: router)
        )
    }

    public func prepareMediaServices(configuration: DeployerMediaServiceConfiguration, transport: any DeployerTransport) async throws -> DeployerMediaServicePlan {
        let mediaRoot = configuration.mediaRoot
        let pxeRoot = configuration.pxeRoot
        let binRoot = "\(configuration.stateRoot)/bin"
        let logRoot = "\(configuration.stateRoot)/logs"
        let runRoot = "\(configuration.stateRoot)/run"
        let scriptPath = "\(binRoot)/tds-range-http-server.py"
        let logPath = "\(logRoot)/media-http.log"
        let pidPath = "\(runRoot)/media-http.pid"
        let startCommand = "nohup python3 \(shellEscape(scriptPath)) --bind \(shellEscape(configuration.httpBindAddress)) --port \(configuration.httpPort) --directory \(shellEscape(mediaRoot)) > \(shellEscape(logPath)) 2>&1 & echo $! > \(shellEscape(pidPath))"

        let remoteCommand = """
        set -e
        sudo mkdir -p \(shellEscape(mediaRoot)) \(shellEscape(pxeRoot)) \(shellEscape(binRoot)) \(shellEscape(logRoot)) \(shellEscape(runRoot))
        sudo chown -R "$(id -un):$(id -gn)" \(shellEscape(configuration.stateRoot)) || true
        cat > \(shellEscape(scriptPath)) <<'PY'
        #!/usr/bin/env python3
        import argparse
        import os
        import posixpath
        import re
        from http.server import SimpleHTTPRequestHandler, HTTPServer
        from socketserver import ThreadingMixIn
        from urllib.parse import unquote

        class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
            daemon_threads = True

        class RangeRequestHandler(SimpleHTTPRequestHandler):
            directory = os.getcwd()

            def translate_path(self, path):
                path = path.split('?', 1)[0].split('#', 1)[0]
                path = posixpath.normpath(unquote(path))
                words = [w for w in path.split('/') if w]
                target = type(self).directory
                for word in words:
                    drive, word = os.path.splitdrive(word)
                    head, word = os.path.split(word)
                    if word in (os.curdir, os.pardir):
                        continue
                    target = os.path.join(target, word)
                return target

            def send_head(self):
                path = self.translate_path(self.path)
                if os.path.isdir(path):
                    return super().send_head()
                try:
                    file_obj = open(path, 'rb')
                except OSError:
                    self.send_error(404, 'File not found')
                    return None
                size = os.fstat(file_obj.fileno()).st_size
                range_header = self.headers.get('Range')
                if not range_header:
                    self.send_response(200)
                    self.send_header('Content-type', 'application/octet-stream')
                    self.send_header('Content-Length', str(size))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.end_headers()
                    return file_obj
                match = re.match(r'bytes=(\\d+)-(\\d*)$', range_header)
                if not match:
                    self.send_error(416, 'Invalid range')
                    file_obj.close()
                    return None
                start = int(match.group(1))
                end = int(match.group(2)) if match.group(2) else size - 1
                if start >= size:
                    self.send_error(416, 'Requested range not satisfiable')
                    file_obj.close()
                    return None
                end = min(end, size - 1)
                self.range = (start, end)
                file_obj.seek(start)
                self.send_response(206)
                self.send_header('Content-type', 'application/octet-stream')
                self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
                self.send_header('Content-Length', str(end - start + 1))
                self.send_header('Accept-Ranges', 'bytes')
                self.end_headers()
                return file_obj

            def copyfile(self, source, outputfile):
                if hasattr(self, 'range'):
                    start, end = self.range
                    remaining = end - start + 1
                    while remaining > 0:
                        chunk = source.read(min(1024 * 1024, remaining))
                        if not chunk:
                            break
                        try:
                            outputfile.write(chunk)
                        except BrokenPipeError:
                            break
                        remaining -= len(chunk)
                    del self.range
                    return
                return super().copyfile(source, outputfile)

        def main():
            parser = argparse.ArgumentParser()
            parser.add_argument('--bind', default='0.0.0.0')
            parser.add_argument('--port', type=int, default=8080)
            parser.add_argument('--directory', required=True)
            args = parser.parse_args()
            RangeRequestHandler.directory = args.directory
            ThreadingHTTPServer((args.bind, args.port), RangeRequestHandler).serve_forever()

        if __name__ == '__main__':
            main()
        PY
        chmod 0755 \(shellEscape(scriptPath))
        cat > \(shellEscape("\(configuration.stateRoot)/media-service.env")) <<'EOF'
        MEDIA_ROOT=\(shellEscape(mediaRoot))
        PXE_ROOT=\(shellEscape(pxeRoot))
        HTTP_BIND=\(shellEscape(configuration.httpBindAddress))
        HTTP_PORT=\(configuration.httpPort)
        START_COMMAND=\(shellEscape(startCommand))
        EOF
        """
        _ = try await transport.run(remoteCommand, timeout: 300)

        return DeployerMediaServicePlan(
            mediaRoot: mediaRoot,
            pxeRoot: pxeRoot,
            httpBindAddress: configuration.httpBindAddress,
            httpPort: configuration.httpPort,
            serviceCommand: startCommand,
            notes: [
                "tds prepared the media/PXE directories and range-capable HTTP service on the selected deployer.",
                "Start the service after media is staged, or let a deployment runner start it when executing the install.",
            ]
        )
    }

    public func syncState(localDirectory: URL, remoteStateRoot: String, connection: SSHConnection) async throws {
        try await syncState(
            localDirectory: localDirectory,
            remoteStateRoot: remoteStateRoot,
            transport: DirectSSHDeployerTransport(connection: connection, router: router)
        )
    }

    public func syncState(localDirectory: URL, remoteStateRoot: String, transport: any DeployerTransport) async throws {
        _ = try await transport.run("mkdir -p \(shellEscape(remoteStateRoot))", timeout: 120)
        try await transport.copy(localPath: localDirectory, remotePath: remoteStateRoot, delete: false)
    }
}

public protocol TalosBuilder: Sendable {
    func buildArtifacts(for spec: DeploymentSpec, plan: DeploymentPlan, in directory: URL) async throws -> URL
}

public struct DeployerNaming: Sendable {
    public init() {}

    public func hostname(for device: DiscoveredDevice, suffix: String = "") -> String {
        let number = deviceNumber(for: device)
        let cleanSuffix = sanitize(suffix)
        return cleanSuffix.isEmpty ? "\(number)-deployer" : "\(number)-deployer-\(cleanSuffix)"
    }

    private func deviceNumber(for device: DiscoveredDevice) -> String {
        let idDigits = device.id.filter(\.isNumber)
        if !idDigits.isEmpty {
            return String(idDigits)
        }
        let nameDigits = device.name.prefix(while: \.isNumber)
        return nameDigits.isEmpty ? device.id : String(nameDigits)
    }

    private func sanitize(_ value: String) -> String {
        value
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public struct StaticNetworkPlanner: Sendable {
    public init() {}

    public func validate(spec: DeploymentSpec) -> [StaticNetworkValidationResult] {
        spec.nodes
            .filter { $0.assignment.role == .controlplane || $0.assignment.role == .worker }
            .map { validate(node: $0) }
    }

    public func validate(node: DeploymentNodeSpec) -> StaticNetworkValidationResult {
        var config = deriveConfig(for: node)
        var errors: [String] = []
        var warnings: [String] = []

        if node.assignment.networkSource == .unavailable {
            errors.append("No network source is available. Provide manual static networking before deployment.")
        }

        if config.managementInterface.isEmpty && config.managementHardwareAddress.isEmpty {
            errors.append("Missing management interface or management NIC hardware address.")
        }
        if config.managementAddressCIDR.isEmpty {
            errors.append("Missing static management address with CIDR from Core, capture, or manual input.")
        } else if !config.managementAddressCIDR.contains("/") {
            errors.append("Static management address must include CIDR prefix.")
        }
        if config.gateway.isEmpty {
            errors.append("Missing default gateway.")
        } else if !config.routes.contains(where: { $0.to == "default" }) {
            config.routes.insert(StaticNetworkRoute(to: "default", via: config.gateway), at: 0)
        }
        if config.nameservers.isEmpty {
            errors.append("Missing DNS nameserver list.")
        }

        if !node.device.privateIP.isEmpty {
            warnings.append("Using Core private IP \(node.device.privateIP) as preferred Talos management IP.")
        } else if !node.device.primaryIP.isEmpty {
            warnings.append("Core private IP missing; using primary IP \(node.device.primaryIP) as Talos management IP.")
        }

        return StaticNetworkValidationResult(
            deviceID: node.device.id,
            isValid: errors.isEmpty,
            config: config,
            errors: errors,
            warnings: warnings
        )
    }

    public func config(for node: DeploymentNodeSpec) -> StaticNetworkConfig {
        validate(node: node).config
    }

    private func deriveConfig(for node: DeploymentNodeSpec) -> StaticNetworkConfig {
        let manual = node.assignment.staticNetwork
        let preferredIP = firstNonEmptyStatic(node.device.privateIP, node.device.primaryIP)
        let matchingInterface = interface(on: node.device, containing: preferredIP) ?? node.device.networkInterfaces.first
        let matchingAddress = matchingInterface?.addresses.first(where: { address in
            preferredIP.isEmpty || address == preferredIP || address.hasPrefix("\(preferredIP)/")
        }) ?? matchingInterface?.addresses.first ?? ""

        var config = manual
        if config.managementInterface.isEmpty {
            config.managementInterface = matchingInterface?.name ?? ""
        }
        if config.managementAddressCIDR.isEmpty {
            config.managementAddressCIDR = matchingAddress
        }
        return config
    }

    private func interface(on device: DiscoveredDevice, containing ip: String) -> NetworkInterface? {
        guard !ip.isEmpty else { return nil }
        return device.networkInterfaces.first { interface in
            interface.addresses.contains { $0 == ip || $0.hasPrefix("\(ip)/") }
        }
    }
}

public struct TalosFactoryVersion: Codable, Equatable, Identifiable, Sendable {
    public var value: String

    public var id: String { value }

    public var isPrerelease: Bool {
        value.contains("-")
    }

    public var displayName: String {
        isPrerelease ? "\(value) (prerelease)" : value
    }

    public init(value: String) {
        self.value = value
    }
}

public struct TalosFactoryVersionCatalog: Codable, Equatable, Sendable {
    public var versions: [TalosFactoryVersion]

    public var newestStable: TalosFactoryVersion? {
        versions.first { !$0.isPrerelease }
    }

    public init(rawVersions: [String]) {
        self.versions = rawVersions
            .map { TalosFactoryVersion(value: $0) }
            .sorted { lhs, rhs in
                TalosSemanticVersion(lhs.value) > TalosSemanticVersion(rhs.value)
            }
    }

    public func contains(_ version: String) -> Bool {
        versions.contains { $0.value == version }
    }

    public func preferredVersion(preserving currentVersion: String) -> TalosFactoryVersion? {
        if contains(currentVersion) {
            return TalosFactoryVersion(value: currentVersion)
        }
        return newestStable ?? versions.first
    }
}

public enum TalosFactoryError: Error, LocalizedError {
    case invalidURL(String)
    case unexpectedStatus(Int)
    case emptyVersionCatalog

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid Talos Image Factory URL: \(url)"
        case .unexpectedStatus(let status):
            return "Talos Image Factory returned HTTP \(status) while loading versions."
        case .emptyVersionCatalog:
            return "Talos Image Factory returned no deployable versions."
        }
    }
}

private struct TalosSemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?
    let raw: String

    init(_ raw: String) {
        self.raw = raw
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts.first?.split(separator: ".").map { Int($0) ?? 0 } ?? []
        self.major = numbers.indices.contains(0) ? numbers[0] : 0
        self.minor = numbers.indices.contains(1) ? numbers[1] : 0
        self.patch = numbers.indices.contains(2) ? numbers[2] : 0
        self.prerelease = parts.indices.contains(1) ? String(parts[1]) : nil
    }

    static func < (lhs: TalosSemanticVersion, rhs: TalosSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return lhs.raw < rhs.raw
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case let (left?, right?):
            return left < right
        }
    }
}

public struct TalosFactoryClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func renderSchematic(settings: TalosImageFactorySettings) -> String {
        var lines = ["customization:"]
        if !settings.extraKernelArgs.isEmpty {
            lines.append("  extraKernelArgs:")
            lines.append(contentsOf: settings.extraKernelArgs.map { "    - \(yamlScalar($0))" })
        }
        if !settings.selectedSystemExtensions.isEmpty {
            lines.append("  systemExtensions:")
            lines.append("    officialExtensions:")
            lines.append(contentsOf: settings.selectedSystemExtensions.map { "      - \(yamlScalar($0))" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func artifactURLs(settings: TalosImageFactorySettings, talosVersion: String) -> TalosFactoryArtifacts {
        let baseURL = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pxeBaseURL = settings.pxeBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model = "\(settings.platform)-\(settings.architecture)"
        return TalosFactoryArtifacts(
            schematicID: settings.schematicID,
            schematicYAML: renderSchematic(settings: settings),
            isoURL: "\(baseURL)/image/\(settings.schematicID)/\(talosVersion)/\(model).iso",
            pxeURL: "\(pxeBaseURL)/pxe/\(settings.schematicID)/\(talosVersion)/\(model)",
            installerImage: "\(settings.registryHost)/installer/\(settings.schematicID):\(talosVersion)"
        )
    }

    public func fetchVersions(baseURL: String) async throws -> TalosFactoryVersionCatalog {
        let normalizedBaseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(normalizedBaseURL)/versions"),
              url.scheme != nil,
              url.host != nil
        else {
            throw TalosFactoryError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TalosFactoryError.unexpectedStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TalosFactoryError.unexpectedStatus(http.statusCode)
        }
        return try parseVersions(data: data)
    }

    public func parseVersions(data: Data) throws -> TalosFactoryVersionCatalog {
        let rawVersions = try JSONDecoder().decode([String].self, from: data)
        let catalog = TalosFactoryVersionCatalog(rawVersions: rawVersions)
        guard !catalog.versions.isEmpty else {
            throw TalosFactoryError.emptyVersionCatalog
        }
        return catalog
    }
}

public final class DefaultTalosBuilder: TalosBuilder, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func buildArtifacts(for spec: DeploymentSpec, plan: DeploymentPlan, in directory: URL) async throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appending(path: "deployment-manifest.json")
        let manifestData = try JSONEncoder.pretty.encode(plan)
        try manifestData.write(to: manifestURL, options: .atomic)

        let nodesDirectory = directory.appending(path: "node-patches", directoryHint: .isDirectory)
        let bootNodesDirectory = directory.appending(path: "boot-node-patches", directoryHint: .isDirectory)
        let bootNetworkMetaDirectory = directory.appending(path: "boot-network-meta", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bootNodesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bootNetworkMetaDirectory, withIntermediateDirectories: true)
        for node in spec.nodes where node.assignment.role == .controlplane || node.assignment.role == .worker {
            let yaml = renderNodePatch(
                node: node,
                spec: spec,
                includeAdditionalNetworking: true,
                includeInstall: true
            )
            try yaml.write(
                to: nodesDirectory.appending(path: "\(node.device.name).yaml"),
                atomically: true,
                encoding: .utf8
            )
            let bootYAML = renderNodePatch(
                node: node,
                spec: spec,
                includeAdditionalNetworking: false,
                includeInstall: false
            )
            try bootYAML.write(
                to: bootNodesDirectory.appending(path: "\(node.device.name).yaml"),
                atomically: true,
                encoding: .utf8
            )
            let bootNetworkMeta = renderInitialNetworkMeta(node: node, spec: spec)
            try bootNetworkMeta.write(
                to: bootNetworkMetaDirectory.appending(path: "\(node.device.name).yaml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let clusterURL = directory.appending(path: "cluster.yaml")
        try renderClusterFile(spec: spec).write(to: clusterURL, atomically: true, encoding: .utf8)

        let factoryURL = directory.appending(path: "talos-factory-schematic.yaml")
        try plan.talosArtifacts.schematicYAML.write(to: factoryURL, atomically: true, encoding: .utf8)

        let artifactsURL = directory.appending(path: "talos-artifacts.json")
        let artifactsData = try JSONEncoder.pretty.encode(plan.talosArtifacts)
        try artifactsData.write(to: artifactsURL, options: .atomic)
        return directory
    }

    private func renderNodePatch(
        node: DeploymentNodeSpec,
        spec: DeploymentSpec,
        includeAdditionalNetworking: Bool,
        includeInstall: Bool
    ) -> String {
        let staticConfig = StaticNetworkPlanner().config(for: node)
        let interfaceName = firstNonEmptyStatic(staticConfig.managementInterface, node.device.networkInterfaces.first?.name ?? "eth0")
        let managementHardwareAddress = staticConfig.managementHardwareAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let managementBridge = includeAdditionalNetworking ? finalManagementBridge(for: staticConfig, fallbackInterfaceName: interfaceName) : nil
        let installerImage = deployerRegistryInstallerImage(for: spec)
            ?? TalosFactoryClient().artifactURLs(settings: spec.talosFactory, talosVersion: spec.talosVersion).installerImage
        var lines = [
            "machine:",
            "  type: \(node.assignment.role == .worker ? "worker" : "controlplane")",
        ]
        lines.append(contentsOf: renderKernelModules(spec.talosKernelModules))
        lines.append(contentsOf: renderLonghornExtraMounts(enabled: spec.enableLonghornExtraMounts))
        lines.append(contentsOf: renderRegistryMirror(spec: spec))
        lines.append(contentsOf: renderTimeServers(spec: spec))
        lines.append("  network:")
        lines.append(contentsOf: renderNameservers(staticConfig, spec: spec))
        lines.append("    interfaces:")
        if let managementBridge {
            lines.append("      - interface: \(managementBridge.name)")
        } else if !managementHardwareAddress.isEmpty {
            lines.append("      - deviceSelector:")
            lines.append("          hardwareAddr: \(yamlScalar(managementHardwareAddress))")
        } else {
            lines.append("      - interface: \(interfaceName)")
        }
        if !staticConfig.managementAddressCIDR.isEmpty {
            lines.append("        addresses:")
            lines.append("          - \(staticConfig.managementAddressCIDR)")
        }
        lines.append(contentsOf: renderRoutes(staticConfig.routes))
        if let managementBridge {
            lines.append(contentsOf: renderBridgeBody(managementBridge))
        }
        if includeAdditionalNetworking {
            lines.append(contentsOf: renderVLANParentInterfaces(staticConfig.vlans, excluding: [interfaceName]))
            lines.append(contentsOf: renderBridgeInterfaces(
                staticConfig.bridges,
                excluding: managementBridge.map { [$0.name] } ?? []
            ))
        }
        if includeInstall {
            lines.append("  install:")
            lines.append("    disk: \(node.device.installDisk.isEmpty ? "/dev/sda" : node.device.installDisk)")
            lines.append("    image: \(installerImage)")
            lines.append("    wipe: \(spec.talosProvisioning.wipeSystemDiskBeforeInstall ? "true" : "false")")
            lines.append("    legacyBIOSSupport: \(spec.talosProvisioning.legacyBIOSSupport ? "true" : "false")")
            lines.append(contentsOf: renderExtraKernelArgs(spec.talosFactory.extraKernelArgs))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderInitialNetworkMeta(node: DeploymentNodeSpec, spec: DeploymentSpec) -> String {
        let staticConfig = StaticNetworkPlanner().config(for: node)
        let interfaceName = firstNonEmptyStatic(staticConfig.managementInterface, node.device.networkInterfaces.first?.name ?? "eth0")
        var lines = [
            "addresses:",
            "  - address: \(yamlScalar(staticConfig.managementAddressCIDR))",
            "    linkName: \(yamlScalar(interfaceName))",
            "    family: inet4",
            "    scope: global",
            "    flags: permanent",
            "    layer: platform",
            "links:",
            "  - name: \(yamlScalar(interfaceName))",
            "    up: true",
            "    layer: platform",
        ]
        if !staticConfig.gateway.isEmpty {
            lines.append(contentsOf: [
                "routes:",
                "  - gateway: \(yamlScalar(staticConfig.gateway))",
                "    outLinkName: \(yamlScalar(interfaceName))",
                "    table: main",
                "    priority: 1024",
                "    scope: global",
                "    type: unicast",
                "    protocol: static",
                "    layer: platform",
            ])
        }
        let nameservers = renderNameserverValues(staticConfig, spec: spec)
        if !nameservers.isEmpty {
            lines.append("resolvers:")
            lines.append("  - dnsServers:")
            lines.append(contentsOf: nameservers.map { "      - \(yamlScalar($0))" })
            lines.append("    layer: platform")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderRegistryMirror(spec: DeploymentSpec) -> [String] {
        guard let endpoint = deployerRegistryEndpoint(for: spec),
              let host = deployerRegistryHost(for: spec)
        else {
            return []
        }
        var lines = [
            "  registries:",
            "    mirrors:",
            "      \(yamlQuotedString(host)):",
            "        endpoints:",
            "          - \(yamlScalar(endpoint))",
            "        skipFallback: true",
        ]
        for mirrorHost in deployerRegistryMirrorHosts(for: spec) {
            lines.append("      \(yamlQuotedString(mirrorHost)):")
            lines.append("        endpoints:")
            lines.append("          - \(yamlScalar(endpoint))")
            lines.append("        skipFallback: true")
        }
        return lines
    }

    private func renderTimeServers(spec: DeploymentSpec) -> [String] {
        let server = deployerNodeAddress(for: spec).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return [] }
        return [
            "  time:",
            "    servers:",
            "      - \(yamlScalar(server))",
        ]
    }

    private func renderKernelModules(_ modules: [TalosKernelModule]) -> [String] {
        guard !modules.isEmpty else { return [] }
        var lines = ["  kernel:", "    modules:"]
        for module in modules {
            lines.append("      - name: \(module.name)")
            if !module.parameters.isEmpty {
                lines.append("        parameters:")
                lines.append(contentsOf: module.parameters.map { "          - \(yamlScalar($0))" })
            }
        }
        return lines
    }

    private func renderExtraKernelArgs(_ args: [String]) -> [String] {
        guard !args.isEmpty else { return [] }
        return ["    extraKernelArgs:"] + args.map { "      - \(yamlScalar($0))" }
    }

    private func renderRoutes(_ routes: [StaticNetworkRoute]) -> [String] {
        guard !routes.isEmpty else { return [] }
        var lines = ["        routes:"]
        for route in routes {
            lines.append("          - network: \(renderRouteDestination(route.to))")
            lines.append("            gateway: \(route.via)")
            if let metric = route.metric {
                lines.append("            metric: \(metric)")
            }
        }
        return lines
    }

    private func renderNestedRoutes(_ routes: [StaticNetworkRoute], indent: String) -> [String] {
        guard !routes.isEmpty else { return [] }
        var lines = ["\(indent)routes:"]
        for route in routes {
            lines.append("\(indent)  - network: \(renderRouteDestination(route.to))")
            if !route.via.isEmpty {
                lines.append("\(indent)    gateway: \(route.via)")
            }
            if let metric = route.metric {
                lines.append("\(indent)    metric: \(metric)")
            }
        }
        return lines
    }

    private func renderVLANParentInterfaces(_ vlans: [NetworkInterface], excluding excludedParents: Set<String> = []) -> [String] {
        let resolved = vlans
            .filter { $0.vlanID != nil }
            .map { vlan in
                (
                    parent: firstNonEmptyStatic(vlan.parentInterface, parentInterfaceName(for: vlan.name)),
                    vlan: vlan
                )
            }
            .filter { !$0.parent.isEmpty && !excludedParents.contains($0.parent) }
        guard !resolved.isEmpty else { return [] }

        let grouped = Dictionary(grouping: resolved, by: \.parent)
        var lines: [String] = []
        for parent in grouped.keys.sorted() {
            lines.append("      - interface: \(parent)")
            lines.append("        vlans:")
            for entry in grouped[parent, default: []].map(\.vlan).sorted(by: { ($0.vlanID ?? 0) < ($1.vlanID ?? 0) }) {
                guard let vlanID = entry.vlanID else { continue }
                lines.append("          - vlanId: \(vlanID)")
                if !entry.addresses.isEmpty {
                    lines.append("            addresses:")
                    lines.append(contentsOf: entry.addresses.map { "              - \($0)" })
                }
                if let mtu = entry.mtu {
                    lines.append("            mtu: \(mtu)")
                }
                lines.append(contentsOf: renderNestedRoutes(entry.routes, indent: "            "))
            }
        }
        return lines
    }

    private func renderBridgeInterfaces(_ bridges: [NetworkInterface]) -> [String] {
        renderBridgeInterfaces(bridges, excluding: [])
    }

    private func renderBridgeInterfaces(_ bridges: [NetworkInterface], excluding excludedNames: [String]) -> [String] {
        guard !bridges.isEmpty else { return [] }
        let excludedNames = Set(excludedNames)
        var lines: [String] = []
        for bridge in bridges.sorted(by: { $0.name < $1.name }) where !bridge.name.isEmpty && !excludedNames.contains(bridge.name) {
            lines.append("      - interface: \(bridge.name)")
            if !bridge.addresses.isEmpty {
                lines.append("        addresses:")
                lines.append(contentsOf: bridge.addresses.map { "          - \($0)" })
            }
            lines.append(contentsOf: renderBridgeBody(bridge))
        }
        return lines
    }

    private func renderBridgeBody(_ bridge: NetworkInterface) -> [String] {
        var lines: [String] = []
        if let mtu = bridge.mtu {
            lines.append("        mtu: \(mtu)")
        }
        lines.append(contentsOf: renderNestedRoutes(bridge.routes, indent: "        "))
        if !bridge.bridgePorts.isEmpty {
            lines.append("        bridge:")
            lines.append("          interfaces:")
            lines.append(contentsOf: bridge.bridgePorts.map { "            - \($0)" })
            lines.append("          stp:")
            lines.append("            enabled: false")
        }
        return lines
    }

    private func finalManagementBridge(
        for config: StaticNetworkConfig,
        fallbackInterfaceName: String
    ) -> NetworkInterface? {
        let managementInterface = config.managementInterface
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = config.bridges.filter { bridge in
            guard !bridge.name.isEmpty, bridge.addresses.isEmpty else { return false }
            if bridge.name == managementInterface || bridge.name == fallbackInterfaceName {
                return true
            }
            if bridge.bridgePorts.contains(managementInterface) || bridge.bridgePorts.contains(fallbackInterfaceName) {
                return true
            }
            return false
        }
        return candidates.first
    }

    private func parentInterfaceName(for vlanName: String) -> String {
        guard let dot = vlanName.firstIndex(of: ".") else { return "" }
        return String(vlanName[..<dot])
    }

    private func renderRouteDestination(_ destination: String) -> String {
        destination == "default" ? "0.0.0.0/0" : destination
    }

    private func renderNameserverValues(_ config: StaticNetworkConfig, spec: DeploymentSpec) -> [String] {
        uniqueNonEmpty([deployerNodeAddress(for: spec)] + config.nameservers)
    }

    private func renderNameservers(_ config: StaticNetworkConfig, spec: DeploymentSpec) -> [String] {
        let nameservers = renderNameserverValues(config, spec: spec)
        guard !nameservers.isEmpty || !config.searchDomains.isEmpty else { return [] }
        var lines = ["    nameservers:"]
        if !nameservers.isEmpty {
            lines.append(contentsOf: nameservers.map { "      - \($0)" })
        }
        if !config.searchDomains.isEmpty {
            lines.append("    searchDomains:")
            lines.append(contentsOf: config.searchDomains.map { "      - \($0)" })
        }
        return lines
    }

    private func renderLonghornExtraMounts(enabled: Bool) -> [String] {
        guard enabled else { return [] }
        return [
            "  kubelet:",
            "    extraMounts:",
            "      - destination: /var/lib/longhorn",
            "        type: bind",
            "        source: /var/lib/longhorn",
            "        options:",
            "          - bind",
            "          - rshared",
            "          - rw",
        ]
    }

    private func renderClusterFile(spec: DeploymentSpec) -> String {
        """
        cluster:
          name: \(spec.clusterName)
          endpoint: \(spec.clusterEndpoint)
          talosVersion: \(spec.talosVersion)
          kubernetesVersion: \(spec.kubernetesVersion)
        """
    }
}

private func yamlScalar(_ value: String) -> String {
    let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@+"))
    if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
        return value
    }
    return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func yamlQuotedString(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func firstNonEmptyStatic(_ values: String...) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
}

private func uniqueNonEmpty(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty {
        guard seen.insert(value).inserted else { continue }
        result.append(value)
    }
    return result
}

func deployerRegistryHost(for spec: DeploymentSpec) -> String? {
    guard spec.talosProvisioning.allowDeployerRegistry else { return nil }
    let host = firstNonEmptyStatic(spec.talosProvisioning.deployerRegistryHost, deployerNodeAddress(for: spec))
    return host.isEmpty ? nil : "\(host):\(spec.talosProvisioning.deployerRegistryPort)"
}

func deployerNodeAddress(for spec: DeploymentSpec) -> String {
    firstNonEmptyStatic(
        spec.talosProvisioning.deployerRegistryAddressCIDR.split(separator: "/").first.map(String.init) ?? "",
        spec.deployerNode?.device.privateIP ?? "",
        spec.deployerNode?.device.primaryIP ?? ""
    )
}

func deployerDNSListenAddresses(for spec: DeploymentSpec) -> [String] {
    uniqueNonEmpty([
        spec.talosProvisioning.deployerRegistryAddressCIDR.split(separator: "/").first.map(String.init) ?? "",
        spec.talosProvisioning.deployerNodeRouteSourceCIDR.split(separator: "/").first.map(String.init) ?? "",
        spec.deployerNode?.device.privateIP ?? "",
        spec.deployerNode?.device.primaryIP ?? "",
    ])
}

func deployerRegistryEndpoint(for spec: DeploymentSpec) -> String? {
    guard let host = deployerRegistryHost(for: spec) else { return nil }
    return "http://\(host)"
}

func deployerRegistryInstallerImage(for spec: DeploymentSpec) -> String? {
    guard let host = deployerRegistryHost(for: spec) else { return nil }
    return "\(host)/installer/\(spec.talosFactory.schematicID):\(spec.talosVersion)"
}

func deployerRegistryMirrorHosts(for spec: DeploymentSpec) -> [String] {
    var seen = Set<String>()
    return spec.talosProvisioning.deployerRegistryMirrorHosts.compactMap { value in
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !seen.contains(host) else { return nil }
        seen.insert(host)
        return host
    }
}

func dockerRegistryWritableCommand(registryRoot: String) -> String {
    """
          sudo mkdir -p \(shellEscape(registryRoot))
          if id docker-registry >/dev/null 2>&1; then
            sudo chown -R docker-registry:docker-registry \(shellEscape(registryRoot)) 2>/dev/null || sudo chmod -R 0777 \(shellEscape(registryRoot)) 2>/dev/null || true
          else
            sudo chmod -R 0777 \(shellEscape(registryRoot)) 2>/dev/null || true
          fi
          sudo chmod -R 0777 \(shellEscape(registryRoot)) 2>/dev/null || true
    """
}

public protocol Provisioner: Sendable {
    func prepare(plan: DeploymentPlan) async throws
}

public struct NoOpProvisioner: Provisioner {
    public init() {}
    public func prepare(plan: DeploymentPlan) async throws {}
}

public enum DeploymentPlannerError: Error, LocalizedError {
    case missingDeployer
    case multipleDeployers
    case invalidControlPlaneCount
    case missingDeployerConfirmation(String)
    case existingMediaHostNotExplicitlyAllowed
    case pxeCannotBootstrapFirstDeployer
    case missingOOBReachableMediaURL
    case staticNetworkInvalid([StaticNetworkValidationResult])

    public var errorDescription: String? {
        switch self {
        case .missingDeployer:
            return "Exactly one deployer must be selected."
        case .multipleDeployers:
            return "Only one deployer may be selected."
        case .invalidControlPlaneCount:
            return "The control plane count must be either 1 or 3."
        case .missingDeployerConfirmation(let name):
            return "Typed confirmation is required before reinstalling deployer \(name)."
        case .existingMediaHostNotExplicitlyAllowed:
            return "Existing OS media host delivery is disabled. Use operator local media for greenfield installs, or explicitly allow an existing media host in Settings."
        case .pxeCannotBootstrapFirstDeployer:
            return "PXE cannot bootstrap the first deployer unless an external PXE service already exists."
        case .missingOOBReachableMediaURL:
            return "OOB-reachable URL media delivery requires an external media base URL in Settings."
        case .staticNetworkInvalid(let results):
            let failures = results
                .filter { !$0.isValid }
                .map { "\($0.deviceID): \($0.errors.joined(separator: "; "))" }
                .joined(separator: " | ")
            return "Static networking is incomplete: \(failures)"
        }
    }
}

public struct DeploymentPlanner: Sendable {
    private let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public func makePlan(spec: DeploymentSpec) throws -> DeploymentPlan {
        let deployers = spec.nodes.filter { $0.assignment.role.isDeployer }
        guard !deployers.isEmpty else { throw DeploymentPlannerError.missingDeployer }
        guard deployers.count == 1 else { throw DeploymentPlannerError.multipleDeployers }
        let controlPlanes = spec.nodes.filter { $0.assignment.role == .controlplane }
        guard controlPlanes.count == 1 || controlPlanes.count == 3 else {
            throw DeploymentPlannerError.invalidControlPlaneCount
        }
        let networkValidation = StaticNetworkPlanner().validate(spec: spec)
        guard networkValidation.allSatisfy(\.isValid) else {
            throw DeploymentPlannerError.staticNetworkInvalid(networkValidation)
        }

        let deployerNode = deployers[0]
        if deployerNode.assignment.shouldInstallOS && settings.safety.requireTypedConfirmationForDeployerReinstall {
            let expected = "\(settings.safety.destructiveConfirmationTextPrefix) \(deployerNode.device.name)"
            guard deployerNode.assignment.typedConfirmation == expected else {
                throw DeploymentPlannerError.missingDeployerConfirmation(deployerNode.device.name)
            }
        }
        try validateBootstrapMediaDelivery(for: deployerNode)

        let planned = spec.nodes
            .filter { $0.assignment.role != .unassigned }
            .map { node in
                PlannedDeviceInstall(
                    device: node.device,
                    assignment: node.assignment,
                    method: selectInstallMethod(for: node, spec: spec)
                )
            }

        guard let deployer = planned.first(where: { $0.assignment.role.isDeployer }) else {
            throw DeploymentPlannerError.missingDeployer
        }

        let remotePath = "\(spec.deployerStateRoot)/\(spec.accountNumber)/\(spec.clusterName)"
        let tempPath = "bootstrap-temp/\(spec.accountNumber)/\(spec.clusterName)"
        let talosArtifacts = TalosFactoryClient().artifactURLs(settings: spec.talosFactory, talosVersion: spec.talosVersion)
        var phases: [DeploymentPhase] = []

        phases.append(
            DeploymentPhase(
                title: "Prepare Talos Artifacts",
                steps: [
                    "Render Image Factory schematic for \(spec.talosFactory.selectedSystemExtensions.isEmpty ? "vanilla Talos" : spec.talosFactory.selectedSystemExtensions.joined(separator: ", ")).",
                    "Use ISO \(talosArtifacts.isoURL).",
                    "Use PXE endpoint \(talosArtifacts.pxeURL).",
                    "Set machine install image to \(talosArtifacts.installerImage).",
                ]
            )
        )

        if deployer.assignment.shouldInstallOS && deployer.assignment.deployerMode == .bootstrap {
            phases.append(
                DeploymentPhase(
                    title: "Bootstrap Deployer",
                    steps: bootstrapDeployerSteps(deployer: deployer, tempPath: tempPath, remotePath: remotePath)
                )
            )
        } else {
            phases.append(
                DeploymentPhase(
                    title: "Prepare Existing Deployer",
                    steps: [
                        "Validate the configured deployer access path for \(deployer.device.name).",
                        "Create durable state root at \(remotePath).",
                        "tds prepares media and PXE directories plus a range-capable HTTP media service on the selected existing device.",
                        "Stage generated Talos/Ubuntu media through tds before booting any dependent nodes.",
                    ]
                )
            )
        }

        let remainingInstalls = planned.filter { $0.device.id != deployer.device.id && $0.assignment.shouldInstallOS }
        phases.append(
            DeploymentPhase(
                title: "Provision Cluster",
                steps: remainingInstalls.map {
                    provisioningStep(for: $0, talosArtifacts: talosArtifacts)
                } + [
                    "Generate machine configs with preserved/manual network settings and selected kernel modules.",
                    "Run talosctl from the deployer to apply configs, bootstrap etcd, fetch kubeconfig, and verify cluster health.",
                    "Persist generated state under \(remotePath).",
                ]
            )
        )

        return DeploymentPlan(
            accountNumber: spec.accountNumber,
            clusterName: spec.clusterName,
            deployer: deployer,
            installs: planned,
            phases: phases,
            talosArtifacts: talosArtifacts,
            networkValidation: networkValidation,
            tempStateDirectory: tempPath,
            durableStateDirectory: remotePath
        )
    }

    private func selectInstallMethod(for node: DeploymentNodeSpec, spec: DeploymentSpec) -> InstallMethod {
        if node.assignment.role.isDeployer && node.assignment.deployerMode == .bootstrap && node.assignment.shouldInstallOS {
            switch settings.bootstrapMedia.deliveryMode {
            case .operatorLocalMedia:
                return .operatorLocalMedia
            case .oobReachableURL, .existingOSMediaHost:
                return .bootURL
            case .pxeAfterDeployerOnline:
                return .pxe
            }
        }

        switch node.assignment.preferredInstall {
        case .virtualMedia:
            return .virtualMedia
        case .pxe:
            return .pxe
        case .automatic:
            if node.assignment.role.isDeployer && node.assignment.shouldInstallOS {
                return .virtualMedia
            }
            if !node.assignment.role.isDeployer {
                return selectAutomaticTalosMethod(for: node, spec: spec)
            }
            if let oob = node.device.oob, oob.supportsVirtualMedia == true {
                return .virtualMedia
            }
            return .pxe
        }
    }

    private func selectAutomaticTalosMethod(for node: DeploymentNodeSpec, spec: DeploymentSpec) -> InstallMethod {
        for strategy in spec.talosProvisioning.preferredStrategies {
            switch strategy {
            case .automatic:
                continue
            case .deployerHostedMedia:
                if spec.talosProvisioning.allowDeployerHostedMedia {
                    return .bootURL
                }
            case .deployerPXE:
                if spec.talosProvisioning.allowDeployerPXE {
                    return .pxe
                }
            case .directVirtualMedia:
                if node.device.oob != nil {
                    return .virtualMedia
                }
            case .operatorLocalMedia:
                return .operatorLocalMedia
            case .externalOOBURL:
                if spec.talosProvisioning.allowExternalOOBURL,
                   !spec.talosProvisioning.externalOOBMediaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .bootURL
                }
            }
        }
        return node.device.oob == nil ? .pxe : .virtualMedia
    }

    private func provisioningStep(for install: PlannedDeviceInstall, talosArtifacts: TalosFactoryArtifacts) -> String {
        switch install.method {
        case .operatorLocalMedia:
            return "Provision \(install.device.name) as \(install.assignment.role.displayName) using operator-attached local media through tds OOB WebView."
        case .virtualMedia:
            return "Provision \(install.device.name) as \(install.assignment.role.displayName) using direct OOB virtual media with \(talosArtifacts.isoURL)."
        case .bootURL:
            return "Provision \(install.device.name) as \(install.assignment.role.displayName) using OOB boot URL media; prefer deployer-hosted ISO, otherwise configured external OOB URL."
        case .pxe:
            return "Provision \(install.device.name) as \(install.assignment.role.displayName) using deployer PXE/DHCP/TFTP/HTTP services."
        case .stagedOnly:
            return "Stage config for \(install.device.name) as \(install.assignment.role.displayName) without booting it."
        }
    }

    private func validateBootstrapMediaDelivery(for deployerNode: DeploymentNodeSpec) throws {
        guard deployerNode.assignment.role.isDeployer,
              deployerNode.assignment.deployerMode == .bootstrap,
              deployerNode.assignment.shouldInstallOS
        else { return }

        switch settings.bootstrapMedia.deliveryMode {
        case .operatorLocalMedia:
            return
        case .oobReachableURL:
            guard !settings.bootstrapMedia.externalMediaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeploymentPlannerError.missingOOBReachableMediaURL
            }
        case .existingOSMediaHost:
            guard settings.bootstrapMedia.allowExistingOSMediaHost else {
                throw DeploymentPlannerError.existingMediaHostNotExplicitlyAllowed
            }
        case .pxeAfterDeployerOnline:
            throw DeploymentPlannerError.pxeCannotBootstrapFirstDeployer
        }
    }

    private func bootstrapDeployerSteps(deployer: PlannedDeviceInstall, tempPath: String, remotePath: String) -> [String] {
        let commonTail = [
            "Install \(deployer.device.name) first and wait for SSH reachability.",
            "Move durable deployment state from the temporary bootstrap workspace to \(remotePath).",
            "Only after the deployer is online may PXE-dependent control-plane and worker nodes proceed.",
        ]

        switch settings.bootstrapMedia.deliveryMode {
        case .operatorLocalMedia:
            return [
                "Persist temporary deployment state on the runtime host at \(tempPath).",
                "Open the configured OOB access profile in the embedded tds WebView.",
                "Attach the selected Ubuntu or Talos ISO as operator local media; do not depend on another target node having an OS.",
            ] + commonTail
        case .oobReachableURL:
            return [
                "Persist temporary deployment state on the runtime host at \(tempPath).",
                "Attach media from the configured OOB-reachable URL \(settings.bootstrapMedia.externalMediaBaseURL).",
                "This requires infrastructure outside the selected bare-metal nodes to serve the ISO on the OOB network.",
            ] + commonTail
        case .existingOSMediaHost:
            return [
                "Persist temporary deployment state on the runtime host at \(tempPath).",
                "Use the explicitly allowed existing OS media host \(settings.bootstrapMedia.mediaHostDeviceID) to serve installation media.",
                "This is not greenfield-safe; every run must document which existing host is being used.",
            ] + commonTail
        case .pxeAfterDeployerOnline:
            return [
                "PXE is deferred until after the deployer is installed.",
            ] + commonTail
        }
    }
}

public final class DeploymentCoordinator: @unchecked Sendable {
    private let settings: AppSettings
    private let builder: TalosBuilder
    private let deployerHostClient: DeployerHostClient
    private let coreClient: CoreClient?
    private let oobHardwareInventoryClient: (any OOBHardwareInventoryClient)?
    private let stateStore: DeploymentStateStore
    private let fileManager: FileManager

    public init(
        settings: AppSettings,
        builder: TalosBuilder = DefaultTalosBuilder(),
        deployerHostClient: DeployerHostClient = DefaultDeployerHostClient(),
        coreClient: CoreClient? = nil,
        oobHardwareInventoryClient: (any OOBHardwareInventoryClient)? = nil,
        stateStore: DeploymentStateStore = DeploymentStateStore(),
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.builder = builder
        self.deployerHostClient = deployerHostClient
        self.coreClient = coreClient
        self.oobHardwareInventoryClient = oobHardwareInventoryClient
        self.stateStore = stateStore
        self.fileManager = fileManager
    }

    public func stage(spec: DeploymentSpec, at baseDirectory: URL) async throws -> DeploymentState {
        tdsProgress("Staging deployment state for \(spec.clusterName)")
        let enrichment = await enrichSpecForOOBHardwareSelectors(spec)
        let spec = enrichment.spec
        let planner = DeploymentPlanner(settings: settings)
        let plan = try planner.makePlan(spec: spec)
        let localStateDirectory = baseDirectory.appending(path: spec.accountNumber).appending(path: spec.clusterName)
        try fileManager.createDirectory(at: localStateDirectory, withIntermediateDirectories: true)
        _ = try await builder.buildArtifacts(for: spec, plan: plan, in: localStateDirectory)
        var state = DeploymentState(
            spec: spec,
            plan: plan,
            events: [DeploymentEvent(message: "Deployment staged locally.")] + enrichment.events.map { DeploymentEvent(message: $0) },
            localStateDirectory: localStateDirectory.path,
            deployerSynchronized: false
        )
        _ = try MaintenanceBundleBuilder(fileManager: fileManager).writeBundle(for: state, in: localStateDirectory)
        state.events.append(DeploymentEvent(message: "Maintenance bundle generated for deployer-owned operations."))
        _ = try stateStore.save(state, to: localStateDirectory)
        tdsProgress("Deployment state staged at \(localStateDirectory.path)")
        return state
    }

    private func enrichSpecForOOBHardwareSelectors(_ spec: DeploymentSpec) async -> OOBNetworkSelectorEnrichment {
        guard let oobHardwareInventoryClient,
              spec.talosProvisioning.useOOBHardwareAddressSelectors
        else {
            return OOBNetworkSelectorEnrichment(spec: spec)
        }
        return await OOBNetworkSelectorEnricher(client: oobHardwareInventoryClient).enrich(
            spec: spec,
            proxyVia: settings.hammertime.deployerVia
        )
    }

    public func synchronizeToDeployer(_ state: DeploymentState, connection: SSHConnection) async throws -> DeploymentState {
        try await synchronizeToDeployer(
            state,
            transport: DirectSSHDeployerTransport(connection: connection)
        )
    }

    public func synchronizeToDeployer(_ state: DeploymentState, transport: any DeployerTransport) async throws -> DeploymentState {
        let localDirectory = URL(fileURLWithPath: state.localStateDirectory, isDirectory: true)
        tdsProgress("Validating deployer transport before state sync via \(transport.targetDescription)")
        _ = try await deployerHostClient.validate(transport: transport)
        tdsProgress("Preparing deployer media services via \(transport.targetDescription)")
        var serviceConfiguration = DeployerMediaServiceConfiguration(defaults: settings.deployer)
        serviceConfiguration.dnsListenAddresses = deployerDNSListenAddresses(for: state.spec)
        let mediaPlan = try await deployerHostClient.prepareMediaServices(
            configuration: serviceConfiguration,
            transport: transport
        )
        tdsProgress("Syncing deployment state to \(state.plan.durableStateDirectory) via \(transport.targetDescription)")
        try await deployerHostClient.syncState(
            localDirectory: localDirectory,
            remoteStateRoot: state.plan.durableStateDirectory,
            transport: transport
        )
        var updated = state
        updated.deployerSynchronized = true
        updated.events.append(DeploymentEvent(message: "Prepared deployer media services through \(transport.targetDescription) at \(mediaPlan.mediaRoot)."))
        updated.events.append(DeploymentEvent(message: "Deployment state synchronized to deployer through \(transport.targetDescription)."))
        _ = try stateStore.save(updated, to: localDirectory)
        tdsProgress("Deployment state synchronized to deployer")
        return updated
    }

    public func run(
        state: DeploymentState,
        connection: SSHConnection? = nil,
        access: DeployerAccessRequest? = nil,
        dryRun: Bool = true
    ) async throws -> TalosExecutionRun {
        let deployer = state.plan.deployer
        let hostname = DeployerNaming().hostname(for: deployer.device, suffix: settings.deployer.hostnameSuffix)
        var serviceConfiguration = DeployerMediaServiceConfiguration(defaults: settings.deployer)
        if serviceConfiguration.talosctlVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serviceConfiguration.talosctlVersion = state.spec.talosVersion
        }
        serviceConfiguration.registryPort = state.spec.talosProvisioning.deployerRegistryPort
        serviceConfiguration.dnsListenAddresses = deployerDNSListenAddresses(for: state.spec)
        var updated = state
        var servicePlan = deployerHostClient.planDeployerServices(configuration: serviceConfiguration)
        let renameResult: CoreRenameResult?
        var accessValidation: DeployerAccessValidation?
        var provisioningExecution: TalosProvisioningExecution?
        var bootstrapResult: TalosBootstrapResult?
        var maintenanceBundle: MaintenanceBundleManifest?

        if dryRun {
            renameResult = CoreRenameResult(
                requestedName: hostname,
                didRename: false,
                warning: "Dry run: Core rename was planned but not executed."
            )
            maintenanceBundle = try? MaintenanceBundleBuilder(fileManager: fileManager).writeBundle(
                for: updated,
                in: URL(fileURLWithPath: updated.localStateDirectory, isDirectory: true)
            )
            accessValidation = DeployerAccessValidation(
                method: access?.method ?? settings.deployer.accessMethod,
                target: deployer.device.id,
                succeeded: false,
                message: "Dry run: deployer access validation was planned but not executed.",
                attempts: []
            )
            provisioningExecution = TalosProvisioningExecution(
                plannedActions: state.plan.installs
                    .filter { $0.assignment.role == .controlplane || $0.assignment.role == .worker }
                    .map { plannedExecutionAction(for: $0, talosArtifacts: state.plan.talosArtifacts) },
                executedActions: [],
                warnings: ["Dry run: Talos node boot/apply/bootstrap commands were not executed."]
            )
            bootstrapResult = TalosBootstrapResult(
                bootstrapNode: state.spec.nodes.first(where: { $0.assignment.role == .controlplane })?.device.name ?? "",
                commands: ["Dry run: deployer maintenance/tds-run-talos-deploy.sh would be executed."],
                succeeded: false,
                warnings: ["Dry run only."]
            )
            updated.events.append(DeploymentEvent(message: "Dry run planned deployer hostname \(hostname)."))
        } else {
            let request = access ?? defaultAccessRequest(connection: connection, deployer: deployer.device)
            tdsProgress("Resolving deployer access path for \(deployer.device.id)")
            let selection = try await DeployerTransportResolver(settings: settings).resolve(request: request, deployer: deployer.device)
            let transport = selection.transport
            accessValidation = DeployerAccessValidation(
                method: selection.validation.method,
                target: selection.validation.target,
                succeeded: true,
                message: selection.validation.message,
                attempts: selection.failedAttempts + selection.validation.attempts
            )
            updated.events.append(DeploymentEvent(message: "Selected deployer access path: \(selection.validation.method.displayName) via \(selection.validation.target)."))
            tdsProgress("Selected deployer access path \(selection.validation.method.displayName) via \(selection.validation.target)")
            tdsProgress("Setting deployer hostname to \(hostname)")
            try await deployerHostClient.setHostname(hostname, transport: transport)
            tdsProgress("Preparing deployer services")
            servicePlan = try await deployerHostClient.prepareDeployerServices(
                configuration: serviceConfiguration,
                transport: transport
            )
            tdsProgress("Writing maintenance bundle before deployer sync")
            maintenanceBundle = try MaintenanceBundleBuilder(fileManager: fileManager).writeBundle(
                for: updated,
                in: URL(fileURLWithPath: updated.localStateDirectory, isDirectory: true)
            )
            updated = try await synchronizeToDeployer(updated, transport: transport)
            updated.events.append(DeploymentEvent(message: "Deployer services prepared through \(transport.targetDescription)."))

            if let coreClient {
                renameResult = await coreClient.renameDevice(
                    accountNumber: state.spec.accountNumber,
                    deviceID: deployer.device.id,
                    newName: hostname
                )
            } else {
                renameResult = CoreRenameResult(
                    requestedName: hostname,
                    didRename: false,
                    warning: "No Core client was configured; skipped Core rename."
                )
            }
            if let renameResult, !renameResult.warning.isEmpty {
                updated.events.append(DeploymentEvent(message: "Core rename warning: \(renameResult.warning)"))
            } else if renameResult?.didRename == true {
                updated.events.append(DeploymentEvent(message: "Core device rename requested: \(hostname)."))
            }

            tdsProgress("Starting Talos provisioning and bootstrap execution")
            let execution = try await TalosDeploymentExecutor(settings: settings).execute(
                state: updated,
                transport: transport,
                configuration: serviceConfiguration
            )
            provisioningExecution = execution.0
            bootstrapResult = execution.1
            updated.events.append(DeploymentEvent(message: "Talos deployer-owned execution completed."))
            tdsProgress("Talos provisioning and bootstrap execution completed")
        }

        let localDirectory = URL(fileURLWithPath: updated.localStateDirectory, isDirectory: true)
        _ = try stateStore.save(updated, to: localDirectory)

        return TalosExecutionRun(
            state: updated,
            deployerHostname: hostname,
            coreRename: renameResult,
            deployerServices: servicePlan,
            networkValidation: state.plan.networkValidation,
            accessValidation: accessValidation,
            provisioningExecution: provisioningExecution,
            bootstrapResult: bootstrapResult,
            maintenanceBundle: maintenanceBundle,
            dryRun: dryRun
        )
    }

    public func resumeDeployerExecution(
        state: DeploymentState,
        connection: SSHConnection? = nil,
        access: DeployerAccessRequest? = nil,
        dryRun: Bool = true
    ) async throws -> TalosExecutionRun {
        let deployer = state.plan.deployer
        let hostname = DeployerNaming().hostname(for: deployer.device, suffix: settings.deployer.hostnameSuffix)
        var serviceConfiguration = DeployerMediaServiceConfiguration(defaults: settings.deployer)
        if serviceConfiguration.talosctlVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serviceConfiguration.talosctlVersion = state.spec.talosVersion
        }
        serviceConfiguration.registryPort = state.spec.talosProvisioning.deployerRegistryPort
        serviceConfiguration.dnsListenAddresses = deployerDNSListenAddresses(for: state.spec)
        var updated = state
        let servicePlan = deployerHostClient.planDeployerServices(configuration: serviceConfiguration)
        let localDirectory = URL(fileURLWithPath: updated.localStateDirectory, isDirectory: true)
        _ = try await builder.buildArtifacts(for: updated.spec, plan: updated.plan, in: localDirectory)
        let maintenanceBundle = try MaintenanceBundleBuilder(fileManager: fileManager).writeBundle(for: updated, in: localDirectory)

        if dryRun {
            return TalosExecutionRun(
                state: updated,
                deployerHostname: hostname,
                deployerServices: servicePlan,
                networkValidation: state.plan.networkValidation,
                accessValidation: DeployerAccessValidation(
                    method: access?.method ?? settings.deployer.accessMethod,
                    target: deployer.device.id,
                    succeeded: false,
                    message: "Dry run: deployer resume was planned but not executed.",
                    attempts: []
                ),
                provisioningExecution: TalosProvisioningExecution(
                    plannedActions: ["Resume deployer-owned Talos apply/bootstrap/health without reissuing OOB boot requests."],
                    warnings: ["Dry run only."]
                ),
                bootstrapResult: TalosBootstrapResult(
                    bootstrapNode: state.spec.nodes.first(where: { $0.assignment.role == .controlplane })?.device.name ?? "",
                    commands: ["Dry run: deployer maintenance/tds-run-talos-deploy.sh would be rerun."],
                    succeeded: false,
                    warnings: ["Dry run only."]
                ),
                maintenanceBundle: maintenanceBundle,
                dryRun: true
            )
        }

        let request = access ?? defaultAccessRequest(connection: connection, deployer: deployer.device)
        tdsProgress("Resolving deployer access path for resume on \(deployer.device.id)")
        let selection = try await DeployerTransportResolver(settings: settings).resolve(request: request, deployer: deployer.device)
        let transport = selection.transport
        let accessValidation = DeployerAccessValidation(
            method: selection.validation.method,
            target: selection.validation.target,
            succeeded: true,
            message: selection.validation.message,
            attempts: selection.failedAttempts + selection.validation.attempts
        )
        tdsProgress("Refreshing deployer media service files before resume")
        _ = try await deployerHostClient.prepareMediaServices(
            configuration: serviceConfiguration,
            transport: transport
        )
        tdsProgress("Syncing updated maintenance bundle before resume")
        updated = try await synchronizeToDeployer(updated, transport: transport)
        tdsProgress("Starting deployer-owned resume without OOB reprovisioning")
        let execution = try await TalosDeploymentExecutor(settings: settings).resumeDeployerState(
            state: updated,
            transport: transport,
            configuration: serviceConfiguration
        )
        updated.events.append(DeploymentEvent(message: "Talos deployer-owned resume completed."))
        _ = try stateStore.save(updated, to: localDirectory)
        return TalosExecutionRun(
            state: updated,
            deployerHostname: hostname,
            deployerServices: servicePlan,
            networkValidation: state.plan.networkValidation,
            accessValidation: accessValidation,
            provisioningExecution: execution.0,
            bootstrapResult: execution.1,
            maintenanceBundle: maintenanceBundle,
            dryRun: false
        )
    }

    public func reprovisionTalosNodes(
        state: DeploymentState,
        targetDeviceIDs: [String],
        wipeFirst: Bool,
        connection: SSHConnection? = nil,
        access: DeployerAccessRequest? = nil,
        dryRun: Bool = true
    ) async throws -> TalosExecutionRun {
        let deployer = state.plan.deployer
        let hostname = DeployerNaming().hostname(for: deployer.device, suffix: settings.deployer.hostnameSuffix)
        var serviceConfiguration = DeployerMediaServiceConfiguration(defaults: settings.deployer)
        if serviceConfiguration.talosctlVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serviceConfiguration.talosctlVersion = state.spec.talosVersion
        }
        serviceConfiguration.registryPort = state.spec.talosProvisioning.deployerRegistryPort
        serviceConfiguration.dnsListenAddresses = deployerDNSListenAddresses(for: state.spec)
        var updated = state
        let servicePlan = deployerHostClient.planDeployerServices(configuration: serviceConfiguration)
        let localDirectory = URL(fileURLWithPath: updated.localStateDirectory, isDirectory: true)
        _ = try await builder.buildArtifacts(for: updated.spec, plan: updated.plan, in: localDirectory)
        let maintenanceBundle = try MaintenanceBundleBuilder(fileManager: fileManager).writeBundle(for: updated, in: localDirectory)

        let requested = targetDeviceIDs.isEmpty ? "all Talos nodes" : targetDeviceIDs.joined(separator: ",")
        if dryRun {
            return TalosExecutionRun(
                state: updated,
                deployerHostname: hostname,
                deployerServices: servicePlan,
                networkValidation: state.plan.networkValidation,
                accessValidation: DeployerAccessValidation(
                    method: access?.method ?? settings.deployer.accessMethod,
                    target: deployer.device.id,
                    succeeded: false,
                    message: "Dry run: would reprovision \(requested) through the deployer.",
                    attempts: []
                ),
                provisioningExecution: TalosProvisioningExecution(
                    plannedActions: ["Reissue OOB boot URL requests for \(requested)."],
                    warnings: ["Dry run only."]
                ),
                bootstrapResult: TalosBootstrapResult(
                    bootstrapNode: state.spec.nodes.first(where: { $0.assignment.role == .controlplane })?.device.name ?? "",
                    commands: ["Dry run: deployer-hosted media would be prepared and selected Talos nodes would be rebooted."],
                    succeeded: false,
                    warnings: ["Dry run only."]
                ),
                maintenanceBundle: maintenanceBundle,
                dryRun: true
            )
        }

        let request = access ?? defaultAccessRequest(connection: connection, deployer: deployer.device)
        tdsProgress("Resolving deployer access path for Talos reprovision on \(deployer.device.id)")
        let selection = try await DeployerTransportResolver(settings: settings).resolve(request: request, deployer: deployer.device)
        let transport = selection.transport
        let accessValidation = DeployerAccessValidation(
            method: selection.validation.method,
            target: selection.validation.target,
            succeeded: true,
            message: selection.validation.message,
            attempts: selection.failedAttempts + selection.validation.attempts
        )
        tdsProgress("Refreshing deployer media service files before Talos reprovision")
        _ = try await deployerHostClient.prepareMediaServices(
            configuration: serviceConfiguration,
            transport: transport
        )
        tdsProgress("Syncing updated maintenance bundle before Talos reprovision")
        updated = try await synchronizeToDeployer(updated, transport: transport)
        let execution = try await TalosDeploymentExecutor(settings: settings).reprovisionNodes(
            state: updated,
            transport: transport,
            configuration: serviceConfiguration,
            targetDeviceIDs: targetDeviceIDs,
            wipeFirst: wipeFirst
        )
        updated.events.append(DeploymentEvent(message: "Talos node reprovision requests completed for \(requested)."))
        _ = try stateStore.save(updated, to: localDirectory)
        return TalosExecutionRun(
            state: updated,
            deployerHostname: hostname,
            deployerServices: servicePlan,
            networkValidation: state.plan.networkValidation,
            accessValidation: accessValidation,
            provisioningExecution: execution,
            bootstrapResult: TalosBootstrapResult(
                bootstrapNode: state.spec.nodes.first(where: { $0.assignment.role == .controlplane })?.device.name ?? "",
                commands: ["Reprovision selected Talos nodes through deployer-hosted media; run deploy resume to apply/bootstrap/verify."],
                succeeded: true,
                warnings: execution.warnings
            ),
            maintenanceBundle: maintenanceBundle,
            dryRun: false
        )
    }

    private func defaultAccessRequest(connection: SSHConnection?, deployer: DiscoveredDevice) -> DeployerAccessRequest {
        var resolvedConnection = connection
        if resolvedConnection?.proxyJump.isEmpty == true, !settings.deployer.proxyJumpHost.isEmpty {
            resolvedConnection?.proxyJump = settings.deployer.proxyJumpHost
        }
        return DeployerAccessRequest(
            method: settings.deployer.accessMethod,
            sshConnection: resolvedConnection,
            hammertimeDeviceID: deployer.id,
            hammertimeVia: settings.hammertime.deployerVia,
            hammertimePrivate: settings.hammertime.deployerUsePrivate,
            passportReason: settings.hammertime.passportReason,
            copyMethod: settings.hammertime.copyMethod
        )
    }

    private func plannedExecutionAction(for install: PlannedDeviceInstall, talosArtifacts: TalosFactoryArtifacts) -> String {
        switch install.method {
        case .operatorLocalMedia:
            return "Wait for operator-attached Talos media on \(install.device.name), then apply static machine config from the deployer."
        case .virtualMedia:
            return "Boot \(install.device.name) through direct OOB virtual media using \(talosArtifacts.isoURL), then apply static machine config from the deployer."
        case .bootURL:
            return "Boot \(install.device.name) through OOB boot URL media, preferring deployer-hosted Talos ISO, then apply static machine config from the deployer."
        case .pxe:
            return "Boot \(install.device.name) through deployer-managed PXE/DHCP/TFTP/HTTP, then apply static machine config from the deployer."
        case .stagedOnly:
            return "Stage \(install.device.name) config on the deployer without booting."
        }
    }

    public func verify(state: DeploymentState) -> ClusterHealthResult {
        let deployerPath = state.plan.durableStateDirectory
        let controlPlanes = state.spec.nodes
            .filter { $0.assignment.role == .controlplane }
            .map(\.device.name)
            .joined(separator: ",")
        let workers = state.spec.nodes
            .filter { $0.assignment.role == .worker }
            .map(\.device.name)
            .joined(separator: ",")
        return ClusterHealthResult(
            talosNodesReady: false,
            kubernetesReady: false,
            checkedCommands: [
                "cd \(deployerPath)",
                "talosctl health --nodes \(controlPlanes)",
                "kubectl --kubeconfig kubeconfig get nodes -o wide",
                "kubectl --kubeconfig kubeconfig get pods -A",
            ],
            warnings: [
                "Verification is planned until tds has an active deployer SSH session.",
                "Control planes: \(controlPlanes.isEmpty ? "none" : controlPlanes)",
                "Workers: \(workers.isEmpty ? "none" : workers)",
            ]
        )
    }
}

public enum DeploymentCoordinatorError: Error, LocalizedError {
    case missingDeployerConnection

    public var errorDescription: String? {
        switch self {
        case .missingDeployerConnection:
            return "A deployer SSH connection is required to execute a non-dry-run deployment."
        }
    }
}

@MainActor
public final class AppController: ObservableObject {
    @Published public var settings: AppSettings
    @Published public var session: CoreSession?
    @Published public var accountNumber: String
    @Published public var devices: [DiscoveredDevice]
    @Published public var assignments: [String: DeviceAssignment]
    @Published public var liveFactsErrors: [String: String]
    @Published public var lastPlan: DeploymentPlan?
    @Published public var lastState: DeploymentState?
    @Published public var lastRun: TalosExecutionRun?
    @Published public var ubuntuCapturePath: String
    @Published public var ubuntuSourceISOPath: String
    @Published public var ubuntuOutputISOPath: String
    @Published public var ubuntuWorkDirectoryPath: String
    @Published public var ubuntuRackPasswordHash: String
    @Published public var ubuntuRootPasswordHash: String
    @Published public var ubuntuSSHKeyFiles: String
    @Published public var ubuntuOOBURL: String
    @Published public var ubuntuOOBUsername: String
    @Published public var ubuntuLastArtifacts: UbuntuAutoinstallArtifacts?
    @Published public var ubuntuLastValidation: UbuntuIsoValidationResult?
    @Published public var ubuntuNetworkPlan: NetworkRebuildPlan?
    @Published public var ubuntuLocalMediaState: LocalMediaSessionState?
    @Published public var accessProfileProxyPasswords: [UUID: String]
    @Published public var availableTalosVersions: [TalosFactoryVersion]
    @Published public var talosVersionRefreshStatus: String
    @Published public var useManualTalosVersion: Bool
    @Published public var inventoryFilterText: String
    @Published public var statusMessage: String

    private let settingsController: SettingsController
    private let authProvider: AuthProvider
    private let coreClient: CoreClient
    private let environmentSessionProvider: EnvironmentCoreSessionProviding?
    private let hammertime: HammertimeAdapter
    private let secretStore: KeychainSecretStore
    private let paths: AppPaths
    private var hasBootstrappedSession = false

    public init(
        settingsController: SettingsController = SettingsController(),
        authProvider: AuthProvider = KeychainAuthProvider(),
        secretStore: KeychainSecretStore = KeychainSecretStore(),
        coreClient: CoreClient? = nil,
        hammertime: HammertimeAdapter? = nil,
        paths: AppPaths = AppPaths()
    ) {
        self.settingsController = settingsController
        self.paths = paths
        self.secretStore = secretStore
        let loadedSettings = (try? settingsController.load()) ?? AppSettings()
        self.settings = loadedSettings
        self.authProvider = authProvider
        self.coreClient = coreClient ?? ConfiguredCoreClient(
            coreSettings: loadedSettings.core,
            hammertimeSettings: loadedSettings.hammertime
        )
        self.environmentSessionProvider = self.coreClient as? EnvironmentCoreSessionProviding
        self.hammertime = hammertime ?? DefaultHammertimeAdapter(settings: loadedSettings.hammertime)
        self.session = try? authProvider.currentSession()
        self.accountNumber = loadedSettings.core.defaultAccountNumber
        self.devices = []
        self.assignments = [:]
        self.liveFactsErrors = [:]
        self.lastRun = nil
        self.ubuntuCapturePath = ""
        self.ubuntuSourceISOPath = ""
        self.ubuntuOutputISOPath = ""
        self.ubuntuWorkDirectoryPath = ""
        self.ubuntuRackPasswordHash = ""
        self.ubuntuRootPasswordHash = ""
        self.ubuntuSSHKeyFiles = ""
        self.ubuntuOOBURL = ""
        self.ubuntuOOBUsername = ""
        self.accessProfileProxyPasswords = Self.loadProxyPasswords(for: loadedSettings.accessProfiles, secretStore: secretStore)
        self.availableTalosVersions = []
        self.talosVersionRefreshStatus = "Talos versions have not been refreshed yet."
        self.useManualTalosVersion = false
        self.inventoryFilterText = ""
        self.statusMessage = "Ready"
    }

    public func saveSettings() {
        do {
            try saveAccessProfileProxyPasswords()
            try settingsController.save(settings)
            statusMessage = "Settings saved."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func addAccessProfile(kind: AccessProfileKind = .httpProxy, scope: AccessScope = .oob) {
        let shouldBecomeDefault = settings.accessProfiles.allSatisfy { !$0.isDefault || $0.kind == .direct }
        settings.accessProfiles.append(
            AccessProfile(
                name: kind == .socksProxy ? "OOB SOCKS Proxy" : "OOB HTTP Proxy",
                kind: kind,
                scope: scope,
                isDefault: shouldBecomeDefault
            )
        )
        statusMessage = "Added \(kind.rawValue) access profile."
    }

    public func setAccessProfileDefault(id: UUID, isDefault: Bool) {
        for index in settings.accessProfiles.indices {
            settings.accessProfiles[index].isDefault = settings.accessProfiles[index].id == id ? isDefault : false
        }
    }

    public func proxyPassword(for profile: AccessProfile?) -> String {
        guard let profile else { return "" }
        return accessProfileProxyPasswords[profile.id] ?? ""
    }

    private static func loadProxyPasswords(for profiles: [AccessProfile], secretStore: KeychainSecretStore) -> [UUID: String] {
        var passwords: [UUID: String] = [:]
        for profile in profiles where !profile.proxyCredentialReference.isEmpty {
            if let password = try? secretStore.getSecret(for: profile.proxyCredentialReference) {
                passwords[profile.id] = password
            }
        }
        return passwords
    }

    private func saveAccessProfileProxyPasswords() throws {
        for profile in settings.accessProfiles where !profile.proxyCredentialReference.isEmpty {
            let password = accessProfileProxyPasswords[profile.id] ?? ""
            if password.isEmpty {
                try? secretStore.deleteSecret(for: profile.proxyCredentialReference)
            } else {
                try secretStore.setSecret(password, for: profile.proxyCredentialReference)
            }
        }
    }

    public func importSession(username: String, headerName: String, secret: String) {
        let secretReference = "core-session-\(UUID().uuidString)"
        let session = CoreSession(username: username, headerName: headerName, secretReference: secretReference)
        do {
            try authProvider.storeSession(session, secret: secret)
            self.session = session
            statusMessage = "Core session stored."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func clearSession() {
        do {
            try authProvider.clearSession()
            session = nil
            statusMessage = "Stored Core session cleared. Refresh to detect an active hammertime-backed session on this workstation."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func bootstrapSessionStatusIfNeeded() async {
        guard !hasBootstrappedSession else { return }
        hasBootstrappedSession = true
        await refreshSessionStatus()
    }

    public func refreshSessionStatus() async {
        do {
            if let storedSession = try authProvider.currentSession() {
                session = storedSession
                statusMessage = "Loaded stored Core session for \(storedSession.username)."
                return
            }
            if let detectedSession = try await environmentSessionProvider?.discoverEnvironmentSession(includeSecret: false) {
                session = detectedSession.session
                statusMessage = "Detected active Core session for \(detectedSession.session.username) from hammertime cache."
                return
            }
            session = nil
            statusMessage = "No Core session is currently available."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func importDetectedSession() async {
        do {
            guard let detectedSession = try await environmentSessionProvider?.discoverEnvironmentSession(includeSecret: true),
                  let secret = detectedSession.secret,
                  !secret.isEmpty
            else {
                statusMessage = "No importable hammertime-backed Core session was detected."
                return
            }

            var session = detectedSession.session
            session.secretReference = "core-session-\(UUID().uuidString)"
            try authProvider.storeSession(session, secret: secret)
            self.session = session
            statusMessage = "Imported the active hammertime-backed Core session into the local store."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func refreshTalosVersions() async {
        do {
            let catalog = try await TalosFactoryClient().fetchVersions(baseURL: settings.talos.factory.baseURL)
            availableTalosVersions = catalog.versions
            let currentVersion = settings.talos.talosVersion
            if let selected = catalog.preferredVersion(preserving: currentVersion) {
                selectTalosVersion(selected.value)
                if selected.value == currentVersion {
                    talosVersionRefreshStatus = "Loaded \(catalog.versions.count) Talos versions from Image Factory. Current selection \(selected.value) is available."
                } else {
                    talosVersionRefreshStatus = "Loaded \(catalog.versions.count) Talos versions from Image Factory. Previous selection \(currentVersion) is unavailable; selected \(selected.value)."
                }
                useManualTalosVersion = false
            } else {
                talosVersionRefreshStatus = "Talos Image Factory returned no deployable versions. Use manual version entry."
                useManualTalosVersion = true
            }
            statusMessage = talosVersionRefreshStatus
        } catch {
            availableTalosVersions = []
            useManualTalosVersion = true
            talosVersionRefreshStatus = "\(error.localizedDescription) Use manual version entry if needed."
            statusMessage = talosVersionRefreshStatus
        }
    }

    public func refreshInventory() async {
        let resolvedAccountNumber = accountNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedAccountNumber.isEmpty else {
            statusMessage = "Enter an account number before loading devices."
            return
        }
        do {
            let source = settings.core.inventorySource
            let loadedDevices: [DiscoveredDevice]
            switch source {
            case .core:
                loadedDevices = try await coreClient.fetchDevices(accountNumber: resolvedAccountNumber)
            case .hammertime:
                loadedDevices = try await hammertime.inventory(accountNumber: resolvedAccountNumber)
            case .auto:
                do {
                    loadedDevices = try await coreClient.fetchDevices(accountNumber: resolvedAccountNumber)
                } catch {
                    loadedDevices = try await hammertime.inventory(accountNumber: resolvedAccountNumber)
                }
            }
            devices = loadedDevices
            for device in loadedDevices where assignments[device.id] == nil {
                assignments[device.id] = defaultAssignment(for: device.id)
            }
            for device in loadedDevices where !device.isClusterEligible {
                var assignment = assignments[device.id] ?? defaultAssignment(for: device.id)
                assignment.role = .unassigned
                assignment.shouldInstallOS = false
                assignments[device.id] = assignment
            }
            statusMessage = "Loaded \(loadedDevices.count) devices for account \(resolvedAccountNumber), \(clusterEligibleDevices.count) eligible for cluster roles."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func refreshLiveFacts(for selectedIDs: [String]? = nil) async {
        let sourceDevices = selectedIDs == nil ? clusterEligibleDevices : devices
        let targetDevices = sourceDevices.filter { selectedIDs == nil || selectedIDs?.contains($0.id) == true }
        let results = await hammertime.refreshLiveFacts(devices: targetDevices, groups: settings.hammertime.defaultFactGroups)
        liveFactsErrors.removeAll()
        devices = devices.map { device in
            guard let result = results[device.id] else { return device }
            switch result {
            case .success(let snapshot):
                var updated = device
                updated.liveFacts = snapshot
                return updated
            case .failure(let error):
                liveFactsErrors[device.id] = error.localizedDescription
                return device
            }
        }
        statusMessage = "Live facts refreshed for \(targetDevices.count) devices."
    }

    public func binding(for device: DiscoveredDevice) -> DeviceAssignment {
        assignments[device.id] ?? defaultAssignment(for: device.id)
    }

    public var clusterEligibleDevices: [DiscoveredDevice] {
        devices.filter(\.isClusterEligible)
    }

    public var filteredClusterEligibleDevices: [DiscoveredDevice] {
        let query = inventoryFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return clusterEligibleDevices
        }
        return clusterEligibleDevices.filter { device in
            inventoryFilterTokens(for: device).contains { $0.contains(query) }
        }
    }

    public var filteredDevices: [DiscoveredDevice] {
        devices.filter { !$0.isClusterEligible }
    }

    public func updateAssignment(_ assignment: DeviceAssignment) {
        assignments[assignment.deviceID] = assignment
    }

    public func selectTalosVersion(_ version: String) {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = settings.talos.talosVersion
        settings.talos.talosVersion = trimmed
        if settings.deployer.talosctlVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
           settings.deployer.talosctlVersion == previous {
            settings.deployer.talosctlVersion = trimmed
        }
    }

    private func defaultAssignment(for deviceID: String) -> DeviceAssignment {
        DeviceAssignment(
            deviceID: deviceID,
            preferredInstall: settings.talos.installerPreference
        )
    }

    private func inventoryFilterTokens(for device: DiscoveredDevice) -> [String] {
        let assignment = binding(for: device)
        var tokens = [
            device.id,
            device.name,
            device.primaryIP,
            device.privateIP,
            device.platformName,
            assignment.role.rawValue,
            assignment.role.displayName,
        ]
        if let oobAddress = device.oob?.address {
            tokens.append(oobAddress)
        }
        tokens.append(contentsOf: device.networkInterfaces.flatMap { interface in
            [interface.name, interface.macAddress] + interface.addresses
        })
        return tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    public func typedConfirmationText(for device: DiscoveredDevice) -> String {
        "\(settings.safety.destructiveConfirmationTextPrefix) \(device.name)"
    }

    public func stageDeployment() async {
        var talosProvisioning = settings.talos.provisioning
        talosProvisioning.deployerRegistryPort = settings.deployer.registryPort
        let spec = DeploymentSpec(
            accountNumber: accountNumber,
            clusterName: settings.talos.clusterName,
            clusterEndpoint: settings.talos.clusterEndpoint,
            talosVersion: settings.talos.talosVersion,
            kubernetesVersion: settings.talos.kubernetesVersion,
            deployerStateRoot: settings.deployer.stateRoot,
            talosFactory: settings.talos.factory,
            talosProvisioning: talosProvisioning,
            talosKernelModules: settings.talos.kernelModules,
            enableLonghornExtraMounts: settings.talos.enableLonghornExtraMounts,
            nodes: clusterEligibleDevices.compactMap { device in
                guard let assignment = assignments[device.id], assignment.role != .unassigned else {
                    return nil
                }
                return DeploymentNodeSpec(device: device, assignment: assignment)
            }
        )
        let coordinator = DeploymentCoordinator(
            settings: settings,
            oobHardwareInventoryClient: makeOOBHardwareInventoryClient()
        )
        do {
            try? paths.ensureExists()
            let state = try await coordinator.stage(spec: spec, at: paths.stateDirectory)
            lastState = state
            lastPlan = state.plan
            lastRun = nil
            statusMessage = "Deployment staged at \(state.localStateDirectory)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func runDeployment(dryRun: Bool) async {
        guard let state = lastState else {
            await stageDeployment()
            guard let staged = lastState else { return }
            await runDeployment(state: staged, dryRun: dryRun)
            return
        }
        await runDeployment(state: state, dryRun: dryRun)
    }

    private func runDeployment(state: DeploymentState, dryRun: Bool) async {
        let coordinator = DeploymentCoordinator(
            settings: settings,
            oobHardwareInventoryClient: makeOOBHardwareInventoryClient()
        )
        do {
            let run = try await coordinator.run(state: state, dryRun: dryRun)
            lastRun = run
            lastState = run.state
            lastPlan = run.state.plan
            statusMessage = dryRun ? "Deployment dry run completed." : "Deployment execution completed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func makeOOBHardwareInventoryClient() -> (any OOBHardwareInventoryClient)? {
        guard settings.hammertime.enabled,
              settings.talos.provisioning.useOOBHardwareAddressSelectors
        else {
            return nil
        }
        return HammertimeOOBHardwareInventoryClient(settings: settings.hammertime)
    }

    public func refreshUbuntuNetworkPlan() {
        do {
            let spec = try ubuntuInstallSpec()
            let plan = try UbuntuAutoinstallBuilder().makeNetworkPlan(fromCapturePath: spec.capturePath)
            ubuntuNetworkPlan = plan
            statusMessage = "Parsed Ubuntu network preservation plan from \(spec.capturePath)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func buildUbuntuISO() async {
        do {
            let spec = try ubuntuInstallSpec()
            let builder = UbuntuAutoinstallBuilder()
            let plan = try builder.makeNetworkPlan(fromCapturePath: spec.capturePath)
            ubuntuNetworkPlan = plan
            let artifacts = try await builder.buildISO(spec: spec, networkPlan: plan)
            ubuntuLastArtifacts = artifacts
            ubuntuLastValidation = artifacts.validation
            statusMessage = "Ubuntu autoinstall ISO built at \(artifacts.outputISOPath)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func validateUbuntuISO() async {
        let isoPath = firstNonEmptyForController(
            ubuntuOutputISOPath,
            ubuntuLastArtifacts?.outputISOPath ?? ""
        )
        guard !isoPath.isEmpty else {
            statusMessage = "Choose or build an Ubuntu ISO before validating."
            return
        }
        do {
            let validation = try await UbuntuAutoinstallBuilder().validateISO(at: isoPath)
            ubuntuLastValidation = validation
            statusMessage = validation.isValid ? "Ubuntu ISO validation passed." : "Ubuntu ISO validation found \(validation.failures.count) issue(s)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func planUbuntuLocalMediaSession() {
        let isoPath = firstNonEmptyForController(
            ubuntuOutputISOPath,
            ubuntuLastArtifacts?.outputISOPath ?? ""
        )
        do {
            ubuntuLocalMediaState = try Ilo4LocalMediaSession().planSession(
                request: LocalMediaSessionRequest(
                    oobURL: ubuntuOOBURL,
                    username: ubuntuOOBUsername,
                    isoPath: isoPath,
                    vendor: .ilo
                )
            )
            statusMessage = "Prepared embedded iLO local-media session."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func ubuntuInstallSpec() throws -> UbuntuInstallSpec {
        let environment = ProcessInfo.processInfo.environment
        let rackHash = firstNonEmptyForController(ubuntuRackPasswordHash, environment["TDS_RACK_PASSWORD_HASH"] ?? "")
        let rootHash = firstNonEmptyForController(ubuntuRootPasswordHash, environment["TDS_ROOT_PASSWORD_HASH"] ?? "", rackHash)
        guard !ubuntuCapturePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UbuntuBootstrapError.missingRequired("Choose a preinstall capture directory or snapshot.json.")
        }
        guard !ubuntuSourceISOPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UbuntuBootstrapError.missingRequired("Choose the source Ubuntu ISO.")
        }
        guard !ubuntuOutputISOPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UbuntuBootstrapError.missingRequired("Choose where to write the customized Ubuntu ISO.")
        }

        return UbuntuInstallSpec(
            accountNumber: accountNumber,
            deviceID: clusterEligibleDevices.first(where: { binding(for: $0).role.isDeployer })?.id ?? "",
            sourceISOPath: ubuntuSourceISOPath.expandingTildeInPath(),
            outputISOPath: ubuntuOutputISOPath.expandingTildeInPath(),
            workDirectoryPath: ubuntuWorkDirectoryPath.expandingTildeInPath(),
            capturePath: ubuntuCapturePath.expandingTildeInPath(),
            rackPasswordHash: rackHash,
            rootPasswordHash: rootHash,
            authorizedSSHKeys: loadUbuntuAuthorizedKeys()
        )
    }

    private func loadUbuntuAuthorizedKeys() -> [String] {
        let explicitFiles = ubuntuSSHKeyFiles
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var keys: [String] = []
        for file in explicitFiles {
            if let content = try? String(contentsOf: URL(fileURLWithPath: file.expandingTildeInPath()), encoding: .utf8) {
                keys.append(contentsOf: content.split(separator: "\n").map(String.init))
            }
        }
        if keys.isEmpty {
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
}

private func firstNonEmptyForController(_ values: String...) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
