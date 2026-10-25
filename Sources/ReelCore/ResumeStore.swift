import Foundation

/// The saved subtitle choice: Off, or a track identity (embedded index plus language, title
/// and codec, or the external file name).
public enum SubtitleChoice: Codable, Sendable, Hashable {
    case off
    case track(TrackIdentity)
}

/// Per-file choices saved with the position (schema 2, design section 11.2). Every field is
/// optional: nil means "not changed for this file", so the default or a carry-over applies.
public struct ResumeChoices: Codable, Sendable, Hashable {
    public var subtitle: SubtitleChoice?
    /// Seconds.
    public var subtitleDelay: Double?
    /// Seconds.
    public var audioDelay: Double?
    /// On the 45 scale (`SubtitleStyle.size`).
    public var subtitleSize: Double?
    /// mpv `sub-pos` (`SubtitleStyle.position`).
    public var subtitlePosition: Double?
    public var loop: LoopState?

    public init(
        subtitle: SubtitleChoice? = nil,
        subtitleDelay: Double? = nil,
        audioDelay: Double? = nil,
        subtitleSize: Double? = nil,
        subtitlePosition: Double? = nil,
        loop: LoopState? = nil
    ) {
        self.subtitle = subtitle
        self.subtitleDelay = subtitleDelay
        self.audioDelay = audioDelay
        self.subtitleSize = subtitleSize
        self.subtitlePosition = subtitlePosition
        self.loop = loop
    }

    public static let empty = ResumeChoices()
    public var isEmpty: Bool { self == .empty }
}

/// One remembered playback position.
public struct ResumeEntry: Codable, Sendable, Hashable {
    public var position: MediaTime
    public var duration: MediaTime
    public var audioStreamIndex: Int?
    /// Last known path, for display and debugging only. The key is the identity.
    public var lastPath: String
    public var updatedAt: Date
    // Schema 2. Version 1 entries decode with these nil.
    public var subtitle: SubtitleChoice?
    public var subtitleDelay: Double?
    public var audioDelay: Double?
    public var subtitleSize: Double?
    public var subtitlePosition: Double?
    public var loop: LoopState?

    public init(
        position: MediaTime,
        duration: MediaTime,
        audioStreamIndex: Int? = nil,
        lastPath: String,
        updatedAt: Date,
        choices: ResumeChoices = .empty
    ) {
        self.position = position
        self.duration = duration
        self.audioStreamIndex = audioStreamIndex
        self.lastPath = lastPath
        self.updatedAt = updatedAt
        self.choices = choices
    }

    public var choices: ResumeChoices {
        get {
            ResumeChoices(
                subtitle: subtitle,
                subtitleDelay: subtitleDelay,
                audioDelay: audioDelay,
                subtitleSize: subtitleSize,
                subtitlePosition: subtitlePosition,
                loop: loop
            )
        }
        set {
            subtitle = newValue.subtitle
            subtitleDelay = newValue.subtitleDelay
            audioDelay = newValue.audioDelay
            subtitleSize = newValue.subtitleSize
            subtitlePosition = newValue.subtitlePosition
            loop = newValue.loop
        }
    }
}

/// The on-disk shape of `resume.json`.
public struct ResumeDocument: VersionedDocument {
    public static let currentVersion = 2

    public var version: Int
    /// Keyed by `ContentKey.hex`.
    public var entries: [String: ResumeEntry]

    public init(version: Int = ResumeDocument.currentVersion, entries: [String: ResumeEntry] = [:]) {
        self.version = version
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case version, entries }

    /// Older versions are migrated on load: version 1 entries simply lack the schema 2 fields, so
    /// the document is upgraded in memory and written as the current version next time.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        self.init(
            version: max(version, ResumeDocument.currentVersion),
            entries: try container.decode([String: ResumeEntry].self, forKey: .entries)
        )
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
    /// `choices` nil keeps the entry's saved choices; pass a value to replace them.
    @discardableResult
    public func record(
        key: ContentKey,
        position: MediaTime,
        duration: MediaTime,
        audioStreamIndex: Int? = nil,
        choices: ResumeChoices? = nil,
        path: String
    ) throws -> ResumeSaveResult {
        let result = update(
            key: key,
            position: position,
            duration: duration,
            audioStreamIndex: audioStreamIndex,
            choices: choices,
            path: path
        )
        try store.flushIfDue()
        return result
    }

    /// Replaces the choices of an existing entry (a subtitle switched early in the file is saved
    /// with the next position). Returns false when there is no entry for `key`.
    @discardableResult
    public func updateChoices(key: ContentKey, choices: ResumeChoices) throws -> Bool {
        let updated = store.mutate { document -> Bool in
            guard document.entries[key.hex] != nil else { return false }
            document.entries[key.hex]?.choices = choices
            return true
        }
        try store.flushIfDue()
        return updated
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
        choices: ResumeChoices?,
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
            let kept = document.entries[key.hex]?.choices ?? .empty
            document.entries[key.hex] = ResumeEntry(
                position: position,
                duration: duration,
                audioStreamIndex: audioStreamIndex,
                lastPath: path,
                updatedAt: date,
                choices: choices ?? kept
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
