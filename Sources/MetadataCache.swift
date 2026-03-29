import Foundation

/// Disk-backed cache for immutable version metadata.
/// Stored at ~/Library/Caches/AppDowngrader/version-metadata.json
actor MetadataCache {
    static let shared = MetadataCache()

    private struct Entry: Codable {
        let version: String?
        let releaseDate: String?
    }

    private var cache: [String: Entry] = [:]
    private let fileURL: URL

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppDowngrader", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("version-metadata.json")
        fileURL = url

        // Load cache inline (init is nonisolated, so can't call actor method)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            cache = decoded
        }
    }

    func get(_ versionId: String) -> (version: String?, releaseDate: String?)? {
        guard let entry = cache[versionId] else { return nil }
        return (entry.version, entry.releaseDate)
    }

    func set(_ versionId: String, version: String?, releaseDate: String?) {
        cache[versionId] = Entry(version: version, releaseDate: releaseDate)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        cache = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
