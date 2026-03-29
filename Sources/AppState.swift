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
    var email = ""
    var password = ""
    var authCode = ""
    var showAuthSheet = false

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

    // MARK: - Actions

    func checkDependencies() async {
        async let ipatool = Shell.which("ipatool")
        async let installer = Shell.which("ideviceinstaller")
        async let deviceId = Shell.which("idevice_id")
        async let deviceInfo = Shell.which("ideviceinfo")

        dependencies.ipatool = await ipatool
        dependencies.ideviceinstaller = await installer
        dependencies.ideviceId = await deviceId
        dependencies.ideviceinfo = await deviceInfo
        dependenciesChecked = true
    }

    func checkAuth() async {
        isAuthenticated = await AppStoreService.isAuthenticated()
    }

    func login() async {
        status = .loading("Logging in...")
        do {
            let success = try await AppStoreService.login(
                email: email, password: password,
                authCode: authCode.isEmpty ? nil : authCode
            )
            if success {
                isAuthenticated = true
                showAuthSheet = false
                status = .success("Logged in")
                password = ""
                authCode = ""
            } else {
                status = .error("Login failed — check credentials or enter 2FA code")
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
            // Reverse: newest versions first
            versions = versionIds.reversed().map { AppVersion(id: $0) }
        } catch {
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
                versions[idx].version = cached.version
                versions[idx].releaseDate = cached.releaseDate
                versions[idx].metadataLoaded = true
            }
            return
        }

        let meta = await AppStoreService.getVersionMetadata(
            bundleId: app.bundleId, versionId: versionId
        )
        if let idx = versions.firstIndex(where: { $0.id == versionId }) {
            versions[idx].version = meta.version
            versions[idx].releaseDate = meta.releaseDate
            versions[idx].metadataLoaded = true
        }

        // Cache to disk (only if we got some data)
        if meta.version != nil || meta.releaseDate != nil {
            await MetadataCache.shared.set(versionId, version: meta.version, releaseDate: meta.releaseDate)
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
        } catch {
            downloadProgress = nil
            status = .error(error.localizedDescription)
        }
    }
}
