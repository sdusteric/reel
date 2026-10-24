import Foundation
import Synchronization

private struct VersionProbe: Decodable { var version: Int }

/// A JSON document with a schema version, stored in one file.
public protocol VersionedDocument: Codable, Sendable, Equatable {
    static var currentVersion: Int { get }
    var version: Int { get }
}

/// What `load()` found.
public enum StoreLoadOutcome: Sendable, Equatable {
    /// No file yet: the defaults are in use.
    case missing
    case loaded
    /// The file did not decode. It was moved aside (never deleted) and the defaults are in use.
    case recovered(movedTo: URL)
    /// The file was written by a newer schema. It was moved aside and the defaults are in use.
    case newerVersion(movedTo: URL)
}

/// One JSON file with atomic writes, a minimum interval between writes, and recovery from a
/// corrupt file. The three Reel stores (settings, state, resume) share it.
///
/// A change is applied in memory first. `flushIfDue()` writes it when the interval has passed,
/// `flush()` writes it now (pause, close, quit). A failed write leaves the change pending, so
/// the next flush retries it, and the error reaches the caller.
final class DocumentStore<Document: VersionedDocument>: Sendable {
    private struct State {
        var document: Document
        var dirty = false
        var lastWrite: Date?
        var writeCount = 0
    }

    let fileURL: URL
    private let minimumWriteInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let state: Mutex<State>

    init(
        fileURL: URL,
        defaultDocument: Document,
        minimumWriteInterval: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.fileURL = fileURL
        self.minimumWriteInterval = minimumWriteInterval
        self.now = now
        self.state = Mutex(State(document: defaultDocument))
    }

    var document: Document { state.withLock { $0.document } }
    var hasPendingWrite: Bool { state.withLock { $0.dirty } }
    var writeCount: Int { state.withLock { $0.writeCount } }

    func load(defaultDocument: Document) throws -> StoreLoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            state.withLock { $0.document = defaultDocument }
            return .missing
        }
        let decoder = DocumentStore.makeDecoder()
        do {
            let probe = try decoder.decode(VersionProbe.self, from: data)
            if probe.version > Document.currentVersion {
                let moved = try moveAside(suffix: "newer")
                state.withLock { $0.document = defaultDocument }
                return .newerVersion(movedTo: moved)
            }
            let document = try decoder.decode(Document.self, from: data)
            state.withLock { $0.document = document; $0.dirty = false }
            return .loaded
        } catch is DecodingError {
            let moved = try moveAside(suffix: "corrupt")
            state.withLock { $0.document = defaultDocument; $0.dirty = false }
            return .recovered(movedTo: moved)
        }
    }

    /// Applies `body` to the document and marks it pending when it changed. Does not write.
    @discardableResult
    func mutate<Result>(_ body: (inout Document) -> Result) -> Result {
        state.withLock { state in
            var copy = state.document
            let result = body(&copy)
            if copy != state.document {
                state.document = copy
                state.dirty = true
            }
            return result
        }
    }

    /// Writes a pending change if the minimum interval since the last write has passed.
    /// Returns true when it wrote.
    @discardableResult
    func flushIfDue() throws -> Bool {
        try state.withLock { state in
            guard state.dirty else { return false }
            let current = now()
            if let last = state.lastWrite, current.timeIntervalSince(last) < minimumWriteInterval {
                return false
            }
            try write(&state, at: current)
            return true
        }
    }

    /// Writes a pending change now, ignoring the interval. Returns true when it wrote.
    @discardableResult
    func flush() throws -> Bool {
        try state.withLock { state in
            guard state.dirty else { return false }
            try write(&state, at: now())
            return true
        }
    }

    private func write(_ state: inout State, at date: Date) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state.document)
        try DocumentStore.atomicWrite(data, to: fileURL)
        state.dirty = false
        state.lastWrite = date
        state.writeCount += 1
    }

    private func moveAside(suffix: String) throws -> URL {
        let stamp = DocumentStore.stamp(now())
        let base = fileURL.deletingLastPathComponent()
        var target = base.appending(path: "\(fileURL.lastPathComponent).\(suffix)-\(stamp)", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            target = base.appending(
                path: "\(fileURL.lastPathComponent).\(suffix)-\(stamp)-\(UUID().uuidString.prefix(8))",
                directoryHint: .notDirectory
            )
        }
        try FileManager.default.moveItem(at: fileURL, to: target)
        return target
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes to a temp file in the same directory, then renames it over `url` (atomic on APFS).
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appending(
            path: "\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))",
            directoryHint: .notDirectory
        )
        try data.write(to: temp)
        let status = rename(temp.path(percentEncoded: false), url.path(percentEncoded: false))
        if status != 0 {
            let code = errno
            do {
                try FileManager.default.removeItem(at: temp)
            } catch {
                // The rename failure below is the useful error; a stray temp file is harmless.
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return formatter.string(from: date)
    }
}
