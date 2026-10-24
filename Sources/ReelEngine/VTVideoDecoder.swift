import CoreMedia
import CoreVideo
import Foundation
import ReelCore
import Synchronization
import VideoToolbox

/// Direct `VTDecompressionSession` decode (design section 7.3, hardware path).
///
/// One session per video stream, kept alive for the whole file. Decode is asynchronous; each
/// frame's output handler tags it with the generation of its packet and drops it when a newer
/// generation was set in the meantime. Output is `420v` (8-bit) or `x420` (10-bit), IOSurface
/// backed and Metal compatible. Frames arrive in decode order (temporal processing is ignored by
/// the hardware decoders); `PresentationOrderer` restores presentation order.
public final class VTVideoDecoder: VideoDecoding {
    public let kind: VideoDecoderKind = .hardware
    public let format: VideoFormat
    public let formatDescription: CMVideoFormatDescription

    /// Counters shared with the output handlers, which may outlive a decode call.
    private final class Counters: Sendable {
        let generation = Atomic<UInt64>(0)
        let failures = Atomic<Int>(0)
        let submitted = Atomic<Int>(0)
        let delivered = Atomic<Int>(0)
    }

    private let handler: DecodeHandler
    private let session: Mutex<VTDecompressionSession?>
    private let counters = Counters()

    /// - Parameter requireHardware: fail instead of falling back to Apple's software decoder.
    public init(format: VideoFormat, requireHardware: Bool = false, handler: @escaping DecodeHandler) throws {
        guard let description = format.formatDescription else {
            throw EngineError.unsupportedCodec("\(format.codecName) has no VideoToolbox format description")
        }
        if format.codec == .vp9 { FormatDescriptionBuilder.registerSupplementalDecoders() }
        self.format = format
        self.formatDescription = description
        self.handler = handler
        session = Mutex(try VTVideoDecoder.makeSession(description, format: format, requireHardware: requireHardware))
    }

    deinit {
        invalidate()
    }

    /// Pixel format for decoded output: 4:2:0 bi-planar, 8 or 10-bit, matching the stream's range.
    public static func outputPixelFormat(bitDepth: Int, fullRange: Bool) -> OSType {
        if bitDepth > 8 {
            return fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        return fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private static func makeSession(_ description: CMVideoFormatDescription, format: VideoFormat, requireHardware: Bool) throws -> VTDecompressionSession {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputPixelFormat(bitDepth: format.bitDepth, fullRange: format.color.isFullRange),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var specification: [CFString: Any] = [:]
        if requireHardware {
            specification[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: specification.isEmpty ? nil : specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw MediaStatusError(status: status, operation: "VTDecompressionSessionCreate(\(format.codecName))")
        }
        return session
    }

    /// True when VideoToolbox picked its hardware decoder for this session.
    public var usesHardware: Bool {
        session.withLock { session in
            guard let session else { return false }
            var value: CFTypeRef?
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &value)
            return (value as? Bool) ?? false
        }
    }

    /// Turns `kVTDecompressionPropertyKey_RealTime` on for steady playback, off for seek bursts.
    public func setRealTime(_ realTime: Bool) {
        session.withLock { session in
            guard let session else { return }
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: realTime ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }

    public var currentGeneration: UInt64 { counters.generation.load(ordering: .acquiring) }
    public var consecutiveFailures: Int { counters.failures.load(ordering: .relaxed) }
    /// Packets submitted and frames handed to the handler since creation.
    public var submittedCount: Int { counters.submitted.load(ordering: .relaxed) }
    public var deliveredCount: Int { counters.delivered.load(ordering: .relaxed) }

    public func cancel(olderThan generation: UInt64) {
        var current = counters.generation.load(ordering: .relaxed)
        while current < generation {
            let (exchanged, original) = counters.generation.compareExchange(expected: current, desired: generation, ordering: .acquiringAndReleasing)
            if exchanged { break }
            current = original
        }
    }

    public func reset(generation: UInt64) {
        cancel(olderThan: generation)
        // Frames still held by the decoder belong to the old run; let them out so they are dropped.
        session.withLock { session in
            guard let session else { return }
            VTDecompressionSessionFinishDelayedFrames(session)
        }
    }

    public func decode(_ packet: Packet, generation frameGeneration: UInt64, output: Bool) throws {
        let formatDescription = self.formatDescription
        var flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        if !output { flags.insert(._DoNotOutputFrame) }
        let counters = self.counters
        let handler = self.handler
        let status: OSStatus = try session.withLock { session in
            guard let session else { return kVTInvalidSessionErr }
            // Built inside the lock so the sample shares the session's isolation region.
            let sample = try packet.makeSampleBuffer(format: formatDescription)
            return VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: nil) { status, _, imageBuffer, presentationTime, duration in
                guard frameGeneration >= counters.generation.load(ordering: .acquiring) else { return }
                if status == noErr, let imageBuffer {
                    counters.failures.store(0, ordering: .relaxed)
                    counters.delivered.add(1, ordering: .relaxed)
                    let frame = DecodedFrame(
                        pixelBuffer: CVReadOnlyPixelBuffer(fresh: imageBuffer),
                        presentationTime: presentationTime,
                        duration: duration,
                        generation: frameGeneration,
                        decoder: .hardware
                    )
                    handler(.frame(frame))
                } else if status != noErr {
                    let count = counters.failures.add(1, ordering: .relaxed).newValue
                    handler(.failed(presentationTime: presentationTime, generation: frameGeneration, status: status, consecutiveFailures: count))
                } else if output {
                    // No error and no picture: VideoToolbox dropped the frame. Whoever waits for it
                    // (the orderer, a decode credit) must hear that it will not come.
                    handler(.dropped(presentationTime: presentationTime, generation: frameGeneration))
                }
            }
        }
        counters.submitted.add(1, ordering: .relaxed)
        if status != noErr {
            throw MediaStatusError(status: status, operation: "VTDecompressionSessionDecodeFrame")
        }
    }

    public func drainSynchronously() {
        session.withLock { session in
            guard let session else { return }
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    public func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                drainSynchronously()
                continuation.resume()
            }
        }
    }

    /// Waits for in-flight frames without forcing out the ones held for reordering.
    public func waitForAsynchronousFrames() {
        session.withLock { session in
            guard let session else { return }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    public func invalidate() {
        session.withLock { session in
            guard let current = session else { return }
            VTDecompressionSessionWaitForAsynchronousFrames(current)
            VTDecompressionSessionInvalidate(current)
            session = nil
        }
    }
}
