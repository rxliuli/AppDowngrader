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
    var goIos: Bool = false

    var allSatisfied: Bool {
        ipatool && goIos
    }

    var missingTools: [String] {
        var missing: [String] = []
        if !ipatool { missing.append("ipatool") }
        if !goIos { missing.append("go-ios") }
        return missing
    }
}

struct AppVersion: Identifiable, Hashable {
    let id: String // external version identifier
    var version: String? // human-readable version string (e.g. "2.0.1")
    var metadataLoaded = false

    var displayName: String {
        if let version { return "v\(version)" }
        return "Build \(id)"
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
