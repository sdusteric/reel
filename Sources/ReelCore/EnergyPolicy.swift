import Foundation

/// The playback states that matter for energy (section 7.9).
public enum EnergyPlayback: String, Sendable, Codable, Hashable, CaseIterable {
    case playing, paused
    /// Ended, failed, or no file.
    case stopped

    /// Maps the engine state; a transitional state (opening, seeking) follows the play intent.
    public init(_ state: PlaybackState, playIntent: Bool) {
        switch state {
        case .playing: self = .playing
        case .paused, .ready: self = .paused
        case .opening, .seeking: self = playIntent ? .playing : .paused
        case .ended, .idle, .failed: self = .stopped
        }
    }
}

/// What the policy is asked about.
public struct EnergyInputs: Sendable, Hashable {
    public var playback: EnergyPlayback
    /// The window has not been visible for at least `EnergyPolicy.occlusionDelay` and Picture
    /// in Picture is not active. Only matters while playing.
    public var occluded: Bool
    /// The pointer moved in the window in the last `EnergyPolicy.pointerRecentSeconds`.
    public var pointerRecent: Bool
    /// `ProcessInfo.isLowPowerModeEnabled`.
    public var lowPower: Bool
    /// The chrome (title and controller) is visible: 10 Hz time events instead of 1 Hz.
    public var chromeVisible: Bool

    public init(playback: EnergyPlayback, occluded: Bool = false, pointerRecent: Bool = false, lowPower: Bool = false, chromeVisible: Bool = true) {
        self.playback = playback
        self.occluded = occluded
        self.pointerRecent = pointerRecent
        self.lowPower = lowPower
        self.chromeVisible = chromeVisible
    }
}

/// Demux read-ahead in a state.
public enum ReadAheadMode: String, Sendable, Codable, Hashable {
    /// Read ahead to the 20 s limit.
    case full
    /// Finish the current fill, then block on a condition (no polling).
    case finishFillThenBlock
    /// Only what audio needs (video decode is off while occluded).
    case audioOnly
    case none
}

/// Time events sent to the UI.
public enum TimeEventMode: Sendable, Codable, Hashable {
    /// Periodic, every `seconds`.
    case interval(seconds: Double)
    /// One on each state change and seek, nothing periodic.
    case onChangeOnly
    case none

    /// The periodic interval, nil when nothing is periodic.
    public var interval: Double? {
        if case .interval(let seconds) = self { return seconds }
        return nil
    }
}

/// Subtitle renders in a state.
public enum SubtitleRenderMode: String, Sendable, Codable, Hashable {
    /// While an event is active or due within `EnergyPolicy.subtitleLookahead`.
    case whileActiveOrDue
    /// One render after each seek, nothing else.
    case onSeekOnly
    case none
}

/// Background thumbnail generation in a state.
public enum ThumbnailMode: String, Sendable, Codable, Hashable {
    case full
    /// Stop after the coarse pass (every 8th position): Low Power Mode.
    case coarse
    case suspended

    public var runs: Bool { self != .suspended }
}

/// What runs in one state (the rows of the section 7.9 table).
public struct EnergyDecision: Sendable, Codable, Hashable {
    /// Video decode and enqueue. While paused nothing is decoded after the shown frame.
    public var videoDecode: Bool
    public var readAhead: ReadAheadMode
    public var audioDecode: Bool
    public var timeEvents: TimeEventMode
    public var subtitleRenders: SubtitleRenderMode
    public var thumbnails: ThumbnailMode
    /// The display sleep assertion and the App Nap activity (`beginActivity`) are held.
    public var holdsDisplaySleepAssertion: Bool
    public var holdsActivity: Bool

    public init(
        videoDecode: Bool,
        readAhead: ReadAheadMode,
        audioDecode: Bool,
        timeEvents: TimeEventMode,
        subtitleRenders: SubtitleRenderMode,
        thumbnails: ThumbnailMode,
        holdsDisplaySleepAssertion: Bool,
        holdsActivity: Bool
    ) {
        self.videoDecode = videoDecode
        self.readAhead = readAhead
        self.audioDecode = audioDecode
        self.timeEvents = timeEvents
        self.subtitleRenders = subtitleRenders
        self.thumbnails = thumbnails
        self.holdsDisplaySleepAssertion = holdsDisplaySleepAssertion
        self.holdsActivity = holdsActivity
    }
}

/// Pure answer to "what may run now" (section 7.9, D58 to D60). The engine and the app read it.
public enum EnergyPolicy {
    /// The window must stay hidden this long before video decode stops.
    public static let occlusionDelay: Double = 1
    /// Paused thumbnails continue while the pointer moved in the window this recently.
    public static let pointerRecentSeconds: Double = 10
    /// Subtitles render while an event is due within this many seconds.
    public static let subtitleLookahead: Double = 1
    public static let chromeVisibleTimeInterval: Double = 0.1
    public static let chromeHiddenTimeInterval: Double = 1
    /// Now Playing needs the time once a second while the window is hidden.
    public static let occludedTimeInterval: Double = 1
    /// Every dispatch timer gets this fraction of its interval as leeway (D60).
    public static let timerLeewayFraction: Double = 0.1

    /// The leeway for a timer firing every `interval` seconds.
    public static func leeway(forInterval interval: Double) -> Double {
        guard interval.isFinite, interval > 0 else { return 0 }
        return interval * timerLeewayFraction
    }

    public static func decide(_ inputs: EnergyInputs) -> EnergyDecision {
        let generation: ThumbnailMode = inputs.lowPower ? .coarse : .full
        switch inputs.playback {
        case .playing where inputs.occluded:
            return EnergyDecision(
                videoDecode: false,
                readAhead: .audioOnly,
                audioDecode: true,
                timeEvents: .interval(seconds: occludedTimeInterval),
                subtitleRenders: .none,
                thumbnails: .suspended,
                holdsDisplaySleepAssertion: false,
                holdsActivity: false
            )
        case .playing:
            return EnergyDecision(
                videoDecode: true,
                readAhead: .full,
                audioDecode: true,
                timeEvents: .interval(seconds: inputs.chromeVisible ? chromeVisibleTimeInterval : chromeHiddenTimeInterval),
                subtitleRenders: .whileActiveOrDue,
                thumbnails: generation,
                holdsDisplaySleepAssertion: true,
                holdsActivity: true
            )
        case .paused:
            return EnergyDecision(
                videoDecode: false,
                readAhead: .finishFillThenBlock,
                audioDecode: false,
                timeEvents: .onChangeOnly,
                subtitleRenders: .onSeekOnly,
                thumbnails: inputs.pointerRecent ? generation : .suspended,
                holdsDisplaySleepAssertion: false,
                holdsActivity: false
            )
        case .stopped:
            return EnergyDecision(
                videoDecode: false,
                readAhead: .none,
                audioDecode: false,
                timeEvents: .none,
                subtitleRenders: .none,
                thumbnails: .suspended,
                holdsDisplaySleepAssertion: false,
                holdsActivity: false
            )
        }
    }
}

/// Engine work counted since open, for `reelctl energy-bench` (section 7.9).
public struct EnergyCounters: Sendable, Codable, Hashable {
    public var framesDecoded: Int
    public var packetsRead: Int
    public var subtitleRenders: Int
    public var timeEvents: Int
    public var thumbnailsDecoded: Int

    public init(framesDecoded: Int = 0, packetsRead: Int = 0, subtitleRenders: Int = 0, timeEvents: Int = 0, thumbnailsDecoded: Int = 0) {
        self.framesDecoded = framesDecoded
        self.packetsRead = packetsRead
        self.subtitleRenders = subtitleRenders
        self.timeEvents = timeEvents
        self.thumbnailsDecoded = thumbnailsDecoded
    }

    public static let zero = EnergyCounters()

    /// The work done between `earlier` and `self`.
    public static func - (later: EnergyCounters, earlier: EnergyCounters) -> EnergyCounters {
        EnergyCounters(
            framesDecoded: later.framesDecoded - earlier.framesDecoded,
            packetsRead: later.packetsRead - earlier.packetsRead,
            subtitleRenders: later.subtitleRenders - earlier.subtitleRenders,
            timeEvents: later.timeEvents - earlier.timeEvents,
            thumbnailsDecoded: later.thumbnailsDecoded - earlier.thumbnailsDecoded
        )
    }
}
