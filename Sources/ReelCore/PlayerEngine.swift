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
}

extension PlayerEngine {
    public func setTimeUpdateInterval(_ seconds: Double) async {}
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
