import Foundation
import XCTest
@testable import TalosDeployCore

final class TalosDeployCoreTests: XCTestCase {
    private func talosDevice(
        id: String = "cp1",
        name: String = "cp-1",
        primaryIP: String = "198.51.100.10",
        privateIP: String = "198.51.100.10",
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
                gateway: "198.51.100.1",
                nameservers: ["198.51.101.10"],
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

    func testDeployRunDoesNotRenameCoreWhenDeployerIsUnreachable() async throws {
        let deployer = talosDevice(id: "deployer", name: "716181-lab2-director.rpc.rackspace.com")
        let controlPlane = talosDevice(id: "cp1", name: "716182-lab2-controller01.rpc.rackspace.com")
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "lab2-talos",
            clusterEndpoint: "https://198.51.100.10:6443",
            talosVersion: "v1.13.0",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(
                    device: deployer,
                    assignment: DeviceAssignment(
                        deviceID: deployer.id,
                        role: .deployer,
                        deployerMode: .existing,
                        shouldInstallOS: false
                    )
                ),
                DeploymentNodeSpec(device: controlPlane, assignment: talosAssignment(deviceID: controlPlane.id)),
            ]
        )
        let coreClient = RenameTrackingCoreClient()
        let coordinator = DeploymentCoordinator(
            settings: AppSettings(hammertime: HammertimeSettings(enabled: false)),
            deployerHostClient: FailingDeployerHostClient(),
            coreClient: coreClient
        )
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let state = try await coordinator.stage(spec: spec, at: base)

        do {
            _ = try await coordinator.run(
                state: state,
                connection: nil,
                dryRun: false
            )
            XCTFail("Expected deployer validation to fail")
        } catch {
            XCTAssertEqual(coreClient.renameCalls, 0)
        }
    }

    func testTalosBuilderCreatesArtifacts() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice(primaryIP: "192.0.2.10", privateIP: "198.51.100.10")
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
        XCTAssertFalse(patch.contains("hostname: cp-1"))
        XCTAssertTrue(patch.contains("name: br_netfilter"))
        XCTAssertTrue(patch.contains("zfs_arc_max=123"))
        XCTAssertTrue(patch.contains("addresses:\n          - 198.51.100.10/22"))
        XCTAssertTrue(patch.contains("network: 0.0.0.0/0"))
        XCTAssertTrue(patch.contains("gateway: 198.51.100.1"))
        XCTAssertTrue(patch.contains("  kubelet:\n    extraMounts:"))
        XCTAssertFalse(patch.contains("  extraMounts:\n    - destination: /var/lib/longhorn"))
        XCTAssertTrue(patch.contains("destination: /var/lib/longhorn"))
    }

    func testStageWritesMaintenanceBundleForDeployerOwnedOperations() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice(primaryIP: "192.0.2.10", privateIP: "198.51.100.10")
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.13.0",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: DeviceAssignment(deviceID: deployer.id, role: .deployer, deployerMode: .existing)),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )

        let state = try await DeploymentCoordinator(settings: AppSettings()).stage(spec: spec, at: temp)
        let stateDirectory = URL(fileURLWithPath: state.localStateDirectory, isDirectory: true)
        let manifestData = try Data(contentsOf: stateDirectory.appending(path: "maintenance-bundle.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(MaintenanceBundleManifest.self, from: manifestData)

        XCTAssertTrue(manifest.scripts.contains("maintenance/tds-prepare-talos-media.sh"))
        XCTAssertTrue(manifest.scripts.contains("maintenance/tds-run-talos-deploy.sh"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDirectory.appending(path: "maintenance/tds-prepare-talos-media.sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDirectory.appending(path: "maintenance/health-check.sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDirectory.appending(path: "inventory/selected-devices.json").path))

        let deployScript = try String(contentsOf: stateDirectory.appending(path: "maintenance/tds-run-talos-deploy.sh"))
        XCTAssertTrue(deployScript.contains("TDS_DEPLOYER_STATE_ROOT='/var/lib/talos-deploy'"))
        XCTAssertTrue(deployScript.contains("${TDS_DEPLOYER_STATE_ROOT}/bin/talosctl"))
        let prepareScript = try String(contentsOf: stateDirectory.appending(path: "maintenance/tds-prepare-talos-media.sh"))
        XCTAssertTrue(prepareScript.contains("talos.config=metal-iso"))
        XCTAssertTrue(prepareScript.contains("talos-v1.13.0-cp1.iso"))
        XCTAssertTrue(prepareScript.contains("gen config 'cluster' 'https://cluster.example.com:6443'"))
        XCTAssertTrue(prepareScript.contains("validate --mode metal --config \"machine-configs/${name}.yaml\" --strict"))
        XCTAssertFalse(prepareScript.contains("if [ ! -f generated/talosconfig ]; then"))
    }

    func testDryRunReportsAccessProvisioningAndBootstrapPlan() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice(primaryIP: "192.0.2.10", privateIP: "198.51.100.10")
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.13.0",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: DeviceAssignment(deviceID: deployer.id, role: .deployer, deployerMode: .existing)),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )
        let coordinator = DeploymentCoordinator(settings: AppSettings())
        let state = try await coordinator.stage(spec: spec, at: temp)
        let run = try await coordinator.run(state: state, dryRun: true)

        XCTAssertEqual(run.accessValidation?.method, .auto)
        XCTAssertFalse(run.provisioningExecution?.plannedActions.isEmpty ?? true)
        XCTAssertEqual(run.bootstrapResult?.bootstrapNode, cp.name)
        XCTAssertTrue(run.maintenanceBundle?.scripts.contains("maintenance/tds-run-talos-deploy.sh") == true)
    }

    func testTalosBuilderRendersManualVLANsAndBridges() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice(primaryIP: "192.0.2.10", privateIP: "198.51.100.10")
        var deployerAssignment = DeviceAssignment(deviceID: "deployer", role: .deployer, deployerMode: .existing)
        let cpAssignment = DeviceAssignment(
            deviceID: "cp1",
            role: .controlplane,
            shouldInstallOS: true,
            networkSource: .manual,
            staticNetwork: StaticNetworkConfig(
                managementInterface: "eno1",
                managementAddressCIDR: "198.51.100.10/22",
                gateway: "198.51.100.1",
                nameservers: ["203.0.113.196", "203.0.113.164"],
                searchDomains: ["rpc.rackspace.com"],
                routes: [StaticNetworkRoute(to: "default", via: "198.51.100.1")],
                vlans: [
                    NetworkInterface(name: "eno3.901", vlanID: 901, parentInterface: "eno3"),
                    NetworkInterface(name: "eno50.1326", vlanID: 1326, parentInterface: "eno50"),
                ],
                bridges: [
                    NetworkInterface(name: "br-ipmi", addresses: ["192.0.2.180/26"], bridgePorts: ["eno3.901"]),
                    NetworkInterface(
                        name: "br-ctlplane",
                        addresses: ["198.51.101.10/22"],
                        bridgePorts: ["eno49"],
                        routes: [StaticNetworkRoute(to: "192.168.100.0/24", via: "198.51.101.36")]
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
        XCTAssertTrue(patch.contains("gateway: 198.51.101.36"))
    }

    func testTalosBuilderRendersManagementDeviceSelectorWhenMACIsKnown() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = talosDevice(primaryIP: "192.0.2.10", privateIP: "198.51.100.10")
        let cpAssignment = DeviceAssignment(
            deviceID: "cp1",
            role: .controlplane,
            shouldInstallOS: true,
            staticNetwork: StaticNetworkConfig(
                managementInterface: "eno1",
                managementHardwareAddress: "3c:a8:2a:1c:a0:28",
                managementAddressCIDR: "198.51.100.10/22",
                gateway: "198.51.100.1",
                nameservers: ["203.0.113.53"],
                routes: [StaticNetworkRoute(to: "default", via: "198.51.100.1")]
            )
        )
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.13.0",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: DeviceAssignment(deviceID: deployer.id, role: .deployer)),
                DeploymentNodeSpec(device: cp, assignment: cpAssignment),
            ]
        )

        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        let output = try await DefaultTalosBuilder().buildArtifacts(for: spec, plan: plan, in: temp)
        let patch = try String(contentsOf: output.appending(path: "node-patches").appending(path: "cp-1.yaml"), encoding: .utf8)

        XCTAssertTrue(patch.contains("      - deviceSelector:\n          hardwareAddr: 3c:a8:2a:1c:a0:28"))
        XCTAssertFalse(patch.contains("      - interface: eno1\n        addresses:"))
        XCTAssertTrue(patch.contains("addresses:\n          - 198.51.100.10/22"))
    }

    func testTalosBuilderUsesDeployerRegistryForInstallerImageWhenAvailable() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(
            id: "deployer",
            accountNumber: "0000000",
            name: "deployer-1",
            primaryIP: "203.0.113.196",
            privateIP: "198.51.100.196"
        )
        let cp = talosDevice(primaryIP: "192.0.2.10", privateIP: "198.51.100.10")
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.13.0",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            talosFactory: TalosImageFactorySettings(schematicID: "abc123"),
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: DeviceAssignment(deviceID: deployer.id, role: .deployer)),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )

        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        let output = try await DefaultTalosBuilder().buildArtifacts(for: spec, plan: plan, in: temp)
        let patch = try String(contentsOf: output.appending(path: "node-patches").appending(path: "cp-1.yaml"), encoding: .utf8)

        XCTAssertTrue(patch.contains("image: 198.51.100.196:5000/installer/abc123:v1.13.0"))
        XCTAssertTrue(patch.contains("registries:"))
        XCTAssertTrue(patch.contains("\"198.51.100.196:5000\":"))
        XCTAssertTrue(patch.contains("http://198.51.100.196:5000"))
        XCTAssertTrue(patch.contains("skipFallback: true"))
    }

    func testTalosBuilderPrefersNodeFacingRegistryAddressCIDR() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(
            id: "deployer",
            accountNumber: "0000000",
            name: "deployer-1",
            primaryIP: "203.0.113.196",
            privateIP: "198.51.100.196"
        )
        let cp = talosDevice(primaryIP: "192.0.2.10", privateIP: "198.51.100.10")
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.13.0",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            talosFactory: TalosImageFactorySettings(schematicID: "abc123"),
            talosProvisioning: TalosProvisioningDefaults(
                deployerRegistryAddressCIDR: "198.51.100.55/32",
                deployerRegistryInterface: "br-ctlplane"
            ),
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: DeviceAssignment(deviceID: deployer.id, role: .deployer)),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )

        let plan = try DeploymentPlanner(settings: AppSettings()).makePlan(spec: spec)
        let output = try await DefaultTalosBuilder().buildArtifacts(for: spec, plan: plan, in: temp)
        let patch = try String(contentsOf: output.appending(path: "node-patches").appending(path: "cp-1.yaml"), encoding: .utf8)

        XCTAssertTrue(patch.contains("image: 198.51.100.55:5000/installer/abc123:v1.13.0"))
        XCTAssertTrue(patch.contains("\"198.51.100.55:5000\":"))
        XCTAssertTrue(patch.contains("http://198.51.100.55:5000"))
        XCTAssertFalse(patch.contains("198.51.100.196:5000"))
    }

    func testOOBIntegratedNICParserReadsHPEPortMACs() {
        let output = """
        status=0
        iLO4_MACAddress=38:63:bb:32:02:d6
        Port1NIC_MACAddress=3c:a8:2a:1c:a0:28
        Port2NIC_MACAddress=3c:a8:2a:1c:a0:29
        """

        let ports = HPEIntegratedNICParser().parse(output)

        XCTAssertEqual(ports.count, 3)
        XCTAssertEqual(ports.first(where: { $0.label == "Port1NIC" })?.portNumber, 1)
        XCTAssertEqual(ports.first(where: { $0.label == "Port1NIC" })?.macAddress, "3c:a8:2a:1c:a0:28")
        XCTAssertTrue(ports.first(where: { $0.label == "iLO4" })?.isManagementPort == true)
    }

    func testCoordinatorEnrichesManagementMACFromOOBBeforeStaging() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = DiscoveredDevice(id: "deployer", accountNumber: "0000000", name: "deployer-1")
        let cp = DiscoveredDevice(
            id: "716182",
            accountNumber: "0000000",
            name: "716182-lab2-controller01",
            primaryIP: "207.97.193.227",
            privateIP: "172.22.220.227",
            networkInterfaces: [
                NetworkInterface(name: "L2-DEPLOY-MGMT", addresses: ["172.22.220.227/22"]),
            ]
        )
        let cpAssignment = DeviceAssignment(
            deviceID: "716182",
            role: .controlplane,
            shouldInstallOS: true,
            staticNetwork: StaticNetworkConfig(
                managementInterface: "eno1",
                managementAddressCIDR: "172.22.220.227/22",
                gateway: "172.22.220.1",
                nameservers: ["172.22.216.10"],
                routes: [StaticNetworkRoute(to: "default", via: "172.22.220.1")]
            )
        )
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.13.0",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: DeviceAssignment(deviceID: deployer.id, role: .deployer)),
                DeploymentNodeSpec(device: cp, assignment: cpAssignment),
            ]
        )
        let inventory = MockOOBHardwareInventoryClient(
            ports: [
                OOBNetworkPort(label: "iLO4", macAddress: "38:63:bb:32:02:d6", isManagementPort: true),
                OOBNetworkPort(label: "Port1NIC", macAddress: "3c:a8:2a:1c:a0:28", portNumber: 1),
            ]
        )

        let state = try await DeploymentCoordinator(
            settings: AppSettings(),
            oobHardwareInventoryClient: inventory
        ).stage(spec: spec, at: temp)
        let stateDirectory = URL(fileURLWithPath: state.localStateDirectory, isDirectory: true)
        let patch = try String(contentsOf: stateDirectory.appending(path: "node-patches/716182-lab2-controller01.yaml"), encoding: .utf8)

        XCTAssertEqual(inventory.requests, ["716182"])
        XCTAssertTrue(state.events.contains { $0.message.contains("Selected OOB NIC MAC 3c:a8:2a:1c:a0:28") })
        XCTAssertTrue(patch.contains("hardwareAddr: 3c:a8:2a:1c:a0:28"))
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
                            "address": "192.0.2.153",
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
        XCTAssertTrue(devices.first?.oob?.address == "192.0.2.153")
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

    func testHammertimeOOBBooterAddsCLPResetFallbackAfterPowerReset() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "inserted", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "connected", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "cd preferred", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "cd first", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "boot once", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "Image Connected = Yes\nBoot Option = BOOT_ONCE", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "clp reset", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "clp stop", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "clp start", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "Image Connected = Yes\nBoot Option = NO_BOOT", stderr: "", exitCode: 0),
            ]
        )
        let booter = HammertimeOOBBooter(
            settings: HammertimeSettings(binaryPath: "/tmp/ht", timeoutSeconds: 30),
            runner: runner,
            clpResetDelayNanoseconds: 0,
            clpPowerOffDelayNanoseconds: 0,
            clpPowerOnDelayNanoseconds: 0
        )

        let result = try await booter.bootURL(
            OOBBootURLRequest(
                deviceID: "716182",
                imageURL: "http://10.0.0.1:8080/talos.iso",
                reboot: true,
                oobVendor: .ilo
            )
        )

        let commands = runner.invocations.compactMap { invocation -> String? in
            guard let index = invocation.arguments.firstIndex(of: "--command") else { return nil }
            return invocation.arguments[index + 1]
        }
        XCTAssertEqual(
            commands,
            [
                "vm cdrom insert http://10.0.0.1:8080/talos.iso",
                "vm cdrom set connect",
                "set /system1/bootconfig1/bootsource4 bootorder=4",
                "set /system1/bootconfig1/bootsource1 bootorder=1",
                "vm cdrom set boot_once",
                "vm cdrom get",
                "reset /system1",
                "stop /system1",
                "start /system1",
                "vm cdrom get",
            ]
        )
        XCTAssertEqual(result.steps.map(\.name).suffix(4), ["clp-system-reset", "clp-power-off", "clp-power-on", "post-reset-media-status"])
        XCTAssertTrue(result.connected)
        XCTAssertFalse(result.bootOnce)
        XCTAssertTrue(runner.invocations.allSatisfy { $0.timeout == 120 })
    }

    func testHammertimeOOBBooterRecordsUnsupportedCLPResetWithoutFailing() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "inserted", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "connected", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "unsupported command", exitCode: 1),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "unsupported command", exitCode: 1),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "boot once", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "Image Connected = Yes\nBoot Option = BOOT_ONCE", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "unsupported command", exitCode: 1),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "unsupported command", exitCode: 1),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "unsupported command", exitCode: 1),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "power reset", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "Image Connected = Yes\nBoot Option = BOOT_ONCE", stderr: "", exitCode: 0),
            ]
        )
        let booter = HammertimeOOBBooter(
            settings: HammertimeSettings(binaryPath: "/tmp/ht", timeoutSeconds: 30),
            runner: runner,
            clpResetDelayNanoseconds: 0,
            clpPowerOffDelayNanoseconds: 0,
            clpPowerOnDelayNanoseconds: 0
        )

        let result = try await booter.bootURL(
            OOBBootURLRequest(deviceID: "716182", imageURL: "http://10.0.0.1:8080/talos.iso", reboot: true)
        )

        let fallback = try XCTUnwrap(result.steps.first(where: { $0.name == "clp-system-reset" }))
        XCTAssertTrue(fallback.stdout.contains("Best-effort OOB command failed"))
        XCTAssertTrue(result.bootOnce)
    }

    func testHammertimeInventoryUsesLongEnoughTimeoutForLargeAccounts() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(
                    executable: "/tmp/ht",
                    arguments: [],
                    stdout: #"[]"#,
                    stderr: "",
                    exitCode: 0
                ),
            ]
        )
        let adapter = DefaultHammertimeAdapter(
            settings: HammertimeSettings(binaryPath: "/tmp/ht", timeoutSeconds: 30),
            runner: runner
        )

        _ = try await adapter.inventory(accountNumber: "0000000")

        XCTAssertEqual(runner.invocations.first?.timeout, 90)
    }

    func testHammertimeDeployerTransportBuildsCommandCopyAndScriptCalls() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
            ]
        )
        let transport = HammertimeDeployerTransport(
            settings: HammertimeSettings(binaryPath: "/tmp/ht", deployerVia: "ORD", deployerUsePrivate: true, copyMethod: "rsync", commandTimeoutSeconds: 60),
            deviceID: "716181",
            runner: runner
        )
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        _ = try await transport.run("hostname", timeout: 60)
        try await transport.copy(localPath: temp, remotePath: "/var/lib/talos-deploy/test", delete: true)
        _ = try await transport.runScript("echo ok", asRoot: true, timeout: 60)

        XCTAssertTrue(runner.invocations[0].arguments.starts(with: ["--batch", "--no-colors", "--no-checks", "command"]))
        XCTAssertTrue(runner.invocations[0].arguments.contains("--via"))
        XCTAssertTrue(runner.invocations[0].arguments.contains("ORD"))
        XCTAssertTrue(runner.invocations[0].arguments.contains("--private"))
        XCTAssertTrue(runner.invocations[0].arguments.contains("--method"))
        XCTAssertTrue(runner.invocations[0].arguments.contains("rsync"))
        XCTAssertTrue(runner.invocations[0].arguments.contains("716181"))
        XCTAssertTrue(runner.invocations[2].arguments.contains("copy"))
        XCTAssertTrue(runner.invocations[2].arguments.contains("--dest"))
        XCTAssertTrue(runner.invocations[2].arguments.contains("716181:/var/lib/talos-deploy/test/"))
        XCTAssertTrue(runner.invocations[3].arguments.contains("script"))
        XCTAssertTrue(runner.invocations[3].arguments.contains("--method"))
        XCTAssertTrue(runner.invocations[3].arguments.contains("--root"))
    }

    func testHammertimeCopyUsesNoSpaceTemporarySourceForApplicationSupportPaths() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
            ]
        )
        let transport = HammertimeDeployerTransport(
            settings: HammertimeSettings(binaryPath: "/tmp/ht", copyMethod: "rsync"),
            deviceID: "716181",
            runner: runner
        )
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        try await transport.copy(localPath: temp, remotePath: "/var/lib/talos-deploy/test", delete: false)

        let sourceIndex = try XCTUnwrap(runner.invocations[1].arguments.firstIndex(of: "--src"))
        let source = runner.invocations[1].arguments[sourceIndex + 1]
        XCTAssertFalse(source.contains("Application Support"))
        XCTAssertTrue(source.contains("tds-ht-copy-"))
    }

    func testTransportResolverFallsBackFromSSHToHammertime() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(executable: "/usr/bin/ssh", arguments: [], stdout: "", stderr: "timeout", exitCode: 255),
                CommandResult(executable: "/tmp/ht", arguments: [], stdout: "", stderr: "", exitCode: 0),
            ]
        )
        let settings = AppSettings(
            hammertime: HammertimeSettings(binaryPath: "/tmp/ht", commandTimeoutSeconds: 60)
        )
        let resolver = DeployerTransportResolver(settings: settings, runner: runner)
        let selection = try await resolver.resolve(
            request: DeployerAccessRequest(
                method: .auto,
                sshConnection: SSHConnection(host: "192.0.2.10", user: "rack"),
                hammertimeDeviceID: "716181"
            ),
            deployer: talosDevice(id: "716181", name: "716181-lab2-director")
        )

        XCTAssertEqual(selection.validation.method, .hammertime)
        XCTAssertTrue(selection.failedAttempts.first?.contains("directSSH") == true)
        XCTAssertEqual(runner.invocations.first?.executable, "/usr/bin/ssh")
        XCTAssertEqual(runner.invocations.last?.executable, "/tmp/ht")
    }

    func testTransportResolverKeepsDirectSSHSeparateFromProxyJump() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(executable: "/usr/bin/ssh", arguments: [], stdout: "", stderr: "timeout", exitCode: 255),
                CommandResult(executable: "/usr/bin/ssh", arguments: [], stdout: "", stderr: "", exitCode: 0),
            ]
        )
        let settings = AppSettings(
            hammertime: HammertimeSettings(enabled: false),
            deployer: DeployerDefaults(proxyJumpHost: "bastion.example.test")
        )
        let resolver = DeployerTransportResolver(settings: settings, runner: runner)

        let selection = try await resolver.resolve(
            request: DeployerAccessRequest(
                method: .auto,
                sshConnection: SSHConnection(host: "192.0.2.10", user: "rack", proxyJump: "bastion.example.test")
            ),
            deployer: talosDevice(id: "716181", name: "716181-lab2-director")
        )

        XCTAssertEqual(selection.validation.method, .proxyJumpSSH)
        XCTAssertFalse(runner.invocations[0].arguments.contains("-J"))
        XCTAssertTrue(runner.invocations[1].arguments.contains("-J"))
        XCTAssertTrue(runner.invocations[1].arguments.contains("bastion.example.test"))
    }

    func testTalosExecutorBootsNodesBeforeRunningDeployerBootstrap() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deployer = talosDevice(id: "deployer", name: "deployer-1", primaryIP: "198.51.100.20", privateIP: "198.51.100.20")
        let cp = talosDevice(id: "cp1", name: "cp-1", primaryIP: "198.51.100.10", privateIP: "198.51.100.10")
        let spec = DeploymentSpec(
            accountNumber: "0000000",
            clusterName: "cluster",
            clusterEndpoint: "https://cluster.example.com:6443",
            talosVersion: "v1.13.0",
            kubernetesVersion: "v1.34.1",
            deployerStateRoot: "/var/lib/talos-deploy",
            talosProvisioning: TalosProvisioningDefaults(
                deployerRegistryAddressCIDR: "198.51.100.55/32",
                deployerRegistryInterface: "br-ctlplane"
            ),
            nodes: [
                DeploymentNodeSpec(device: deployer, assignment: DeviceAssignment(deviceID: deployer.id, role: .deployer, deployerMode: .existing)),
                DeploymentNodeSpec(device: cp, assignment: talosAssignment()),
            ]
        )
        let state = try await DeploymentCoordinator(settings: AppSettings()).stage(spec: spec, at: temp)
        let runner = MockCommandRunner(
            responses: [
                CommandResult(executable: "/usr/bin/ssh", arguments: [], stdout: "", stderr: "", exitCode: 0),
                CommandResult(executable: "/usr/bin/ssh", arguments: [], stdout: "", stderr: "", exitCode: 0),
                CommandResult(executable: "/usr/bin/ssh", arguments: [], stdout: "", stderr: "", exitCode: 0),
                CommandResult(executable: "/usr/bin/ssh", arguments: [], stdout: "", stderr: "", exitCode: 0),
                CommandResult(executable: "/usr/bin/ssh", arguments: [], stdout: "", stderr: "", exitCode: 0),
            ]
        )
        let transport = DirectSSHDeployerTransport(
            connection: SSHConnection(host: "198.51.100.20", user: "rack"),
            router: SSHCommandRouter(runner: runner)
        )
        let oob = MockOOBBooter()

        let execution = try await TalosDeploymentExecutor(oobBooter: oob).execute(
            state: state,
            transport: transport,
            configuration: DeployerMediaServiceConfiguration()
        )

        XCTAssertEqual(oob.urlRequests.map(\.deviceID), ["cp1"])
        XCTAssertEqual(oob.urlRequests.first?.imageURL, "http://198.51.100.20:8080/talos-v1.13.0-cp1.iso")
        XCTAssertTrue(execution.0.executedActions.contains { $0.contains("OOB URL boot connected") })
        XCTAssertTrue(runner.invocations.first?.arguments.last?.contains("systemctl restart tds-media-http.service") == true)
        XCTAssertTrue(runner.invocations.first?.arguments.last?.contains("socket.create_connection") == true)
        XCTAssertTrue(runner.invocations.contains { $0.arguments.last?.contains("tds-registry-address.service") == true })
        XCTAssertTrue(runner.invocations.contains { $0.arguments.last?.contains("tds-node-routes.service") == true })
        XCTAssertTrue(runner.invocations.contains { $0.arguments.last?.contains("route replace '198.51.100.10/32' dev 'br-ctlplane' src '198.51.100.55'") == true })
        XCTAssertTrue(runner.invocations.contains { $0.arguments.last?.contains("addr replace '198.51.100.55/32' dev 'br-ctlplane'") == true })
        XCTAssertTrue(runner.invocations.contains { $0.arguments.last?.contains("chown -R docker-registry:docker-registry '/var/lib/talos-deploy/registry'") == true })
        XCTAssertTrue(runner.invocations.contains { $0.arguments.last?.contains("chmod -R 0777 '/var/lib/talos-deploy/registry'") == true })
        XCTAssertTrue(runner.invocations.last?.arguments.last?.contains("tds-run-talos-deploy.sh") == true)
    }

    func testTalosDefaultsPreferVirtualMedia() {
        XCTAssertTrue(TalosDefaults().installerPreference == .virtualMedia)
    }

    func testTalosDefaultsUseCurrentStableFactoryVersion() {
        XCTAssertEqual(TalosDefaults().talosVersion, "v1.13.0")
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

    func testTalosFactoryVersionCatalogSortsAndPrefersNewestStable() throws {
        let data = #"["v1.11.7","v1.12.0-beta.1","v1.12.0","v1.12.1"]"#.data(using: .utf8)!

        let catalog = try TalosFactoryClient().parseVersions(data: data)

        XCTAssertEqual(catalog.versions.map(\.value), ["v1.12.1", "v1.12.0", "v1.12.0-beta.1", "v1.11.7"])
        XCTAssertEqual(catalog.newestStable?.value, "v1.12.1")
        XCTAssertEqual(catalog.preferredVersion(preserving: "v1.11.7")?.value, "v1.11.7")
        XCTAssertEqual(catalog.preferredVersion(preserving: "v1.10.0")?.value, "v1.12.1")
        XCTAssertEqual(catalog.versions.first { $0.value == "v1.12.0-beta.1" }?.displayName, "v1.12.0-beta.1 (prerelease)")
    }

    func testTalosFactoryVersionCatalogRejectsEmptyResponse() throws {
        let data = #"[]"#.data(using: .utf8)!

        XCTAssertThrowsError(try TalosFactoryClient().parseVersions(data: data)) { error in
            guard case TalosFactoryError.emptyVersionCatalog = error else {
                return XCTFail("Expected emptyVersionCatalog, got \(error)")
            }
        }
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
        XCTAssertTrue(result.config.managementAddressCIDR == "198.51.100.10/22")
        XCTAssertTrue(result.config.routes.first == StaticNetworkRoute(to: "default", via: "198.51.100.1"))
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

    @MainActor
    func testInventoryFilterMatchesNameIPPlatformOOBAndRoleWithoutChangingAssignments() {
        let controller = AppController(
            settingsController: temporarySettingsController(),
            authProvider: StaticAuthProvider(),
            coreClient: StaticCoreClient(devices: []),
            hammertime: StaticHammertimeAdapter(devices: [])
        )
        let controlPlane = DiscoveredDevice(
            id: "100002",
            accountNumber: "0000000",
            name: "100002-lab-controller01.example.test",
            primaryIP: "198.51.100.20",
            privateIP: "198.51.100.20",
            platformName: "HP DL380 G9 OpenStack",
            oob: OOBEndpoint(vendor: .ilo, address: "192.0.2.20")
        )
        let worker = DiscoveredDevice(
            id: "100003",
            accountNumber: "0000000",
            name: "100003-lab-compute01.example.test",
            primaryIP: "198.51.100.21",
            privateIP: "198.51.100.21",
            platformName: "Dell PowerEdge R730",
            oob: OOBEndpoint(vendor: .idrac, address: "192.0.2.21")
        )
        controller.devices = [controlPlane, worker]
        controller.updateAssignment(DeviceAssignment(deviceID: controlPlane.id, role: .controlplane))
        controller.updateAssignment(DeviceAssignment(deviceID: worker.id, role: .worker))

        controller.inventoryFilterText = "192.0.2.21"
        XCTAssertEqual(controller.filteredClusterEligibleDevices.map(\.id), [worker.id])

        controller.inventoryFilterText = "controlplane"
        XCTAssertEqual(controller.filteredClusterEligibleDevices.map(\.id), [controlPlane.id])

        controller.inventoryFilterText = "dl380"
        XCTAssertEqual(controller.filteredClusterEligibleDevices.map(\.id), [controlPlane.id])

        controller.inventoryFilterText = ""
        XCTAssertEqual(Set(controller.filteredClusterEligibleDevices.map(\.id)), Set([controlPlane.id, worker.id]))
        XCTAssertEqual(controller.binding(for: worker).role, .worker)
    }

    func testDeployerServicePlanIncludesManagedPackagesAndUnits() {
        let plan = DefaultDeployerHostClient().planDeployerServices(configuration: DeployerMediaServiceConfiguration())

        XCTAssertTrue(plan.packages.contains("dnsmasq"))
        XCTAssertTrue(plan.packages.contains("xorriso"))
        XCTAssertTrue(plan.packages.contains("docker-registry"))
        XCTAssertTrue(plan.packages.contains("skopeo"))
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
            privateIP: "198.51.100.196",
            platformName: "HP DL380 G9 OpenStack",
            oob: OOBEndpoint(vendor: .ilo, address: "192.0.2.132", username: "root")
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
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "eno1 UP 198.51.100.196/22\nbr-ipmi UP 192.0.2.182/26\n", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "2: eno1: <BROADCAST>", stderr: "", exitCode: 0),
            CommandResult(executable: "/tmp/ht", arguments: [], stdout: "default via 198.51.100.1 dev eno1\n192.0.2.128/26 dev br-ipmi\n", stderr: "", exitCode: 0),
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
                nameserver 198.51.101.10
                nameserver 203.0.113.164
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
        XCTAssertTrue(snapshot.summary.oobIP == "192.0.2.132")
        XCTAssertTrue(snapshot.summary.dnsServers == ["198.51.101.10", "203.0.113.164"])
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
                dnsServers: ["198.51.101.10", "203.0.113.164", "8.8.8.8"],
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
                    IPADDR=198.51.100.196
                    PREFIX=22
                    GATEWAY=198.51.100.1
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
                    IPADDR=198.51.101.9
                    PREFIX=22
                    ONBOOT=yes
                    ---FILE:/etc/sysconfig/network-scripts/ifcfg-br-ipmi---
                    DEVICE=br-ipmi
                    TYPE=Bridge
                    IPADDR=192.0.2.182
                    PREFIX=26
                    ONBOOT=yes
                    ---FILE:/etc/sysconfig/network-scripts/route-br-ctlplane---
                    192.168.100.0/24 via 198.51.101.36
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
        XCTAssertTrue(brIPMI?.addresses == ["192.0.2.182/26"])
        XCTAssertTrue(brCtlplane?.routes.contains(NetplanRoute(to: "192.168.100.0/24", via: "198.51.101.36")) == true)
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
                    addresses: ["198.51.100.196/22"],
                    routes: [NetplanRoute(to: "default", via: "198.51.100.1")],
                    nameservers: ["198.51.101.10"],
                    searchDomains: ["example.test"]
                ),
            ],
            vlans: [NetplanVLAN(name: "eno3.901", id: 901, link: "eno3")],
            bridges: [NetplanBridge(name: "br-ipmi", interfaces: ["eno3.901"], addresses: ["192.0.2.182/26"])]
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

    func testUserFacingTextDoesNotNameSpecificRuntimeHost() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let files = [
            "README.md",
            "Sources/TalosDeployApp/TalosDeployApp.swift",
            "Sources/TalosDeployCLI/main.swift",
            "Sources/TalosDeployCore/Deployment.swift",
        ]
        let forbidden = try NSRegularExpression(pattern: #"(?i)\brax\b|rax-temp"#)
        for file in files {
            let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = forbidden.matches(in: text, range: range)
            XCTAssertTrue(matches.isEmpty, "Found host-specific runtime text in \(file)")
        }
    }

    func testLocalCommandRunnerDrainsLargeOutputWhileProcessRuns() async throws {
        let runner = LocalCommandRunner()
        let result = try await runner.run(
            "/bin/sh",
            arguments: ["-c", "yes x | head -c 200000"],
            timeout: 5
        )

        XCTAssertEqual(result.stdout.count, 200000)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSSHRouterUsesNonInteractiveTimeouts() async throws {
        let runner = MockCommandRunner(
            responses: [
                CommandResult(executable: "/usr/bin/ssh", arguments: [], stdout: "", stderr: "", exitCode: 0),
            ]
        )
        let router = SSHCommandRouter(runner: runner)

        _ = try await router.run(
            connection: SSHConnection(host: "192.0.2.10", user: "rack"),
            remoteCommand: "true"
        )

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.timeout, 60)
        XCTAssertTrue(invocation.arguments.contains("BatchMode=yes"))
        XCTAssertTrue(invocation.arguments.contains("ConnectTimeout=10"))
    }

}

private func temporarySettingsController() -> SettingsController {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    setenv("TDS_HOME", base.path, 1)
    return SettingsController(paths: AppPaths())
}

private struct StaticAuthProvider: AuthProvider {
    func currentSession() throws -> CoreSession? {
        nil
    }

    func storeSession(_ session: CoreSession, secret: String) throws {}

    func clearSession() throws {}
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
        let response = responses.removeFirst()
        if response.exitCode != 0 {
            throw CommandError.executionFailed(response)
        }
        return response
    }
}

private struct CommandInvocation {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var currentDirectory: URL?
    var timeout: TimeInterval?
}

private final class MockOOBBooter: OOBNodeBooting, @unchecked Sendable {
    private(set) var urlRequests: [OOBBootURLRequest] = []
    private(set) var pxeRequests: [OOBPXEBootRequest] = []

    func bootURL(_ request: OOBBootURLRequest) async throws -> OOBBootURLResult {
        urlRequests.append(request)
        return OOBBootURLResult(
            deviceID: request.deviceID,
            imageURL: request.imageURL,
            connected: true,
            bootOnce: request.bootOnce,
            rebooted: request.reboot,
            steps: [OOBBootURLStep(name: "mock", stdout: "Image Connected = Yes")]
        )
    }

    func bootPXE(_ request: OOBPXEBootRequest) async throws -> OOBPXEBootResult {
        pxeRequests.append(request)
        return OOBPXEBootResult(
            deviceID: request.deviceID,
            oneTimeBoot: request.oneTimeBoot,
            rebooted: request.reboot,
            steps: [OOBBootURLStep(name: "mock", stdout: "pxe")]
        )
    }
}

private final class MockOOBHardwareInventoryClient: OOBHardwareInventoryClient, @unchecked Sendable {
    private let ports: [OOBNetworkPort]
    private(set) var requests: [String] = []

    init(ports: [OOBNetworkPort]) {
        self.ports = ports
    }

    func fetchNetworkPorts(deviceID: String, proxyVia: String?) async throws -> [OOBNetworkPort] {
        requests.append(deviceID)
        return ports
    }
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

private final class RenameTrackingCoreClient: CoreClient, @unchecked Sendable {
    private(set) var renameCalls = 0

    func fetchDevices(accountNumber: String) async throws -> [DiscoveredDevice] {
        []
    }

    func fetchDeviceDetails(accountNumber: String, deviceID: String) async throws -> DiscoveredDevice {
        DiscoveredDevice(id: deviceID, accountNumber: accountNumber, name: deviceID)
    }

    func renameDevice(accountNumber: String, deviceID: String, newName: String) async -> CoreRenameResult {
        renameCalls += 1
        return CoreRenameResult(requestedName: newName, didRename: true, warning: "")
    }
}

private struct FailingDeployerHostClient: DeployerHostClient {
    func validate(connection: SSHConnection) async throws {
        throw CommandError.timedOut("/usr/bin/ssh", [connection.host], 60)
    }

    func validate(transport: any DeployerTransport) async throws -> DeployerAccessValidation {
        throw CommandError.timedOut("deployer-transport", [transport.targetDescription], 60)
    }

    func setHostname(_ hostname: String, connection: SSHConnection) async throws {}

    func setHostname(_ hostname: String, transport: any DeployerTransport) async throws {}

    func planDeployerServices(configuration: DeployerMediaServiceConfiguration) -> DeployerServicePlan {
        DefaultDeployerHostClient().planDeployerServices(configuration: configuration)
    }

    func prepareDeployerServices(configuration: DeployerMediaServiceConfiguration, connection: SSHConnection) async throws -> DeployerServicePlan {
        planDeployerServices(configuration: configuration)
    }

    func prepareDeployerServices(configuration: DeployerMediaServiceConfiguration, transport: any DeployerTransport) async throws -> DeployerServicePlan {
        planDeployerServices(configuration: configuration)
    }

    func prepareMediaServices(configuration: DeployerMediaServiceConfiguration, connection: SSHConnection) async throws -> DeployerMediaServicePlan {
        DeployerMediaServicePlan(
            mediaRoot: configuration.mediaRoot,
            pxeRoot: configuration.pxeRoot,
            httpBindAddress: configuration.httpBindAddress,
            httpPort: configuration.httpPort,
            serviceCommand: "python3 -m http.server"
        )
    }

    func prepareMediaServices(configuration: DeployerMediaServiceConfiguration, transport: any DeployerTransport) async throws -> DeployerMediaServicePlan {
        try await prepareMediaServices(configuration: configuration, connection: SSHConnection(host: "192.0.2.10", user: "rack"))
    }

    func syncState(localDirectory: URL, remoteStateRoot: String, connection: SSHConnection) async throws {}

    func syncState(localDirectory: URL, remoteStateRoot: String, transport: any DeployerTransport) async throws {}
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
