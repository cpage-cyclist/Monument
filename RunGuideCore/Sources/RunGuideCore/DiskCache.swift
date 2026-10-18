import Foundation

/// Keeps raw API responses on disk so screens can open instantly from the last copy and
/// refresh in the background. Entries are stored as files named by a sanitised key, with
/// the file's modification date as the time it was saved.
public final class DiskCache: @unchecked Sendable {
    public let folder: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(folder: URL) {
        self.folder = folder
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The app's default cache, in Library/Caches (iOS may clear it when storage is low).
    public static func standard(named name: String = "Intervals") -> DiskCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return DiskCache(folder: caches.appendingPathComponent(name, isDirectory: true))
    }

    public struct Entry: Sendable {
        public let data: Data
        public let savedAt: Date

        public func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(savedAt) }
    }

    public func read(_ key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        let url = self.url(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let saved = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        return Entry(data: data, savedAt: saved)
    }

    public func write(_ data: Data, for key: String) {
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: url(for: key), options: .atomic)
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: url(for: key))
    }

    /// Deletes entries whose key starts with `prefix`, oldest first, until at most `keep` remain.
    public func trim(prefix: String, keep: Int) {
        lock.lock(); defer { lock.unlock() }
        let safePrefix = Self.fileName(for: prefix)
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let matching = files
            .filter { $0.lastPathComponent.hasPrefix(safePrefix) }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in matching.dropFirst(max(keep, 0)) {
            try? fileManager.removeItem(at: url)
        }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: folder)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func url(for key: String) -> URL {
        folder.appendingPathComponent(Self.fileName(for: key))
    }

    static func fileName(for key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

/// Cache keys, kept in one place so the app and tests agree.
public enum CacheKey {
    public static let activityList = "activities"
    public static let streamsPrefix = "streams-"
    public static let detailPrefix = "activity-"

    public static func streams(_ id: String) -> String { streamsPrefix + id }
    public static func detail(_ id: String) -> String { detailPrefix + id }
}
