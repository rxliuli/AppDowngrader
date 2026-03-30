import Foundation

/// Disk-backed cache for immutable version metadata.
/// Stored at ~/Library/Caches/AppDowngrader/version-metadata.json
actor MetadataCache {
    static let shared = MetadataCache()

    private var cache: [String: String] = [:] // versionId -> displayVersion

    private let fileURL: URL

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppDowngrader", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("version-metadata.json")
        fileURL = url

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = decoded
        }
    }

    func get(_ versionId: String) -> String? {
        cache[versionId]
    }

    func set(_ versionId: String, version: String) {
        cache[versionId] = version
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
