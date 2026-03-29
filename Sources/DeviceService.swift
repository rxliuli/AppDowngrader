import Foundation

enum DeviceService {
    static func listDeviceUDIDs() async -> [String] {
        guard let result = try? await Shell.run("idevice_id", arguments: ["-l"]),
              result.succeeded else { return [] }
        return result.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    static func getDeviceInfo(udid: String) async throws -> Device {
        let result = try await Shell.run("ideviceinfo", arguments: ["-u", udid, "-s"])
        guard result.succeeded else {
            throw NSError(domain: "DeviceService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }

        var name = udid
        var productType = "Unknown"
        var iosVersion = "Unknown"

        for line in result.stdout.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "DeviceName": name = parts[1]
            case "ProductType": productType = parts[1]
            case "ProductVersion": iosVersion = parts[1]
            default: break
            }
        }

        return Device(id: udid, name: name, productType: productType, iosVersion: iosVersion)
    }

    static func listInstalledApps(udid: String) async throws -> [InstalledApp] {
        let result = try await Shell.run(
            "ideviceinstaller",
            arguments: ["-u", udid, "list", "--user"]
        )
        guard result.succeeded else {
            throw NSError(domain: "DeviceService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }

        var apps: [InstalledApp] = []
        let lines = result.stdout.components(separatedBy: .newlines)

        for line in lines.dropFirst() { // skip header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Format: "com.example.app, \"1.0\", \"App Name\""
            let parts = trimmed.components(separatedBy: ", ")
            guard parts.count >= 3 else { continue }

            let bundleId = parts[0]
            let version = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let name = parts.dropFirst(2).joined(separator: ", ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            apps.append(InstalledApp(bundleId: bundleId, name: name, version: version))
        }

        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func uninstallApp(udid: String, bundleId: String) async throws {
        let result = try await Shell.run(
            "ideviceinstaller",
            arguments: ["-u", udid, "uninstall", bundleId],
            timeout: 30
        )
        guard result.succeeded else {
            throw NSError(domain: "DeviceService", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: result.stderr.strippingANSI])
        }
    }

    static func installIPA(udid: String, path: String) async throws {
        let result = try await Shell.run(
            "ideviceinstaller", arguments: ["-u", udid, "install", path],
            timeout: 600
        )
        guard result.succeeded else {
            throw NSError(domain: "DeviceService", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: result.stderr.strippingANSI])
        }
    }
}
