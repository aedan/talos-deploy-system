import AppKit
import Network
import SwiftUI
import TalosDeployCore
import UniformTypeIdentifiers
import WebKit

@main
struct TalosDeployApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                .frame(minWidth: 1180, minHeight: 760)
        }
        Settings {
            SettingsRootView()
                .environmentObject(controller)
                .padding()
                .frame(width: 680)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
}

private struct RootView: View {
    @EnvironmentObject private var controller: AppController
    @State private var selectedSidebar: SidebarItem? = .signin

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedSidebar) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationTitle("tds")
        } detail: {
            switch selectedSidebar ?? .signin {
            case .signin:
                SignInView()
            case .inventory:
                InventoryView()
            case .bootstrap:
                BootstrapDeployerView()
            case .talosFactory:
                TalosFactoryView()
            case .deployment:
                DeploymentView()
            case .deployerOps:
                DeployerOpsView()
            case .recovery:
                RecoveryView()
            case .settings:
                SettingsRootView()
            }
        }
        .task {
            await controller.bootstrapSessionStatusIfNeeded()
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                Text(controller.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum SidebarItem: String, CaseIterable, Identifiable {
    case signin
    case inventory
    case bootstrap
    case talosFactory
    case deployment
    case deployerOps
    case recovery
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .signin: "Sign In"
        case .inventory: "Inventory + Roles"
        case .bootstrap: "Bootstrap Deployer"
        case .talosFactory: "Talos Factory"
        case .deployment: "Deployment Run"
        case .deployerOps: "Deployer Ops"
        case .recovery: "Recovery"
        case .settings: "Settings"
        }
    }
    var systemImage: String {
        switch self {
        case .signin: "person.badge.key"
        case .inventory: "server.rack"
        case .bootstrap: "externaldrive.badge.plus"
        case .talosFactory: "shippingbox"
        case .deployment: "bolt.badge.clock"
        case .deployerOps: "terminal"
        case .recovery: "arrow.clockwise"
        case .settings: "gearshape"
        }
    }
}

private struct BootstrapDeployerView: View {
    @EnvironmentObject private var controller: AppController
    @State private var iloPassword = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard(title: "Preinstall Snapshot") {
                    TextField("Snapshot device ID or name", text: $controller.ubuntuSnapshotDeviceSelector)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Defaults to the selected deployer when blank.")
                    TextField("Output directory", text: $controller.ubuntuSnapshotOutputDirectory)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Defaults to the app state directory when blank.")
                    Button("Capture Snapshot") {
                        Task { await controller.captureUbuntuSnapshot() }
                    }
                    if let snapshot = controller.ubuntuLastSnapshot {
                        Text("Captured \(snapshot.device.name) at \(snapshot.directory)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Hostname: \(snapshot.summary.hostname)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SectionCard(title: "Ubuntu Autoinstall Media") {
                    Text("Builds a NoCloud-seeded Ubuntu 24.04 ISO from the preinstall capture. Greenfield installs use operator local media through the embedded OOB session, so they do not depend on another selected node having an OS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Preinstall capture directory or snapshot.json", text: $controller.ubuntuCapturePath)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Path to the snapshot captured before reinstall; this is what preserves bridges, VLANs, routes, DNS, and MAC mappings.")
                    TextField("Source Ubuntu ISO", text: $controller.ubuntuSourceISOPath)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Path to the stock Ubuntu 24.04 server ISO that tds will rebuild with a NoCloud autoinstall seed.")
                    TextField("Output customized ISO", text: $controller.ubuntuOutputISOPath)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Destination path for the generated bootable ISO that will be attached through iLO local media.")
                    TextField("Work directory (optional)", text: $controller.ubuntuWorkDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Optional scratch directory for ISO extraction/rebuild work; leave blank to let tds choose a temporary location.")
                    TextField("SSH public key files, comma separated (optional)", text: $controller.ubuntuSSHKeyFiles)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Comma-separated public key files to install for rack and root; blank uses the CLI/default key behavior.")
                    SecureField("rack password hash, or TDS_RACK_PASSWORD_HASH", text: $controller.ubuntuRackPasswordHash)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Crypt password hash for the installed rack admin user; raw passwords are not accepted here.")
                    SecureField("root password hash, or TDS_ROOT_PASSWORD_HASH", text: $controller.ubuntuRootPasswordHash)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Crypt password hash for root so hammertime/operator recovery access still works after install.")
                    HStack {
                        Button("Parse Network Plan") {
                            controller.refreshUbuntuNetworkPlan()
                        }
                        Button("Build ISO") {
                            Task { await controller.buildUbuntuISO() }
                        }
                        Button("Validate ISO") {
                            Task { await controller.validateUbuntuISO() }
                        }
                    }
                }

                if let networkPlan = controller.ubuntuNetworkPlan {
                    SectionCard(title: "Preserved Network Plan") {
                        Text("Ethernets: \(networkPlan.ethernets.map { $0.name }.joined(separator: ", "))")
                            .font(.caption)
                        Text("VLANs: \(networkPlan.vlans.map { $0.name }.joined(separator: ", "))")
                            .font(.caption)
                        Text("Bridges: \(networkPlan.bridges.map { "\($0.name) -> \($0.interfaces.joined(separator: ","))" }.joined(separator: "; "))")
                            .font(.caption)
                        ScrollView(.horizontal) {
                            Text(networkPlan.renderNetplanYAML())
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                    }
                }

                if let validation = controller.ubuntuLastValidation {
                    SectionCard(title: "ISO Validation") {
                        Label(validation.isValid ? "Valid NoCloud autoinstall media" : "Validation needs attention", systemImage: validation.isValid ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(validation.isValid ? .green : .orange)
                        ForEach(validation.failures, id: \.self) { failure in
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        ForEach(validation.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SectionCard(title: "HPE iLO 4 Operator Local Media") {
                    Text("This is the default bootstrap path for a brand-new environment. The ISO is selected from the operator workstation inside tds; an existing OS media host is only allowed when explicitly configured in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("iLO URL, for example https://192.0.2.10", text: $controller.ubuntuOOBURL)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("HTTPS address for the target server's iLO; the embedded WebView uses the configured OOB access profile.")
                    TextField("iLO username", text: $controller.ubuntuOOBUsername)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Username used only for this iLO browser session.")
                    SecureField("iLO password (not saved)", text: $iloPassword)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Password for the current iLO local-media attach; it is intentionally not persisted.")
                    HStack {
                        Button("Prepare Local Media Session") {
                            controller.planUbuntuLocalMediaSession()
                        }
                        Text(controller.ubuntuLastArtifacts?.outputISOPath ?? controller.ubuntuOutputISOPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let state = controller.ubuntuLocalMediaState {
                        ForEach(state.steps, id: \.self) { step in
                            Text(step)
                                .font(.caption)
                        }
                    }
                    if let profile = controller.defaultOOBAccessProfile {
                        Text("WebView access profile: \(profile.name) (\(profile.kind.rawValue))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("WebView access profile: direct")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    IloLocalMediaWebView(
                        urlString: $controller.ubuntuOOBURL,
                        username: $controller.ubuntuOOBUsername,
                        password: $iloPassword,
                        isoPath: controller.ubuntuLastArtifacts?.outputISOPath ?? controller.ubuntuOutputISOPath,
                        accessProfile: controller.defaultOOBAccessProfile,
                        accessProfileProxyPassword: controller.proxyPassword(for: controller.defaultOOBAccessProfile),
                        statusMessage: $controller.statusMessage
                    )
                    .frame(minHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                }

                SectionCard(title: "Ubuntu OOB URL Boot") {
                    DirectOOBBootFields(defaultImageURL: controller.settings.bootstrapMedia.externalMediaBaseURL)
                }
            }
            .padding()
        }
        .navigationTitle("Bootstrap Deployer")
    }
}

private struct TalosFactoryView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard(title: "Image Factory") {
                    HStack {
                        Button("Refresh Versions") {
                            Task { await controller.refreshTalosVersions() }
                        }
                        Button("Render Schematic") {
                            controller.renderTalosSchematic()
                        }
                        Button("Upload Schematic") {
                            Task { await controller.uploadTalosSchematic() }
                        }
                        Button("Compute Artifacts") {
                            controller.computeTalosArtifacts()
                        }
                    }
                    Text(controller.talosVersionRefreshStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !controller.talosRenderedSchematic.isEmpty {
                        Text("Schematic")
                            .font(.headline)
                        ScrollView(.horizontal) {
                            Text(controller.talosRenderedSchematic)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 180)
                    }
                    if let upload = controller.talosLastSchematicUpload {
                        Text("Uploaded schematic ID: \(upload.id)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    if let artifacts = controller.talosLastArtifacts {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ISO: \(artifacts.isoURL)")
                            Text("PXE: \(artifacts.pxeURL)")
                            Text("Installer: \(artifacts.installerImage)")
                        }
                        .font(.caption)
                        .textSelection(.enabled)
                    }
                }

                SectionCard(title: "Talos OOB URL Boot") {
                    DirectOOBBootFields(defaultImageURL: controller.talosLastArtifacts?.isoURL ?? "")
                }
            }
            .padding()
        }
        .navigationTitle("Talos Factory")
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct FieldHelpModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private extension View {
    func fieldHelp(_ text: String) -> some View {
        modifier(FieldHelpModifier(text: text))
    }
}

private struct SignInView: View {
    @EnvironmentObject private var controller: AppController
    @State private var username = ""
    @State private var headerName = "Cookie"
    @State private var secret = ""

    var body: some View {
        Form {
            Section("Core Session") {
                HStack {
                    Button("Refresh Session") {
                        Task { await controller.refreshSessionStatus() }
                    }
                    Button("Import From Hammertime Cache") {
                        Task { await controller.importDetectedSession() }
                    }
                }
                Text("The app can read an active hammertime-backed Core session from this workstation and import it into the local store if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Username", text: $username)
                    .fieldHelp("Optional Core username label for a manually stored session; hammertime-backed sessions are detected automatically when available.")
                TextField("Header Name", text: $headerName)
                    .fieldHelp("HTTP header used for the Core session secret, usually Cookie unless Core docs say otherwise.")
                SecureField("Cookie or bearer token", text: $secret)
                    .fieldHelp("Manual Core auth material stored in Keychain; prefer hammertime session import when available.")
                HStack {
                    Button("Store Session") {
                        controller.importSession(username: username, headerName: headerName, secret: secret)
                        secret = ""
                    }
                    Button("Clear Session", role: .destructive) {
                        controller.clearSession()
                    }
                }
                if let session = controller.session {
                    Text("Current session: \(session.username) via \(session.headerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No Core session is currently available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Docs") {
                Text("Run the app from a workstation that can reach Core and has a valid hammertime-backed session for the automatic inventory path.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Sign In")
    }
}

private struct InventoryView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Account Number", text: $controller.accountNumber)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .disabled(controller.isInventoryLoading)
                        .fieldHelp("Core account number to inventory; tds does not ship with a default real account.")
                    Button {
                        Task { await controller.refreshInventory() }
                    } label: {
                        HStack(spacing: 6) {
                            if controller.isInventoryLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(controller.isInventoryLoading ? "Loading..." : "Load Devices")
                        }
                    }
                    .disabled(controller.isInventoryLoading)
                    Button("Refresh Live Facts") {
                        Task { await controller.refreshLiveFacts() }
                    }
                    .disabled(controller.isInventoryLoading)
                }
                TextField("Filter physical servers by name, ID, IP, OOB, platform, or role", text: $controller.inventoryFilterText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.isInventoryLoading)
                    .fieldHelp("Narrows the physical-server table without changing selected roles or install choices; clear it to show every eligible server.")

                if controller.isInventoryLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for inventory to load...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !controller.devices.isEmpty {
                    Text("Showing \(controller.filteredClusterEligibleDevices.count) of \(controller.clusterEligibleDevices.count) physical server candidates; \(controller.filteredDevices.count) non-server devices filtered out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Table(controller.filteredClusterEligibleDevices) {
                    TableColumn("Device") { device in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            if !device.platformName.isEmpty {
                                Text(device.platformName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("Primary IP") { device in
                        Text(device.primaryIP)
                    }
                    TableColumn("OOB") { device in
                        Text(device.oob?.address ?? "-")
                    }
                    TableColumn("Role") { device in
                        Picker("Role", selection: Binding(
                            get: { controller.binding(for: device).role },
                            set: {
                                var assignment = controller.binding(for: device)
                                assignment.role = $0
                                controller.updateAssignment(assignment)
                            }
                        )) {
                            ForEach(DeviceRole.selectableRoles, id: \.self) { role in
                                Text(role.displayName).tag(role)
                            }
                        }
                        .labelsHidden()
                    }
                    TableColumn("Install") { device in
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { controller.binding(for: device).shouldInstallOS },
                                set: {
                                    var assignment = controller.binding(for: device)
                                    assignment.shouldInstallOS = $0
                                    if assignment.role.isDeployer && $0 {
                                        assignment.deployerMode = .bootstrap
                                    }
                                    controller.updateAssignment(assignment)
                                }
                            )
                        )
                        .labelsHidden()
                    }
                }
                .frame(minHeight: 280, maxHeight: 420)
                Text("Install toggles mark devices whose current OS should be replaced; selecting install on the deployer switches it into bootstrap mode and requires the destructive confirmation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                NetworkingEditorView()

                if !controller.filteredDevices.isEmpty {
                    DisclosureGroup("Filtered non-server devices (\(controller.filteredDevices.count))") {
                        List(controller.filteredDevices) { device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                Text(device.clusterIneligibilityReason ?? "Filtered out")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !device.platformName.isEmpty {
                                    Text(device.platformName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(minHeight: 120, maxHeight: 220)
                    }
                }

                if let deployer = controller.clusterEligibleDevices.first(where: {
                    let assignment = controller.binding(for: $0)
                    return assignment.role.isDeployer && assignment.shouldInstallOS
                }) {
                    DeployerWarningView(device: deployer)
                }
            }
            .padding()
        }
        .navigationTitle("Inventory + Role Assignment")
    }
}

private struct DeployerWarningView: View {
    @EnvironmentObject private var controller: AppController
    let device: DiscoveredDevice

    var body: some View {
        let assignment = controller.binding(for: device)
        VStack(alignment: .leading, spacing: 8) {
            Text("Deployer reinstall warning")
                .font(.headline)
            Text("Installing a new OS on the deployer will stage temporary state on the runtime host until the deployer comes back.")
                .foregroundStyle(.secondary)
            TextField(
                "Type \(controller.typedConfirmationText(for: device))",
                text: Binding(
                    get: { assignment.typedConfirmation },
                    set: {
                        var updated = assignment
                        updated.typedConfirmation = $0
                        controller.updateAssignment(updated)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .fieldHelp("Required only when reinstalling the selected deployer, because this destroys the current OS before the cluster can proceed.")
        }
        .padding()
        .background(.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct NetworkingEditorView: View {
    @EnvironmentObject private var controller: AppController

    private var talosNodes: [DiscoveredDevice] {
        controller.clusterEligibleDevices.filter { device in
            let role = controller.binding(for: device).role
            return role == .controlplane || role == .worker
        }
    }

    var body: some View {
        SectionCard(title: "Talos Static Networking (\(talosNodes.count))") {
            if talosNodes.isEmpty {
                Text("Assign controlplane or worker roles to edit final static networking. DHCP may be used only for live boot; machine configs must use Core/captured/manual static IPs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Review and complete final static networking for each Talos node. This section stays inline so role selection cannot navigate away from the inventory screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(talosNodes) { device in
                        DeviceNetworkEditor(device: device)
                            .environmentObject(controller)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

private struct DeviceNetworkEditor: View {
    @EnvironmentObject private var controller: AppController
    let device: DiscoveredDevice

    var body: some View {
        let assignment = controller.binding(for: device)
        let validation = StaticNetworkPlanner().validate(node: DeploymentNodeSpec(device: device, assignment: assignment))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(device.name)
                        .font(.headline)
                    Text("Core private: \(emptyDash(device.privateIP))  primary: \(emptyDash(device.primaryIP))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Detected interfaces: \(device.networkInterfaces.map { "\($0.name) \($0.addresses.joined(separator: ","))" }.joined(separator: "; "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(validation.isValid ? "Valid" : "Incomplete", systemImage: validation.isValid ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(validation.isValid ? .green : .orange)
            }
            Picker("Network Source", selection: Binding(
                get: { controller.binding(for: device).networkSource },
                set: {
                    var updated = controller.binding(for: device)
                    updated.networkSource = $0
                    controller.updateAssignment(updated)
                }
            )) {
                ForEach(NetworkConfigurationSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            Picker("Install Preference", selection: Binding(
                get: { controller.binding(for: device).preferredInstall },
                set: {
                    var updated = controller.binding(for: device)
                    updated.preferredInstall = $0
                    if $0 == .stagedOnly {
                        updated.shouldInstallOS = false
                    }
                    controller.updateAssignment(updated)
                }
            )) {
                ForEach(InstallPreference.allCases, id: \.self) { preference in
                    Text(preference.rawValue).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .fieldHelp("Use stagedOnly for cloud-image or prebooted Talos nodes that should be configured in place.")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Interface")
                    TextField("eno1", text: networkStringBinding(\.managementInterface))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Final Talos management NIC name; use the captured/Core NIC or enter the expected post-boot interface.")
                    Text("NIC MAC")
                    TextField("3c:a8:2a:00:00:01", text: networkStringBinding(\.managementHardwareAddress))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Optional management NIC hardware address. When present, Talos selects the NIC by MAC instead of relying on interface names.")
                }
                GridRow {
                    Text("Static CIDR")
                    TextField("198.51.100.20/24", text: networkStringBinding(\.managementAddressCIDR))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Static management IP with prefix length for the Talos machine config; DHCP is only for live boot.")
                    Text("Gateway")
                    TextField("198.51.100.1", text: networkStringBinding(\.gateway))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Default gateway for the final static Talos network.")
                }
                GridRow {
                    Text("DNS")
                    TextField("198.51.100.53,8.8.8.8", text: networkListBinding(\.nameservers))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Comma-separated DNS servers rendered into the machine config.")
                    Text("Search Domains")
                    TextField("lab.example,example.test", text: networkListBinding(\.searchDomains))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Comma-separated DNS search domains for the node.")
                }
                GridRow {
                    Text("Manual Plan")
                    TextField("/path/to/network-plan.yaml", text: Binding(
                        get: { controller.binding(for: device).manualNetworkPlanPath },
                        set: {
                            var updated = controller.binding(for: device)
                            updated.manualNetworkPlanPath = $0
                            controller.updateAssignment(updated)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .fieldHelp("Optional path to a reviewed network plan when Core/captured data is incomplete or needs overrides.")
                }
            }
            StaticNetworkAdvancedEditor(device: device)
                .environmentObject(controller)
            ForEach(validation.errors, id: \.self) { error in
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(validation.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private func networkStringBinding(_ keyPath: WritableKeyPath<StaticNetworkConfig, String>) -> Binding<String> {
        Binding(
            get: { controller.binding(for: device).staticNetwork[keyPath: keyPath] },
            set: {
                var updated = controller.binding(for: device)
                updated.staticNetwork[keyPath: keyPath] = $0
                controller.updateAssignment(updated)
            }
        )
    }

    private func networkListBinding(_ keyPath: WritableKeyPath<StaticNetworkConfig, [String]>) -> Binding<String> {
        Binding(
            get: { controller.binding(for: device).staticNetwork[keyPath: keyPath].joined(separator: ",") },
            set: {
                var updated = controller.binding(for: device)
                updated.staticNetwork[keyPath: keyPath] = $0
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                controller.updateAssignment(updated)
            }
        )
    }
}

private struct StaticNetworkAdvancedEditor: View {
    @EnvironmentObject private var controller: AppController
    let device: DiscoveredDevice
    @State private var routesJSON = ""
    @State private var vlansJSON = ""
    @State private var bridgesJSON = ""

    var body: some View {
        DisclosureGroup("Advanced Routes, VLANs, And Bridges") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Routes JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $routesJSON)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("VLAN Interfaces JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vlansJSON)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("Bridge Interfaces JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $bridgesJSON)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Button("Reload JSON") {
                        reload()
                    }
                    Button("Apply JSON") {
                        apply()
                    }
                }
            }
            .padding(.top, 6)
        }
        .onAppear {
            reload()
        }
    }

    private func reload() {
        let config = controller.binding(for: device).staticNetwork
        routesJSON = prettyJSONString(config.routes)
        vlansJSON = prettyJSONString(config.vlans)
        bridgesJSON = prettyJSONString(config.bridges)
    }

    private func apply() {
        do {
            var updated = controller.binding(for: device)
            updated.staticNetwork.routes = try decodeJSONString([StaticNetworkRoute].self, from: routesJSON)
            updated.staticNetwork.vlans = try decodeJSONString([NetworkInterface].self, from: vlansJSON)
            updated.staticNetwork.bridges = try decodeJSONString([NetworkInterface].self, from: bridgesJSON)
            controller.updateAssignment(updated)
            controller.statusMessage = "Applied advanced network JSON for \(device.name)."
        } catch {
            controller.statusMessage = error.localizedDescription
        }
    }
}

private struct DeploymentView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionCard(title: "Selected Inventory Deployment") {
                    HStack {
                        Button("Stage Deployment") {
                            Task { await controller.stageDeployment() }
                        }
                        .fieldHelp("Builds the local deployment state, Talos artifacts, network validation, and deployer maintenance bundle without touching servers.")

                        Button("Dry Run") {
                            Task { await controller.runDeployment(dryRun: true) }
                        }
                        .fieldHelp("Plans deployer access, provisioning, and bootstrap actions without running OOB, SSH, Hammertime, or talosctl commands.")

                        Button("Execute Deployment") {
                            Task { await controller.runDeployment(dryRun: false) }
                        }
                        .buttonStyle(.borderedProminent)
                        .fieldHelp("Runs the full owned workflow: validate deployer access, prepare services, sync state, boot Talos nodes, apply configs, bootstrap, and verify health.")
                    }
                }

                SectionCard(title: "Deployment Spec File") {
                    TextField("deployment-spec.json", text: $controller.deploymentSpecPath)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Plan Spec") {
                            Task { await controller.planDeploymentSpecFromPath() }
                        }
                        Button("Dry Run Spec") {
                            Task { await controller.runDeploymentSpecFromPath(dryRun: true) }
                        }
                        Button("Execute Spec") {
                            Task { await controller.runDeploymentSpecFromPath(dryRun: false) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let plan = controller.lastPlan {
                    SectionCard(title: "Phases") {
                        ForEach(plan.phases) { phase in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(phase.title)
                                    .font(.headline)
                                ForEach(phase.steps, id: \.self) { step in
                                    Text(step)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    Text("No deployment has been staged yet.")
                        .foregroundStyle(.secondary)
                }

                if let run = controller.lastRun {
                    RunResultView(run: run)
                }
            }
            .padding()
        }
        .navigationTitle("Deployment Run")
    }
}

private struct DeployerOpsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard(title: "Deployer Services") {
                    TextField("Device override, optional", text: $controller.deployerOpsDeviceID)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Blank uses the selected deployer; enter a device ID to match the CLI deployer commands directly.")
                    HStack {
                        Button("Plan Services") {
                            controller.planDeployerServices()
                        }
                        Button("Access Test") {
                            Task { await controller.testDeployerAccess() }
                        }
                        Button("Prepare Services") {
                            Task { await controller.prepareDeployerServices() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let validation = controller.lastDeployerAccessValidation {
                        Text("Access: \(validation.method.displayName) via \(validation.target)")
                            .font(.caption)
                        Text(validation.message)
                            .font(.caption)
                            .foregroundStyle(validation.succeeded ? Color.secondary : Color.red)
                    }
                    if let plan = controller.lastDeployerServicePlan {
                        Text("Packages: \(plan.packages.joined(separator: ", "))")
                            .font(.caption)
                        Text("Units: \(plan.systemdUnits.joined(separator: ", "))")
                            .font(.caption)
                        DisclosureGroup("Online Install Commands") {
                            ForEach(plan.onlineInstallCommands, id: \.self) { command in
                                Text(command)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        DisclosureGroup("Cache Fallback Commands") {
                            ForEach(plan.cacheFallbackCommands, id: \.self) { command in
                                Text(command)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Deployer Ops")
    }
}

private struct RecoveryView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard(title: "Deployment State") {
                    TextField("deployment-state.json or containing directory", text: $controller.recoveryStatePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Load State") {
                        controller.loadDeploymentStateFromPath()
                    }
                    if let state = controller.lastState {
                        Text("Loaded: \(state.spec.clusterName)")
                            .font(.caption)
                        Text("State directory: \(state.localStateDirectory)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("No deployment state is loaded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SectionCard(title: "Resume") {
                    HStack {
                        Button("Resume Dry Run") {
                            Task { await controller.resumeDeployment(dryRun: true) }
                        }
                        Button("Resume Execute") {
                            Task { await controller.resumeDeployment(dryRun: false) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                SectionCard(title: "Reprovision Talos Nodes") {
                    TextField("Target device IDs or names, comma separated; blank means all Talos nodes", text: $controller.recoveryTargetDeviceIDs)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Wipe before normal media boot", isOn: $controller.recoveryWipeFirst)
                    HStack {
                        Button("Reprovision Dry Run") {
                            Task { await controller.reprovisionDeployment(dryRun: true) }
                        }
                        Button("Reprovision Execute") {
                            Task { await controller.reprovisionDeployment(dryRun: false) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                SectionCard(title: "Installed-Disk Boot") {
                    Toggle("Reboot after restoring disk boot", isOn: $controller.recoveryRebootAfterDiskBoot)
                    HStack {
                        Button("Disk Boot Dry Run") {
                            Task { await controller.prepareInstalledDiskBoot(dryRun: true) }
                        }
                        Button("Disk Boot Execute") {
                            Task { await controller.prepareInstalledDiskBoot(dryRun: false) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let execution = controller.lastDiskBootExecution {
                        ProvisioningExecutionView(execution: execution)
                    }
                }

                SectionCard(title: "Verify And Maintenance") {
                    HStack {
                        Button("Verify") {
                            controller.verifyDeploymentState()
                        }
                        Button("Write Maintenance Bundle") {
                            controller.writeMaintenanceBundle()
                        }
                    }
                    if let health = controller.lastClusterHealth {
                        Text("Talos ready: \(health.talosNodesReady ? "yes" : "planned")  Kubernetes ready: \(health.kubernetesReady ? "yes" : "planned")")
                            .font(.caption)
                        ForEach(health.checkedCommands, id: \.self) { command in
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        ForEach(health.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let manifest = controller.lastMaintenanceBundle {
                        Text("Bundle: \(manifest.clusterName) at \(manifest.stateRoot)")
                            .font(.caption)
                        Text("Scripts: \(manifest.scripts.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SectionCard(title: "Direct OOB URL Boot") {
                    DirectOOBBootFields(defaultImageURL: "")
                }

                if let run = controller.lastRun {
                    RunResultView(run: run)
                }
            }
            .padding()
        }
        .navigationTitle("Recovery")
    }
}

private struct DirectOOBBootFields: View {
    @EnvironmentObject private var controller: AppController
    let defaultImageURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Device ID", text: $controller.directOOBDeviceID)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("OOB-reachable image URL", text: $controller.directOOBImageURL)
                    .textFieldStyle(.roundedBorder)
                if !defaultImageURL.isEmpty {
                    Button("Use Current") {
                        controller.directOOBImageURL = defaultImageURL
                    }
                }
            }
            TextField("One-time boot target, optional", text: $controller.directOOBOneTimeBoot)
                .textFieldStyle(.roundedBorder)
            Toggle("Reboot after media request", isOn: $controller.directOOBReboot)
            Button("Boot OOB URL") {
                Task { await controller.bootDirectOOBURL() }
            }
            .buttonStyle(.borderedProminent)
            if let result = controller.lastOOBBootResult {
                Text("Device \(result.deviceID): connected \(result.connected ? "yes" : "no"), boot once \(result.bootOnce ? "yes" : "no"), rebooted \(result.rebooted ? "yes" : "no")")
                    .font(.caption)
                ForEach(result.steps, id: \.name) { step in
                    DisclosureGroup(step.name) {
                        Text(step.stdout)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct RunResultView: View {
    let run: TalosExecutionRun

    var body: some View {
        SectionCard(title: "Last Run") {
            VStack(alignment: .leading, spacing: 8) {
                if let access = run.accessValidation {
                    Text("Access path: \(access.method.displayName) via \(access.target)")
                    Text(access.message)
                        .foregroundStyle(access.succeeded ? Color.secondary : Color.red)
                }
                if let provisioning = run.provisioningExecution {
                    ProvisioningExecutionView(execution: provisioning)
                }
                if let bootstrap = run.bootstrapResult {
                    Text("Bootstrap node: \(bootstrap.bootstrapNode)")
                    Text(bootstrap.succeeded ? "Bootstrap/health completed." : "Bootstrap/health not executed.")
                        .foregroundStyle(bootstrap.succeeded ? Color.green : Color.secondary)
                    ForEach(bootstrap.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if !run.state.events.isEmpty {
                    Text("Run Log")
                        .font(.headline)
                    ForEach(Array(run.state.events.suffix(8).enumerated()), id: \.offset) { _, event in
                        Text(event.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProvisioningExecutionView: View {
    let execution: TalosProvisioningExecution

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !execution.plannedActions.isEmpty {
                Text("Planned")
                    .font(.headline)
                ForEach(execution.plannedActions, id: \.self) { action in
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !execution.executedActions.isEmpty {
                Text("Executed")
                    .font(.headline)
                ForEach(execution.executedActions, id: \.self) { action in
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(execution.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct SettingsRootView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "Access Profiles") {
                ForEach(Array(controller.settings.accessProfiles.enumerated()), id: \.element.id) { index, profile in
                    VStack(alignment: .leading) {
                        TextField("Name", text: Binding(
                            get: { controller.settings.accessProfiles[index].name },
                            set: { controller.settings.accessProfiles[index].name = $0 }
                        ))
                        .fieldHelp("Operator-facing name for this access path, such as OOB corporate proxy or direct lab network.")
                        Picker("Type", selection: Binding(
                            get: { controller.settings.accessProfiles[index].kind },
                            set: { controller.settings.accessProfiles[index].kind = $0 }
                        )) {
                            ForEach(AccessProfileKind.allCases, id: \.self) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        Picker("Scope", selection: Binding(
                            get: { controller.settings.accessProfiles[index].scope },
                            set: { controller.settings.accessProfiles[index].scope = $0 }
                        )) {
                            ForEach(AccessScope.allCases, id: \.self) { scope in
                                Text(scope.rawValue).tag(scope)
                            }
                        }
                        Toggle("Default for this scope", isOn: Binding(
                            get: { controller.settings.accessProfiles[index].isDefault },
                            set: { controller.setAccessProfileDefault(id: profile.id, isDefault: $0) }
                        ))
                        .fieldHelp("Marks this profile as the default route for its scope; only one profile is default at a time.")
                        TextField("Proxy URL", text: Binding(
                            get: { controller.settings.accessProfiles[index].proxyURL },
                            set: { controller.settings.accessProfiles[index].proxyURL = $0 }
                        ))
                        .fieldHelp("HTTP/SOCKS proxy endpoint used by OOB browser sessions, for example https://proxy.example:3128 or socks5://127.0.0.1:1080.")
                        TextField("Proxy Username (optional)", text: Binding(
                            get: { controller.settings.accessProfiles[index].proxyUsername },
                            set: { controller.settings.accessProfiles[index].proxyUsername = $0 }
                        ))
                        .fieldHelp("Optional proxy username; password is stored separately in Keychain.")
                        SecureField("Proxy Password (Keychain)", text: Binding(
                            get: { controller.accessProfileProxyPasswords[profile.id] ?? "" },
                            set: { controller.accessProfileProxyPasswords[profile.id] = $0 }
                        ))
                        .fieldHelp("Optional proxy password stored in Keychain for this access profile.")
                        TextField("Hammertime via", text: Binding(
                            get: { controller.settings.accessProfiles[index].hammertimeVia },
                            set: { controller.settings.accessProfiles[index].hammertimeVia = $0 }
                        ))
                        .fieldHelp("Optional hammertime/bastion routing hint for diagnostic actions; deployment does not depend on ht proxy.")
                        if profile.kind == .httpProxy {
                            Text("For OOB browser access, configure the corporate proxy URL here and optionally store credentials in Keychain. Environment variables TDS_OOB_PROXY_USER and TDS_OOB_PROXY_PASSWORD still work for headless testing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Add OOB HTTP Proxy") {
                        controller.addAccessProfile(kind: .httpProxy, scope: .oob)
                    }
                    Button("Add OOB SOCKS Proxy") {
                        controller.addAccessProfile(kind: .socksProxy, scope: .oob)
                    }
                }
            }
            SectionCard(title: "Core Session") {
                TextField("Default Account", text: $controller.settings.core.defaultAccountNumber)
                    .fieldHelp("Optional operator convenience default; leave blank unless you repeatedly work one account.")
                Picker("Inventory Source", selection: $controller.settings.core.inventorySource) {
                    ForEach(InventorySource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                TextField("Docs URL", text: $controller.settings.core.docsURL)
                    .fieldHelp("Core documentation endpoint for operators on a workstation that can reach Core.")
                TextField("Service URL", text: $controller.settings.core.serviceURL)
                    .fieldHelp("Base WS Core API endpoint used for account inventory and device details.")
            }
            SectionCard(title: "Hammertime") {
                Toggle("Enabled", isOn: $controller.settings.hammertime.enabled)
                    .fieldHelp("Allows tds to use hammertime for inventory fallback, live facts, and OOB helper actions when available.")
                Toggle("Skip device checks (--no-checks)", isOn: $controller.settings.hammertime.skipDeviceChecks)
                    .fieldHelp("Passes --no-checks so old OS records do not block pre-provision access attempts.")
                TextField("Binary Path", text: $controller.settings.hammertime.binaryPath)
                    .fieldHelp("Path to the ht executable on this workstation.")
                TextField("Python Path (optional)", text: $controller.settings.hammertime.pythonPath)
                    .fieldHelp("Optional Python interpreter for the bundled Core bridge; leave blank for system Python.")
                TextField("Session Cache Path", text: $controller.settings.hammertime.sessionCachePath)
                    .fieldHelp("Optional hammertime cache path to inspect for active Core auth; blank uses the default discovery paths.")
                TextField("Deployer Via (optional)", text: $controller.settings.hammertime.deployerVia)
                    .fieldHelp("Optional Hammertime region or gateway hint used when tds reaches the Ubuntu deployer through ht command/copy/script.")
                Toggle("Use private deployer path", isOn: $controller.settings.hammertime.deployerUsePrivate)
                    .fieldHelp("Adds --private to Hammertime deployer automation when the private network path is the reachable one.")
                TextField("Passport Reason (optional)", text: $controller.settings.hammertime.passportReason)
                    .fieldHelp("Optional Passport/access request reason passed to Hammertime for deployer automation when required.")
                TextField("Copy Method", text: $controller.settings.hammertime.copyMethod)
                    .fieldHelp("Hammertime copy method for deployer state sync, normally rsync or scp.")
                TextField("Deployer SSH Args", text: $controller.settings.hammertime.deployerSSHArgs)
                    .fieldHelp("Extra SSH options passed through Hammertime for deployer automation. Defaults bound connection attempts so failed paths do not hang indefinitely.")
                Stepper("Command Timeout Seconds: \(controller.settings.hammertime.commandTimeoutSeconds)", value: $controller.settings.hammertime.commandTimeoutSeconds, in: 30...3600)
                    .fieldHelp("Maximum time tds waits for Hammertime deployer command/script operations before failing the deployment step.")
                Stepper("Auth Preflight Timeout Seconds: \(controller.settings.hammertime.authPreflightTimeoutSeconds)", value: $controller.settings.hammertime.authPreflightTimeoutSeconds, in: 10...300)
                    .fieldHelp("Maximum time tds waits for Hammertime SSO/session validation before reporting that interactive authentication must be refreshed.")
                TextField("Default Fact Groups", text: Binding(
                    get: { controller.settings.hammertime.defaultFactGroups.joined(separator: ",") },
                    set: { controller.settings.hammertime.defaultFactGroups = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                ))
                .fieldHelp("Comma-separated fact groups passed to ht raxfacts during optional live enrichment.")
                Stepper("Timeout Seconds: \(controller.settings.hammertime.timeoutSeconds)", value: $controller.settings.hammertime.timeoutSeconds, in: 5...300)
                    .fieldHelp("Maximum time tds waits for each hammertime command before treating enrichment as non-blocking failed data.")
            }
            SectionCard(title: "Talos Defaults") {
                HStack {
                    if !controller.availableTalosVersions.isEmpty && !controller.useManualTalosVersion {
                        Picker("Talos Version", selection: Binding(
                            get: { controller.settings.talos.talosVersion },
                            set: { controller.selectTalosVersion($0) }
                        )) {
                            ForEach(controller.availableTalosVersions) { version in
                                Text(version.displayName).tag(version.value)
                            }
                        }
                    } else {
                        TextField("Talos Version", text: Binding(
                            get: { controller.settings.talos.talosVersion },
                            set: { controller.selectTalosVersion($0) }
                        ))
                    }
                    Button("Refresh Versions") {
                        Task { await controller.refreshTalosVersions() }
                    }
                    Toggle("Manual", isOn: $controller.useManualTalosVersion)
                        .toggleStyle(.switch)
                }
                .fieldHelp("Talos release used for generated Image Factory artifacts and talosctl pinning. Refresh loads deployable versions from Talos Image Factory; Manual allows an explicit override.")
                Text(controller.talosVersionRefreshStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Kubernetes Version", text: $controller.settings.talos.kubernetesVersion)
                    .fieldHelp("Kubernetes version passed into generated Talos cluster config.")
                TextField("Cluster Name", text: $controller.settings.talos.clusterName)
                    .fieldHelp("Logical cluster name used for state paths and generated Talos config.")
                TextField("Cluster Endpoint", text: $controller.settings.talos.clusterEndpoint)
                    .fieldHelp("Final Kubernetes API endpoint URL rendered into Talos machine configs.")
                TextField("System Extensions", text: Binding(
                    get: { controller.settings.talos.factory.selectedSystemExtensions.joined(separator: ",") },
                    set: {
                        let values = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        controller.settings.talos.factory.selectedSystemExtensions = values
                        controller.settings.talos.extensions = values
                    }
                ))
                .fieldHelp("Comma-separated Talos system extensions for Image Factory; defaults include Rackspace bare-metal storage/network utilities.")
                TextField("Kernel Modules", text: Binding(
                    get: { controller.settings.talos.kernelModules.map { module in
                        module.parameters.isEmpty ? module.name : "\(module.name)(\(module.parameters.joined(separator: " ")))"
                    }.joined(separator: ",") },
                    set: { controller.settings.talos.kernelModules = parseKernelModules($0) }
                ))
                .fieldHelp("Comma-separated kernel modules rendered into machine configs, optionally name(param=value param2=value).")
                TextField("Extra Kernel Args", text: Binding(
                    get: { controller.settings.talos.factory.extraKernelArgs.joined(separator: ",") },
                    set: { controller.settings.talos.factory.extraKernelArgs = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ))
                .fieldHelp("Comma-separated kernel args included in the Image Factory schematic.")
                Picker("Installer Preference", selection: $controller.settings.talos.installerPreference) {
                    ForEach(InstallPreference.allCases, id: \.self) { preference in
                        Text(preference.rawValue).tag(preference)
                    }
                }
                Toggle("Render Longhorn extraMounts", isOn: $controller.settings.talos.enableLonghornExtraMounts)
                    .fieldHelp("Adds the /var/lib/longhorn bind mount required by Longhorn on every Talos node.")
            }
            SectionCard(title: "Talos Image Factory") {
                TextField("Factory URL", text: $controller.settings.talos.factory.baseURL)
                    .fieldHelp("Base Image Factory URL for metal ISO and installer artifacts.")
                TextField("PXE Factory URL", text: $controller.settings.talos.factory.pxeBaseURL)
                    .fieldHelp("Base Image Factory URL for PXE kernel/initramfs endpoints.")
                TextField("Registry Host", text: $controller.settings.talos.factory.registryHost)
                    .fieldHelp("Registry host for generated installer image references.")
                TextField("Architecture", text: $controller.settings.talos.factory.architecture)
                    .fieldHelp("Target Talos artifact architecture, normally amd64 for HPE/Dell bare metal.")
                TextField("Platform", text: $controller.settings.talos.factory.platform)
                    .fieldHelp("Talos platform identifier, normally metal for physical servers.")
                TextField("Schematic ID", text: $controller.settings.talos.factory.schematicID)
                    .fieldHelp("Optional prebuilt Image Factory schematic ID; blank/default uses selected extensions to render the schematic.")
                Text("Image Factory creates ISO/PXE/installer artifacts from schematics and system extensions. Kernel modules are rendered into machine configs separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SectionCard(title: "Talos Provisioning") {
                Toggle("Allow deployer-hosted media", isOn: $controller.settings.talos.provisioning.allowDeployerHostedMedia)
                    .fieldHelp("Lets tds serve Talos ISO media from the Ubuntu deployer when OOB controllers can reach it.")
                Toggle("Allow deployer PXE", isOn: $controller.settings.talos.provisioning.allowDeployerPXE)
                    .fieldHelp("Lets tds configure deployer-managed dnsmasq/PXE for nodes that should boot over the data network.")
                Toggle("Capture OOB NIC MACs", isOn: $controller.settings.talos.provisioning.useOOBHardwareAddressSelectors)
                    .fieldHelp("When Hammertime/iLO can read physical NIC MACs, tds stores them with the selected node networking for validation and troubleshooting.")
                Toggle("Wipe Talos system disk before install", isOn: $controller.settings.talos.provisioning.wipeSystemDiskBeforeInstall)
                    .fieldHelp("Boots a tds-generated Talos reset ISO before normal install media so repeat deployments clear any previous or partial Talos install.")
                Toggle("Enable legacy BIOS disk boot support", isOn: $controller.settings.talos.provisioning.legacyBIOSSupport)
                    .fieldHelp("Marks the Talos install disk bootable for legacy BIOS systems. Keep enabled for older HPE/Dell bare metal that reports Legacy boot mode; disable only for environments known to be UEFI-only.")
                Toggle("Use deployer installer registry", isOn: $controller.settings.talos.provisioning.allowDeployerRegistry)
                    .fieldHelp("Caches the Talos installer and selected cluster images in a registry on the Ubuntu deployer so Talos nodes do not need Internet access during install/bootstrap.")
                TextField("Deployer registry host override", text: $controller.settings.talos.provisioning.deployerRegistryHost)
                    .fieldHelp("Optional host/IP Talos nodes should use for the deployer registry. If blank, tds uses the node-facing registry CIDR host, then the deployer private IP from Core.")
                TextField("Deployer registry address CIDR", text: $controller.settings.talos.provisioning.deployerRegistryAddressCIDR)
                    .fieldHelp("Optional node-facing IP/CIDR that tds should add to the deployer for Talos installer pulls. This must live on the network where Talos node management NICs can ARP/reach it, which may differ from the deployer private IP interface.")
                TextField("Deployer registry interface", text: $controller.settings.talos.provisioning.deployerRegistryInterface)
                    .fieldHelp("Ubuntu deployer interface where the registry address CIDR should be assigned. Use the bridge, VLAN, or NIC that is actually reachable from Talos node management ports.")
                TextField("Deployer node route interface", text: $controller.settings.talos.provisioning.deployerNodeRouteInterface)
                    .fieldHelp("Optional interface tds should force for reaching Talos node management IPs when the deployer OS would otherwise choose the wrong route.")
                TextField("Deployer node route source CIDR", text: $controller.settings.talos.provisioning.deployerNodeRouteSourceCIDR)
                    .fieldHelp("Optional source IP/CIDR for forced Talos node management routes. In isolated or bridged environments this is often the same /32 alias used for the deployer registry.")
                TextField("Deployer registry mirror hosts", text: Binding(
                    get: { controller.settings.talos.provisioning.deployerRegistryMirrorHosts.joined(separator: ",") },
                    set: {
                        controller.settings.talos.provisioning.deployerRegistryMirrorHosts = $0
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
                .fieldHelp("Comma-separated public registry hosts that Talos nodes should mirror through the deployer registry. Defaults cover ghcr.io and registry.k8s.io for Talos/Kubernetes images.")
                Toggle("Allow external OOB URL", isOn: $controller.settings.talos.provisioning.allowExternalOOBURL)
                    .fieldHelp("Allows OOB controllers to boot media from an operator-configured external URL when that network path exists.")
                TextField("External OOB media base URL", text: $controller.settings.talos.provisioning.externalOOBMediaBaseURL)
                    .fieldHelp("Base URL reachable from OOB controllers when using direct/external boot media instead of deployer hosting.")
                TextField("Strategy order", text: Binding(
                    get: { controller.settings.talos.provisioning.preferredStrategies.map(\.rawValue).joined(separator: ",") },
                    set: {
                        controller.settings.talos.provisioning.preferredStrategies = $0
                            .split(separator: ",")
                            .compactMap { TalosProvisioningStrategy(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
                    }
                ))
                .fieldHelp("Comma-separated provisioning priorities; default is deployer-hosted media, deployer PXE, external OOB URL, operator local media.")
                Text("After the Ubuntu deployer node is established, tds can use it for PXE/DHCP/HTTP media, or use direct/external OOB media when that is safer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SectionCard(title: "Bootstrap Media") {
                Picker("First deployer media delivery", selection: $controller.settings.bootstrapMedia.deliveryMode) {
                    ForEach(BootstrapMediaDeliveryMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Toggle("Require operator local media for greenfield", isOn: $controller.settings.bootstrapMedia.requireOperatorLocalMediaForGreenfield)
                    .fieldHelp("Keeps the first deployer bootstrap greenfield-safe when no existing node OS is available.")
                Toggle("Allow existing OS media host", isOn: $controller.settings.bootstrapMedia.allowExistingOSMediaHost)
                    .fieldHelp("Explicitly permits using an already-running host as a temporary media source; leave disabled for true greenfield runs.")
                TextField("OOB-reachable external media base URL", text: $controller.settings.bootstrapMedia.externalMediaBaseURL)
                    .fieldHelp("External media URL for the first Ubuntu deployer only when the iLO/iDRAC network can fetch it.")
                TextField("Existing media host device ID (explicit only)", text: $controller.settings.bootstrapMedia.mediaHostDeviceID)
                    .fieldHelp("Device ID of an already-running host used to serve bootstrap media; leave blank for greenfield-safe local media.")
                Text("Default is operator local media through the embedded OOB browser. Existing media hosts are intentionally opt-in because they do not work for all-bare-metal greenfield environments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SectionCard(title: "Deployer Defaults") {
                Picker("Access Method", selection: $controller.settings.deployer.accessMethod) {
                    ForEach(DeployerAccessMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                TextField("Deployer SSH User", text: $controller.settings.deployer.sshUser)
                    .fieldHelp("SSH user tds uses after Ubuntu is installed or when preparing an existing deployer.")
                TextField("SSH ProxyJump Host", text: $controller.settings.deployer.proxyJumpHost)
                    .fieldHelp("Optional SSH -J jump host used before falling back to Hammertime in automatic deployer access mode.")
                TextField("State Root", text: $controller.settings.deployer.stateRoot)
                    .fieldHelp("Durable deployer directory for cluster state, cached media, generated configs, and run logs.")
                TextField("Hostname Suffix", text: $controller.settings.deployer.hostnameSuffix)
                    .fieldHelp("Optional suffix appended to <deviceNumber>-deployer, for example lab2.")
                TextField("PXE Address", text: $controller.settings.deployer.pxeAddress)
                    .fieldHelp("Address/interface on the deployer that dnsmasq/PXE should serve when PXE is selected.")
                TextField("HTTP Bind Address", text: $controller.settings.deployer.httpBindAddress)
                    .fieldHelp("Bind address for the deployer-hosted range-capable media HTTP service.")
                TextField("Media Directory Name", text: $controller.settings.deployer.mediaDirectoryName)
                    .fieldHelp("Subdirectory under the deployer state root where ISO and installer media are cached.")
                TextField("PXE Directory Name", text: $controller.settings.deployer.pxeDirectoryName)
                    .fieldHelp("Subdirectory under the deployer state root for PXE assets and dnsmasq config.")
                TextField("Package Cache Root", text: $controller.settings.deployer.packageCacheRoot)
                    .fieldHelp("Cache directory for offline/repeat package and talosctl installs when the deployer has limited internet.")
                TextField("Pinned talosctl Version", text: $controller.settings.deployer.talosctlVersion)
                    .fieldHelp("talosctl version installed and managed by tds on the deployer.")
                Toggle("Keep local state mirror", isOn: $controller.settings.deployer.keepLocalMirror)
                    .fieldHelp("Keeps a workstation copy for UI resume/debug while treating the deployer copy as the maintenance source of truth.")
                Stepper("HTTP Port: \(controller.settings.deployer.httpPort)", value: $controller.settings.deployer.httpPort, in: 1...65535)
                    .fieldHelp("TCP port used by the deployer-hosted media HTTP service.")
                Stepper("Registry Port: \(controller.settings.deployer.registryPort)", value: $controller.settings.deployer.registryPort, in: 1...65535)
                    .fieldHelp("TCP port used by the deployer-hosted OCI registry for Talos installer images.")
            }
            SectionCard(title: "Safety") {
                Toggle("Require typed confirmation for deployer reinstall", isOn: $controller.settings.safety.requireTypedConfirmationForDeployerReinstall)
                    .fieldHelp("Requires an exact typed phrase before reinstalling the deployer because that action destroys its current OS.")
                TextField("Confirmation Prefix", text: $controller.settings.safety.destructiveConfirmationTextPrefix)
                    .fieldHelp("Prefix used for destructive reinstall confirmation, combined with the selected deployer name.")
            }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Text("Settings are saved locally on this workstation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel Changes") {
                    controller.reloadSettings()
                }
                Button("Save Settings") {
                    controller.saveSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Settings")
    }
}

private struct IloLocalMediaWebView: NSViewRepresentable {
    @Binding var urlString: String
    @Binding var username: String
    @Binding var password: String
    let isoPath: String
    let accessProfile: AccessProfile?
    let accessProfileProxyPassword: String
    @Binding var statusMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        context.coordinator.configureProxy(on: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.loadIfPossible(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadIfPossible(webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: IloLocalMediaWebView
        private var lastLoadedURL = ""

        init(_ parent: IloLocalMediaWebView) {
            self.parent = parent
        }

        func configureProxy(on configuration: WKWebViewConfiguration) {
            guard #available(macOS 14.0, *) else { return }
            guard let profile = parent.accessProfile,
                  let proxy = WebViewProxyConfiguration(profile: profile, password: parent.accessProfileProxyPassword)
            else { return }

            let dataStore = WKWebsiteDataStore.nonPersistent()
            dataStore.proxyConfigurations = [proxy.configuration]
            configuration.websiteDataStore = dataStore
        }

        func loadIfPossible(_ webView: WKWebView) {
            let raw = parent.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, raw != lastLoadedURL else { return }
            let normalized = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://\(raw)"
            guard let url = URL(string: normalized) else {
                parent.statusMessage = "Invalid iLO URL."
                return
            }
            lastLoadedURL = raw
            webView.load(URLRequest(url: url))
            parent.statusMessage = "Loading embedded iLO session for \(normalized)."
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust
            {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            injectLoginHints(into: webView)
            parent.statusMessage = "iLO page loaded. Open the HTML5 console and choose local media if it is not already selected."
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
        ) {
            let candidate = URL(fileURLWithPath: parent.isoPath.expandingTildeInPath())
            if FileManager.default.fileExists(atPath: candidate.path) {
                completionHandler([candidate])
                parent.statusMessage = "Selected ISO for iLO local media: \(candidate.path)"
                return
            }

            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
            panel.message = "Choose the Ubuntu or Talos ISO to attach through iLO local media."
            let response = panel.runModal()
            completionHandler(response == .OK ? panel.urls : nil)
        }

        private func injectLoginHints(into webView: WKWebView) {
            let user = jsString(parent.username)
            let pass = jsString(parent.password)
            let script = """
            (function() {
              const username = \(user);
              const password = \(pass);
              const userSelectors = ['input[name="username"]','input[name="user"]','input[id*="user" i]','input[placeholder*="user" i]'];
              const passSelectors = ['input[type="password"]','input[name="password"]','input[id*="password" i]'];
              for (const selector of userSelectors) {
                const element = document.querySelector(selector);
                if (element && username) { element.value = username; element.dispatchEvent(new Event('input', { bubbles: true })); break; }
              }
              for (const selector of passSelectors) {
                const element = document.querySelector(selector);
                if (element && password) { element.value = password; element.dispatchEvent(new Event('input', { bubbles: true })); break; }
              }
            })();
            """
            webView.evaluateJavaScript(script)
        }
    }
}

@available(macOS 14.0, *)
private struct WebViewProxyConfiguration {
    let configuration: ProxyConfiguration

    init?(profile: AccessProfile, password: String) {
        switch profile.kind {
        case .httpProxy:
            guard let parsed = ParsedProxyURL(rawValue: profile.proxyURL) else { return nil }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(parsed.host), port: NWEndpoint.Port(rawValue: parsed.port) ?? 8080)
            var proxy = ProxyConfiguration(
                httpCONNECTProxy: endpoint,
                tlsOptions: parsed.usesTLS ? NWProtocolTLS.Options() : nil
            )
            proxy.allowFailover = false
            Self.applyCredential(to: &proxy, parsed: parsed, profile: profile, password: password)
            self.configuration = proxy
        case .socksProxy, .sshDynamicSocks:
            guard let parsed = ParsedProxyURL(rawValue: profile.proxyURL) else { return nil }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(parsed.host), port: NWEndpoint.Port(rawValue: parsed.port) ?? 1080)
            var proxy = ProxyConfiguration(socksv5Proxy: endpoint)
            proxy.allowFailover = false
            Self.applyCredential(to: &proxy, parsed: parsed, profile: profile, password: password)
            self.configuration = proxy
        case .direct, .hammertimeProxy:
            return nil
        }
    }

    private static func applyCredential(to proxy: inout ProxyConfiguration, parsed: ParsedProxyURL, profile: AccessProfile, password: String) {
        let environment = ProcessInfo.processInfo.environment
        let username = firstNonEmpty(parsed.username, profile.proxyUsername, environment["TDS_OOB_PROXY_USER"] ?? "")
        let resolvedPassword = firstNonEmpty(parsed.password, password, environment["TDS_OOB_PROXY_PASSWORD"] ?? "")
        if !username.isEmpty || !resolvedPassword.isEmpty {
            proxy.applyCredential(username: username, password: resolvedPassword)
        }
    }
}

private struct ParsedProxyURL {
    let host: String
    let port: UInt16
    let usesTLS: Bool
    let username: String
    let password: String

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              let host = components.host,
              !host.isEmpty
        else { return nil }

        let scheme = components.scheme?.lowercased()
        self.host = host
        self.port = UInt16(components.port ?? (scheme == "https" ? 443 : 8080))
        self.usesTLS = scheme == "https"
        self.username = components.user ?? ""
        self.password = components.password ?? ""
    }
}

private func firstNonEmpty(_ values: String...) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
}

private func emptyDash(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "-" : value
}

private func prettyJSONString<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value),
          let rendered = String(data: data, encoding: .utf8)
    else {
        return "[]"
    }
    return rendered
}

private func decodeJSONString<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
    let data = Data(value.utf8)
    return try JSONDecoder().decode(type, from: data)
}

private func parseKernelModules(_ value: String) -> [TalosKernelModule] {
    value
        .split(separator: ",")
        .compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
                let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
                let paramsStart = trimmed.index(after: open)
                let paramsEnd = trimmed.index(before: trimmed.endIndex)
                let parameters = trimmed[paramsStart..<paramsEnd]
                    .split(separator: " ")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return name.isEmpty ? nil : TalosKernelModule(name: name, parameters: parameters)
            }
            return TalosKernelModule(name: trimmed)
        }
}

private extension AppController {
    var defaultOOBAccessProfile: AccessProfile? {
        settings.accessProfiles.first {
            $0.isDefault && ($0.scope == .oob || $0.scope == .both) && $0.kind != .direct
        } ?? settings.accessProfiles.first {
            ($0.scope == .oob || $0.scope == .both) && $0.kind != .direct
        }
    }
}

private func jsString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let string = String(data: data, encoding: .utf8)
    else {
        return "\"\""
    }
    return string
}
