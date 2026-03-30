import Foundation

enum DeviceService {
    /// Parse JSON from go-ios output, skipping warning/log lines.
    private static func parseJSON(_ output: String) -> Any? {
        // go-ios outputs warning/log lines before JSON; collect non-log content
        var jsonLines: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("{\"level\"") { continue }
            jsonLines.append(line)
        }

        let joined = jsonLines.joined(separator: "\n")
        guard let data = joined.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func listDeviceUDIDs() async -> [String] {
        guard let result = try? await Shell.run("ios", arguments: ["list"]),
              result.succeeded,
              let json = parseJSON(result.stdout) as? [String: Any],
              let list = json["deviceList"] as? [String]
        else { return [] }
        return list
    }

    static func getDeviceInfo(udid: String) async throws -> Device {
        // Get product type and version from list --details
        async let detailsResult = Shell.run(
            "ios", arguments: ["list", "--details", "--udid=\(udid)"]
        )
        // Get device name separately
        async let nameResult = Shell.run(
            "ios", arguments: ["devicename", "--udid=\(udid)"]
        )

        let details = try await detailsResult
        let nameRes = try await nameResult

        var productType = "Unknown"
        var iosVersion = "Unknown"

        if details.succeeded,
           let json = parseJSON(details.stdout) as? [String: Any],
           let list = json["deviceList"] as? [[String: Any]],
           let device = list.first {
            productType = device["ProductType"] as? String ?? "Unknown"
            iosVersion = device["ProductVersion"] as? String ?? "Unknown"
        }

        var name = udid
        if nameRes.succeeded,
           let json = parseJSON(nameRes.stdout) as? [String: Any],
           let deviceName = json["devicename"] as? String {
            name = deviceName
        }

        return Device(id: udid, name: name, productType: productType, iosVersion: iosVersion)
    }

    static func listInstalledApps(udid: String) async throws -> [InstalledApp] {
        let result = try await Shell.run(
            "ios", arguments: ["apps", "--udid=\(udid)"],
            timeout: 30
        )
        guard result.succeeded else {
            throw NSError(domain: "DeviceService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: result.stderr.strippingANSI])
        }

        // go-ios apps outputs a JSON array (possibly after warning lines)
        guard let apps = parseJSON(result.stdout) as? [[String: Any]]
        else { return [] }

        return apps
            .filter { ($0["ApplicationType"] as? String) == "User" }
            .compactMap { app -> InstalledApp? in
                guard let bundleId = app["CFBundleIdentifier"] as? String else { return nil }
                let name = app["CFBundleDisplayName"] as? String
                    ?? app["CFBundleName"] as? String
                    ?? bundleId
                let version = app["CFBundleShortVersionString"] as? String ?? "?"
                return InstalledApp(bundleId: bundleId, name: name, version: version)
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    static func uninstallApp(udid: String, bundleId: String) async throws {
        let result = try await Shell.run(
            "ios", arguments: ["uninstall", bundleId, "--udid=\(udid)"],
            timeout: 30
        )
        guard result.succeeded else {
            throw NSError(domain: "DeviceService", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: result.stderr.strippingANSI])
        }
    }

    static func installIPA(udid: String, path: String) async throws {
        let result = try await Shell.run(
            "ios", arguments: ["install", "--path=\(path)", "--udid=\(udid)"],
            timeout: 600
        )
        guard result.succeeded else {
            throw NSError(domain: "DeviceService", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: result.stderr.strippingANSI])
        }
    }
}
