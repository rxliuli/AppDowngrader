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

/// Per-version metadata read from the IPA itself (`ipatool get-version-metadata`).
struct VersionMetadata: Codable, Hashable {
    var displayVersion: String?
    var releaseDate: Date?
}

struct AppVersion: Identifiable, Hashable {
    let id: String // external version identifier
    var version: String? // human-readable version string (e.g. "2.0.1")
    var releaseDate: Date? // App Store release date, nil until metadata loads
    var metadataLoaded = false
    /// The last metadata request failed (timeout, network, ...). Not final: the row
    /// retries when it reappears or when the user asks.
    var metadataFailed = false

    var displayName: String {
        if let version { return "v\(version)" }
        return "Build \(id)"
    }

    /// Secondary line: raw external ID plus the release date once it is known.
    var detailsText: String {
        var parts = ["ID: \(id)"]
        if let releaseDate {
            parts.append("Released \(Self.dayFormatter.string(from: releaseDate))")
        }
        return parts.joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // A version's identity is its external version ID. Metadata (display version,
    // release date) arrives later and must not change the List selection tag.
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
