import SwiftUI

struct AppDetailView: View {
    let app: InstalledApp
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header: app info + store info
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    AppIconView(urlString: state.storeInfo?.artworkUrl512
                                ?? state.storeInfo?.artworkUrl100)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.title2.bold())
                        HStack(spacing: 8) {
                            Text(app.bundleId)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("Installed: v\(app.version)")
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.1), in: Capsule())
                        }
                        .font(.subheadline)

                        if let info = state.storeInfo {
                            HStack(spacing: 16) {
                                Text("Latest: \(info.version ?? "?")")
                                if let min = info.minimumOsVersion {
                                    Text("Min iOS: \(min)")
                                }
                                if let s = info.fileSizeBytes, let size = Int(s) {
                                    Text(ByteCountFormatter.string(
                                        fromByteCount: Int64(size), countStyle: .file
                                    ))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(20)

            Divider()

            // Version list (fills remaining space)
            versionSection

            // Fixed bottom bar
            bottomBar
        }
    }

    // MARK: - Version Selection

    @ViewBuilder
    private var versionSection: some View {
        @Bindable var state = state

        if state.isLoadingVersions {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading available versions...").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = state.versionsError {
            VStack(spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Text("Enter version ID manually:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("e.g. 843465168", text: $state.manualVersionId)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.versions.isEmpty {
            Text("No versions available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(state.versions, selection: $state.selectedVersion) { version in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(version.displayName)
                                .font(.body)
                            if version.version == app.version {
                                Text("installed")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.1), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                        }
                        HStack(spacing: 8) {
                            if let date = version.formattedDate {
                                Text(date)
                            }
                            Text("ID: \(version.id)")
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if !version.metadataLoaded {
                        ProgressView().controlSize(.mini)
                    }
                }
                .tag(version)
                .onAppear {
                    Task { await state.loadMetadataIfNeeded(for: version.id) }
                }
            }
        }
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            // Status
            statusView

            // Action button
            HStack(spacing: 12) {
                Button {
                    Task { await state.downloadAndInstall() }
                } label: {
                    Label(downloadButtonTitle, systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !state.isAuthenticated || state.selectedDevice == nil || isLoading
                )

                if !state.isAuthenticated {
                    Label("Login required", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var downloadButtonTitle: String {
        if let v = state.selectedVersion {
            return "Download & Install \(v.displayName)"
        }
        if !state.manualVersionId.isEmpty {
            return "Download & Install (ID: \(state.manualVersionId))"
        }
        return "Reinstall Latest"
    }

    // MARK: - Status

    @ViewBuilder
    private var statusView: some View {
        switch state.status {
        case .idle:
            EmptyView()
        case .loading(let msg):
            VStack(alignment: .leading, spacing: 6) {
                if let progress = state.downloadProgress {
                    ProgressView(value: progress) {
                        HStack {
                            Text(msg).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(progress * 100))%").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(msg).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isLoading: Bool {
        if case .loading = state.status { return true }
        return false
    }
}

// MARK: - App Icon

struct AppIconView: View {
    let urlString: String?
    var size: CGFloat = 48

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } placeholder: {
                iconPlaceholder
            }
            .frame(width: size, height: size)
        } else {
            iconPlaceholder
        }
    }

    private var iconPlaceholder: some View {
        Image(systemName: "app.fill")
            .font(.system(size: size * 0.8))
            .foregroundStyle(.blue)
            .frame(width: size, height: size)
    }
}
