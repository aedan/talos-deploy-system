import Foundation
import XCTest
@testable import TalosDeployCore

final class TalosDeployCoreTests: XCTestCase {
    private func talosDevice(
        id: String = "cp1",
        name: String = "cp-1",
        primaryIP: String = "198.51.100.10",
        privateIP: String = "172.22.220.10",
        oob: OOBEndpoint? = nil
    ) -> DiscoveredDevice {
        DiscoveredDevice(
            id: id,
            accountNumber: "0000000",
            name: name,
            primaryIP: primaryIP,
            privateIP: privateIP,
            networkInterfaces: [
                NetworkInterface(name: "eno1", addresses: ["\(privateIP)/22"], macAddress: "94:57:a5:6d:9c:c0"),
            ],
            oob: oob
        )
    }

    private func talosAssignment(
        deviceID: String = "cp1",
        role: DeviceRole = .controlplane,
        shouldInstallOS: Bool = true
    ) -> DeviceAssignment {
        DeviceAssignment(
            deviceID: deviceID,
            role: role,
            shouldInstallOS: shouldInstallOS,
            staticNetwork: StaticNetworkConfig(
                gateway: "172.22.220.1",
                nameservers: ["172.22.216.10"],
                searchDomains: ["example.test"]
            )
        )
    }

    func testCoreDefaultsDoNotBakeInATestAccount() {
        XCTAssertTrue(CoreAPISettings().defaultAccountNumber.isEmpty)
    }

    func testSettingsRoundTrip() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        setenv("TDS_HOME", base.path, 1)
        let paths = AppPaths()
        try paths.ensureExists()

        let controller = SettingsController(paths: paths)
        var settings = AppSettings()
        settings.core.defaultAccountNumber = "123456"
        settings.deployer.stateRoot = "/srv/talos"
        try controller.save(settings)

        let loaded = try controller.load()
        XCTAssertTrue(loaded.core.defaultAccountNumber == "123456")
        XCTAssertTrue(loaded.deployer.stateRoot == "/srv/talos")
    }

    func testBootstrapDefaultsUseOperatorLocalMedia() {
        let settings = AppSettings()

        XCTAssertTrue(settings.bootstrapMedia.deliveryMode == .operatorLocalMedia)
        XCTAssertTrue(settings.bootstrapMedia.allowExistingOSMediaHost == false)
        XCTAssertTrue(settings.bootstrapMedia.requireOperatorLocalMediaForGreenfield)
    }

    func testPlannerRequiresExactlyOneDeployer() throws {
        let device = DiscoveredDevice(id: "1", accountNumber: "0000000", name: "node-1")
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "test",
            clusterEndpoint: "https://test.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: device, assignment: DeviceAssignment(deviceID: "1", role: .controlplane, shouldInstallOS: true)),
            ]
        )
        XCTAssertThrowsError(try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)) { error in
            XCTAssertTrue(error is DeploymentPlannerError)
        }
    }

    func testBootstrapDeployerCreatesGreenfieldLocalMediaPlan() throws {
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice()
        var deployerAssignment = DeviceAssignment(deviceID: "deployer", role: .deployer, deployerMode: .bootstrap, shouldInstallOS: true)
        deployerAssignment.typedConfirmation = "INSTALL deployer-1"
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: deployerAssignment),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )
        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        XCTAssertTrue(plan.phases.contains { $0.title == "Bootstrap Deployer" })
        XCTAssertTrue(plan.phases.contains { phase in
            phase.steps.contains { $0.contains("do not depend on another target node having an OS") }
        })
        XCTAssertTrue(plan.deployer.method == .operatorLocalMedia)
    }

    func testPlannerRejectsExistingOSMediaHostUnlessExplicitlyAllowed() throws {
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice()
        var deployerAssignment = DeviceAssignment(deviceID: "deployer", role: .deployer, deployerMode: .bootstrap, shouldInstallOS: true)
        deployerAssignment.typedConfirmation = "INSTALL deployer-1"
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: deployerAssignment),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )
        let settings = AppSettings(
            bootstrapMedia: BootstrapMediaDefaults(deliveryMode: .existingOSMediaHost)
        )

        XCTAssertThrowsError(try DeploymentPlanner(settings: settings).makePlan(spec: spec)) { error in
            guard case DeploymentPlannerError.existingMediaHostNotExplicitlyAllowed = error else {
                return XCTFail("Expected existingMediaHostNotExplicitlyAllowed, got \(error)")
            }
        }
    }

    func testPlannerAllowsExplicitExistingOSMediaHost() throws {
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice()
        var deployerAssignment = DeviceAssignment(deviceID: "deployer", role: .deployer, deployerMode: .bootstrap, shouldInstallOS: true)
        deployerAssignment.typedConfirmation = "INSTALL deployer-1"
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: deployerAssignment),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )
        let settings = AppSettings(
            bootstrapMedia: BootstrapMediaDefaults(
                deliveryMode: .existingOSMediaHost,
                allowExistingOSMediaHost: true,
                mediaHostDeviceID: "716091"
            )
        )

        let plan = try DeploymentPlanner(settings: settings).makePlan(spec: spec)

        XCTAssertTrue(plan.deployer.method == .bootURL)
        XCTAssertTrue(plan.phases.contains { phase in
            phase.steps.contains { $0.contains("not greenfield-safe") }
        })
    }

    func testExistingDeployerPlanIncludesTDSMediaSetup() throws {
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "existing-deployer")
        let cp = talosDevice()
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: DeviceAssignment(deviceID: "deployer", role: .deployer, deployerMode: .existing, shouldInstallOS: false)),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )

        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)

        XCTAssertTrue(plan.phases.contains { $0.title == "Prepare Existing Deployer" })
        XCTAssertTrue(plan.phases.contains { phase in
            phase.steps.contains { $0.contains("tds prepares media and PXE directories") }
        })
    }

    func testTalosBuilderCreatesArtifacts() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice(primaryIP: "192.0.2.10", privateIP: "172.22.220.10")
        var deployerAssignment = DeviceAssignment(deviceID: "deployer", role: .deployer, deployerMode: .existing)
        deployerAssignment.typedConfirmation = ""
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            talosFactory: TalosImageFactorySettings(schematicID: "abc123", extraKernelArgs: ["console=ttyS1"]),
            talosKernelModules: [
                TalosKernelModule(name: "br_netfilter"),
                TalosKernelModule(name: "zfs", parameters: ["zfs_arc_max=123"]),
            ],
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: deployerAssignment),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )
        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        let output = try await DefaultTalosBuilder().buildArtifacts(for: spec, plan: plan, in: temp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appending(path: "deployment-manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appending(path: "cluster.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appending(path: "talos-factory-schematic.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appending(path: "talos-artifacts.json").path))
        let patch = try String(contentsOf: output.appending(path: "node-patches").appending(path: "cp-1.yaml"), encoding: .utf8)
        XCTAssertTrue(patch.contains("image: factory.talos.dev/installer/abc123:v1.11.3"))
        XCTAssertTrue(patch.contains("name: br_netfilter"))
        XCTAssertTrue(patch.contains("zfs_arc_max=123"))
        XCTAssertTrue(patch.contains("addresses:\n          - 172.22.220.10/22"))
        XCTAssertTrue(patch.contains("network: 0.0.0.0/0"))
        XCTAssertTrue(patch.contains("gateway: 172.22.220.1"))
        XCTAssertTrue(patch.contains("destination: /var/lib/longhorn"))
    }

    func testTalosBuilderRendersManualVLANsAndBridges() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice(primaryIP: "192.0.2.10", privateIP: "172.22.220.10")
        var deployerAssignment = DeviceAssignment(deviceID: "deployer", role: .deployer, deployerMode: .existing)
        let cpAssignment = DeviceAssignment(
            deviceID: "cp1",
            role: .controlplane,
            shouldInstallOS: true,
            networkSource: .manual,
            staticNetwork: StaticNetworkConfig(
                managementInterface: "eno1",
                managementAddressCIDR: "172.22.220.10/22",
                gateway: "172.22.220.1",
                nameservers: ["69.20.0.196", "69.20.0.164"],
                searchDomains: ["rpc.rackspace.com"],
                routes: [StaticNetworkRoute(to: "default", via: "172.22.220.1")],
                vlans: [
                    NetworkInterface(name: "eno3.901", vlanID: 901, parentInterface: "eno3"),
                    NetworkInterface(name: "eno50.1326", vlanID: 1326, parentInterface: "eno50"),
                ],
                bridges: [
                    NetworkInterface(name: "br-ipmi", addresses: ["10.17.123.180/26"], bridgePorts: ["eno3.901"]),
                    NetworkInterface(
                        name: "br-ctlplane",
                        addresses: ["172.22.216.10/22"],
                        bridgePorts: ["eno49"],
                        routes: [StaticNetworkRoute(to: "192.168.100.0/24", via: "172.22.216.36")]
                    ),
                ]
            )
        )
        deployerAssignment.typedConfirmation = ""
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: deployerAssignment),
                DeploymentNodeSpec(device: cp, assignment: cpAssignment),
            ]
        )

        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        let output = try await DefaultTalosBuilder().buildArtifacts(for: spec, plan: plan, in: temp)
        let patch = try String(contentsOf: output.appending(path: "node-patches").appending(path: "cp-1.yaml"), encoding: .utf8)

        XCTAssertTrue(patch.contains("      - interface: eno3\n        vlans:\n          - vlanId: 901"))
        XCTAssertTrue(patch.contains("      - interface: eno50\n        vlans:\n          - vlanId: 1326"))
        XCTAssertTrue(patch.contains("      - interface: br-ipmi"))
        XCTAssertTrue(patch.contains("          - eno3.901"))
        XCTAssertTrue(patch.contains("      - interface: br-ctlplane"))
        XCTAssertTrue(patch.contains("          - eno49"))
        XCTAssertTrue(patch.contains("network: 192.168.100.0/24"))
        XCTAssertTrue(patch.contains("gateway: 172.22.216.36"))
    }

    func testBridgeSessionDetectionParsesHammertimeCachePayload() async throws {
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

        XCTAssertTrue(session?.session.username == "testuser")
        XCTAssertTrue(session?.session.headerName == "X-Auth-Token")
        XCTAssertTrue(session?.secret == "test-token")
        XCTAssertTrue(runner.invocations.first?.arguments.contains("auth-status") == true)
    }

    func testBridgeInventoryParsesDevices() async throws {
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

        XCTAssertTrue(devices.count == 1)
        XCTAssertTrue(devices.first?.id == "123452")
        XCTAssertTrue(devices.first?.platformName == "Load-Balancer")
        XCTAssertTrue(devices.first?.oob?.address == "10.17.123.153")
        XCTAssertTrue(devices.first?.networkInterfaces.first?.vlanID == 1220)
        XCTAssertTrue(devices.first?.isClusterEligible == false)
        XCTAssertTrue(runner.invocations.first?.arguments.contains("account-devices") == true)
    }

    func testPhysicalServerEligibilityExcludesNetworkDevicesAndVMs() throws {
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

        XCTAssertTrue(server.isClusterEligible)
        XCTAssertTrue(firewall.isClusterEligible == false)
        XCTAssertTrue(vm.isClusterEligible == false)
    }

    func testHammertimeDefaultsSkipChecksForPreProvisionAccess() {
        XCTAssertTrue(HammertimeSettings().skipDeviceChecks)
    }

    func testTalosDefaultsPreferVirtualMedia() {
        XCTAssertTrue(TalosDefaults().installerPreference == .virtualMedia)
    }

    func testTalosFactoryArtifactsRenderSelectedExtensions() {
        let settings = TalosImageFactorySettings(
            architecture: "amd64",
            platform: "metal",
            schematicID: "abc123",
            selectedSystemExtensions: ["siderolabs/iscsi-tools", "siderolabs/zfs"],
            extraKernelArgs: ["console=ttyS1"]
        )

        let artifacts = TalosFactoryClient().artifactURLs(settings: settings, talosVersion: "v1.12.1")

        XCTAssertTrue(artifacts.isoURL == "https://factory.talos.dev/image/abc123/v1.12.1/metal-amd64.iso")
        XCTAssertTrue(artifacts.pxeURL == "https://pxe.factory.talos.dev/pxe/abc123/v1.12.1/metal-amd64")
        XCTAssertTrue(artifacts.installerImage == "factory.talos.dev/installer/abc123:v1.12.1")
        XCTAssertTrue(artifacts.schematicYAML.contains("siderolabs/zfs"))
        XCTAssertTrue(artifacts.schematicYAML.contains("extraKernelArgs:"))
    }

    func testAutomaticTalosProvisioningPrefersDeployerHostedMedia() throws {
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice(oob: OOBEndpoint(vendor: .ilo, address: "10.0.0.11"))
        var deployerAssignment = DeviceAssignment(deviceID: "deployer", role: .deployer, deployerMode: .bootstrap, shouldInstallOS: true)
        deployerAssignment.typedConfirmation = "INSTALL deployer-1"
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.11.3",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: deployerAssignment),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )

        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        let controlPlane = plan.installs.first { $0.device.id == "cp1" }

        XCTAssertTrue(controlPlane?.method == .bootURL)
        XCTAssertTrue(plan.phases.contains { $0.title == "Prepare Talos Artifacts" })
        XCTAssertTrue(plan.phases.last?.steps.contains(where: { $0.contains("deployer-hosted ISO") }) == true)
    }

    func testDeployerRoleIsTheOnlyInstallControlRole() {
        XCTAssertTrue(DeviceRole.deployer.isDeployer)
        XCTAssertTrue(DeviceRole.selectableRoles.contains(.deployer))
        XCTAssertTrue(DeviceRole.selectableRoles == [.unassigned, .deployer, .controlplane, .worker])
        XCTAssertTrue(DeviceRole.deployer.displayName == "deployer")
    }

    func testDeployerHostnameGenerationUsesDeviceNumberAndSuffix() {
        let device = DiscoveredDevice(id: "device-100001", accountNumber: "0000000", name: "100001-lab2-director")

        let hostname = DeployerNaming().hostname(for: device, suffix: "Lab 2")

        XCTAssertTrue(hostname == "100001-deployer-lab-2")
    }

    func testStaticNetworkValidationBlocksIncompleteTalosNodes() {
        let node = DeploymentNodeSpec(
            device: DiscoveredDevice(id: "cp1", accountNumber: "0000000", name: "cp-1"),
            assignment: DeviceAssignment(deviceID: "cp1", role: .controlplane, shouldInstallOS: true)
        )

        let result = StaticNetworkPlanner().validate(node: node)

        XCTAssertTrue(result.isValid == false)
        XCTAssertTrue(result.errors.contains("Missing default gateway."))
    }

    func testStaticNetworkValidationPrefersCorePrivateIP() {
        let node = DeploymentNodeSpec(device: talosDevice(), assignment: talosAssignment())

        let result = StaticNetworkPlanner().validate(node: node)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.config.managementAddressCIDR == "172.22.220.10/22")
        XCTAssertTrue(result.config.routes.first == StaticNetworkRoute(to: "default", via: "172.22.220.1"))
    }

    func testTalosDefaultsIncludeRackspaceExtensionsAndLonghorn() {
        let defaults = TalosDefaults()

        XCTAssertTrue(defaults.factory.selectedSystemExtensions == [
            "siderolabs/iscsi-tools",
            "siderolabs/util-linux-tools",
            "siderolabs/bnx2-bnx2x",
        ])
        XCTAssertTrue(defaults.enableLonghornExtraMounts)
    }

    func testDeployerServicePlanIncludesManagedPackagesAndUnits() {
        let plan = DefaultDeployerHostClient().planDeployerServices(configuration: DeployerMediaServiceConfiguration())

        XCTAssertTrue(plan.packages.contains("dnsmasq"))
        XCTAssertTrue(plan.systemdUnits.contains("tds-media-http.service"))
        XCTAssertTrue(plan.systemdUnits.contains("tds-dnsmasq.service"))
        XCTAssertTrue(plan.cacheFallbackCommands.contains { $0.contains("/var/cache/tds") })
    }

    func testPreinstallSnapshotCapturePersistsArtifacts() async throws {
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

        XCTAssertTrue(snapshot.device.id == "123456")
        XCTAssertTrue(snapshot.summary.hostname == "123456-lab2-director.example.test")
        XCTAssertTrue(snapshot.summary.oobIP == "10.17.123.132")
        XCTAssertTrue(snapshot.summary.dnsServers == ["172.22.216.10", "69.20.0.164"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: snapshot.directory).appending(path: "snapshot.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: snapshot.directory).appending(path: "captures").appending(path: "hostnamectl.json").path))
        XCTAssertTrue(runner.invocations.first?.arguments.contains("--no-checks") == true)
    }

    func testUbuntuNetworkPlanPreservesBridgesVlansAndRoutes() throws {
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

        XCTAssertTrue(eno1?.macAddress == "94:57:a5:6d:9c:c0")
        XCTAssertTrue(plan.vlans.contains(NetplanVLAN(name: "eno3.901", id: 901, link: "eno3")))
        XCTAssertTrue(brIPMI?.interfaces == ["eno3.901"])
        XCTAssertTrue(brIPMI?.addresses == ["10.17.123.182/26"])
        XCTAssertTrue(brCtlplane?.routes.contains(NetplanRoute(to: "192.168.100.0/24", via: "172.22.216.36")) == true)
        XCTAssertTrue(plan.bridges.contains(where: { $0.name == "virbr0" }) == false)
        XCTAssertTrue(plan.renderNetplanYAML().contains("nameservers:"))
    }

    func testUbuntuAutoinstallSeedCreatesRackRootAndEvidence() throws {
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

        XCTAssertTrue(userData.contains("autoinstall:"))
        XCTAssertTrue(userData.contains("name: rack"))
        XCTAssertTrue(userData.contains("name: root"))
        XCTAssertTrue(userData.contains("PermitRootLogin yes"))
        XCTAssertTrue(userData.contains("/var/log/installer/tds"))
        XCTAssertTrue(userData.contains("br-ipmi:"))
        XCTAssertTrue(metaData.contains("instance-id: tds-0000000-123456-director"))
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
