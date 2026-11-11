import AppKit
import SwiftUI

enum InitPhase: Equatable {
    case checkingDependencies
    case checkingAuth
    case detectingDevices
    case loadingApps
    case ready
}

@MainActor @Observable
class AppState {
    // Init
    var initPhase: InitPhase = .checkingDependencies

    // Dependencies
    var dependencies = DependencyStatus()
    var dependenciesChecked = false

    // Device
    var devices: [Device] = []
    var selectedDevice: Device?
    var isRefreshingDevices = false

    // Apps
    var installedApps: [InstalledApp] = []
    var selectedApp: InstalledApp?
    var searchText = ""
    var isLoadingApps = false

    // Auth
    var isAuthenticated = false
    enum AuthStep { case credentials, twoFactor }
    var authStep: AuthStep = .credentials
    var email = ""
    var password = ""
    var authCode = ""
    var showAuthSheet = false
    private var retryAfterLogin: (@MainActor () async -> Void)?

    // Task status (for download/install operations)
    var status: TaskStatus = .idle

    /// The login in flight, so the sheet's Stop button has something to cancel.
    private var loginTask: Task<Void, Never>?

    init() {
        // A login in flight must not outlive the app: ipatool would keep provisioning for
        // ~20 minutes with nobody left to show it or to kill it (observed as an orphan
        // reparented to launchd).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Shell.stopAll()
        }
    }

    // Versions
    var versions: [AppVersion] = []
    var isLoadingVersions = false
    var versionsError: String?
    var selectedVersion: AppVersion?
    var manualVersionId = ""

    // Download progress (0.0 - 1.0, nil when not downloading)
    var downloadProgress: Double?

    // Store info
    var storeInfo: ITunesLookupResult?

    var filteredApps: [InstalledApp] {
        if searchText.isEmpty { return installedApps }
        return installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleId.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// The version ID to use for download: selected version > manual input > nil (latest)
    var effectiveVersionId: String? {
        if let v = selectedVersion { return v.id }
        if !manualVersionId.isEmpty { return manualVersionId }
        return nil
    }

    // Device polling
    private var devicePollTask: Task<Void, Never>?

    // MARK: - Startup

    func initialize() async {
        Logger.shared.info("App initializing (dependencies / devices / apps)...")
        initPhase = .checkingDependencies
        let stale = AppStoreService.discardStaleWorkspaces()
        if stale > 0 {
            Logger.shared.info("Removed \(stale) leftover ipatool workspace(s)")
        }
        await checkDependencies()

        guard dependencies.allSatisfied else {
            Logger.shared.error("Missing dependencies: \(dependencies.missingTools.joined(separator: ", "))")
            return
        }

        initPhase = .checkingAuth
        await checkAuth()

        initPhase = .detectingDevices
        await refreshDevices()

        initPhase = .ready
        Logger.shared.info("App initialization complete")
        startDevicePolling()
    }

    private func startDevicePolling() {
        devicePollTask?.cancel()
        devicePollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Poll quietly (don't spam the log) and only refresh when a device appears/disappears.
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }

                let udids = await DeviceService.listDeviceUDIDs(quiet: true)
                let currentIds = self?.devices.map(\.id) ?? []

                // Only refresh if device list changed
                if Set(udids) != Set(currentIds) {
                    await self?.refreshDevices()
                }
            }
        }
    }

    // MARK: - Auth Error Handling

    private static let authErrorPatterns = [
        "password token is expired", "token is expired",
        "authentication required", "not authenticated",
        "unsupported protocol scheme",
        "could not be found in the keyring", "failed to get account",
    ]

    nonisolated static func looksLikeAuthError(_ message: String) -> Bool {
        authErrorPatterns.contains { message.localizedCaseInsensitiveContains($0) }
    }

    /// Check if an error is auth-related; if so, prompt login and retry.
    /// Returns true if re-login was triggered (caller should abort current flow).
    private func handleAuthErrorIfNeeded(_ error: Error, retry: @escaping @MainActor () async -> Void) -> Bool {
        let msg = error.localizedDescription
        if Self.looksLikeAuthError(msg) {
            Logger.shared.warn("Auth error detected, prompting re-login: \(msg)")
            isAuthenticated = false
            authStep = .credentials
            retryAfterLogin = retry
            showAuthSheet = true
            status = .idle
            return true
        }
        return false
    }

    private static func preparationLabel(
        _ progress: (extracted: Int64, total: Int64), since started: Date
    ) -> String {
        let done = Int(Double(progress.extracted) / 1_048_576)
        let total = Int(Double(progress.total) / 1_048_576)
        let elapsed = Int(Date().timeIntervalSince(started))
        let clock = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        return "First login: preparing Apple assets \(done) / \(total) MB · \(clock)"
    }

    // MARK: - Actions

    func checkDependencies() async {
        async let ipatool = Shell.which("ipatool")
        async let goIos = Shell.which("ios")

        dependencies.ipatool = await ipatool
        dependencies.goIos = await goIos
        dependenciesChecked = true
    }

    func checkAuth() async {
        isAuthenticated = await AppStoreService.isAuthenticated()
    }

    /// Entry point for the sheet. While it runs, the primary button becomes Stop.
    func startLogin() {
        guard loginTask == nil else { return }
        loginTask = Task { [weak self] in
            await self?.login()
            self?.loginTask = nil
        }
    }

    /// macOS convention: the button that started the operation becomes Stop in place
    /// (Xcode's Run -> Stop). Cancelling the Task reaches the child through Shell's
    /// cancellation handler, so ipatool is really terminated, not just abandoned.
    func stopLogin() {
        Logger.shared.info("Login stopped by user")
        loginTask?.cancel()
    }

    func login() async {
        let is2FA = authStep == .twoFactor
        Logger.shared.info("Login started (\(is2FA ? "2FA verification" : "credentials"))")
        status = .loading(
            is2FA || AppStoreService.assetsReady()
                ? "Preparing authentication, first login may take a few minutes..."
                : "First login: preparing Apple assets..."
        )

        // ipatool provisions its SAP assets silently before it even tries to sign in, and it
        // cannot report anything while doing so. Watch its workspace instead, so the sheet
        // shows progress for the minutes this takes instead of a frozen spinner.
        let preexisting = AppStoreService.workspaceNames()
        let monitor = Task { @MainActor in
            let started = Date()
            while !Task.isCancelled {
                if let progress = AppStoreService.preparationProgress(excluding: preexisting) {
                    status = .loading(Self.preparationLabel(progress, since: started))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { monitor.cancel() }
        do {
            // Deliberately do not revoke the existing session before logging in.
            // Apple's auth edge intermittently rejects or redirects a login
            // (HTTP 301/403/204); revoking first turned such a transient failure
            // into a logout that also lost a previously working session. ipatool
            // overwrites the stored account on success anyway.
            let result = try await AppStoreService.login(
                email: email, password: password,
                authCode: is2FA ? authCode : nil,
                preexistingWorkspaces: preexisting
            )
            switch result {
            case .success:
                Logger.shared.info("Login succeeded")
                isAuthenticated = true
                showAuthSheet = false
                status = .idle
                password = ""
                authCode = ""
                authStep = .credentials

                // Retry the action that triggered re-login
                if let retry = retryAfterLogin {
                    retryAfterLogin = nil
                    await retry()
                }
            case .requires2FA:
                Logger.shared.info("2FA code required")
                authStep = .twoFactor
                status = .idle
            case .failure(let msg):
                Logger.shared.error("Login failed: \(msg)")
                AppStoreService.discardWorkspaces(createdSince: preexisting)
                status = .error(msg)
            }
        } catch {
            Logger.shared.error("Login threw: \(error.localizedDescription)")
            AppStoreService.discardWorkspaces(createdSince: preexisting)
            status = .error(error.localizedDescription)
        }
    }

    func logout() async {
        Logger.shared.info("Logging out")
        await AppStoreService.revoke()
        isAuthenticated = false
        authStep = .credentials
        status = .idle
    }

    func refreshDevices() async {
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }

        let udids = await DeviceService.listDeviceUDIDs()
        var newDevices: [Device] = []
        for udid in udids {
            if let device = try? await DeviceService.getDeviceInfo(udid: udid) {
                newDevices.append(device)
            }
        }
        devices = newDevices

        if selectedDevice == nil || !devices.contains(where: { $0.id == selectedDevice?.id }) {
            selectedDevice = devices.first
        }

        if let device = selectedDevice {
            await loadApps(for: device)
        } else {
            installedApps = []
        }
    }

    func loadApps(for device: Device) async {
        isLoadingApps = true
        defer { isLoadingApps = false }
        do {
            installedApps = try await DeviceService.listInstalledApps(udid: device.id)
        } catch {
            status = .error(error.localizedDescription)
            installedApps = []
        }
    }

    func selectApp(_ app: InstalledApp) async {
        status = .idle
        storeInfo = nil
        resetMetadataLoads()
        versions = []
        selectedVersion = nil
        versionsError = nil
        manualVersionId = ""

        // Load store info and versions in parallel
        async let info: Void = loadStoreInfo(for: app.bundleId)
        async let vers: Void = loadVersions(for: app.bundleId)
        _ = await (info, vers)
    }

    private func loadStoreInfo(for bundleId: String) async {
        storeInfo = await AppStoreService.lookupApp(bundleId: bundleId)
    }

    func loadVersions(for bundleId: String) async {
        isLoadingVersions = true
        versionsError = nil
        defer { isLoadingVersions = false }

        do {
            let versionIds = try await AppStoreService.listVersions(bundleId: bundleId)
            // The user may have picked another app during the (minute-long) request.
            guard selectedApp?.bundleId == bundleId else { return }
            resetMetadataLoads()
            versions = versionIds.reversed().map { AppVersion(id: $0) }
        } catch {
            if handleAuthErrorIfNeeded(error, retry: { [weak self] in
                guard let self, let app = self.selectedApp else { return }
                await self.loadVersions(for: app.bundleId)
            }) {
                return
            }
            versionsError = error.localizedDescription
        }
    }

    /// How many `get-version-metadata` calls may run at once. With ipatool 2.8.0 each one
    /// takes about a minute and ~600MB, because every signed request reloads Apple's assets
    /// and runs the Store emulator. Starting one per visible row (~15 at once) made them
    /// all starve each other past the timeout, so none ever finished.
    private static let maxConcurrentMetadataLoads = 2

    /// Version IDs waiting for a metadata slot, oldest request first.
    @ObservationIgnored private var metadataQueue: [String] = []
    @ObservationIgnored private var metadataInFlight: Set<String> = []
    @ObservationIgnored private var metadataWorkers: [UUID: Task<Void, Never>] = [:]

    /// Request metadata for a version (called when its row appears, or on retry).
    ///
    /// Costs one `ipatool get-version-metadata` call per version: a signed App Store
    /// request plus a ranged read of the IPA (~160 KB). Kept lazy, queued and disk-cached.
    func loadMetadataIfNeeded(for versionId: String) async {
        guard let app = selectedApp,
              let idx = versions.firstIndex(where: { $0.id == versionId }),
              !versions[idx].metadataLoaded,
              !metadataInFlight.contains(versionId),
              !metadataQueue.contains(versionId)
        else { return }
        let bundleId = app.bundleId

        // Check disk cache first
        if let cached = await MetadataCache.shared.get(
            bundleId: bundleId, versionId: versionId
        ) {
            apply(metadata: cached, for: versionId, bundleId: bundleId)
            return
        }

        // Re-check after the await: the app may have changed, or another call queued it.
        guard selectedApp?.bundleId == bundleId,
              let idx = versions.firstIndex(where: { $0.id == versionId }),
              !versions[idx].metadataLoaded,
              !metadataInFlight.contains(versionId),
              !metadataQueue.contains(versionId)
        else { return }

        versions[idx].metadataFailed = false
        metadataQueue.append(versionId)
        startMetadataWorkers()
    }

    /// A row scrolled out of view: drop its request if it has not started yet, so the
    /// slots go to the rows the user is looking at. A request already running finishes
    /// and is cached.
    func cancelMetadataLoad(for versionId: String) {
        metadataQueue.removeAll { $0 == versionId }
    }

    private func startMetadataWorkers() {
        while metadataWorkers.count < Self.maxConcurrentMetadataLoads, !metadataQueue.isEmpty {
            let workerId = UUID()
            metadataWorkers[workerId] = Task { [weak self] in
                await self?.runMetadataWorker()
                self?.metadataWorkers[workerId] = nil
            }
        }
    }

    private func runMetadataWorker() async {
        while !Task.isCancelled, !metadataQueue.isEmpty {
            guard let bundleId = selectedApp?.bundleId else { return }
            let versionId = metadataQueue.removeFirst()
            metadataInFlight.insert(versionId)
            defer { metadataInFlight.remove(versionId) }

            do {
                let metadata = try await AppStoreService.getVersionMetadata(
                    bundleId: bundleId, versionId: versionId
                )
                apply(metadata: metadata, for: versionId, bundleId: bundleId)
                if let metadata {
                    await MetadataCache.shared.set(
                        bundleId: bundleId, versionId: versionId, metadata: metadata
                    )
                }
            } catch {
                // Cancelled means the user moved to another app: nothing to report.
                if Task.isCancelled || error is CancellationError { return }
                Logger.shared.warn("Version metadata \(bundleId) \(versionId) failed: \(error.localizedDescription)")
                markMetadataFailed(versionId, bundleId: bundleId)
            }
        }
    }

    /// Stop everything queued or running for the previous version list. Cancelling a
    /// worker kills its ipatool child (Shell.run's cancellation handler).
    private func resetMetadataLoads() {
        metadataQueue.removeAll()
        metadataInFlight.removeAll()
        for worker in metadataWorkers.values { worker.cancel() }
        metadataWorkers.removeAll()
    }

    private func apply(metadata: VersionMetadata?, for versionId: String, bundleId: String) {
        // The user may have switched apps while the request was in flight.
        guard selectedApp?.bundleId == bundleId,
              let idx = versions.firstIndex(where: { $0.id == versionId })
        else { return }

        versions[idx].version = metadata?.displayVersion
        versions[idx].releaseDate = metadata?.releaseDate
        versions[idx].metadataLoaded = true
        versions[idx].metadataFailed = false
    }

    private func markMetadataFailed(_ versionId: String, bundleId: String) {
        guard selectedApp?.bundleId == bundleId,
              let idx = versions.firstIndex(where: { $0.id == versionId })
        else { return }
        // Deliberately not metadataLoaded: a failure is not an answer, so the row can retry.
        versions[idx].metadataFailed = true
    }

    func downloadAndInstall() async {
        guard let app = selectedApp, let device = selectedDevice else { return }

        Logger.shared.info("Download & install \(app.name) (\(app.bundleId)) version=\(effectiveVersionId ?? "latest") to device \(device.id)")
        downloadProgress = 0
        status = .loading("Downloading \(app.name)...")
        do {
            let ipaPath = try await AppStoreService.download(
                bundleId: app.bundleId,
                versionId: effectiveVersionId
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }

            downloadProgress = nil
            status = .loading("Installing \(app.name)...")
            try await DeviceService.installIPA(udid: device.id, path: ipaPath)

            // Clean up
            try? FileManager.default.removeItem(atPath: ipaPath)

            Logger.shared.info("Successfully installed \(app.name)")
            status = .success("Successfully installed \(app.name)")
            await loadApps(for: device)
            // Update selectedApp to reflect the new installed version
            if let updated = installedApps.first(where: { $0.bundleId == app.bundleId }) {
                selectedApp = updated
            }
        } catch {
            downloadProgress = nil
            Logger.shared.error("Download/install failed: \(error.localizedDescription)")
            if !handleAuthErrorIfNeeded(error, retry: { [weak self] in
                await self?.downloadAndInstall()
            }) {
                status = .error(error.localizedDescription)
            }
        }
    }
}
