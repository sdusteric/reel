import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ReelCore
import Synchronization

/// One decoded picture, tagged with the seek generation of the packet that produced it.
public struct DecodedFrame: Sendable {
    public let pixelBuffer: CVReadOnlyPixelBuffer
    public let presentationTime: CMTime
    public let duration: CMTime
    public let generation: UInt64
    public let decoder: VideoDecoderKind

    public init(pixelBuffer: CVReadOnlyPixelBuffer, presentationTime: CMTime, duration: CMTime, generation: UInt64, decoder: VideoDecoderKind) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.duration = duration
        self.generation = generation
        self.decoder = decoder
    }

    public var time: MediaTime {
        presentationTime.isValid ? MediaTime(seconds: presentationTime.seconds) : .zero
    }

    public var width: Int { pixelBuffer.withUnsafeBuffer { CVPixelBufferGetWidth($0) } }
    public var height: Int { pixelBuffer.withUnsafeBuffer { CVPixelBufferGetHeight($0) } }
    public var pixelFormat: OSType { pixelBuffer.withUnsafeBuffer { CVPixelBufferGetPixelFormatType($0) } }

    /// A colour attachment value as a string (e.g. `kCVImageBufferTransferFunctionKey`).
    public func attachment(_ key: CFString) -> String? {
        pixelBuffer.withUnsafeBuffer { CVBufferCopyAttachment($0, key, nil) as? String }
    }

    public func attachmentData(_ key: CFString) -> Data? {
        pixelBuffer.withUnsafeBuffer { CVBufferCopyAttachment($0, key, nil) as? Data }
    }
}

/// What a decoder reports through its handler.
public enum DecodeEvent: Sendable {
    case frame(DecodedFrame)
    /// A frame failed to decode. `consecutiveFailures` counts failures since the last good frame.
    case failed(presentationTime: CMTime, generation: UInt64, status: Int32, consecutiveFailures: Int)
    /// The decoder dropped a frame submitted for output without an error (VideoToolbox in
    /// real-time mode falling behind). It will not arrive; it is not a decode failure.
    case dropped(presentationTime: CMTime, generation: UInt64)
}

public typealias DecodeHandler = @Sendable (DecodeEvent) -> Void

/// Common surface of `VTVideoDecoder` and `SoftwareVideoDecoder`.
public protocol VideoDecoding: AnyObject, Sendable {
    var kind: VideoDecoderKind { get }

    /// Submits one prepared packet. With `output` false the frame is decoded for reference only and
    /// never reaches the handler (pre-target frames of an exact seek).
    func decode(_ packet: Packet, generation: UInt64, output: Bool) throws

    /// Frames of older generations are dropped from now on (cancel by generation, no waiting).
    func cancel(olderThan generation: UInt64)

    /// Starts a new decode run at a keyframe: drops queued work and decoder references.
    func reset(generation: UInt64)

    /// Emits every frame still held for reordering and returns when all submitted packets are done.
    /// Decoding continues only from a keyframe afterwards.
    func drain() async

    /// Blocking `drain`, for threads and tests.
    func drainSynchronously()

    func invalidate()
}

extension MediaTime {
    /// Exact conversion of a valid CMTime (rounded to microseconds); nil when invalid.
    public init?(_ time: CMTime) {
        guard time.isValid, time.timescale != 0 else { return nil }
        self.init(value: time.value, timeBaseNum: 1, timeBaseDen: time.timescale)
    }
}

/// Puts decoded frames back into presentation order.
///
/// VideoToolbox calls back in decode order, so a B-frame stream comes out shuffled. The caller
/// registers the pts of every packet it submits for output; a frame is released once every
/// expected frame with a smaller pts has been released or has failed. Frames whose pts was never
/// registered pass straight through.
public final class PresentationOrderer: Sendable {
    private struct State {
        var expected: [MediaTime] = []   // sorted
        var held: [MediaTime: DecodedFrame] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Registers a packet submitted with `output: true`.
    public func expect(_ pts: CMTime) {
        guard let time = MediaTime(pts) else { return }
        state.withLock { state in
            let index = state.expected.firstIndex { $0 > time } ?? state.expected.count
            if index > 0, state.expected[index - 1] == time { return }
            state.expected.insert(time, at: index)
        }
    }

    /// Takes a decoded frame and returns the frames that are now in order.
    public func receive(_ frame: DecodedFrame) -> [DecodedFrame] {
        guard let time = MediaTime(frame.presentationTime) else { return [frame] }
        return state.withLock { state in
            guard state.expected.contains(time) else { return [frame] }
            state.held[time] = frame
            return release(&state)
        }
    }

    /// A frame that will not arrive (decode failure). Returns frames it was holding back.
    public func fail(_ pts: CMTime) -> [DecodedFrame] {
        guard let time = MediaTime(pts) else { return [] }
        return state.withLock { state in
            state.expected.removeAll { $0 == time && state.held[$0] == nil }
            return release(&state)
        }
    }

    /// Frames still held, in order, and forgets every expectation (end of stream or a drain).
    public func flush() -> [DecodedFrame] {
        state.withLock { state in
            let frames = state.held.sorted { $0.key < $1.key }.map(\.value)
            state = State()
            return frames
        }
    }

    /// Forgets everything (a new seek).
    public func reset() {
        state.withLock { $0 = State() }
    }

    public var pendingCount: Int { state.withLock { $0.expected.count } }

    private func release(_ state: inout State) -> [DecodedFrame] {
        var ready: [DecodedFrame] = []
        while let first = state.expected.first, let frame = state.held.removeValue(forKey: first) {
            state.expected.removeFirst()
            ready.append(frame)
        }
        return ready
    }
}

/// Turns decoded frames into sample buffers and enqueues them on a macOS 27 video renderer
/// receiver (design section 7.3). Holds at most `maxFramesAhead` frames between the decoder and
/// the receiver; frames from an older seek generation are dropped before enqueue.
public actor VideoOutput {
    /// A 4K P010 frame is about 25 MB, so the decoded-ahead queue is capped at 8 frames.
    public static let maxFramesAhead = 8
    /// Frames due within this much of the clock skip the receiver's back-pressure. Paused, the
    /// receiver takes only about 25 MB (one 4K frame past the shown one) and asks for more about
    /// 20 ms after that frame comes due, so at 60 fps the next frame would arrive late.
    public static let immediateLead = MediaTime.milliseconds(100)

    public enum EnqueueOutcome: Sendable, Equatable {
        case enqueued
        case enqueuedWithDecodeFailures
        /// The frame was older than the current generation and was not enqueued.
        case dropped
        case cancelledByFlush
        case failed(String)
    }

    private let receiver: AVSampleBufferVideoRenderer.Receiver
    private var generation: UInt64 = 0
    private var formatCache: (key: FormatKey, description: CMVideoFormatDescription)?
    private let ahead = Mutex<Int>(0)
    private var spaceWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var enqueuedCount = 0
    public private(set) var lastEnqueuedTime: CMTime = .invalid

    private struct FormatKey: Equatable {
        var width: Int
        var height: Int
        var pixelFormat: OSType
        var attachments: String
    }

    private let clock: (@Sendable () -> MediaTime)?

    /// - Parameter clock: the synchronizer time; with it, frames due within `immediateLead` are
    ///   enqueued at once instead of waiting for the receiver to ask.
    public init(receiver: sending AVSampleBufferVideoRenderer.Receiver, clock: (@Sendable () -> MediaTime)? = nil) {
        self.receiver = receiver
        self.clock = clock
    }

    /// True when `frame` is due within `immediateLead` of the clock.
    nonisolated func isDueSoon(_ frame: DecodedFrame) -> Bool {
        guard let clock, let pts = MediaTime(frame.presentationTime) else { return false }
        return pts <= clock() + VideoOutput.immediateLead
    }

    /// Frames reserved or waiting for the receiver.
    public nonisolated var framesAhead: Int { ahead.withLock { $0 } }

    /// Raises the current generation; queued frames of older generations are dropped.
    public func setGeneration(_ generation: UInt64) {
        self.generation = max(self.generation, generation)
    }

    public var currentGeneration: UInt64 { generation }

    /// Waits until fewer than `maxFramesAhead` frames are pending, then reserves a slot. Call before
    /// submitting a packet that will produce an output frame; `enqueue` releases the slot.
    public func reserveSlot() async {
        while ahead.withLock({ count in
            guard count >= VideoOutput.maxFramesAhead else { count += 1; return false }
            return true
        }) {
            await withCheckedContinuation { spaceWaiters.append($0) }
        }
    }

    /// Gives back a slot reserved for a frame that will not arrive (a skipped or failed frame).
    public func releaseSlot() {
        ahead.withLock { $0 = max(0, $0 - 1) }
        resumeSpaceWaiters()
    }

    /// Enqueues a decoded frame. Suspends under receiver back-pressure.
    @discardableResult
    public func enqueue(_ frame: DecodedFrame, releasingSlot: Bool = true) async -> EnqueueOutcome {
        defer {
            if releasingSlot { releaseSlot() }
        }
        guard frame.generation >= generation else { return .dropped }
        let sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
        do {
            sample = try makeSampleBuffer(frame)
        } catch {
            return .failed(String(describing: error))
        }
        do {
            // Bounded: only the frames of the next 100 ms bypass the receiver's readiness.
            let result = isDueSoon(frame) ? receiver.enqueueImmediately(sample) : try await receiver.enqueue(sample)
            switch result {
            case .enqueued:
                enqueuedCount += 1
                lastEnqueuedTime = frame.presentationTime
                return .enqueued
            case .enqueuedWithDecodeFailures:
                enqueuedCount += 1
                lastEnqueuedTime = frame.presentationTime
                return .enqueuedWithDecodeFailures
            case .cancelledDueToFlush, .cancelledDueToFlushRequiredToResume:
                return .cancelledByFlush
            case .cancelledDueToError(let error):
                return .failed(String(describing: error))
            @unknown default:
                return .failed("unknown enqueue result")
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Flushes the receiver. With `removingDisplayedImage` false the last picture stays on screen.
    public func flush(removingDisplayedImage: Bool = false) async {
        await receiver.flush(removingDisplayedImage: removingDisplayedImage)
    }

    private func resumeSpaceWaiters() {
        let waiters = spaceWaiters
        spaceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// A ready sample buffer for `frame`, reusing the format description while the pixel buffer
    /// format and colour stay the same.
    func makeSampleBuffer(_ frame: DecodedFrame) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let key = frame.pixelBuffer.withUnsafeBuffer { pixelBuffer in
            FormatKey(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
                attachments: VideoOutput.colorSignature(pixelBuffer)
            )
        }
        let description: CMVideoFormatDescription
        if let cached = formatCache, cached.key == key {
            description = cached.description
        } else {
            description = try frame.pixelBuffer.withUnsafeBuffer { try VideoOutput.formatDescription(for: $0) }
            formatCache = (key, description)
        }
        return try VideoOutput.readySampleBuffer(frame, format: description)
    }

    /// A ready sample buffer carrying the decoded picture with the stream pts.
    public static func readySampleBuffer(_ frame: DecodedFrame, format: CMVideoFormatDescription) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        try frame.pixelBuffer.withUnsafeBuffer { pixelBuffer in
            let sample = try sampleBuffer(pixelBuffer, format: format, time: frame.presentationTime, duration: frame.duration)
            return CMReadySampleBuffer(fresh: sample)
        }
    }

    static func colorSignature(_ buffer: CVPixelBuffer) -> String {
        [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
            .map { (CVBufferCopyAttachment(buffer, $0, nil) as? String) ?? "-" }
            .joined(separator: "|")
    }

    public static func formatDescription(for pixelBuffer: CVPixelBuffer) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw MediaStatusError(status: status, operation: "CMVideoFormatDescriptionCreateForImageBuffer")
        }
        return description
    }

    /// `CMSampleBufferCreateReadyWithImageBuffer` with the stream pts.
    public static func sampleBuffer(_ pixelBuffer: CVPixelBuffer, format: CMVideoFormatDescription, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw MediaStatusError(status: status, operation: "CMSampleBufferCreateReadyWithImageBuffer")
        }
        return sample
    }
}

/// A display layer that is in no window, with its synchronizer and output: the headless target
/// tests and reelctl enqueue on. A bare `AVSampleBufferVideoRenderer` without a layer rejects
/// enqueues, so the layer is required even though nothing is shown.
@MainActor
public final class HeadlessVideoTarget {
    public let layer: AVSampleBufferDisplayLayer
    public let synchronizer: AVSampleBufferRenderSynchronizer
    public let output: VideoOutput

    public init() {
        layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        synchronizer = AVSampleBufferRenderSynchronizer()
        output = VideoOutput(receiver: synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer))
    }
}
