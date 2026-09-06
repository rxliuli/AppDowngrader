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

    static func login(email: String, password: String, authCode: String? = nil) async throws -> LoginResult {
        var args = ["auth", "login", "-e", email, "-p", password,
                    "--format", "json", "--non-interactive"]
        if let code = authCode, !code.isEmpty {
            args += ["--auth-code", code]
        }
        // First login may take a few minutes: ipatool downloads & sets up the
        // SAP/Unicorn runtime on first run, so use a generous timeout.
        let result = try await Shell.run("ipatool", arguments: args, timeout: 300)
        print("[AppStore] login: exit=\(result.exitCode) stdout=\(result.stdout) stderr=\(result.stderr)")
        // ipatool returns exit=0 with a "message" field when 2FA is needed
        let output = result.stdout
        if output.contains("2FA") || output.contains("--auth-code") {
            return .requires2FA
        }
        if result.succeeded {
            return .success
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
            timeout: 30
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
        var result = try await Shell.run(
            "ipatool",
            arguments: ["list-versions", "-b", bundleId, "--format", "json"],
            timeout: 30
        )
        print("[AppStore] listVersions: exit=\(result.exitCode) stdout=\(result.stdout) stderr=\(result.stderr)")

        // If failed, try purchase + retry
        if !result.succeeded {
            print("[AppStore] listVersions: failed, attempting purchase...")
            let purchaseResult = await purchase(bundleId: bundleId)
            if purchaseResult.succeeded {
                result = try await Shell.run(
                    "ipatool",
                    arguments: ["list-versions", "-b", bundleId, "--format", "json"],
                    timeout: 30
                )
                print("[AppStore] listVersions retry: exit=\(result.exitCode) stdout=\(result.stdout) stderr=\(result.stderr)")
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
            let raw = result.stderr.isEmpty ? result.stdout : result.stderr
            throw NSError(domain: "AppStore", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: Self.parseError(raw)])
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

    static func getVersionMetadata(
        bundleId: String, versionId: String
    ) async -> String? {
        guard let result = try? await Shell.run(
            "ipatool",
            arguments: [
                "get-version-metadata", "-b", bundleId,
                "--external-version-id", versionId, "--format", "json",
            ],
            timeout: 15
        ), result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return json["displayVersion"] as? String
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
    private static func parseError(_ raw: String) -> String {
        let cleaned = raw.strippingANSI
        // Try to parse as JSON and extract "error" field
        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String {
            return error
        }
        return cleaned
    }
}
