import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if !state.dependenciesChecked {
                InitLoadingView(phase: state.initPhase)
            } else if !state.dependencies.allSatisfied {
                SetupView()
            } else if state.initPhase != .ready {
                InitLoadingView(phase: state.initPhase)
            } else {
                MainView()
            }
        }
        .task {
            await state.initialize()
        }
    }
}

// MARK: - Init Loading View

struct InitLoadingView: View {
    let phase: InitPhase

    private var steps: [(label: String, done: Bool)] {
        let phases: [InitPhase] = [
            .checkingDependencies, .checkingAuth, .detectingDevices, .loadingApps,
        ]
        let labels = [
            "Checking dependencies",
            "Checking authentication",
            "Detecting devices",
            "Loading apps",
        ]
        let currentIndex = phases.firstIndex(of: phase) ?? phases.count
        return zip(labels, phases.indices).map { label, i in
            (label: label, done: i < currentIndex)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("AppDowngrader")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 10) {
                        if step.done {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if index == steps.firstIndex(where: { !$0.done }) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.quaternary)
                        }
                        Text(step.label)
                            .foregroundStyle(step.done ? .primary : .secondary)
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Setup View

struct SetupView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)

            Text("Missing Dependencies")
                .font(.title2.bold())

            Text("Install the following tools via Homebrew:")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.dependencies.missingTools, id: \.self) { tool in
                    Label(tool, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Text("brew install ipatool && npm install -g go-ios")
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)

            HStack {
                Button("Retry") {
                    Task { await state.initialize() }
                }
                .buttonStyle(.borderedProminent)

                Button("Open Log Folder") {
                    Logger.shared.revealInFinder()
                }
                .buttonStyle(.bordered)
            }

            Text("Log: \(Logger.shared.logFilePath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Main View

struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            if let app = state.selectedApp {
                AppDetailView(app: app)
                    .id(app.id)
            } else {
                ContentUnavailableView(
                    "Select an App",
                    systemImage: "app.dashed",
                    description: Text(
                        "Choose an installed app from the sidebar to manage its version")
                )
            }
        }
        .sheet(isPresented: $state.showAuthSheet) {
            AuthSheet()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        List(selection: $state.selectedApp) {
            // Device section
            Section("Device") {
                if state.isRefreshingDevices {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Detecting devices...").foregroundStyle(.secondary)
                    }
                } else if let device = state.selectedDevice {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(device.name, systemImage: "iphone")
                            .font(.headline)
                        Text("iOS \(device.iosVersion) \u{00B7} \(device.productType)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Label("No device connected", systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                }
            }

            // Apps section
            Section("Installed Apps (\(state.filteredApps.count))") {
                if state.isLoadingApps {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading apps...").foregroundStyle(.secondary)
                    }
                } else if state.filteredApps.isEmpty && !state.searchText.isEmpty {
                    Text("No matching apps")
                        .foregroundStyle(.secondary)
                } else if state.filteredApps.isEmpty {
                    Text("No apps found on device")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.filteredApps) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.body)
                            Text("\(app.bundleId) \u{00B7} v\(app.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(app)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .searchable(text: $state.searchText, prompt: "Filter apps")
        .onChange(of: state.selectedApp) { _, newValue in
            if let app = newValue {
                Task { await state.selectApp(app) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    state.showAuthSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(
                            systemName: state.isAuthenticated
                                ? "person.fill.checkmark" : "person.badge.key"
                        )
                        Text(state.isAuthenticated ? "Logged in" : "Login")
                            .font(.caption)
                    }
                    .foregroundStyle(state.isAuthenticated ? .green : .orange)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Task { await state.refreshDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(state.isRefreshingDevices)
                .help("Refresh device & apps")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

// MARK: - Auth Sheet

struct AuthSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private var isLoggingIn: Bool {
        if case .loading = state.status { return true }
        return false
    }

    @ViewBuilder
    private var loginStatus: some View {
        if case .loading(let msg) = state.status {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(msg)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 16) {
            Text("Apple ID Login")
                .font(.title2.bold())

            if state.isAuthenticated {
                Text("Login with your Apple ID to download apps")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Label("Already authenticated", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Button("Logout") {
                    Task { await state.logout() }
                }
                .buttonStyle(.bordered)
            } else if state.authStep == .twoFactor {
                Text("A verification code has been sent to your device.\nEnter it below to continue.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TextField("Verification Code", text: $state.authCode)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLoggingIn)
                    .onSubmit { if !state.authCode.isEmpty { Task { await state.login() } } }

                if case .error(let msg) = state.status {
                    Text(msg)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                loginStatus

                Button("Verify") {
                    Task { await state.login() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.authCode.isEmpty || isLoggingIn)
            } else {
                Text("Login with your Apple ID to download apps")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TextField("Email", text: $state.email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLoggingIn)

                SecureField("Password", text: $state.password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLoggingIn)
                    .onSubmit { if !state.email.isEmpty && !state.password.isEmpty { Task { await state.login() } } }

                if case .error(let msg) = state.status {
                    Text(msg)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                loginStatus

                Button("Login") {
                    Task { await state.login() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.email.isEmpty || state.password.isEmpty || isLoggingIn)
            }

            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .disabled(isLoggingIn)
        }
        .padding(24)
        .frame(width: 360)
    }
}
