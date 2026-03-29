import Foundation

enum AppStoreService {
    static func isAuthenticated() async -> Bool {
        guard let result = try? await Shell.run("ipatool", arguments: ["auth", "info"]) else {
            return false
        }
        return result.succeeded
    }

    static func login(email: String, password: String, authCode: String? = nil) async throws -> Bool {
        var args = ["auth", "login", "-e", email, "-p", password]
        if let code = authCode, !code.isEmpty {
            args += ["--auth-code", code]
        }
        let result = try await Shell.run("ipatool", arguments: args)
        return result.succeeded
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

    static func listVersions(bundleId: String) async throws -> [String] {
        let result = try await Shell.run(
            "ipatool",
            arguments: ["list-versions", "-b", bundleId, "--format", "json"],
            timeout: 30
        )
        guard result.succeeded else {
            let raw = result.stderr.isEmpty ? result.stdout : result.stderr
            throw NSError(domain: "AppStore", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: Self.parseError(raw)])
        }

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = json["externalVersionIdentifiers"] as? [Any]
        else { return [] }

        return ids.compactMap {
            if let str = $0 as? String { return str }
            if let num = $0 as? NSNumber { return num.stringValue }
            return nil
        }
    }

    struct VersionMetadata {
        let version: String?
        let releaseDate: String?
    }

    static func getVersionMetadata(
        bundleId: String, versionId: String
    ) async -> VersionMetadata {
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
        else { return VersionMetadata(version: nil, releaseDate: nil) }

        return VersionMetadata(
            version: json["displayVersion"] as? String,
            releaseDate: json["releaseDate"] as? String
        )
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
