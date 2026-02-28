import Foundation

final class MACCacheStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let newDir = appSupport.appendingPathComponent("Samsung Frame Remote", isDirectory: true)
        let legacyDir = appSupport.appendingPathComponent("FrameMacApp", isDirectory: true)
        let newURL = newDir.appendingPathComponent("mac_cache.json")
        let legacyURL = legacyDir.appendingPathComponent("mac_cache.json")

        if !FileManager.default.fileExists(atPath: newURL.path),
           FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: legacyURL, to: newURL)
        }

        self.fileURL = newURL
    }

    func get(for ip: String) -> String? {
        let cache = loadCache()
        return cache[ip]
    }

    func set(_ mac: String, for ip: String) {
        var cache = loadCache()
        cache[ip] = mac
        saveCache(cache)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadCache() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func saveCache(_ cache: [String: String]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let data = try? JSONSerialization.data(withJSONObject: cache, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }

        try? data.write(to: fileURL, options: .atomic)
    }
}
