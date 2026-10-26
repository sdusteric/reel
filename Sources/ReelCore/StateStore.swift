import Foundation

/// A window frame in screen points, stored without CoreGraphics so ReelCore stays Foundation only.
public struct WindowFrame: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Remembered state, not settings (design sections 11.1 and 11.3).
public struct RememberedState: VersionedDocument {
    public static let currentVersion = 1
    public static let defaultControllerCenterX = 0.49
    public static let defaultControllerBottomY = 0.11

    public var version: Int
    /// 0 to 100 on the mpv scale. First run is 47, the user's IINA level.
    public var volume: Double
    /// The right-hand time label shows remaining time (`-12:34`) rather than the total.
    public var showRemainingTime: Bool
    public var windowFrame: WindowFrame?
    /// Horizontal centre of the controller as a fraction of the window width.
    public var controllerCenterX: Double
    /// Distance from the window bottom to the controller's bottom edge, as a fraction of the window height.
    public var controllerBottomY: Double
    /// (M2) Subtitle size for new files on the 45 scale, set when changed from the panel.
    public var subtitleSize: Double
    /// (M2) Playback menu "Auto-Advance to Next Episode", on by default.
    public var autoAdvance: Bool
    /// (M3) Output device: System Default or a device by UID with its name (section 7.11).
    public var outputDevice: OutputDeviceChoice
    /// Paths of the files opened most recently, newest first, for `reel://open-recent`.
    public var recentFiles: [String]

    public static let maximumRecentFiles = 10

    /// Puts `path` first, drops an older copy and keeps the newest `maximumRecentFiles`.
    public mutating func noteRecent(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > RememberedState.maximumRecentFiles {
            recentFiles.removeLast(recentFiles.count - RememberedState.maximumRecentFiles)
        }
    }

    public init(
        version: Int = RememberedState.currentVersion,
        volume: Double = VolumeCurve.firstRunVolume,
        showRemainingTime: Bool = true,
        windowFrame: WindowFrame? = nil,
        controllerCenterX: Double = RememberedState.defaultControllerCenterX,
        controllerBottomY: Double = RememberedState.defaultControllerBottomY,
        subtitleSize: Double = SubtitleStyle.baseSize,
        autoAdvance: Bool = true,
        outputDevice: OutputDeviceChoice = .systemDefault,
        recentFiles: [String] = []
    ) {
        self.version = version
        self.volume = RememberedState.clampVolume(volume)
        self.showRemainingTime = showRemainingTime
        self.windowFrame = windowFrame
        self.controllerCenterX = RememberedState.clampFraction(controllerCenterX)
        self.controllerBottomY = RememberedState.clampFraction(controllerBottomY)
        self.subtitleSize = SubtitleStyle(size: subtitleSize).size
        self.autoAdvance = autoAdvance
        self.outputDevice = outputDevice
        self.recentFiles = Array(recentFiles.prefix(RememberedState.maximumRecentFiles))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RememberedState()
        self.init(
            version: try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version,
            volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? defaults.volume,
            showRemainingTime: try container.decodeIfPresent(Bool.self, forKey: .showRemainingTime)
                ?? defaults.showRemainingTime,
            windowFrame: try container.decodeIfPresent(WindowFrame.self, forKey: .windowFrame),
            controllerCenterX: try container.decodeIfPresent(Double.self, forKey: .controllerCenterX)
                ?? defaults.controllerCenterX,
            controllerBottomY: try container.decodeIfPresent(Double.self, forKey: .controllerBottomY)
                ?? defaults.controllerBottomY,
            subtitleSize: try container.decodeIfPresent(Double.self, forKey: .subtitleSize) ?? defaults.subtitleSize,
            autoAdvance: try container.decodeIfPresent(Bool.self, forKey: .autoAdvance) ?? defaults.autoAdvance,
            outputDevice: try container.decodeIfPresent(OutputDeviceChoice.self, forKey: .outputDevice) ?? defaults.outputDevice,
            recentFiles: try container.decodeIfPresent([String].self, forKey: .recentFiles) ?? defaults.recentFiles
        )
    }

    private static func clampVolume(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 100) : VolumeCurve.firstRunVolume
    }

    private static func clampFraction(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}

/// `REEL_HOME/state.json`. Volume changes arrive in bursts, so periodic updates write at most
/// once per second; `flush()` writes the rest at quit.
public final class StateStore: Sendable {
    public static let writeInterval: TimeInterval = 1

    private let store: DocumentStore<RememberedState>

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        store = DocumentStore(
            fileURL: fileURL,
            defaultDocument: RememberedState(),
            minimumWriteInterval: StateStore.writeInterval,
            now: now
        )
    }

    public convenience init(paths: ReelPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(fileURL: paths.stateFile, now: now)
    }

    public var fileURL: URL { store.fileURL }
    public var state: RememberedState { store.document }
    public var hasPendingWrite: Bool { store.hasPendingWrite }
    public var writeCount: Int { store.writeCount }

    @discardableResult
    public func load() throws -> StoreLoadOutcome {
        try store.load(defaultDocument: RememberedState())
    }

    /// Applies `change` (values are clamped to their ranges) and writes if the interval allows.
    public func update(_ change: (inout RememberedState) -> Void) throws {
        store.mutate { state in
            change(&state)
            state = RememberedState(
                version: state.version,
                volume: state.volume,
                showRemainingTime: state.showRemainingTime,
                windowFrame: state.windowFrame,
                controllerCenterX: state.controllerCenterX,
                controllerBottomY: state.controllerBottomY,
                subtitleSize: state.subtitleSize,
                autoAdvance: state.autoAdvance,
                outputDevice: state.outputDevice,
                recentFiles: state.recentFiles
            )
        }
        try store.flushIfDue()
    }

    @discardableResult
    public func flush() throws -> Bool {
        try store.flush()
    }

    @discardableResult
    public func flushIfDue() throws -> Bool {
        try store.flushIfDue()
    }
}
