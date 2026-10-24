import CryptoKit
import Foundation

/// Identity of a media file for resume (design section 11.2): SHA-256 of the file size, the
/// first 64 KiB and the last 64 KiB. It survives renames, moves and different mount points.
public struct ContentKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public static let sampleLength = 64 * 1024

    /// Lowercase hex SHA-256.
    public let hex: String

    public init(hex: String) {
        self.hex = hex
    }

    public var description: String { hex }

    /// Reads at most 128 KiB from `url`.
    public init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let sample = UInt64(ContentKey.sampleLength)
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: ContentKey.sampleLength) ?? Data()
        var tail = Data()
        if size > sample {
            try handle.seek(toOffset: size - min(size, sample))
            tail = try handle.read(upToCount: ContentKey.sampleLength) ?? Data()
        }
        self.init(size: size, head: head, tail: tail)
    }

    /// The key for a file of `size` bytes whose first and last 64 KiB are `head` and `tail`.
    /// For a file of 64 KiB or less the tail is empty, so the content is hashed once.
    public init(size: UInt64, head: Data, tail: Data) {
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: head)
        hasher.update(data: tail)
        self.hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
