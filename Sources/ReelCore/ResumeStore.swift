import Foundation

/// One remembered playback position.
public struct ResumeEntry: Codable, Sendable, Hashable {
    public var position: MediaTime
    public var duration: MediaTime
    public var audioStreamIndex: Int?
    /// Last known path, for display and debugging only. The key is the identity.
    public var lastPath: String
    public var updatedAt: Date

    public init(
        position: MediaTime,
        duration: MediaTime,
        audioStreamIndex: Int? = nil,
        lastPath: String,
        updatedAt: Date
    ) {
        self.position = position
        self.duration = duration
        self.audioStreamIndex = audioStreamIndex
        self.lastPath = lastPath
        self.updatedAt = updatedAt
    }
}

/// The on-disk shape of `resume.json`.
public struct ResumeDocument: VersionedDocument {
    public static let currentVersion = 1

    public var version: Int
    /// Keyed by `ContentKey.hex`.
    public var entries: [String: ResumeEntry]

    public init(version: Int = ResumeDocument.currentVersion, entries: [String: ResumeEntry] = [:]) {
        self.version = version
        self.entries = entries
    }
}

/// What `record` did with a position.
public enum ResumeSaveResult: Sendable, Hashable {
    case saved
    /// Within 30 s of the end: the file counts as finished and its entry was removed.
    case finished
    /// Under 5 s: not worth remembering. An existing entry is left alone.
    case tooEarly
}

/// Resume positions keyed by content (design section 11.2), in `REEL_HOME/resume.json`.
public final class ResumeStore: Sendable {
    public static let minimumPosition = MediaTime.seconds(5)
    public static let finishedMargin = MediaTime.seconds(30)
    /// Periodic saves write at most once per second.
    public static let writeInterval: TimeInterval = 1
    /// Oldest entries are dropped beyond this many.
    public static let maximumEntries = 1_000

    private let store: DocumentStore<ResumeDocument>
    private let now: @Sendable () -> Date

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        store = DocumentStore(
            fileURL: fileURL,
            defaultDocument: ResumeDocument(),
            minimumWriteInterval: ResumeStore.writeInterval,
            now: now
        )
    }

    public convenience init(paths: ReelPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(fileURL: paths.resumeFile, now: now)
    }

    public var fileURL: URL { store.fileURL }
    public var entryCount: Int { store.document.entries.count }
    public var hasPendingWrite: Bool { store.hasPendingWrite }
    /// Files written so far, for tests of the debounce.
    public var writeCount: Int { store.writeCount }

    @discardableResult
    public func load() throws -> StoreLoadOutcome {
        try store.load(defaultDocument: ResumeDocument())
    }

    public func entry(for key: ContentKey) -> ResumeEntry? {
        store.document.entries[key.hex]
    }

    /// Applies the save rules, then writes if the one-second interval allows. Call `flush()` on
    /// pause, close and quit so the latest position is never left in memory.
    @discardableResult
    public func record(
        key: ContentKey,
        position: MediaTime,
        duration: MediaTime,
        audioStreamIndex: Int? = nil,
        path: String
    ) throws -> ResumeSaveResult {
        let result = update(key: key, position: position, duration: duration, audioStreamIndex: audioStreamIndex, path: path)
        try store.flushIfDue()
        return result
    }

    public func remove(key: ContentKey) throws {
        store.mutate { $0.entries[key.hex] = nil }
        try store.flushIfDue()
    }

    @discardableResult
    public func flush() throws -> Bool {
        try store.flush()
    }

    /// Writes a pending change when the interval has passed; for a periodic timer.
    @discardableResult
    public func flushIfDue() throws -> Bool {
        try store.flushIfDue()
    }

    private func update(
        key: ContentKey,
        position: MediaTime,
        duration: MediaTime,
        audioStreamIndex: Int?,
        path: String
    ) -> ResumeSaveResult {
        let date = now()
        let isFinished = duration > .zero && duration - position < ResumeStore.finishedMargin
        if isFinished {
            store.mutate { $0.entries[key.hex] = nil }
            return .finished
        }
        if position < ResumeStore.minimumPosition { return .tooEarly }
        store.mutate { document in
            document.entries[key.hex] = ResumeEntry(
                position: position,
                duration: duration,
                audioStreamIndex: audioStreamIndex,
                lastPath: path,
                updatedAt: date
            )
            ResumeStore.prune(&document)
        }
        return .saved
    }

    private static func prune(_ document: inout ResumeDocument) {
        let excess = document.entries.count - maximumEntries
        guard excess > 0 else { return }
        let oldest = document.entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(excess)
        for (key, _) in oldest {
            document.entries[key] = nil
        }
    }
}
