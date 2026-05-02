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
            case .deployment:
                DeploymentView()
            case .resume:
                ResumeView()
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
    case deployment
    case resume
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .signin: "Sign In"
        case .inventory: "Inventory + Roles"
        case .bootstrap: "Bootstrap Deployer"
        case .deployment: "Deployment Run"
        case .resume: "Resume"
        case .settings: "Settings"
        }
    }
    var systemImage: String {
        switch self {
        case .signin: "person.badge.key"
        case .inventory: "server.rack"
        case .bootstrap: "externaldrive.badge.plus"
        case .deployment: "bolt.badge.clock"
        case .resume: "arrow.clockwise"
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
                    Text("This is the default bootstrap path for a brand-new environment. The ISO is selected from the operator workstation or rax session inside tds; an existing OS media host is only allowed when explicitly configured in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("iLO URL, for example https://10.17.123.132", text: $controller.ubuntuOOBURL)
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
            }
            .padding()
        }
        .navigationTitle("Bootstrap Deployer")
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
                Text("On rax, the app now reads the active hammertime-backed Core session automatically and can import it into the local store if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Username", text: $username)
                    .fieldHelp("Optional Core username label for a manually stored session; rax normally detects this from hammertime.")
                TextField("Header Name", text: $headerName)
                    .fieldHelp("HTTP header used for the Core session secret, usually Cookie unless Core docs say otherwise.")
                SecureField("Cookie or bearer token", text: $secret)
                    .fieldHelp("Manual Core auth material stored in Keychain; prefer hammertime session import on rax when available.")
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
                Text("Run the app on rax to use the verified ws.core.rackspace.com + hammertime-backed inventory path.")
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Account Number", text: $controller.accountNumber)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .fieldHelp("Core account number to inventory; tds does not ship with a default real account.")
                Button("Load Devices") {
                    Task { await controller.refreshInventory() }
                }
                Button("Refresh Live Facts") {
                    Task { await controller.refreshLiveFacts() }
                }
            }

            if !controller.devices.isEmpty {
                Text("Showing \(controller.clusterEligibleDevices.count) physical server candidates. Filtered out \(controller.filteredDevices.count) non-server devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Table(controller.clusterEligibleDevices) {
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
            Text("Installing a new OS on the deployer will stage temporary state on rax until the deployer comes back.")
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
        DisclosureGroup("Talos Static Networking (\(talosNodes.count))") {
            if talosNodes.isEmpty {
                Text("Assign controlplane or worker roles to edit final static networking. DHCP may be used only for live boot; machine configs must use Core/captured/manual static IPs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
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
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Interface")
                    TextField("eno1", text: networkStringBinding(\.managementInterface))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Final Talos management NIC name; use the captured/Core NIC or enter the expected post-boot interface.")
                    Text("Static CIDR")
                    TextField("172.22.220.196/22", text: networkStringBinding(\.managementAddressCIDR))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Static management IP with prefix length for the Talos machine config; DHCP is only for live boot.")
                }
                GridRow {
                    Text("Gateway")
                    TextField("172.22.220.1", text: networkStringBinding(\.gateway))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Default gateway for the final static Talos network.")
                    Text("DNS")
                    TextField("172.22.216.10,8.8.8.8", text: networkListBinding(\.nameservers))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Comma-separated DNS servers rendered into the machine config.")
                }
                GridRow {
                    Text("Search Domains")
                    TextField("lab.example,example.test", text: networkListBinding(\.searchDomains))
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp("Comma-separated DNS search domains for the node.")
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

private struct DeploymentView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("Stage Deployment") {
                Task { await controller.stageDeployment() }
            }
            if let plan = controller.lastPlan {
                Text("Phases")
                    .font(.headline)
                List(plan.phases) { phase in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phase.title)
                            .font(.headline)
                        ForEach(phase.steps, id: \.self) { step in
                            Text(step)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Text("No deployment has been staged yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Deployment Run")
    }
}

private struct ResumeView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resume uses the saved deployment-state.json from the local staging directory or the deployer state root.")
                .foregroundStyle(.secondary)
            if let state = controller.lastState {
                Text("Last staged deployment: \(state.spec.clusterName)")
                Text("State directory: \(state.localStateDirectory)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No local deployment state is loaded.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Resume")
    }
}

private struct SettingsRootView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section("Access Profiles") {
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
            Section("Core Session") {
                TextField("Default Account", text: $controller.settings.core.defaultAccountNumber)
                    .fieldHelp("Optional operator convenience default; leave blank unless you repeatedly work one account.")
                Picker("Inventory Source", selection: $controller.settings.core.inventorySource) {
                    ForEach(InventorySource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                TextField("Docs URL", text: $controller.settings.core.docsURL)
                    .fieldHelp("Core documentation endpoint for operators running on rax.")
                TextField("Service URL", text: $controller.settings.core.serviceURL)
                    .fieldHelp("Base WS Core API endpoint used for account inventory and device details.")
            }
            Section("Hammertime") {
                Toggle("Enabled", isOn: $controller.settings.hammertime.enabled)
                Toggle("Skip device checks (--no-checks)", isOn: $controller.settings.hammertime.skipDeviceChecks)
                TextField("Binary Path", text: $controller.settings.hammertime.binaryPath)
                    .fieldHelp("Path to the ht executable on rax.")
                TextField("Python Path (optional)", text: $controller.settings.hammertime.pythonPath)
                    .fieldHelp("Optional Python interpreter for the bundled Core bridge; leave blank for system Python.")
                TextField("Session Cache Path", text: $controller.settings.hammertime.sessionCachePath)
                    .fieldHelp("Optional hammertime cache path to inspect for active Core auth; blank uses the default discovery paths.")
                TextField("Default Fact Groups", text: Binding(
                    get: { controller.settings.hammertime.defaultFactGroups.joined(separator: ",") },
                    set: { controller.settings.hammertime.defaultFactGroups = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                ))
                .fieldHelp("Comma-separated fact groups passed to ht raxfacts during optional live enrichment.")
                Stepper("Timeout Seconds: \(controller.settings.hammertime.timeoutSeconds)", value: $controller.settings.hammertime.timeoutSeconds, in: 5...300)
                    .fieldHelp("Maximum time tds waits for each hammertime command before treating enrichment as non-blocking failed data.")
            }
            Section("Talos Defaults") {
                TextField("Talos Version", text: $controller.settings.talos.talosVersion)
                    .fieldHelp("Talos release used for generated factory artifacts and talosctl pinning.")
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
            }
            Section("Talos Image Factory") {
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
            Section("Talos Provisioning") {
                Toggle("Allow deployer-hosted media", isOn: $controller.settings.talos.provisioning.allowDeployerHostedMedia)
                Toggle("Allow deployer PXE", isOn: $controller.settings.talos.provisioning.allowDeployerPXE)
                Toggle("Allow external OOB URL", isOn: $controller.settings.talos.provisioning.allowExternalOOBURL)
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
            Section("Bootstrap Media") {
                Picker("First deployer media delivery", selection: $controller.settings.bootstrapMedia.deliveryMode) {
                    ForEach(BootstrapMediaDeliveryMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Toggle("Require operator local media for greenfield", isOn: $controller.settings.bootstrapMedia.requireOperatorLocalMediaForGreenfield)
                Toggle("Allow existing OS media host", isOn: $controller.settings.bootstrapMedia.allowExistingOSMediaHost)
                TextField("OOB-reachable external media base URL", text: $controller.settings.bootstrapMedia.externalMediaBaseURL)
                    .fieldHelp("External media URL for the first Ubuntu deployer only when the iLO/iDRAC network can fetch it.")
                TextField("Existing media host device ID (explicit only)", text: $controller.settings.bootstrapMedia.mediaHostDeviceID)
                    .fieldHelp("Device ID of an already-running host used to serve bootstrap media; leave blank for greenfield-safe local media.")
                Text("Default is operator local media through the embedded OOB browser. Existing media hosts are intentionally opt-in because they do not work for all-bare-metal greenfield environments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Deployer Defaults") {
                TextField("Deployer SSH User", text: $controller.settings.deployer.sshUser)
                    .fieldHelp("SSH user tds uses after Ubuntu is installed or when preparing an existing deployer.")
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
                Stepper("HTTP Port: \(controller.settings.deployer.httpPort)", value: $controller.settings.deployer.httpPort, in: 1...65535)
                    .fieldHelp("TCP port used by the deployer-hosted media HTTP service.")
            }
            Section("Safety") {
                Toggle("Require typed confirmation for deployer reinstall", isOn: $controller.settings.safety.requireTypedConfirmationForDeployerReinstall)
                TextField("Confirmation Prefix", text: $controller.settings.safety.destructiveConfirmationTextPrefix)
                    .fieldHelp("Prefix used for destructive reinstall confirmation, combined with the selected deployer name.")
            }
            Button("Save Settings") {
                controller.saveSettings()
            }
        }
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
