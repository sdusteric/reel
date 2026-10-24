import Foundation

/// Chroma subsampling of a video stream, as far as the decoder choice cares.
public enum ChromaSubsampling: String, Sendable, Codable, Hashable {
    case yuv420, yuv422, yuv444, other
}

/// What the policy needs to know about a video stream.
public struct VideoStreamTraits: Sendable, Hashable {
    /// FFmpeg codec name: "h264", "hevc", "vp9", "av1", "mpeg4", ...
    public var codec: String
    public var bitDepth: Int
    public var chroma: ChromaSubsampling

    public init(codec: String, bitDepth: Int = 8, chroma: ChromaSubsampling = .yuv420) {
        self.codec = codec.lowercased()
        self.bitDepth = bitDepth
        self.chroma = chroma
    }
}

/// Which codecs VideoToolbox can decode on this machine. The engine fills it in from
/// `VTIsHardwareDecodeSupported` and the VP9 supplemental decoder registration.
public struct HardwareDecodeSupport: Sendable, Hashable {
    public var h264: Bool
    public var hevc: Bool
    public var vp9: Bool
    public var av1: Bool

    public init(h264: Bool = true, hevc: Bool = true, vp9: Bool = true, av1: Bool = true) {
        self.h264 = h264
        self.hevc = hevc
        self.vp9 = vp9
        self.av1 = av1
    }

    public static let all = HardwareDecodeSupport()
    public static let none = HardwareDecodeSupport(h264: false, hevc: false, vp9: false, av1: false)
}

/// Why the policy picked a decoder. Logged and shown by `reelctl probe`.
public enum DecoderReason: String, Sendable, Hashable {
    case forcedByEnvironment
    case disabledInSettings
    case hardwareSupported
    case hardwareUnavailable
    case unsupportedProfile
    case unsupportedCodec
    case failureFallback
}

public struct DecoderDecision: Sendable, Hashable {
    public var kind: VideoDecoderKind
    public var reason: DecoderReason

    public init(kind: VideoDecoderKind, reason: DecoderReason) {
        self.kind = kind
        self.reason = reason
    }
}

/// Picks the video decoder for a stream (design section 7.3). Pure.
public struct DecoderPolicy: Sendable, Hashable {
    /// `REEL_FORCE_DECODER`, for tests and benches.
    public var forced: VideoDecoderKind?
    /// The "Hardware decoding" setting.
    public var hardwareEnabled: Bool
    public var support: HardwareDecodeSupport

    public init(
        forced: VideoDecoderKind? = nil,
        hardwareEnabled: Bool = true,
        support: HardwareDecodeSupport = .all
    ) {
        self.forced = forced
        self.hardwareEnabled = hardwareEnabled
        self.support = support
    }

    public init(environment: ReelEnvironment, hardwareEnabled: Bool = true, support: HardwareDecodeSupport = .all) {
        self.init(forced: environment.forcedDecoder, hardwareEnabled: hardwareEnabled, support: support)
    }

    public func decide(for stream: VideoStreamTraits) -> DecoderDecision {
        if let forced {
            return DecoderDecision(kind: forced, reason: .forcedByEnvironment)
        }
        guard hardwareEnabled else {
            return DecoderDecision(kind: .software, reason: .disabledInSettings)
        }
        switch stream.codec {
        case "h264":
            // VideoToolbox has no High 10 or 4:2:2/4:4:4 H.264 decoder.
            guard stream.chroma == .yuv420, stream.bitDepth == 8 else { return software(.unsupportedProfile) }
            return hardware(support.h264)
        case "hevc":
            guard stream.chroma == .yuv420, stream.bitDepth == 8 || stream.bitDepth == 10 else {
                return software(.unsupportedProfile)
            }
            return hardware(support.hevc)
        case "vp9":
            guard stream.chroma == .yuv420, stream.bitDepth == 8 || stream.bitDepth == 10 else {
                return software(.unsupportedProfile)
            }
            return hardware(support.vp9)
        case "av1":
            return hardware(support.av1)
        default:
            return software(.unsupportedCodec)
        }
    }

    private func hardware(_ supported: Bool) -> DecoderDecision {
        supported
            ? DecoderDecision(kind: .hardware, reason: .hardwareSupported)
            : DecoderDecision(kind: .software, reason: .hardwareUnavailable)
    }

    private func software(_ reason: DecoderReason) -> DecoderDecision {
        DecoderDecision(kind: .software, reason: reason)
    }
}

/// Tracks decode failures of one stream and decides when to leave hardware decoding.
///
/// Three consecutive failed frames after a keyframe, or a session that cannot be created,
/// schedule a switch to software that takes effect at the next keyframe. A forced decoder
/// never falls back, so benches measure what they asked for.
public struct DecoderFailureTracker: Sendable, Hashable {
    public static let failureLimit = 3

    public private(set) var current: VideoDecoderKind
    public private(set) var consecutiveFailures = 0
    public private(set) var switchPending = false
    public private(set) var lastFailureNote: String?
    private let allowsFallback: Bool

    public init(initial: DecoderDecision, forced: Bool = false) {
        current = initial.kind
        allowsFallback = !forced && initial.reason != .forcedByEnvironment
    }

    /// A frame decoded. Resets the consecutive failure count.
    public mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    /// A frame failed to decode. Returns true when this failure scheduled the switch.
    @discardableResult
    public mutating func recordFailure(_ note: String? = nil) -> Bool {
        lastFailureNote = note
        consecutiveFailures += 1
        guard allowsFallback, current == .hardware, !switchPending,
              consecutiveFailures >= DecoderFailureTracker.failureLimit else { return false }
        switchPending = true
        return true
    }

    /// The hardware session could not be created: switch at once.
    @discardableResult
    public mutating func recordSessionCreationFailure(_ note: String? = nil) -> Bool {
        lastFailureNote = note
        guard allowsFallback, current == .hardware else { return false }
        current = .software
        switchPending = false
        consecutiveFailures = 0
        return true
    }

    /// The decoder reached a keyframe. Returns `.software` when the scheduled switch applies now.
    public mutating func reachedKeyframe() -> VideoDecoderKind? {
        guard switchPending else { return nil }
        switchPending = false
        consecutiveFailures = 0
        current = .software
        return .software
    }
}
