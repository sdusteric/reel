import Foundation

/// The user settings (design section 11.1): the M1 four and (M3) High dynamic range. Missing keys decode to their defaults, so an
/// older file keeps working when a setting is added.
public struct Settings: VersionedDocument {
    public static let currentVersion = 1

    public var version: Int
    /// Resume playback where I left off.
    public var resumePlayback: Bool
    /// Show remaining time (`-12:34`) instead of the total in the controller.
    public var showRemainingTime: Bool
    /// Show a keyframe preview while seeking.
    public var keyframePreview: Bool
    /// Hardware decoding. Off forces software, for diagnosis.
    public var hardwareDecoding: Bool
    /// (M3) High dynamic range: Full, Limited or Off (section 7.7, D51).
    public var highDynamicRange: HDRSetting

    public init(
        version: Int = Settings.currentVersion,
        resumePlayback: Bool = true,
        showRemainingTime: Bool = true,
        keyframePreview: Bool = true,
        hardwareDecoding: Bool = true,
        highDynamicRange: HDRSetting = .default
    ) {
        self.version = version
        self.resumePlayback = resumePlayback
        self.showRemainingTime = showRemainingTime
        self.keyframePreview = keyframePreview
        self.hardwareDecoding = hardwareDecoding
        self.highDynamicRange = highDynamicRange
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        resumePlayback = try container.decodeIfPresent(Bool.self, forKey: .resumePlayback) ?? defaults.resumePlayback
        showRemainingTime = try container.decodeIfPresent(Bool.self, forKey: .showRemainingTime)
            ?? defaults.showRemainingTime
        keyframePreview = try container.decodeIfPresent(Bool.self, forKey: .keyframePreview) ?? defaults.keyframePreview
        hardwareDecoding = try container.decodeIfPresent(Bool.self, forKey: .hardwareDecoding)
            ?? defaults.hardwareDecoding
        // An unknown value (a newer build's) falls back to the default rather than failing the file.
        let hdr = try container.decodeIfPresent(String.self, forKey: .highDynamicRange)
        highDynamicRange = hdr.flatMap(HDRSetting.init(rawValue:)) ?? defaults.highDynamicRange
    }
}

/// `REEL_HOME/settings.json`. Changes are rare, so each one is written at once.
public final class SettingsStore: Sendable {
    private let store: DocumentStore<Settings>

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        store = DocumentStore(fileURL: fileURL, defaultDocument: Settings(), minimumWriteInterval: 0, now: now)
    }

    public convenience init(paths: ReelPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(fileURL: paths.settingsFile, now: now)
    }

    public var fileURL: URL { store.fileURL }
    public var settings: Settings { store.document }

    @discardableResult
    public func load() throws -> StoreLoadOutcome {
        try store.load(defaultDocument: Settings())
    }

    /// Applies `change` and writes the file if anything changed.
    public func update(_ change: (inout Settings) -> Void) throws {
        store.mutate(change)
        try store.flush()
    }
}
