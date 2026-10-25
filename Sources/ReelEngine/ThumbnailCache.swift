import Foundation
import ReelCore

/// Thumbnail packs on disk (design sections 9.4 and 11.3): one pack per content key in
/// `REEL_HOME/Caches/thumbnails`, written atomically, evicted oldest-first above the byte cap.
///
/// A finished pack is `<key>.thumbs`. A generation that stops early (the file was closed) leaves
/// `<key>.partial`, in the same format, which the next generation for that key resumes from.
/// Loading a pack touches its modification date, so eviction removes the least recently used.
public struct ThumbnailCache: Sendable {
    /// 500 MB (D38).
    public static let defaultByteLimit: Int64 = 500_000_000
    public static let partialExtension = "partial"
    /// Temp files a crashed write left behind are removed once they are this old.
    static let staleTempAge: TimeInterval = 3_600

    public let directory: URL
    public let byteLimit: Int64

    public init(directory: URL, byteLimit: Int64 = ThumbnailCache.defaultByteLimit) {
        self.directory = directory.standardizedFileURL
        self.byteLimit = byteLimit
    }

    public init(paths: ReelPaths, byteLimit: Int64 = ThumbnailCache.defaultByteLimit) {
        self.init(directory: paths.thumbnailsDirectory, byteLimit: byteLimit)
    }

    public func packURL(for key: ContentKey) -> URL {
        directory.appending(path: "\(key.hex).\(ThumbnailPack.fileExtension)", directoryHint: .notDirectory)
    }

    public func partialURL(for key: ContentKey) -> URL {
        directory.appending(path: "\(key.hex).\(ThumbnailCache.partialExtension)", directoryHint: .notDirectory)
    }

    /// The finished pack for `key`, memory-mapped. A pack that fails to parse is deleted.
    public func load(_ key: ContentKey) -> ThumbnailPack? {
        load(packURL(for: key))
    }

    /// The partial pack a stopped generation left for `key`.
    public func loadPartial(_ key: ContentKey) -> ThumbnailPack? {
        load(partialURL(for: key))
    }

    private func load(_ url: URL) -> ThumbnailPack? {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let pack = try ThumbnailPack.load(contentsOf: url)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
            return pack
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Writes `pack` for `key` (atomic rename), then evicts the oldest other packs above the cap.
    /// A complete pack replaces the partial one.
    public func store(_ pack: ThumbnailPack, for key: ContentKey, complete: Bool) throws {
        if complete {
            try pack.write(to: packURL(for: key))
            try? FileManager.default.removeItem(at: partialURL(for: key))
        } else {
            try pack.write(to: partialURL(for: key))
        }
        evict(keeping: key)
    }

    /// Deletes both packs of `key`.
    public func remove(_ key: ContentKey) {
        try? FileManager.default.removeItem(at: packURL(for: key))
        try? FileManager.default.removeItem(at: partialURL(for: key))
    }

    struct File {
        var url: URL
        var bytes: Int64
        var modified: Date
        var key: String
    }

    /// Pack files (finished and partial) in the directory.
    func files() -> [File] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        let now = Date()
        var result: [File] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.contains(".tmp-") {
                if now.timeIntervalSince(modified) > ThumbnailCache.staleTempAge { try? FileManager.default.removeItem(at: url) }
                continue
            }
            let fileExtension = url.pathExtension
            guard fileExtension == ThumbnailPack.fileExtension || fileExtension == ThumbnailCache.partialExtension else { continue }
            result.append(File(url: url, bytes: Int64(values.fileSize ?? 0), modified: modified, key: url.deletingPathExtension().lastPathComponent))
        }
        return result
    }

    /// Bytes used by every pack in the directory.
    public var totalBytes: Int64 {
        files().reduce(0) { $0 + $1.bytes }
    }

    /// Removes the least recently used packs until the total is at most `byteLimit`. The packs of
    /// `keeping` are never removed. Returns the removed files.
    @discardableResult
    public func evict(keeping key: ContentKey? = nil) -> [URL] {
        let all = files()
        var total = all.reduce(0) { $0 + $1.bytes }
        guard total > byteLimit else { return [] }
        var removed: [URL] = []
        for file in all.sorted(by: { $0.modified < $1.modified }) where total > byteLimit {
            if let key, file.key == key.hex { continue }
            do {
                try FileManager.default.removeItem(at: file.url)
                total -= file.bytes
                removed.append(file.url)
            } catch {
                continue
            }
        }
        return removed
    }
}
