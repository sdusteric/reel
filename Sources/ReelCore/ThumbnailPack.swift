import Foundation

/// One seek-bar thumbnail: a JPEG with the pts of the keyframe it shows.
public struct ThumbnailImage: Sendable, Hashable {
    public var jpeg: Data
    public var pts: MediaTime
    /// Pixel size of the JPEG.
    public var width: Int
    public var height: Int

    public init(jpeg: Data, pts: MediaTime, width: Int, height: Int) {
        self.jpeg = jpeg
        self.pts = pts
        self.width = width
        self.height = height
    }
}

public enum ThumbnailPackError: Error, Sendable, Hashable, LocalizedError {
    case badMagic
    case unsupportedVersion(UInt32)
    case truncated
    case badIndex(String)

    public var errorDescription: String? {
        switch self {
        case .badMagic: "Not a Reel thumbnail pack."
        case .unsupportedVersion(let version): "Thumbnail pack version \(version) is not supported."
        case .truncated: "The thumbnail pack is truncated."
        case .badIndex(let reason): "The thumbnail pack index is invalid: \(reason)."
        }
    }
}

/// The thumbnails of one file in one pack (design section 11.3). Little-endian layout:
///
///     magic "REELTHMB" (8), version u32, width u32, height u32, count u32,
///     count x (pts i64 microseconds, offset u64 from the file start, length u32),
///     JPEG blobs.
///
/// Entries are sorted by pts. Loading reads only the header and index; blobs are sliced from the
/// (memory-mapped) data on demand, so a reload costs about one page fault per thumbnail shown.
public struct ThumbnailPack: Sendable {
    public struct Entry: Sendable, Hashable {
        public var pts: MediaTime
        public var offset: Int
        public var length: Int
    }

    public static let magic = Data("REELTHMB".utf8)
    public static let version: UInt32 = 1
    public static let headerSize = 24
    public static let indexEntrySize = 20
    /// At most this many thumbnails per file (D38).
    public static let maximumCount = 400
    public static let standardWidth = 384
    public static let standardHeight = 216
    public static let fileExtension = "thumbs"

    public let width: Int
    public let height: Int
    public let entries: [Entry]
    private let data: Data

    /// Builds a pack from JPEGs keyed by keyframe pts. Duplicate pts keep the last image.
    public init(width: Int, height: Int, images: [(pts: MediaTime, jpeg: Data)]) {
        var unique: [MediaTime: Data] = [:]
        for image in images { unique[image.pts] = image.jpeg }
        let sorted = unique.sorted { $0.key < $1.key }
        var output = Data()
        output.append(ThumbnailPack.magic)
        ThumbnailPack.append(&output, UInt32(ThumbnailPack.version))
        ThumbnailPack.append(&output, UInt32(width))
        ThumbnailPack.append(&output, UInt32(height))
        ThumbnailPack.append(&output, UInt32(sorted.count))
        var offset = ThumbnailPack.headerSize + sorted.count * ThumbnailPack.indexEntrySize
        var entries: [Entry] = []
        for (pts, jpeg) in sorted {
            ThumbnailPack.append(&output, UInt64(bitPattern: pts.microseconds))
            ThumbnailPack.append(&output, UInt64(offset))
            ThumbnailPack.append(&output, UInt32(jpeg.count))
            entries.append(Entry(pts: pts, offset: offset, length: jpeg.count))
            offset += jpeg.count
        }
        for (_, jpeg) in sorted { output.append(jpeg) }
        self.width = width
        self.height = height
        self.entries = entries
        self.data = output
    }

    /// Parses a pack, validating the header and that every blob lies inside `data`.
    public init(data: Data) throws {
        let bytes = data
        guard bytes.count >= ThumbnailPack.headerSize else { throw ThumbnailPackError.truncated }
        guard bytes.prefix(8) == ThumbnailPack.magic else { throw ThumbnailPackError.badMagic }
        let version: UInt32 = ThumbnailPack.read(bytes, at: 8)
        guard version == ThumbnailPack.version else { throw ThumbnailPackError.unsupportedVersion(version) }
        let width = Int(ThumbnailPack.read(bytes, at: 12) as UInt32)
        let height = Int(ThumbnailPack.read(bytes, at: 16) as UInt32)
        let count = Int(ThumbnailPack.read(bytes, at: 20) as UInt32)
        let indexEnd = ThumbnailPack.headerSize + count * ThumbnailPack.indexEntrySize
        guard bytes.count >= indexEnd else { throw ThumbnailPackError.truncated }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var previous: MediaTime?
        for index in 0..<count {
            let base = ThumbnailPack.headerSize + index * ThumbnailPack.indexEntrySize
            let pts = MediaTime(microseconds: Int64(bitPattern: ThumbnailPack.read(bytes, at: base) as UInt64))
            let offset = Int(clamping: ThumbnailPack.read(bytes, at: base + 8) as UInt64)
            let length = Int(ThumbnailPack.read(bytes, at: base + 16) as UInt32)
            guard offset >= indexEnd, length > 0, offset <= bytes.count - length else {
                throw ThumbnailPackError.badIndex("entry \(index) points outside the file")
            }
            if let previous, pts <= previous { throw ThumbnailPackError.badIndex("entries are not sorted by pts") }
            previous = pts
            entries.append(Entry(pts: pts, offset: offset, length: length))
        }
        self.width = width
        self.height = height
        self.entries = entries
        self.data = bytes
    }

    /// Loads a pack file, memory-mapped.
    public static func load(contentsOf url: URL) throws -> ThumbnailPack {
        try ThumbnailPack(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    /// The encoded file.
    public var encoded: Data { data }

    /// Writes to a temp file next to `url` and renames it into place.
    public func write(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))", directoryHint: .notDirectory)
        try data.write(to: temp)
        if rename(temp.path(percentEncoded: false), url.path(percentEncoded: false)) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public var count: Int { entries.count }

    public func image(at index: Int) -> ThumbnailImage {
        let entry = entries[index]
        let start = data.startIndex + entry.offset
        return ThumbnailImage(jpeg: data.subdata(in: start..<(start + entry.length)), pts: entry.pts, width: width, height: height)
    }

    /// The index of the last thumbnail at or before `time`; the first when `time` precedes all.
    public func index(atOrBefore time: MediaTime) -> Int? {
        ThumbnailPack.lastIndex(atOrBefore: time, in: entries.map(\.pts))
    }

    public func thumbnail(atOrBefore time: MediaTime) -> ThumbnailImage? {
        index(atOrBefore: time).map(image(at:))
    }

    /// Binary search over sorted times.
    static func lastIndex(atOrBefore time: MediaTime, in sorted: [MediaTime]) -> Int? {
        guard !sorted.isEmpty else { return nil }
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T {
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { buffer in
            let start = data.startIndex + offset
            data.copyBytes(to: buffer, from: start..<(start + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }
}

/// Which keyframes get thumbnails, and in what order (design section 9.4, D38).
public struct ThumbnailPlan: Sendable, Hashable {
    /// Chosen keyframe pts, ascending.
    public let times: [MediaTime]
    /// Indices into `times` in generation order: every 8th first, then every 4th, 2nd, the rest.
    public let order: [Int]

    /// Chooses at most `maximumCount` keyframes: the keyframe at or before each of that many
    /// evenly spaced times, duplicates dropped, topped up evenly when duplicates left gaps, so the
    /// count is always `min(keyframes, maximumCount)`.
    public init(keyframes: [MediaTime], duration: MediaTime?, maximumCount: Int = ThumbnailPack.maximumCount) {
        let sorted = Array(Set(keyframes)).sorted()
        guard maximumCount > 0, !sorted.isEmpty else {
            times = []
            order = []
            return
        }
        if sorted.count <= maximumCount {
            times = sorted
        } else {
            let first = sorted[0]
            let last = sorted[sorted.count - 1]
            let end = max(duration ?? last, last)
            let span = Double((end - first).microseconds)
            var chosen = Set<Int>()
            for step in 0..<maximumCount {
                let target = first + MediaTime(microseconds: Int64(span * Double(step) / Double(maximumCount)))
                if let index = ThumbnailPack.lastIndex(atOrBefore: target, in: sorted) { chosen.insert(index) }
            }
            let missing = maximumCount - chosen.count
            if missing > 0 {
                let unused = (0..<sorted.count).filter { !chosen.contains($0) }
                let stride = Double(unused.count) / Double(missing)
                for step in 0..<missing {
                    chosen.insert(unused[min(Int(stride * (Double(step) + 0.5)), unused.count - 1)])
                }
                for index in unused where chosen.count < maximumCount {
                    chosen.insert(index)
                }
            }
            times = chosen.sorted().map { sorted[$0] }
        }
        order = ThumbnailPlan.coarseToFine(count: times.count)
    }

    public var count: Int { times.count }

    /// Generation order for `count` slots: strides 8, 4, 2, then 1.
    public static func coarseToFine(count: Int) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        result.reserveCapacity(count)
        for stride in [8, 4, 2, 1] {
            for index in Swift.stride(from: 0, to: count, by: stride) where seen.insert(index).inserted {
                result.append(index)
            }
        }
        return result
    }

    /// The slot whose keyframe a hover at `time` shows: the last at or before it.
    public func slot(for time: MediaTime) -> Int? {
        ThumbnailPack.lastIndex(atOrBefore: time, in: times)
    }
}
