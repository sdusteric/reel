import Foundation

/// The engine state machine (design section 7.1).
public enum PlaybackState: String, Sendable, Hashable, Codable {
    case idle, opening, ready, playing, paused, seeking, ended, failed

    /// A file is open and has a picture or position to show.
    public var hasMedia: Bool {
        switch self {
        case .ready, .playing, .paused, .seeking, .ended: true
        case .idle, .opening, .failed: false
        }
    }
}

public enum EngineError: Error, Sendable, Hashable, LocalizedError {
    case notImplemented(String)
    case openFailed(String)
    case noPlayableStream
    case unsupportedCodec(String)
    case decoderFailed(String)
    case io(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let what): "Not implemented: \(what)"
        case .openFailed(let reason): "Could not open the file: \(reason)"
        case .noPlayableStream: "The file has no playable video or audio stream."
        case .unsupportedCodec(let codec): "Unsupported codec: \(codec)"
        case .decoderFailed(let reason): "Decoding failed: \(reason)"
        case .io(let reason): "Read error: \(reason)"
        case .notOpen: "No file is open."
        }
    }
}

/// Everything the engine tells the UI, delivered in order through `PlayerEngine.events`.
public enum EngineEvent: Sendable, Hashable {
    case stateChanged(PlaybackState)
    /// The file is open and its streams are selected. Sent once per `open`.
    case opened(MediaInfo)
    /// The synchronizer clock, sent at the interval set by `setTimeUpdateInterval`.
    case time(MediaTime)
    /// A seek settled or was superseded.
    case seekCompleted(SeekReport)
    /// The range of media held in memory by the PacketStore, for the seek bar.
    case storedRange(ClosedRange<MediaTime>?)
    /// The video decoder changed, e.g. a hardware session failed and software took over.
    case decoderChanged(VideoDecoderKind, reason: String)
    /// Playback reached the end of the file.
    case ended
    case failed(EngineError)
}
