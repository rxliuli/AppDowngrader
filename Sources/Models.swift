import Foundation

struct Device: Identifiable, Hashable {
    let id: String // UDID
    let name: String
    let productType: String
    let iosVersion: String
}

struct InstalledApp: Identifiable, Hashable {
    var id: String { bundleId }
    let bundleId: String
    let name: String
    let version: String
}

struct DependencyStatus {
    var ipatool: Bool = false
    var ideviceinstaller: Bool = false
    var ideviceId: Bool = false
    var ideviceinfo: Bool = false

    var allSatisfied: Bool {
        ipatool && ideviceinstaller && ideviceId && ideviceinfo
    }

    var missingTools: [String] {
        var missing: [String] = []
        if !ipatool { missing.append("ipatool") }
        if !ideviceinstaller { missing.append("ideviceinstaller") }
        if !ideviceId { missing.append("idevice_id (libimobiledevice)") }
        if !ideviceinfo { missing.append("ideviceinfo (libimobiledevice)") }
        return missing
    }
}

struct AppVersion: Identifiable, Hashable {
    let id: String // external version identifier
    var version: String? // human-readable version string (e.g. "2.0.1")
    var releaseDate: String? // ISO date string
    var metadataLoaded = false

    var displayName: String {
        if let version { return "v\(version)" }
        return "Build \(id)"
    }

    var formattedDate: String? {
        guard let releaseDate else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: releaseDate) else { return nil }
        let display = DateFormatter()
        display.dateFormat = "yyyy-MM-dd"
        return display.string(from: date)
    }
}

enum TaskStatus: Equatable {
    case idle
    case loading(String)
    case success(String)
    case error(String)
}

// MARK: - iTunes API Models

struct ITunesLookupResponse: Codable {
    let resultCount: Int
    let results: [ITunesLookupResult]
}

struct ITunesLookupResult: Codable {
    let trackId: Int?
    let trackName: String?
    let bundleId: String?
    let version: String?
    let minimumOsVersion: String?
    let fileSizeBytes: String?
    let artworkUrl100: String?
    let artworkUrl512: String?
}
