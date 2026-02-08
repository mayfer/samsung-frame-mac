import Foundation

final class MACCacheStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = appSupport.appendingPathComponent("FrameMacApp", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("mac_cache.json")
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
