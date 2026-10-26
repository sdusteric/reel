import Foundation
import Synchronization

/// The status file Shelf reads (Shelf design section 14): `status/reel.json`. Only the title the
/// user already sees, the time left and the position. No paths, URLs, file names or hashes.
public struct ShelfStatus: Codable, Sendable, Equatable {
    public static let schema = 1
    public static let appName = "reel"
    public static let maxTitleLength = 80
    /// Shelf ignores a file over this size.
    public static let maxFileBytes = 16 * 1024

    public var schema: Int
    public var app: String
    public var appVersion: String
    /// UTC, ISO 8601, whole seconds.
    public var updatedAt: String
    public var resumeTitle: String
    public var remainingSeconds: Int
    /// 0 to 1.
    public var positionFraction: Double
    /// Where the preview is, relative to the status folder. Present only while `poster.jpg` exists.
    public var poster: String?

    public init(
        appVersion: String,
        updatedAt: Date,
        title: String,
        position: Double,
        duration: Double,
        poster: String? = nil
    ) {
        schema = ShelfStatus.schema
        app = ShelfStatus.appName
        self.appVersion = appVersion
        self.updatedAt = ShelfStatus.timestamp(updatedAt)
        resumeTitle = ShelfStatus.cut(title)
        let safeDuration = duration.isFinite ? max(duration, 0) : 0
        let safePosition = position.isFinite ? min(max(position, 0), safeDuration) : 0
        remainingSeconds = Int((safeDuration - safePosition).rounded())
        positionFraction = safeDuration > 0 ? (safePosition / safeDuration * 10_000).rounded() / 10_000 : 0
        self.poster = poster
    }

    enum CodingKeys: String, CodingKey {
        case schema, app, poster
        case appVersion = "app_version"
        case updatedAt = "updated_at"
        case resumeTitle = "resume_title"
        case remainingSeconds = "remaining_seconds"
        case positionFraction = "position_fraction"
    }

    /// At most 80 characters, whitespace trimmed.
    public static func cut(_ title: String) -> String {
        var trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The title is often the file name; Shelf shows it without the extension.
        let ext = (trimmed as NSString).pathExtension
        if (2...4).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            trimmed = (trimmed as NSString).deletingPathExtension
        }
        return String(trimmed.prefix(maxTitleLength))
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum ShelfStatusError: Error, Equatable {
    case posterTooLarge(Int)
    case statusTooLarge(Int)
    case writeFailed(String)
}

/// Writes `reel.json` and the optional `reel/poster.jpg` into Shelf's status folder. The folder is
/// always injected (`ReelEnvironment.shelfStatusDirectory`), so tests and tools point it at a temp dir.
public final class ShelfStatusWriter: Sendable {
    public static let posterFolder = "reel"
    public static let posterName = "poster.jpg"
    public static let maxPosterWidth = 240
    public static let maxPosterBytes = 30 * 1024

    public let directory: URL
    private let appVersion: String
    private let now: @Sendable () -> Date
    private struct State {
        var hasPoster = false
        var lastBody: ShelfStatus?
    }
    private let state = Mutex(State())

    public init(directory: URL, appVersion: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory.standardizedFileURL
        self.appVersion = appVersion
        self.now = now
    }

    public var statusFile: URL { directory.appending(path: "reel.json", directoryHint: .notDirectory) }
    public var posterFile: URL {
        directory.appending(path: "\(Self.posterFolder)/\(Self.posterName)", directoryHint: .notDirectory)
    }

    public var hasPoster: Bool { state.withLock { $0.hasPoster } }

    /// Writes the status for the open file. A write with the same values as the last one is skipped.
    @discardableResult
    public func write(title: String, position: Double, duration: Double) throws -> Bool {
        let poster = state.withLock { $0.hasPoster }
            ? "\(Self.posterFolder)/\(Self.posterName)" : nil
        let status = ShelfStatus(
            appVersion: appVersion, updatedAt: now(), title: title,
            position: position, duration: duration, poster: poster
        )
        let unchanged = state.withLock { last in
            guard var previous = last.lastBody else { return false }
            previous.updatedAt = status.updatedAt
            return previous == status
        }
        if unchanged { return false }
        let data = try status.encoded()
        guard data.count <= ShelfStatus.maxFileBytes else { throw ShelfStatusError.statusTooLarge(data.count) }
        try Self.atomicWrite(data, to: statusFile)
        state.withLock { $0.lastBody = status }
        return true
    }

    /// Writes `reel/poster.jpg`. The caller has already checked the preview setting.
    public func writePoster(_ jpeg: Data) throws {
        guard jpeg.count <= Self.maxPosterBytes else { throw ShelfStatusError.posterTooLarge(jpeg.count) }
        try Self.atomicWrite(jpeg, to: posterFile)
        state.withLock { $0.hasPoster = true }
    }

    /// Deletes the poster (the setting turned off) and drops the `poster` field from the next status.
    public func removePoster() {
        try? FileManager.default.removeItem(at: posterFile)
        state.withLock {
            $0.hasPoster = false
            $0.lastBody = nil
        }
    }

    /// Temp file in the same folder, fsync, rename over the target, mode 0600.
    static func atomicWrite(_ data: Data, to target: URL) throws {
        let folder = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appending(path: ".\(target.lastPathComponent).tmp", directoryHint: .notDirectory)
        let tempPath = temp.path(percentEncoded: false)
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw ShelfStatusError.writeFailed("open: \(String(cString: strerror(errno)))") }
        var failure: String?
        if fchmod(fd, 0o600) != 0 { failure = "chmod: \(String(cString: strerror(errno)))" }
        if failure == nil {
            let ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
            if !ok { failure = "write: \(String(cString: strerror(errno)))" }
        }
        if failure == nil, fsync(fd) != 0 { failure = "fsync: \(String(cString: strerror(errno)))" }
        close(fd)
        if failure == nil, rename(tempPath, target.path(percentEncoded: false)) != 0 {
            failure = "rename: \(String(cString: strerror(errno)))"
        }
        if let failure {
            unlink(tempPath)
            throw ShelfStatusError.writeFailed(failure)
        }
    }
}
