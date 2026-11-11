import Foundation

enum AppStoreService {
    static func isAuthenticated() async -> Bool {
        guard let result = try? await Shell.run("ipatool", arguments: ["auth", "info"]) else {
            return false
        }
        return result.succeeded
    }

    enum LoginResult {
        case success
        case requires2FA
        case failure(String)
    }

    /// ipatool 2.8.0 provisions its SAP assets on the first login: it reads 7 pinned files
    /// out of Apple's macOS restore image, extracts them into a temporary workspace, and only
    /// writes its cache once every one of them is done. That takes ~20 minutes on a slow
    /// connection and ipatool prints nothing at all while doing it, so the UI has to derive
    /// the phase and the progress from the filesystem.
    ///
    /// These sizes come from `requiredFiles` in internal/sap/assets/assets.go (v2.8.0). They
    /// only ever feed a label - never a decision - so a wrong guess degrades the text, not
    /// the behaviour.
    private static let sapAssetBytes: Int64 = 174_733_872
    /// Long enough for the first-login asset provisioning to finish on a slow line: measured
    /// 21m19s on a 120KB/s connection. A hung connection is the user's Stop button, not this
    /// number - ipatool has no read timeout of its own, so we still need an upper bound.
    private static let loginTimeout: TimeInterval = 1800

    /// Upper bound for one signed store call (list-versions, get-version-metadata, purchase).
    /// ipatool 2.8.0 runs every signed request through its local Store emulator and reloads
    /// ~175MB of Apple assets each time, so even with the assets cached a single call is slow:
    /// measured on an M2 (2026-11-12, one call at a time) list-versions 38s,
    /// get-version-metadata 45-53s, purchase 9s. The old 15s/30s limits killed every call.
    static let storeRequestTimeout: TimeInterval = 180

    private static var sapCacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ipatool/sap", isDirectory: true)
    }

    /// True once ipatool will answer from its cache instead of provisioning again.
    /// Matches any macOS build: the directory name carries it
    /// (`apple-assets-macos-27-26A434-arm64-v4`).
    static func assetsReady() -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: sapCacheRoot, includingPropertiesForKeys: nil
        )) ?? []
        return entries.contains { $0.lastPathComponent.hasPrefix("apple-assets-macos-") }
    }

    /// Snapshot of the provisioning workspaces that already exist, taken before the run
    /// starts. ipatool creates `$TMPDIR/ipatool-macos-27-<random>` per attempt and never
    /// cleans it up after a SIGTERM, so a machine can have several lying around; without
    /// this the UI can adopt a dead attempt's workspace and show progress jumping backwards.
    static func workspaceNames() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return Set(
            entries.map(\.lastPathComponent).filter { $0.hasPrefix("ipatool-macos-27-") }
        )
    }

    /// Delete the workspaces an abandoned attempt left behind. ipatool cleans its workspace
    /// with `defer os.RemoveAll`, which does not run when we SIGTERM it, so every timeout or
    /// Stop otherwise strands ~170MB in $TMPDIR (1.5GB had piled up before this existed).
    static func discardWorkspaces(createdSince preexisting: Set<String>) {
        let temp = FileManager.default.temporaryDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries
        where entry.lastPathComponent.hasPrefix("ipatool-macos-27-")
            && !preexisting.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Workspaces are per-attempt scratch space, so anything present at launch is a leftover
    /// from an interrupted run and can go. Returns how many were removed, for the log.
    @discardableResult
    static func discardStaleWorkspaces() -> Int {
        let temp = FileManager.default.temporaryDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: nil
        )) ?? []
        let stale = entries.filter { $0.lastPathComponent.hasPrefix("ipatool-macos-27-") }
        for entry in stale { try? FileManager.default.removeItem(at: entry) }
        return stale.count
    }

    /// Progress of an in-flight provisioning run, or nil when there is none to show
    /// (nothing on disk yet, or the assets are already cached).
    static func preparationProgress(
        excluding preexisting: Set<String> = []
    ) -> (extracted: Int64, total: Int64)? {
        guard !assetsReady() else { return nil }

        let temp = FileManager.default.temporaryDirectory
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: nil
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix("ipatool-macos-27-")
                && !preexisting.contains($0.lastPathComponent)
        }

        var best: (bytes: Int64, touched: Date)?
        for candidate in candidates {
            let frameworks = candidate.appendingPathComponent("frameworks", isDirectory: true)
            var bytes: Int64 = 0
            var touched = Date.distantPast
            guard let walker = FileManager.default.enumerator(
                at: frameworks, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { continue }
            for case let file as URL in walker {
                let values = try? file.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
                bytes += Int64(values?.fileSize ?? 0)
                if let date = values?.contentModificationDate, date > touched { touched = date }
            }
            if bytes > 0, touched > (best?.touched ?? .distantPast) {
                best = (bytes, touched)
            }
        }

        guard let best else { return nil }
        return (best.bytes, sapAssetBytes)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }

    static func login(
        email: String, password: String, authCode: String? = nil,
        preexistingWorkspaces: Set<String> = []
    ) async throws -> LoginResult {
        var args = ["auth", "login", "-e", email, "-p", password,
                    "--format", "json", "--non-interactive"]
        if let code = authCode, !code.isEmpty {
            args += ["--auth-code", code]
        }
        // First login may take a few minutes: ipatool downloads & sets up the
        // SAP/Unicorn runtime on first run, so use a generous timeout.
        let result = try await Shell.run("ipatool", arguments: args, timeout: loginTimeout)
        print("[AppStore] login: exit=\(result.exitCode) stdout=\(result.stdout) stderr=\(result.stderr)")
        // ipatool returns exit=0 with a "message" field when 2FA is needed
        let output = result.stdout
        if output.contains("2FA") || output.contains("--auth-code") {
            return .requires2FA
        }
        if result.succeeded {
            return .success
        }
        if let stopReason = result.stopReason {
            // A killed child only tells us SIGTERM, so name the phase we were in instead of
            // echoing whatever ipatool happened to have printed (an info line counts as an
            // error to parseError, which is what shipped as "Login failed: preparing
            // authentication; the first login may take a few minutes").
            let progress = preparationProgress(excluding: preexistingWorkspaces).map {
                " at \(megabytes($0.extracted)) / \(megabytes($0.total)) MB"
            } ?? ""

            switch stopReason {
            case .cancelled:
                return .failure(
                    "Stopped\(progress). ipatool cannot resume, so what it had already "
                        + "downloaded is discarded - a retry starts from zero."
                )
            case .timeout:
                let minutes = Int(loginTimeout / 60)
                if assetsReady() {
                    return .failure(
                        "Apple did not answer within \(minutes) minutes. The Apple assets are "
                            + "already prepared, so this was the sign-in request itself - retry, "
                            + "or try another network."
                    )
                }
                return .failure(
                    "Preparing Apple assets timed out after \(minutes) minutes\(progress). "
                        + "The first login downloads them from Apple (~20 minutes on a slow "
                        + "connection); ipatool cannot resume, so a retry starts over."
                )
            }
        }
        let raw = result.stderr.isEmpty ? output : result.stderr
        return .failure(parseError(raw))
    }

    static func lookupApp(bundleId: String) async -> ITunesLookupResult? {
        guard let url = URL(
            string: "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=us"
        ) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ITunesLookupResponse.self, from: data)
            return response.results.first
        } catch {
            return nil
        }
    }

    static func revoke() async {
        _ = try? await Shell.run("ipatool", arguments: ["auth", "revoke"], timeout: 10)
    }

    static func purchase(bundleId: String) async -> (succeeded: Bool, error: String?) {
        print("[AppStore] purchase: \(bundleId)")
        guard let result = try? await Shell.run(
            "ipatool",
            arguments: ["purchase", "-b", bundleId, "--format", "json"],
            timeout: storeRequestTimeout
        ) else {
            print("[AppStore] purchase: failed to run ipatool")
            return (false, "failed to run ipatool")
        }
        print("[AppStore] purchase: exit=\(result.exitCode) stdout=\(result.stdout) stderr=\(result.stderr)")
        if result.succeeded {
            return (true, nil)
        }
        let raw = result.stderr.isEmpty ? result.stdout : result.stderr
        return (false, parseError(raw))
    }

    static func listVersions(bundleId: String) async throws -> [String] {
        print("[AppStore] listVersions: \(bundleId)")

        // Try list-versions directly first (works if user already has license)
        var result = try await runListVersions(bundleId: bundleId)

        // Only a missing license is fixed by purchasing. A timeout or any other failure used
        // to take this path too, which doubled the wait and then reported the retry's
        // timeout instead of the real problem.
        if !result.succeeded, result.stopReason == nil,
           Self.parseError(failureOutput(result)).localizedCaseInsensitiveContains("license is required") {
            print("[AppStore] listVersions: no license, attempting purchase...")
            let purchaseResult = await purchase(bundleId: bundleId)
            if purchaseResult.succeeded {
                result = try await runListVersions(bundleId: bundleId)
            } else if let purchaseError = purchaseResult.error,
                      AppState.looksLikeAuthError(purchaseError) {
                // Auth error from purchase — trigger re-login
                throw NSError(domain: "AppStore", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: purchaseError])
            } else {
                print("[AppStore] listVersions: purchase also failed: \(purchaseResult.error ?? "unknown")")
            }
        }

        guard result.succeeded else {
            throw NSError(domain: "AppStore", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: storeFailureMessage(result)])
        }

        let cleaned = result.stdout.strippingANSI
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            print("[AppStore] listVersions: failed to parse JSON from stdout: \(result.stdout)")
            return []
        }

        print("[AppStore] listVersions: JSON keys=\(Array(json.keys))")

        guard let ids = json["externalVersionIdentifiers"] as? [Any] else {
            print("[AppStore] listVersions: no externalVersionIdentifiers, full JSON: \(json)")
            return []
        }

        print("[AppStore] listVersions: found \(ids.count) versions")
        return ids.compactMap {
            if let str = $0 as? String { return str }
            if let num = $0 as? NSNumber { return num.stringValue }
            return nil
        }
    }

    private static func runListVersions(bundleId: String) async throws -> ShellResult {
        let result = try await Shell.run(
            "ipatool",
            arguments: ["list-versions", "-b", bundleId, "--format", "json"],
            timeout: storeRequestTimeout
        )
        print("[AppStore] listVersions: exit=\(result.exitCode) stdout=\(result.stdout) stderr=\(result.stderr)")
        return result
    }

    private static func failureOutput(_ result: ShellResult) -> String {
        result.stderr.isEmpty ? result.stdout : result.stderr
    }

    /// A killed child only reports SIGTERM, and whatever ipatool printed before that is an
    /// info line, not the cause - so name what actually happened.
    private static func storeFailureMessage(_ result: ShellResult) -> String {
        switch result.stopReason {
        case .timeout:
            return "Apple did not respond within \(Int(storeRequestTimeout)) seconds. "
                + "ipatool 2.8.0 needs about a minute per request, so retry, or try another network."
        case .cancelled:
            return "Cancelled."
        case nil:
            return parseError(failureOutput(result))
        }
    }

    /// Returns nil when ipatool answered but had no display version or release date for
    /// this build (a final answer), and throws when the call itself failed, timed out or
    /// was cancelled, so the caller can try again later instead of caching "nothing".
    static func getVersionMetadata(
        bundleId: String, versionId: String
    ) async throws -> VersionMetadata? {
        let result = try await Shell.run(
            "ipatool",
            arguments: [
                "get-version-metadata", "-b", bundleId,
                "--external-version-id", versionId, "--format", "json",
            ],
            timeout: storeRequestTimeout
        )
        try Task.checkCancellation()
        guard result.succeeded else {
            throw NSError(domain: "AppStore", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: storeFailureMessage(result)])
        }
        guard let data = result.stdout.strippingANSI.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "AppStore", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Unreadable ipatool output: \(result.stdout)",
            ])
        }

        let displayVersion = (json["displayVersion"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let releaseDate = (json["releaseDate"] as? String).flatMap(parseReleaseDate)
        guard displayVersion != nil || releaseDate != nil else { return nil }
        return VersionMetadata(displayVersion: displayVersion, releaseDate: releaseDate)
    }

    /// ipatool emits RFC3339 timestamps; unknown dates arrive as the zero time
    /// (`0001-01-01T00:00:00Z`) and must not be shown as a release date.
    private static func parseReleaseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = fractional.date(from: raw) ?? plain.date(from: raw),
              date.timeIntervalSince1970 > 0
        else { return nil }
        return date
    }

    static func download(
        bundleId: String,
        versionId: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDowngrader", isDirectory: true).path

        try? FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true
        )

        // Clean up old IPAs for this bundle
        if let files = try? FileManager.default.contentsOfDirectory(atPath: outputDir) {
            for file in files where file.contains(bundleId) && file.hasSuffix(".ipa") {
                try? FileManager.default.removeItem(
                    atPath: (outputDir as NSString).appendingPathComponent(file)
                )
            }
        }

        var args = ["download", "-b", bundleId, "-o", outputDir, "--purchase"]
        if let vid = versionId, !vid.isEmpty {
            args += ["--external-version-id", vid]
        }

        let result = try await Shell.runWithProgress(
            "ipatool", arguments: args, timeout: 600
        ) { output in
            // Parse "downloading  XX%" from ipatool's progress output
            guard let range = output.range(
                of: #"(\d+)%"#, options: .regularExpression
            ) else { return }
            let match = output[range].dropLast() // remove "%"
            if let pct = Double(match) {
                onProgress?(pct / 100.0)
            }
        }

        guard result.succeeded else {
            let raw = result.stderr.isEmpty ? result.stdout : result.stderr
            throw NSError(domain: "AppStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: Self.parseError(raw)])
        }

        // Find the downloaded IPA
        if let files = try? FileManager.default.contentsOfDirectory(atPath: outputDir),
           let ipa = files.first(where: { $0.hasSuffix(".ipa") }) {
            return (outputDir as NSString).appendingPathComponent(ipa)
        }

        throw NSError(domain: "AppStore", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "IPA file not found after download"])
    }

    /// Extract human-readable error from ipatool's JSON or text output.
    ///
    /// ipatool (zerolog) writes one JSON object per line: an informational
    /// "preparing authentication" line followed by the actual error result.
    /// Decoding the whole stream as a single JSON document therefore failed and
    /// the UI used to show the raw log lines (including the info line in red).
    private static func parseError(_ raw: String) -> String {
        let lines = raw.strippingANSI
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Newest entry first: the error is the last structured record.
        for line in lines.reversed() {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let error = json["error"] as? String, !error.isEmpty {
                return error
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
        }

        return lines.isEmpty ? raw.strippingANSI : lines.joined(separator: "\n")
    }
}
