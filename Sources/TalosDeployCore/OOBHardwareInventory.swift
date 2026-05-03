import Foundation

public struct OOBNetworkPort: Codable, Equatable, Sendable {
    public var label: String
    public var macAddress: String
    public var portNumber: Int?
    public var isManagementPort: Bool

    public init(label: String, macAddress: String, portNumber: Int? = nil, isManagementPort: Bool = false) {
        self.label = label
        self.macAddress = normalizedMACAddress(macAddress)
        self.portNumber = portNumber
        self.isManagementPort = isManagementPort
    }
}

public protocol OOBHardwareInventoryClient: Sendable {
    func fetchNetworkPorts(deviceID: String, proxyVia: String?) async throws -> [OOBNetworkPort]
}

public struct HPEIntegratedNICParser: Sendable {
    public init() {}

    public func parse(_ output: String) -> [OOBNetworkPort] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap(parseLine)
    }

    private func parseLine(_ line: Substring) -> OOBNetworkPort? {
        let parts = line.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2 else { return nil }
        let key = parts[0]
        let mac = normalizedMACAddress(parts[1])
        guard isValidMACAddress(mac) else { return nil }
        guard key.localizedCaseInsensitiveContains("MACAddress") else { return nil }

        let label = key
            .replacingOccurrences(of: "_MACAddress", with: "")
            .replacingOccurrences(of: "MACAddress", with: "")
        return OOBNetworkPort(
            label: label,
            macAddress: mac,
            portNumber: portNumber(from: key),
            isManagementPort: key.localizedCaseInsensitiveContains("ilo")
        )
    }

    private func portNumber(from key: String) -> Int? {
        guard let portRange = key.range(of: #"Port[0-9]+NIC"#, options: .regularExpression) else {
            return nil
        }
        let fragment = String(key[portRange])
        let digits = fragment.filter(\.isNumber)
        return Int(digits)
    }
}

public final class HammertimeOOBHardwareInventoryClient: OOBHardwareInventoryClient, @unchecked Sendable {
    private let settings: HammertimeSettings
    private let runner: CommandRunning
    private let parser: HPEIntegratedNICParser

    public init(
        settings: HammertimeSettings = HammertimeSettings(),
        runner: CommandRunning = LocalCommandRunner(),
        parser: HPEIntegratedNICParser = HPEIntegratedNICParser()
    ) {
        self.settings = settings
        self.runner = runner
        self.parser = parser
    }

    public func fetchNetworkPorts(deviceID: String, proxyVia: String?) async throws -> [OOBNetworkPort] {
        var arguments = ["--batch", "--no-colors"]
        if settings.skipDeviceChecks {
            arguments.append("--no-checks")
        }
        arguments.append("oobm")
        if let proxyVia, !proxyVia.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--proxy-via", proxyVia])
        }
        arguments.append(contentsOf: ["--command", "show /system1/network1/Integrated_NICs", deviceID])

        let result = try await runner.run(
            settings.binaryPath.expandingTildeInPath(),
            arguments: arguments,
            environment: [:],
            currentDirectory: nil,
            timeout: TimeInterval(max(settings.timeoutSeconds, 120))
        )
        return parser.parse(result.stdout)
    }
}

public struct OOBNetworkSelectorEnrichment: Sendable {
    public var spec: DeploymentSpec
    public var events: [String]

    public init(spec: DeploymentSpec, events: [String] = []) {
        self.spec = spec
        self.events = events
    }
}

public struct OOBNetworkSelectorEnricher: Sendable {
    private let client: any OOBHardwareInventoryClient

    public init(client: any OOBHardwareInventoryClient) {
        self.client = client
    }

    public func enrich(spec: DeploymentSpec, proxyVia: String? = nil) async -> OOBNetworkSelectorEnrichment {
        guard spec.talosProvisioning.useOOBHardwareAddressSelectors else {
            return OOBNetworkSelectorEnrichment(spec: spec)
        }

        var events: [String] = []
        let nodes = await withTaskGroup(of: (DeploymentNodeSpec, [String]).self) { group in
            for node in spec.nodes {
                group.addTask {
                    await enrichNodeForOOBHardwareSelector(node: node, client: client, proxyVia: proxyVia)
                }
            }

            var enriched: [(DeploymentNodeSpec, [String])] = []
            for await result in group {
                enriched.append(result)
            }
            return enriched.sorted { $0.0.device.name < $1.0.device.name }
        }

        var orderedNodesByID: [String: DeploymentNodeSpec] = [:]
        for (node, nodeEvents) in nodes {
            orderedNodesByID[node.device.id] = node
            events.append(contentsOf: nodeEvents)
        }

        var updated = spec
        updated.nodes = spec.nodes.map { orderedNodesByID[$0.device.id] ?? $0 }
        return OOBNetworkSelectorEnrichment(spec: updated, events: events)
    }
}

private func enrichNodeForOOBHardwareSelector(node: DeploymentNodeSpec, client: any OOBHardwareInventoryClient, proxyVia: String?) async -> (DeploymentNodeSpec, [String]) {
    guard node.assignment.role == .controlplane || node.assignment.role == .worker else {
        return (node, [])
    }

    let staticConfig = StaticNetworkPlanner().config(for: node)
    if !staticConfig.managementHardwareAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return (node, [])
    }

    if let existingMAC = matchingDeviceInterfaceMAC(for: node, config: staticConfig) {
        var updated = node
        updated.assignment.staticNetwork.managementHardwareAddress = existingMAC
        return (updated, ["Using captured management NIC MAC \(existingMAC) for \(node.device.name)."])
    }

    do {
        let ports = try await client.fetchNetworkPorts(deviceID: node.device.id, proxyVia: proxyVia)
        guard let mac = inferredManagementMAC(for: staticConfig.managementInterface, ports: ports) else {
            let labels = ports.map { "\($0.label)=\($0.macAddress)" }.joined(separator: ", ")
            return (node, ["No OOB NIC MAC matched \(node.device.name) management interface \(staticConfig.managementInterface). Ports: \(labels.isEmpty ? "none" : labels)."])
        }
        var updated = node
        updated.assignment.staticNetwork.managementHardwareAddress = mac
        return (updated, ["Selected OOB NIC MAC \(mac) for \(node.device.name) management interface \(staticConfig.managementInterface)."])
    } catch {
        return (node, ["Could not read OOB NIC MACs for \(node.device.name); continuing with interface-name networking: \(error.localizedDescription)"])
    }
}

private func matchingDeviceInterfaceMAC(for node: DeploymentNodeSpec, config: StaticNetworkConfig) -> String? {
    let interfaceName = config.managementInterface.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !interfaceName.isEmpty else { return nil }
    return node.device.networkInterfaces
        .first { $0.name == interfaceName }
        .flatMap { interface in
            let mac = normalizedMACAddress(interface.macAddress)
            return isValidMACAddress(mac) ? mac : nil
        }
}

private func inferredManagementMAC(for interfaceName: String, ports: [OOBNetworkPort]) -> String? {
    let candidates = ports.filter { !$0.isManagementPort }
    if let portNumber = expectedPortNumber(for: interfaceName),
       let port = candidates.first(where: { $0.portNumber == portNumber }) {
        return port.macAddress
    }
    if candidates.count == 1 {
        return candidates[0].macAddress
    }
    return nil
}

private func expectedPortNumber(for interfaceName: String) -> Int? {
    let lowercased = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let number = suffixNumber(in: lowercased, prefix: "eno") {
        return number
    }
    if let number = suffixNumber(in: lowercased, prefix: "em") {
        return number
    }
    if let number = suffixNumber(in: lowercased, prefix: "eth") {
        return number + 1
    }
    if let range = lowercased.range(of: #"port[0-9]+"#, options: .regularExpression) {
        return Int(lowercased[range].filter(\.isNumber))
    }
    return nil
}

private func suffixNumber(in value: String, prefix: String) -> Int? {
    guard value.hasPrefix(prefix) else { return nil }
    let suffix = value.dropFirst(prefix.count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
    return Int(suffix)
}

private func normalizedMACAddress(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func isValidMACAddress(_ value: String) -> Bool {
    let parts = value.split(separator: ":")
    guard parts.count == 6 else { return false }
    return parts.allSatisfy { part in
        part.count == 2 && part.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character.lowercased())
        }
    }
}
