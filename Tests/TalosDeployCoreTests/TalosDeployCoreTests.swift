import Foundation
import Testing
@testable import TalosDeployCore

struct TalosDeployCoreTests {
    @Test
    func coreDefaultsDoNotBakeInATestAccount() {
        #expect(CoreAPISettings().defaultAccountNumber.isEmpty)
    }

    @Test
    func settingsRoundTrip() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        setenv("TALOS_DEPLOY_HOME", base.path, 1)
        let paths = AppPaths()
        try paths.ensureExists()

        let controller = SettingsController(paths: paths)
        var settings = AppSettings()
        settings.core.defaultAccountNumber = "123456"
        settings.helper.stateRoot = "/srv/talos"
        try controller.save(settings)

        let loaded = try controller.load()
        #expect(loaded.core.defaultAccountNumber == "123456")
        #expect(loaded.helper.stateRoot == "/srv/talos")
    }

    @Test
    func plannerRequiresExactlyOneHelper() throws {
        let device = DiscoveredDevice(id: "1", accountNumber: "0000000", name: "node-1")
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "test",
            clusterEndpoint: "https://test.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            helperStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: device, assignment: DeviceAssignment(deviceID: "1", role: .controlplane, shouldInstallOS: true)),
            ]
        )
        #expect(throws: DeploymentPlannerError.self) {
            _ = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        }
    }

    @Test
    func bootstrapHelperCreatesTwoPhasePlan() throws {
        let helper = DiscoveredDevice(id: "helper", accountNumber: "0000000", name: "helper-1")
        let cp = DiscoveredDevice(id: "cp1", accountNumber: "0000000", name: "cp-1")
        var helperAssignment = DeviceAssignment(deviceID: "helper", role: .helper, helperMode: .bootstrap, shouldInstallOS: true)
        helperAssignment.typedConfirmation = "INSTALL helper-1"
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            helperStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: helper, assignment: helperAssignment),
                DeploymentNodeSpec(device: cp, assignment: DeviceAssignment(deviceID: "cp1", role: .controlplane, shouldInstallOS: true)),
            ]
        )
        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        #expect(plan.phases.first?.title == "Bootstrap Helper")
        #expect(plan.helper.method == .virtualMedia)
    }

    @Test
    func talosBuilderCreatesArtifacts() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let helper = DiscoveredDevice(id: "helper", accountNumber: "0000000", name: "helper-1")
        let cp = DiscoveredDevice(id: "cp1", accountNumber: "0000000", name: "cp-1", primaryIP: "192.0.2.10")
        var helperAssignment = DeviceAssignment(deviceID: "helper", role: .helper, helperMode: .existing)
        helperAssignment.typedConfirmation = ""
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            helperStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: helper, assignment: helperAssignment),
                DeploymentNodeSpec(device: cp, assignment: DeviceAssignment(deviceID: "cp1", role: .controlplane, shouldInstallOS: true)),
            ]
        )
        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        let output = try await DefaultTalosBuilder().buildArtifacts(for: spec, plan: plan, in: temp)
        #expect(FileManager.default.fileExists(atPath: output.appending(path: "deployment-manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: output.appending(path: "cluster.yaml").path))
    }

    @Test
    func bridgeSessionDetectionParsesHammertimeCachePayload() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(
                    executable: "/usr/bin/python3",
                    arguments: [],
                    stdout: """
                    {"authenticated":true,"username":"testuser","header_name":"X-Auth-Token","source":"hammertime-cache","expires_at":"2026-04-22T12:34:56Z","secret":"test-token"}
                    """,
                    stderr: "",
                    exitCode: 0
                ),
            ]
        )
        let client = HammertimeBackedCoreClient(
            settings: HammertimeSettings(binaryPath: "/tmp/ht", pythonPath: "/usr/bin/python3"),
            runner: runner
        )

        let session = try await client.discoverEnvironmentSession(includeSecret: true)

        #expect(session?.session.username == "testuser")
        #expect(session?.session.headerName == "X-Auth-Token")
        #expect(session?.secret == "test-token")
        #expect(runner.invocations.first?.arguments.contains("auth-status") == true)
    }

    @Test
    func bridgeInventoryParsesDevices() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(
                    executable: "/usr/bin/python3",
                    arguments: [],
                    stdout: """
                    {
                      "account_number": "0000000",
                      "devices": [
                        {
                          "id": "123452",
                          "account_number": "0000000",
                          "name": "123452-lbal1.example.test",
                          "primary_ip": "69.20.118.192",
                          "private_ip": "172.24.96.192",
                          "platform_name": "Load-Balancer",
                          "os_type": "Network",
                          "service_level": "Intensive",
                          "service_tag": "",
                          "memory_gib": null,
                          "storage_gib": null,
                          "install_disk": "",
                          "network_interfaces": [
                            {
                              "name": "FW-LB",
                              "addresses": ["172.24.96.192"],
                              "mac_address": "",
                              "vlan_id": 1220,
                              "mtu": null
                            }
                          ],
                          "oob": {
                            "vendor": "idrac",
                            "address": "10.17.123.153",
                            "username": "",
                            "credential_reference": "",
                            "supports_virtual_media": null,
                            "supports_pxe": null
                          },
                          "credential_reference": ""
                        }
                      ]
                    }
                    """,
                    stderr: "",
                    exitCode: 0
                ),
            ]
        )
        let client = ConfiguredCoreClient(
            coreSettings: CoreAPISettings(),
            hammertimeSettings: HammertimeSettings(binaryPath: "/tmp/ht", pythonPath: "/usr/bin/python3"),
            runner: runner
        )

        let devices = try await client.fetchDevices(accountNumber: "0000000")

        #expect(devices.count == 1)
        #expect(devices.first?.id == "123452")
        #expect(devices.first?.platformName == "Load-Balancer")
        #expect(devices.first?.oob?.address == "10.17.123.153")
        #expect(devices.first?.networkInterfaces.first?.vlanID == 1220)
        #expect(devices.first?.isClusterEligible == false)
        #expect(runner.invocations.first?.arguments.contains("account-devices") == true)
    }

    @Test
    func physicalServerEligibilityExcludesNetworkDevicesAndVMs() throws {
        let server = DiscoveredDevice(
            id: "node-1",
            accountNumber: "0000000",
            name: "123450-lab4-compute03.example.test",
            platformName: "HP DL380 G9 OpenStack"
        )
        let firewall = DiscoveredDevice(
            id: "fw-1",
            accountNumber: "0000000",
            name: "123451-fw1.example.test",
            platformName: "Firewall - Cisco ASA"
        )
        let vm = DiscoveredDevice(
            id: "undercloud",
            accountNumber: "0000000",
            name: "1230474-lab2-undercloud",
            platformName: "Virtual Machine for Infrastructure - Linux (Internal Use Only) Required"
        )

        #expect(server.isClusterEligible)
        #expect(firewall.isClusterEligible == false)
        #expect(vm.isClusterEligible == false)
    }

    @Test
    func hammertimeDefaultsSkipChecksForPreProvisionAccess() {
        #expect(HammertimeSettings().skipDeviceChecks)
    }

    @Test
    func talosDefaultsPreferVirtualMedia() {
        #expect(TalosDefaults().installerPreference == .virtualMedia)
    }

    @Test
    func preinstallSnapshotCapturePersistsArtifacts() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let device = DiscoveredDevice(
            id: "123456",
            accountNumber: "0000000",
            name: "123456-lab2-director.example.test",
            primaryIP: "69.20.118.196",
            privateIP: "172.22.220.196",
            platformName: "HP DL380 G9 OpenStack",
            oob: OOBEndpoint(vendor: .ilo, address: "10.17.123.132", username: "root")
        )

        let responses: [CommandResult] = [
            CommandResult(
                executable: "/tmp/ht",
                arguments: [],
                stdout: #"{"123456":{"name":{"value":"123456-lab2-director.example.test"}}}"#,
                stderr: "",
                exitCode: 0
            ),
            CommandResult(
                executable: "/tmp/ht",
                arguments: [],
                stdout: #"{"123456-lab2-director.example.test":{"os":"Red Hat Enterprise Linux 8.5","memory_gib":64}}"#,
                stderr: "",
                exitCode: 0
            ),
            CommandResult(
                executable: "/tmp/ht",
                arguments: [],
                stdout: """
                Static hostname: 123456-lab2-director.example.test
                Operating System: Red Hat Enterprise Linux 8.5
                """,
                stderr: "",
                exitCode: 0
            ),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "eno1 UP 172.22.220.196/22\nbr-ipmi UP 10.17.123.182/26\n", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "2: eno1: <BROADCAST>", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "default via 172.22.220.1 dev eno1\n10.17.123.128/26 dev br-ipmi\n", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "0: from all lookup local\n32766: from all lookup main\n", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "eno1:Wired connection 1:802-3-ethernet:eno1\n", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "GENERAL.DEVICE: eno1\n", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "Bridge br-ipmi\n", stderr: "", exitCode: 0),
            CommandResult(
                executable: "/tmp/ht",
                arguments: [],
                stdout: """
                ---ETC-HOSTNAME---
                123456-lab2-director.example.test
                ---ETC-HOSTS---
                127.0.0.1 localhost
                ---RESOLV---
                search lab.example maas example.test
                nameserver 172.22.216.10
                nameserver 69.20.0.164
                """,
                stderr: "",
                exitCode: 0
            ),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "---FILE:/etc/sysconfig/network-scripts/ifcfg-eno1---\nDEVICE=eno1\n", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
        ]

        let runner = MockCommandRunner(responses: responses)
        let capturer = PreinstallSnapshotCapturer(
            settings: AppSettings(hammertime: HammertimeSettings(binaryPath: "/tmp/ht", pythonPath: "/usr/bin/python3")),
            coreClient: StaticCoreClient(devices: [device]),
            hammertime: StaticHammertimeAdapter(devices: [device]),
            runner: runner
        )

        let snapshot = try await capturer.capture(
            accountNumber: "0000000",
            deviceSelector: "123456",
            source: .core,
            baseDirectory: temp
        )

        #expect(snapshot.device.id == "123456")
        #expect(snapshot.summary.hostname == "123456-lab2-director.example.test")
        #expect(snapshot.summary.oobIP == "10.17.123.132")
        #expect(snapshot.summary.dnsServers == ["172.22.216.10", "69.20.0.164"])
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: snapshot.directory).appending(path: "snapshot.json").path))
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: snapshot.directory).appending(path: "captures").appending(path: "hostnamectl.json").path))
        #expect(runner.invocations.first?.arguments.contains("--no-checks") == true)
    }

    @Test
    func ubuntuNetworkPlanPreservesBridgesVlansAndRoutes() throws {
        let snapshot = NetworkPreservationSnapshot(
            accountNumber: "0000000",
            device: DiscoveredDevice(id: "123456", accountNumber: "0000000", name: "director"),
            summary: NetworkPreservationSummary(
                hostname: "123456-lab2-director.example.test",
                dnsServers: ["172.22.216.10", "69.20.0.164", "8.8.8.8"],
                searchDomains: ["lab.example", "maas", "example.test"]
            ),
            captures: [
                CommandCapture(
                    label: "host-networking",
                    executable: "ht",
                    arguments: [],
                    stdout: """
                    ---IP-DETAIL-LINK---
                    2: eno1: <BROADCAST,UP> mtu 1500
                        link/ether 94:57:a5:6d:9c:c0 brd ff:ff:ff:ff:ff:ff
                    4: eno3: <BROADCAST,UP> mtu 1500
                        link/ether 94:57:a5:6d:9c:c2 brd ff:ff:ff:ff:ff:ff
                    6: eno49: <BROADCAST,UP> mtu 1500
                        link/ether 5c:b9:01:8f:8c:9c brd ff:ff:ff:ff:ff:ff
                    63: eno3.901@eno3: <BROADCAST,UP> mtu 1500
                        link/ether 94:57:a5:6d:9c:c2 brd ff:ff:ff:ff:ff:ff
                    16: vnet0: <BROADCAST,UP> mtu 1500
                        link/ether fe:54:00:4c:af:46 brd ff:ff:ff:ff:ff:ff
                    ---BRIDGE-LINK---
                    6: eno49: <BROADCAST,UP> mtu 1500 master br-ctlplane state forwarding
                    63: eno3.901@eno3: <BROADCAST,UP> mtu 1500 master br-ipmi state forwarding
                    16: vnet0: <BROADCAST,UP> mtu 1500 master virbr0 state forwarding
                    ---FILE:/etc/sysconfig/network-scripts/ifcfg-eno1---
                    DEVICE=eno1
                    TYPE=Ethernet
                    IPADDR=172.22.220.196
                    PREFIX=22
                    GATEWAY=172.22.220.1
                    ONBOOT=yes
                    ---FILE:/etc/sysconfig/network-scripts/ifcfg-eno49---
                    DEVICE=eno49
                    BRIDGE=br-ctlplane
                    BOOTPROTO=none
                    ONBOOT=yes
                    ---FILE:/etc/sysconfig/network-scripts/ifcfg-eno3.901---
                    DEVICE=eno3.901
                    VLAN=yes
                    BRIDGE=br-ipmi
                    ONBOOT=yes
                    ---FILE:/etc/sysconfig/network-scripts/ifcfg-br-ctlplane---
                    DEVICE=br-ctlplane
                    TYPE=Bridge
                    IPADDR=172.22.216.9
                    PREFIX=22
                    ONBOOT=yes
                    ---FILE:/etc/sysconfig/network-scripts/ifcfg-br-ipmi---
                    DEVICE=br-ipmi
                    TYPE=Bridge
                    IPADDR=10.17.123.182
                    PREFIX=26
                    ONBOOT=yes
                    ---FILE:/etc/sysconfig/network-scripts/route-br-ctlplane---
                    192.168.100.0/24 via 172.22.216.36
                    """,
                    stderr: "",
                    exitCode: 0
                ),
            ],
            directory: "/tmp"
        )

        let plan = try UbuntuAutoinstallBuilder().makeNetworkPlan(from: snapshot)

        let eno1 = plan.ethernets.first(where: { $0.name == "eno1" })
        let brIPMI = plan.bridges.first(where: { $0.name == "br-ipmi" })
        let brCtlplane = plan.bridges.first(where: { $0.name == "br-ctlplane" })

        #expect(eno1?.macAddress == "94:57:a5:6d:9c:c0")
        #expect(plan.vlans.contains(NetplanVLAN(name: "eno3.901", id: 901, link: "eno3")))
        #expect(brIPMI?.interfaces == ["eno3.901"])
        #expect(brIPMI?.addresses == ["10.17.123.182/26"])
        #expect(brCtlplane?.routes.contains(NetplanRoute(to: "192.168.100.0/24", via: "172.22.216.36")) == true)
        #expect(plan.bridges.contains(where: { $0.name == "virbr0" }) == false)
        #expect(plan.renderNetplanYAML().contains("nameservers:"))
    }

    @Test
    func ubuntuAutoinstallSeedCreatesRackRootAndEvidence() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let spec = UbuntuInstallSpec(
            accountNumber: "0000000",
            deviceID: "123456",
            sourceISOPath: "/tmp/source.iso",
            outputISOPath: temp.appending(path: "ubuntu.iso").path,
            workDirectoryPath: temp.path,
            hostname: "director",
            fqdn: "director.example.com",
            installDiskSerial: "disk-serial",
            rackPasswordHash: "$6$rack",
            rootPasswordHash: "$6$root",
            authorizedSSHKeys: ["ssh-ed25519 AAAATEST user@example"]
        )
        let plan = NetworkRebuildPlan(
            hostname: "director.example.com",
            fqdn: "director.example.com",
            ethernets: [
                NetplanEthernet(
                    name: "eno1",
                    macAddress: "94:57:a5:6d:9c:c0",
                    addresses: ["172.22.220.196/22"],
                    routes: [NetplanRoute(to: "default", via: "172.22.220.1")],
                    nameservers: ["172.22.216.10"],
                    searchDomains: ["example.test"]
                ),
            ],
            vlans: [NetplanVLAN(name: "eno3.901", id: 901, link: "eno3")],
            bridges: [NetplanBridge(name: "br-ipmi", interfaces: ["eno3.901"], addresses: ["10.17.123.182/26"])]
        )

        let artifacts = try UbuntuAutoinstallBuilder().writeSeed(spec: spec, networkPlan: plan)
        let userData = try String(contentsOf: URL(fileURLWithPath: artifacts.userDataPath), encoding: .utf8)
        let metaData = try String(contentsOf: URL(fileURLWithPath: artifacts.metaDataPath), encoding: .utf8)

        #expect(userData.contains("autoinstall:"))
        #expect(userData.contains("name: rack"))
        #expect(userData.contains("name: root"))
        #expect(userData.contains("PermitRootLogin yes"))
        #expect(userData.contains("/var/log/installer/tds"))
        #expect(userData.contains("br-ipmi:"))
        #expect(metaData.contains("instance-id: tds-0000000-123456-director"))
    }

}

private final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    private(set) var invocations: [CommandInvocation] = []
    private var responses: [CommandResult]

    init(responses: [CommandResult]) {
        self.responses = responses
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String : String],
        currentDirectory: URL?,
        timeout: TimeInterval?
    ) async throws -> CommandResult {
        invocations.append(
            CommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                timeout: timeout
            )
        )
        guard !responses.isEmpty else {
            throw CoreBridgeError.invalidBridgeOutput
        }
        return responses.removeFirst()
    }
}

private struct CommandInvocation {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var currentDirectory: URL?
    var timeout: TimeInterval?
}

private struct StaticCoreClient: CoreClient, EnvironmentCoreSessionProviding {
    let devices: [DiscoveredDevice]

    func fetchDevices(accountNumber: String) async throws -> [DiscoveredDevice] {
        devices
    }

    func fetchDeviceDetails(accountNumber: String, deviceID: String) async throws -> DiscoveredDevice {
        devices.first(where: { $0.id == deviceID || $0.name == deviceID }) ?? devices[0]
    }

    func discoverEnvironmentSession(includeSecret: Bool) async throws -> EnvironmentCoreSession? {
        nil
    }
}

private struct StaticHammertimeAdapter: HammertimeAdapter {
    let devices: [DiscoveredDevice]

    func inventory(accountNumber: String) async throws -> [DiscoveredDevice] {
        devices
    }

    func refreshLiveFacts(devices: [DiscoveredDevice], groups: [String]) async -> [String : Result<LiveFactSnapshot, any Error>] {
        [:]
    }

    func establishProxy(profile: AccessProfile, targetDeviceID: String?) async throws -> CommandResult {
        CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0)
    }

    func openOOB(deviceID: String, via: String?) async throws -> CommandResult {
        CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0)
    }
}
