import Foundation

/// The commands the UI sends to a playback engine. `PlaybackEngine` in ReelEngine is the real
/// one; ReelUI tests use a fake. All commands are async because the engine is an actor.
public protocol PlayerEngine: AnyObject, Sendable {
    /// Events in order. One stream per engine, finished on `close()`.
    var events: AsyncStream<EngineEvent> { get }

    /// Opens a file, replacing any open one, and shows its first frame paused.
    @discardableResult
    func open(_ url: URL) async throws -> MediaInfo

    func play() async
    func pause() async

    /// Starts a seek. Returns once the request is accepted; the result arrives as `.seekCompleted`.
    func seek(_ request: SeekRequest) async

    /// Volume 0 to 100 on the mpv scale. The engine applies the cubic curve `(v / 100)^3`.
    func setVolume(_ volume: Double) async
    func setMuted(_ muted: Bool) async

    /// How often `.time` events are sent: 0.1 s while the chrome is visible, 1 s while hidden.
    func setTimeUpdateInterval(_ seconds: Double) async

    /// Stops playback, releases the file and finishes `events`.
    func close() async

    // MARK: M2 (design sections 8, 9.7 to 9.12). Each has a no-op default below.

    /// Switches audio without moving the picture; answered by `.tracksChanged`.
    func selectAudioTrack(_ streamIndex: Int) async
    /// Ctrl+Cmd+V cycling; answered by `.tracksChanged`.
    func selectVideoTrack(_ streamIndex: Int) async
    /// Shows an embedded track, an external file (added to the track list if new) or nothing.
    func selectSubtitle(_ selection: SubtitleSelection) async
    /// Seconds; positive shows subtitles later. Applies to text and bitmap tracks.
    func setSubtitleDelay(_ seconds: Double) async
    /// Seconds; positive plays audio later. Applied by offsetting audio timestamps, no re-decode.
    func setAudioDelay(_ seconds: Double) async
    /// Font scale for text tracks, 1 for size 45 (`SubtitleStyle.scale`). Bitmaps ignore it.
    func setSubtitleScale(_ factor: Double) async
    /// mpv `sub-pos`: 100 is the default bottom position, each 1 is 1% of the video height.
    func setSubtitlePosition(_ percent: Double) async
    func setSubtitlesVisible(_ visible: Bool) async
    /// Lifts bottom-aligned, unpositioned lines so their bottom edge sits this many points above
    /// the window bottom (`SubtitleStyle.liftInset`); nil puts them back (section 8.5).
    func setSubtitleAvoidance(bottomInsetPoints: Double?) async
    /// Playback rate 0.25 to 4 with pitch preserved; answered by `.rateChanged`.
    func setRate(_ rate: Double) async
    /// A-B loop and file loop; answered by `.loopChanged`.
    func setLoop(_ loop: LoopState) async
    /// The stored thumbnail of the last keyframe at or before `time`, or nil if none is ready.
    func thumbnail(at time: MediaTime) async -> ThumbnailImage?
    /// Start and end of every known event of the selected subtitle track, sorted, for next and
    /// previous line. Empty with no text track selected.
    func subtitleEvents() async -> [SubtitleEventTime]

    // MARK: M3 (sections 7.9 and 7.11). Each has a no-op default below.

    /// The window became hidden. Called as soon as the occlusion state changes:
    /// the engine itself waits `EnergyPolicy.occlusionDelay` before it stops video decode (audio
    /// goes on). False resyncs with an exact seek to the clock time.
    func setOccluded(_ occluded: Bool) async
    /// The pointer moved in the window within `EnergyPolicy.pointerRecentSeconds`; paused
    /// thumbnail generation runs only while true.
    func setPointerRecent(_ recent: Bool) async
    /// An `AudioDeviceUID` for the audio renderer, or nil for the system default.
    func setOutputDevice(_ uid: String?) async
    /// Work counted since open, for the energy bench.
    func energyCounters() async -> EnergyCounters
}

extension PlayerEngine {
    public func setTimeUpdateInterval(_ seconds: Double) async {}
    public func selectAudioTrack(_ streamIndex: Int) async {}
    public func selectVideoTrack(_ streamIndex: Int) async {}
    public func selectSubtitle(_ selection: SubtitleSelection) async {}
    public func setSubtitleDelay(_ seconds: Double) async {}
    public func setAudioDelay(_ seconds: Double) async {}
    public func setSubtitleScale(_ factor: Double) async {}
    public func setSubtitlePosition(_ percent: Double) async {}
    public func setSubtitlesVisible(_ visible: Bool) async {}
    public func setSubtitleAvoidance(bottomInsetPoints: Double?) async {}
    public func setRate(_ rate: Double) async {}
    public func setLoop(_ loop: LoopState) async {}
    public func thumbnail(at time: MediaTime) async -> ThumbnailImage? { nil }
    public func subtitleEvents() async -> [SubtitleEventTime] { [] }
    public func setOccluded(_ occluded: Bool) async {}
    public func setPointerRecent(_ recent: Bool) async {}
    public func setOutputDevice(_ uid: String?) async {}
    public func energyCounters() async -> EnergyCounters { .zero }
}

/// The cubic volume curve mpv uses, so a level matches IINA's (design section 7.4).
public enum VolumeCurve {
    public static let firstRunVolume: Double = 47

    /// Maps 0 to 100 to a linear gain 0 to 1.
    public static func gain(forVolume volume: Double) -> Float {
        let clamped = min(max(volume, 0), 100) / 100
        return Float(clamped * clamped * clamped)
    }
}
