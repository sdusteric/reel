import Foundation

/// A request to move the playhead (design section 7.5).
public enum SeekRequest: Sendable, Hashable, Codable {
    /// Keyframe-only preview while dragging the seek bar or scrolling. Coalesced by the engine.
    case scrub(MediaTime)
    /// Lands on the frame whose display interval contains the target.
    case exact(MediaTime)

    public var target: MediaTime {
        switch self {
        case .scrub(let time), .exact(let time): time
        }
    }

    public var kind: Kind {
        switch self {
        case .scrub: .scrub
        case .exact: .exact
        }
    }

    public var isExact: Bool { kind == .exact }

    public enum Kind: String, Sendable, Hashable, Codable {
        case scrub, exact
    }
}

/// How an exact seek started decoding (the SeekPlanner's choice).
public enum SeekStart: String, Sendable, Hashable, Codable {
    /// Decoded from the last keyframe at or before the target.
    case keyframe
    /// Continued from the live decoder position without a flush.
    case continueDecoder
    /// Scrub: the keyframe was already on screen, nothing decoded.
    case alreadyDisplayed
}

/// What one seek cost. Emitted by the engine when the seek settles or is superseded.
public struct SeekReport: Sendable, Hashable, Codable {
    public var kind: SeekRequest.Kind
    public var target: MediaTime
    /// The engine's seek generation for this request.
    public var generation: UInt64
    /// Monotonic clock reading (nanoseconds, `DispatchTime.now().uptimeNanoseconds`) when the request arrived.
    public var requestedAtNanos: UInt64
    /// Milliseconds from the request to the keyframe preview being enqueued, if one was shown.
    public var previewMilliseconds: Double?
    /// Milliseconds from the request to the target (or, for a scrub, the keyframe) being enqueued.
    public var targetMilliseconds: Double?
    /// Presentation time of the frame that was displayed.
    public var landedPTS: MediaTime?
    /// Presentation time of the keyframe decoding started from.
    public var startKeyframePTS: MediaTime?
    public var start: SeekStart
    /// Frames submitted to the decoder.
    public var framesDecoded: Int
    /// Non-reference frames before the target that were never submitted.
    public var framesSkipped: Int
    /// Compressed bytes read from the file for this seek (0 on a store hit).
    public var bytesRead: Int64
    /// All needed packets were already in the PacketStore.
    public var storeHit: Bool
    /// A newer request superseded this one before it landed.
    public var cancelled: Bool
    /// The decoder the run started on: software for a long VP9 exact seek (D46).
    public var decoder: VideoDecoderKind?
    /// The VP9 hybrid's software to hardware hand-offs since the file opened, when the report
    /// was made (a hand-off happens after a software landing, at the next keyframe).
    public var decoderHandoffs: Int?

    public init(
        kind: SeekRequest.Kind,
        target: MediaTime,
        generation: UInt64,
        requestedAtNanos: UInt64,
        previewMilliseconds: Double? = nil,
        targetMilliseconds: Double? = nil,
        landedPTS: MediaTime? = nil,
        startKeyframePTS: MediaTime? = nil,
        start: SeekStart = .keyframe,
        framesDecoded: Int = 0,
        framesSkipped: Int = 0,
        bytesRead: Int64 = 0,
        storeHit: Bool = false,
        cancelled: Bool = false,
        decoder: VideoDecoderKind? = nil,
        decoderHandoffs: Int? = nil
    ) {
        self.kind = kind
        self.target = target
        self.generation = generation
        self.requestedAtNanos = requestedAtNanos
        self.previewMilliseconds = previewMilliseconds
        self.targetMilliseconds = targetMilliseconds
        self.landedPTS = landedPTS
        self.startKeyframePTS = startKeyframePTS
        self.start = start
        self.framesDecoded = framesDecoded
        self.framesSkipped = framesSkipped
        self.bytesRead = bytesRead
        self.storeHit = storeHit
        self.cancelled = cancelled
        self.decoder = decoder
        self.decoderHandoffs = decoderHandoffs
    }
}
