import Foundation

/// Decode speed estimates in frames per second (design sections 7.5 and 7.6).
///
/// Defaults are the spike's measurements on this Mac where one exists (HEVC and H.264 1080p,
/// AV1 and VP9 2160p hardware, VP9 2160p software) and conservative estimates elsewhere.
/// The engine feeds real timings back through `record`, so the estimate follows the machine.
public struct DecodeRates: Sendable, Hashable {
    private struct Reference: Sendable, Hashable {
        /// Frame size the rate was measured at.
        var pixels: Int
        var framesPerSecond: Double
    }

    private struct Key: Sendable, Hashable {
        var codec: String
        var decoder: VideoDecoderKind
    }

    private static let hd = 1920 * 1080
    private static let uhd = 3840 * 2160

    private static let defaults: [Key: Reference] = [
        // Measured: full GOP of 250 frames in 128 ms, 300 frames in 195 ms, 300 frames in 405 ms.
        Key(codec: "hevc", decoder: .hardware): Reference(pixels: hd, framesPerSecond: 1_950),
        Key(codec: "h264", decoder: .hardware): Reference(pixels: hd, framesPerSecond: 1_540),
        Key(codec: "av1", decoder: .hardware): Reference(pixels: uhd, framesPerSecond: 740),
        // Measured: VP9 4K hardware 249 fps, software 576 fps (design section 1).
        Key(codec: "vp9", decoder: .hardware): Reference(pixels: uhd, framesPerSecond: 249),
        Key(codec: "vp9", decoder: .software): Reference(pixels: uhd, framesPerSecond: 576),
        // Not measured in the spike.
        Key(codec: "hevc", decoder: .software): Reference(pixels: hd, framesPerSecond: 500),
        Key(codec: "h264", decoder: .software): Reference(pixels: hd, framesPerSecond: 900),
        Key(codec: "av1", decoder: .software): Reference(pixels: uhd, framesPerSecond: 300),
    ]

    private static let fallback = Reference(pixels: hd, framesPerSecond: 150)

    /// Smoothing for `record`: weight of the newest measurement.
    public static let smoothing = 0.3

    private var learned: [Key: Reference] = [:]

    public init() {}

    /// Estimated frames per second for a stream of `width` x `height`. Rates scale inversely with
    /// the frame area relative to the size they were measured at.
    public func framesPerSecond(codec: String, decoder: VideoDecoderKind, width: Int, height: Int) -> Double {
        let key = Key(codec: codec.lowercased(), decoder: decoder)
        let reference = learned[key] ?? DecodeRates.defaults[key] ?? DecodeRates.fallback
        let pixels = Double(max(width * height, 1))
        return max(reference.framesPerSecond * Double(reference.pixels) / pixels, 1)
    }

    /// Folds a measured decode burst into the estimate (exponential moving average).
    public mutating func record(
        codec: String,
        decoder: VideoDecoderKind,
        width: Int,
        height: Int,
        frames: Int,
        seconds: Double
    ) {
        guard frames > 0, seconds > 0, width > 0, height > 0 else { return }
        let key = Key(codec: codec.lowercased(), decoder: decoder)
        let base = learned[key] ?? DecodeRates.defaults[key] ?? DecodeRates.fallback
        // Express the measurement at the reference frame size.
        let measured = Double(frames) / seconds * Double(width * height) / Double(base.pixels)
        let blended = base.framesPerSecond * (1 - DecodeRates.smoothing) + measured * DecodeRates.smoothing
        learned[key] = Reference(pixels: base.pixels, framesPerSecond: blended)
    }
}

/// What the planner needs to know about the video stream being decoded.
public struct DecodeProfile: Sendable, Hashable {
    public var codec: String
    public var decoder: VideoDecoderKind
    public var width: Int
    public var height: Int
    /// Duration of one frame. Must be positive.
    public var frameDuration: MediaTime
    /// Fraction of frames before the target that need not be submitted (non-reference frames),
    /// 0 when the codec or stream does not allow skipping. Between 0 and 1.
    public var skippableFraction: Double

    public init(
        codec: String,
        decoder: VideoDecoderKind,
        width: Int,
        height: Int,
        frameDuration: MediaTime,
        skippableFraction: Double = 0
    ) {
        self.codec = codec
        self.decoder = decoder
        self.width = width
        self.height = height
        self.frameDuration = frameDuration.microseconds > 0 ? frameDuration : MediaTime(microseconds: 1)
        self.skippableFraction = min(max(skippableFraction, 0), 0.95)
    }
}

/// The live decoder, when there is one (a file is playing or paused with packets flowing).
public struct DecoderPosition: Sendable, Hashable {
    /// Presentation time of the last frame submitted to the decoder.
    public var lastSubmittedPTS: MediaTime

    public init(lastSubmittedPTS: MediaTime) {
        self.lastSubmittedPTS = lastSubmittedPTS
    }
}

/// How an exact seek will run.
public struct SeekPlan: Sendable, Hashable {
    /// `.keyframe` flushes and restarts at `keyframe`; `.continueDecoder` keeps the decoder going.
    public var start: SeekStart
    /// Where decoding starts: the keyframe pts, or the decoder's last submitted pts.
    public var startPTS: MediaTime
    /// The last keyframe at or before the target. Nil when the index has none (decode from the file start).
    public var keyframe: KeyframeIndex.Entry?
    /// Frames to submit to the decoder, after subtracting skippable ones.
    public var framesToDecode: Int
    public var predictedMilliseconds: Double
    /// Decode the keyframe first and show it while the rest decodes (predicted time over the threshold).
    public var showsKeyframePreview: Bool
    /// The old decoder state is discarded (flush both receivers, reset the decoder).
    public var needsFlush: Bool
}

/// What a scrub will do.
public enum ScrubPlan: Sendable, Hashable {
    /// Decode this keyframe alone and show it.
    case showKeyframe(KeyframeIndex.Entry)
    /// The keyframe is already on screen.
    case alreadyDisplayed
    /// The index has no keyframe at or before the target.
    case noKeyframe
}

/// Chooses where a seek starts decoding (design section 7.5). Pure and deterministic.
public struct SeekPlanner: Sendable, Hashable {
    /// A restart predicted to take longer than this shows the keyframe first.
    public static let previewThresholdMilliseconds = 150.0
    /// Flush plus one demuxer seek, added to a restart.
    public static let defaultRestartOverheadMilliseconds = 4.0

    public var rates: DecodeRates
    public var previewThresholdMilliseconds: Double
    public var restartOverheadMilliseconds: Double
    /// The "Show a keyframe preview while seeking" setting.
    public var keyframePreviewEnabled: Bool

    public init(
        rates: DecodeRates = DecodeRates(),
        previewThresholdMilliseconds: Double = SeekPlanner.previewThresholdMilliseconds,
        restartOverheadMilliseconds: Double = SeekPlanner.defaultRestartOverheadMilliseconds,
        keyframePreviewEnabled: Bool = true
    ) {
        self.rates = rates
        self.previewThresholdMilliseconds = previewThresholdMilliseconds
        self.restartOverheadMilliseconds = restartOverheadMilliseconds
        self.keyframePreviewEnabled = keyframePreviewEnabled
    }

    public func planExact(
        target: MediaTime,
        index: KeyframeIndex,
        decoder: DecoderPosition?,
        profile: DecodeProfile
    ) -> SeekPlan {
        let rate = rates.framesPerSecond(
            codec: profile.codec, decoder: profile.decoder, width: profile.width, height: profile.height
        )
        let keyframe = index.entry(atOrBefore: target)
        let restartPTS = keyframe?.pts ?? .zero
        let restartFrames = framesInclusive(from: restartPTS, to: target, profile: profile)
        // Both starts skip the same kind of frames, so both costs count only frames submitted.
        let restartEffective = effectiveFrames(restartFrames, profile: profile)
        let restartMilliseconds = restartOverheadMilliseconds + milliseconds(frames: restartEffective, rate: rate)

        if let decoder {
            let ahead = framesBetween(decoder.lastSubmittedPTS, target, profile: profile)
            if ahead >= 1 {
                let effective = effectiveFrames(ahead, profile: profile)
                let continueMilliseconds = milliseconds(frames: effective, rate: rate)
                if continueMilliseconds <= restartMilliseconds {
                    return SeekPlan(
                        start: .continueDecoder,
                        startPTS: decoder.lastSubmittedPTS,
                        keyframe: keyframe,
                        framesToDecode: effective,
                        predictedMilliseconds: continueMilliseconds,
                        showsKeyframePreview: false,
                        needsFlush: false
                    )
                }
            }
        }

        return SeekPlan(
            start: .keyframe,
            startPTS: restartPTS,
            keyframe: keyframe,
            framesToDecode: restartEffective,
            predictedMilliseconds: restartMilliseconds,
            showsKeyframePreview: keyframePreviewEnabled && keyframe != nil
                && restartFrames > 1 && restartMilliseconds > previewThresholdMilliseconds,
            needsFlush: true
        )
    }

    public func planScrub(target: MediaTime, index: KeyframeIndex, displayedKeyframe: MediaTime?) -> ScrubPlan {
        guard let keyframe = index.entry(atOrBefore: target) else { return .noKeyframe }
        if keyframe.pts == displayedKeyframe { return .alreadyDisplayed }
        return .showKeyframe(keyframe)
    }

    /// Frames after `from` up to and including the one displayed at `target`.
    private func framesBetween(_ from: MediaTime, _ target: MediaTime, profile: DecodeProfile) -> Int {
        let delta = target.microseconds - from.microseconds
        guard delta > 0 else { return 0 }
        // The small bias absorbs frame durations rounded to whole microseconds (1/24 s is 41667 us).
        return Int(Double(delta) / Double(profile.frameDuration.microseconds) + 0.01)
    }

    /// Frames from the keyframe at `from` through the target frame.
    private func framesInclusive(from: MediaTime, to target: MediaTime, profile: DecodeProfile) -> Int {
        framesBetween(from, target, profile: profile) + 1
    }

    /// The keyframe itself and the target frame are always submitted; the rest may be thinned.
    private func effectiveFrames(_ frames: Int, profile: DecodeProfile) -> Int {
        guard frames > 2, profile.skippableFraction > 0 else { return frames }
        let skippable = Double(frames - 2) * profile.skippableFraction
        return frames - Int(skippable)
    }

    private func milliseconds(frames: Int, rate: Double) -> Double {
        Double(frames) / rate * 1_000
    }
}

/// Latest request wins, one in flight (design section 7.5, scrub step 2). Used for scrubs and
/// for key-repeat seeks the engine cannot keep up with.
public struct LatestWinsCoalescer<Value: Sendable & Equatable>: Sendable {
    public private(set) var inFlight: Value?
    public private(set) var pending: Value?

    public init() {}

    public var isBusy: Bool { inFlight != nil }

    /// Returns `value` when it should start now, or nil when it was stored as the pending one.
    public mutating func request(_ value: Value) -> Value? {
        if inFlight == nil {
            inFlight = value
            pending = nil
            return value
        }
        pending = value
        return nil
    }

    /// The in-flight request finished. Returns the pending request to run next, which becomes in flight.
    public mutating func finish() -> Value? {
        inFlight = nil
        guard let next = pending else { return nil }
        pending = nil
        inFlight = next
        return next
    }

    /// An exact seek supersedes everything queued.
    public mutating func cancel() {
        inFlight = nil
        pending = nil
    }
}

public typealias ScrubCoalescer = LatestWinsCoalescer<MediaTime>
