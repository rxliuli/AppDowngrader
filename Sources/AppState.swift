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
        initPhase = .checkingDependencies
        await checkDependencies()

        guard dependencies.allSatisfied else { return }

        initPhase = .checkingAuth
        await checkAuth()

        initPhase = .detectingDevices
        await refreshDevices()

        initPhase = .ready
        startDevicePolling()
    }

    private func startDevicePolling() {
        devicePollTask?.cancel()
        devicePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }

                let udids = await DeviceService.listDeviceUDIDs()
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
            isAuthenticated = false
            authStep = .credentials
            retryAfterLogin = retry
            showAuthSheet = true
            status = .idle
            return true
        }
        return false
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

    func login() async {
        status = .loading("Logging in...")
        do {
            // Revoke existing session to clear potentially corrupted state
            if authStep == .credentials {
                await AppStoreService.revoke()
            }

            let result = try await AppStoreService.login(
                email: email, password: password,
                authCode: authStep == .twoFactor ? authCode : nil
            )
            switch result {
            case .success:
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
                authStep = .twoFactor
                status = .idle
            case .failure(let msg):
                status = .error(msg)
            }
        } catch {
            status = .error(error.localizedDescription)
        }
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
        storeInfo = nil
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

    /// Load metadata for a single version on demand (called when row appears)
    func loadMetadataIfNeeded(for versionId: String) async {
        guard let idx = versions.firstIndex(where: { $0.id == versionId }),
              !versions[idx].metadataLoaded,
              let app = selectedApp
        else { return }

        // Check disk cache first
        if let cached = await MetadataCache.shared.get(versionId) {
            if let idx = versions.firstIndex(where: { $0.id == versionId }) {
                versions[idx].version = cached
                versions[idx].metadataLoaded = true
            }
            return
        }

        let version = await AppStoreService.getVersionMetadata(
            bundleId: app.bundleId, versionId: versionId
        )
        if let idx = versions.firstIndex(where: { $0.id == versionId }) {
            versions[idx].version = version
            versions[idx].metadataLoaded = true
        }

        if let version {
            await MetadataCache.shared.set(versionId, version: version)
        }
    }

    func downloadAndInstall() async {
        guard let app = selectedApp, let device = selectedDevice else { return }

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

            status = .success("Successfully installed \(app.name)")
            await loadApps(for: device)
            // Update selectedApp to reflect the new installed version
            if let updated = installedApps.first(where: { $0.bundleId == app.bundleId }) {
                selectedApp = updated
            }
        } catch {
            downloadProgress = nil
            if !handleAuthErrorIfNeeded(error, retry: { [weak self] in
                await self?.downloadAndInstall()
            }) {
                status = .error(error.localizedDescription)
            }
        }
    }
}
