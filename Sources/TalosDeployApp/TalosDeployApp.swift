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
                BootstrapHelperView()
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
        case .bootstrap: "Bootstrap Helper"
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

private struct BootstrapHelperView: View {
    @EnvironmentObject private var controller: AppController
    @State private var iloPassword = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard(title: "Ubuntu Autoinstall Media") {
                    Text("Builds a NoCloud-seeded Ubuntu 24.04 ISO from the preinstall capture. The same local-media path can later boot stock Talos media without editing the Talos ISO.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Preinstall capture directory or snapshot.json", text: $controller.ubuntuCapturePath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Source Ubuntu ISO", text: $controller.ubuntuSourceISOPath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Output customized ISO", text: $controller.ubuntuOutputISOPath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Work directory (optional)", text: $controller.ubuntuWorkDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                    TextField("SSH public key files, comma separated (optional)", text: $controller.ubuntuSSHKeyFiles)
                        .textFieldStyle(.roundedBorder)
                    SecureField("rack password hash, or TDS_RACK_PASSWORD_HASH", text: $controller.ubuntuRackPasswordHash)
                        .textFieldStyle(.roundedBorder)
                    SecureField("root password hash, or TDS_ROOT_PASSWORD_HASH", text: $controller.ubuntuRootPasswordHash)
                        .textFieldStyle(.roundedBorder)
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

                SectionCard(title: "HPE iLO 4 Local Media") {
                    TextField("iLO URL, for example https://10.17.123.132", text: $controller.ubuntuOOBURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("iLO username", text: $controller.ubuntuOOBUsername)
                        .textFieldStyle(.roundedBorder)
                    SecureField("iLO password (not saved)", text: $iloPassword)
                        .textFieldStyle(.roundedBorder)
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
                        statusMessage: $controller.statusMessage
                    )
                    .frame(minHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                }
            }
            .padding()
        }
        .navigationTitle("Bootstrap Helper")
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
                TextField("Header Name", text: $headerName)
                SecureField("Cookie or bearer token", text: $secret)
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
                        ForEach(DeviceRole.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
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
                                if assignment.role == .helper && $0 {
                                    assignment.helperMode = .bootstrap
                                }
                                controller.updateAssignment(assignment)
                            }
                        )
                    )
                    .labelsHidden()
                }
            }

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

            if let helper = controller.clusterEligibleDevices.first(where: {
                let assignment = controller.binding(for: $0)
                return assignment.role == .helper && assignment.shouldInstallOS
            }) {
                HelperWarningView(device: helper)
            }
        }
        .padding()
        .navigationTitle("Inventory + Role Assignment")
    }
}

private struct HelperWarningView: View {
    @EnvironmentObject private var controller: AppController
    let device: DiscoveredDevice

    var body: some View {
        let assignment = controller.binding(for: device)
        VStack(alignment: .leading, spacing: 8) {
            Text("Helper reinstall warning")
                .font(.headline)
            Text("Installing a new OS on the helper/overseer will stage temporary state on rax until the helper comes back.")
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
        }
        .padding()
        .background(.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
            Text("Resume uses the saved deployment-state.json from the local staging directory or the helper host state root.")
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
                        TextField("Hammertime via", text: Binding(
                            get: { controller.settings.accessProfiles[index].hammertimeVia },
                            set: { controller.settings.accessProfiles[index].hammertimeVia = $0 }
                        ))
                        if profile.kind == .httpProxy {
                            Text("For OOB browser access, use http://127.0.0.1:18081 for the local cproxy relay or https://cproxy.iad3.corp.rackspace.net:3128 on rax. Proxy credentials can come from TDS_OOB_PROXY_USER and TDS_OOB_PROXY_PASSWORD.")
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
                Picker("Inventory Source", selection: $controller.settings.core.inventorySource) {
                    ForEach(InventorySource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                TextField("Docs URL", text: $controller.settings.core.docsURL)
                TextField("Service URL", text: $controller.settings.core.serviceURL)
            }
            Section("Hammertime") {
                Toggle("Enabled", isOn: $controller.settings.hammertime.enabled)
                Toggle("Skip device checks (--no-checks)", isOn: $controller.settings.hammertime.skipDeviceChecks)
                TextField("Binary Path", text: $controller.settings.hammertime.binaryPath)
                TextField("Python Path (optional)", text: $controller.settings.hammertime.pythonPath)
                TextField("Session Cache Path", text: $controller.settings.hammertime.sessionCachePath)
                TextField("Default Fact Groups", text: Binding(
                    get: { controller.settings.hammertime.defaultFactGroups.joined(separator: ",") },
                    set: { controller.settings.hammertime.defaultFactGroups = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                ))
                Stepper("Timeout Seconds: \(controller.settings.hammertime.timeoutSeconds)", value: $controller.settings.hammertime.timeoutSeconds, in: 5...300)
            }
            Section("Talos Defaults") {
                TextField("Talos Version", text: $controller.settings.talos.talosVersion)
                TextField("Kubernetes Version", text: $controller.settings.talos.kubernetesVersion)
                TextField("Cluster Name", text: $controller.settings.talos.clusterName)
                TextField("Cluster Endpoint", text: $controller.settings.talos.clusterEndpoint)
                Picker("Installer Preference", selection: $controller.settings.talos.installerPreference) {
                    ForEach(InstallPreference.allCases, id: \.self) { preference in
                        Text(preference.rawValue).tag(preference)
                    }
                }
            }
            Section("Helper Defaults") {
                TextField("SSH User", text: $controller.settings.helper.sshUser)
                TextField("State Root", text: $controller.settings.helper.stateRoot)
                TextField("PXE Address", text: $controller.settings.helper.pxeAddress)
                Stepper("HTTP Port: \(controller.settings.helper.httpPort)", value: $controller.settings.helper.httpPort, in: 1...65535)
            }
            Section("Safety") {
                Toggle("Require typed confirmation for helper reinstall", isOn: $controller.settings.safety.requireTypedConfirmationForHelperReinstall)
                TextField("Confirmation Prefix", text: $controller.settings.safety.destructiveConfirmationTextPrefix)
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
                  let proxy = WebViewProxyConfiguration(profile: profile)
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

    init?(profile: AccessProfile) {
        switch profile.kind {
        case .httpProxy:
            guard let parsed = ParsedProxyURL(rawValue: profile.proxyURL) else { return nil }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(parsed.host), port: NWEndpoint.Port(rawValue: parsed.port) ?? 8080)
            var proxy = ProxyConfiguration(
                httpCONNECTProxy: endpoint,
                tlsOptions: parsed.usesTLS ? NWProtocolTLS.Options() : nil
            )
            proxy.allowFailover = false
            Self.applyCredential(to: &proxy, parsed: parsed)
            self.configuration = proxy
        case .socksProxy, .sshDynamicSocks:
            guard let parsed = ParsedProxyURL(rawValue: profile.proxyURL) else { return nil }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(parsed.host), port: NWEndpoint.Port(rawValue: parsed.port) ?? 1080)
            var proxy = ProxyConfiguration(socksv5Proxy: endpoint)
            proxy.allowFailover = false
            Self.applyCredential(to: &proxy, parsed: parsed)
            self.configuration = proxy
        case .direct, .hammertimeProxy:
            return nil
        }
    }

    private static func applyCredential(to proxy: inout ProxyConfiguration, parsed: ParsedProxyURL) {
        let environment = ProcessInfo.processInfo.environment
        let username = firstNonEmpty(parsed.username, environment["TDS_OOB_PROXY_USER"] ?? "")
        let password = firstNonEmpty(parsed.password, environment["TDS_OOB_PROXY_PASSWORD"] ?? "")
        if !username.isEmpty || !password.isEmpty {
            proxy.applyCredential(username: username, password: password)
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
