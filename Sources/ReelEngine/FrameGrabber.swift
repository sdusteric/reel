import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ReelCore
import Synchronization
import VideoToolbox

/// Decodes single frames outside the playback engine: the frame shown at a time, as a pixel buffer
/// or a `CGImage` (via `VTCreateCGImageFromCVPixelBuffer`). Used by tests, seek-bench's PSNR check
/// and shot mode. Synchronous; call it off the main actor.
public enum FrameGrabber {
    public struct Grab: Sendable {
        public let frame: DecodedFrame
        public let format: VideoFormat
        /// Presentation time of the keyframe decoding started from (nil for a decode from the start).
        public let startKeyframe: MediaTime?
        public let packetsSubmitted: Int
    }

    /// Decodes the frame whose display interval contains `time` (the last frame with pts at or
    /// before it), starting from the keyframe at or before `time`.
    /// - Parameter decoder: nil picks hardware when VideoToolbox supports the codec, else software.
    public static func grab(url: URL, at time: MediaTime, decoder: VideoDecoderKind? = nil) throws -> Grab {
        let opened = try Opened(url: url)
        let kind = decoder ?? (opened.format.isHardwareDecodeSupported ? .hardware : .software)
        let startKey = try seekToKeyframe(opened, atOrBefore: time)
        return try decode(opened, until: time, kind: kind, startKeyframe: startKey, skipLeadingFrom: startKey)
    }

    /// Decodes every frame from the start of the file with libavcodec until `time`: the reference a
    /// seek is checked against.
    public static func grabSequential(url: URL, at time: MediaTime) throws -> Grab {
        let opened = try Opened(url: url)
        return try decode(opened, until: time, kind: .software, startKeyframe: nil, skipLeadingFrom: nil)
    }

    /// The frame at `time` as an image.
    public static func grabImage(url: URL, at time: MediaTime, decoder: VideoDecoderKind? = nil) throws -> CGImage {
        try image(from: grab(url: url, at: time, decoder: decoder).frame.pixelBuffer)
    }

    public static func image(from pixelBuffer: CVReadOnlyPixelBuffer) throws -> CGImage {
        try pixelBuffer.withUnsafeBuffer { buffer in
            var image: CGImage?
            let status = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            guard status == noErr, let image else {
                throw MediaStatusError(status: status, operation: "VTCreateCGImageFromCVPixelBuffer")
            }
            return image
        }
    }

    // MARK: PSNR

    /// Luma PSNR in dB between two decoded 4:2:0 bi-planar buffers of the same size (8 or 10-bit).
    /// Returns infinity for identical planes and nil when the sizes or formats cannot be compared.
    public static func lumaPSNR(_ first: CVReadOnlyPixelBuffer, _ second: CVReadOnlyPixelBuffer) -> Double? {
        guard let lumaA = lumaPlane(first), let lumaB = lumaPlane(second),
              lumaA.width == lumaB.width, lumaA.height == lumaB.height, !lumaA.values.isEmpty else { return nil }
        var squared = 0.0
        for index in lumaA.values.indices {
            let difference = lumaA.values[index] - lumaB.values[index]
            squared += difference * difference
        }
        let meanSquared = squared / Double(lumaA.values.count)
        return meanSquared == 0 ? .infinity : 10 * log10(1 / meanSquared)
    }

    /// Luma samples normalised to 0...1.
    public static func lumaPlane(_ pixelBuffer: CVReadOnlyPixelBuffer) -> (width: Int, height: Int, values: [Double])? {
        pixelBuffer.withUnsafeBuffer { buffer -> (width: Int, height: Int, values: [Double])? in
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let sixteenBit = [
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            ].contains(format)
            var values = [Double](repeating: 0, count: width * height)
            for row in 0..<height {
                let line = base.advanced(by: row * stride)
                if sixteenBit {
                    let samples = line.assumingMemoryBound(to: UInt16.self)
                    for column in 0..<width { values[row * width + column] = Double(samples[column] >> 6) / 1023 }
                } else {
                    let samples = line.assumingMemoryBound(to: UInt8.self)
                    for column in 0..<width { values[row * width + column] = Double(samples[column]) / 255 }
                }
            }
            return (width, height, values)
        }
    }

    // MARK: Decoding

    private final class Opened {
        let source: MediaSource
        let format: VideoFormat
        let parameters: CodecParameters
        let videoIndex: Int
        /// Packets read while building the format; replayed when no seek happens.
        var initialPackets: [Packet]
        let keyframes: KeyframeIndex

        init(url: URL) throws {
            source = try MediaSource(url: url)
            guard let videoIndex = source.videoStreamIndex, let stream = source.stream(videoIndex) else {
                throw EngineError.noPlayableStream
            }
            self.videoIndex = videoIndex
            parameters = try CodecParameters(copying: stream)
            var packets: [Packet] = []
            var videoPackets: [Packet] = []
            while videoPackets.count < 12, let packet = try source.readPacket() {
                packets.append(packet)
                if packet.streamIndex == videoIndex { videoPackets.append(packet) }
            }
            format = try FormatDescriptionBuilder.make(stream: stream, firstPackets: videoPackets)
            initialPackets = packets
            let firstKey = videoPackets.first(where: \.isKeyframe)
            var offset = MediaTime.zero
            if let pts = firstKey?.pts, let dts = firstKey?.dts { offset = pts - dts }
            keyframes = KeyframeIndex(source.indexedKeyframes(ptsOffset: offset))
        }

        func nextPacket() throws -> Packet? {
            if !initialPackets.isEmpty { return initialPackets.removeFirst() }
            return try source.readPacket()
        }
    }

    /// Seeks so the next video packet is a keyframe with pts at or before `time`. Returns its pts
    /// when known from the index.
    private static func seekToKeyframe(_ opened: Opened, atOrBefore time: MediaTime) throws -> MediaTime? {
        // A target in the first GOP needs no seek: the packets read at open start there.
        if let firstKey = opened.initialPackets.first(where: { $0.streamIndex == opened.videoIndex && $0.isKeyframe }),
           let firstPTS = firstKey.pts ?? firstKey.dts,
           opened.keyframes.next(after: firstPTS).map({ time < $0.pts }) ?? (time < firstPTS + .seconds(1)) {
            return firstPTS
        }
        let target = opened.keyframes.entry(atOrBefore: time)?.pts ?? time
        let landing = try opened.source.seekVerified(toKeyframe: target)
        opened.initialPackets = landing
        guard let key = landing.last, key.isKeyframe else { return nil }
        return key.pts ?? key.dts
    }

    private final class Collector: Sendable {
        struct State {
            var best: DecodedFrame?
            var passed = false
            var failures = 0
        }

        let target: CMTime
        let state = Mutex(State())

        init(target: MediaTime) {
            self.target = CMTime(value: target.microseconds, timescale: 1_000_000)
        }

        func handle(_ event: DecodeEvent) {
            switch event {
            case .frame(let frame):
                state.withLock { state in
                    if CMTimeCompare(frame.presentationTime, target) <= 0 {
                        if let best = state.best, CMTimeCompare(best.presentationTime, frame.presentationTime) > 0 { return }
                        state.best = frame
                    } else {
                        state.passed = true
                    }
                }
            case .failed:
                state.withLock { $0.failures += 1 }
            case .dropped:
                break
            }
        }
    }

    private static func decode(_ opened: Opened, until time: MediaTime, kind: VideoDecoderKind, startKeyframe: MediaTime?, skipLeadingFrom: MediaTime?) throws -> Grab {
        let collector = Collector(target: time)
        let orderer = PresentationOrderer()
        let handler: DecodeHandler = { event in
            switch event {
            case .frame(let frame):
                orderer.receive(frame).forEach { collector.handle(.frame($0)) }
            case .failed(let pts, _, _, _), .dropped(let pts, _):
                collector.handle(event)
                orderer.fail(pts).forEach { collector.handle(.frame($0)) }
            }
        }
        let decoder: any VideoDecoding
        switch kind {
        case .hardware:
            decoder = try VTVideoDecoder(format: opened.format, handler: handler)
        case .software:
            decoder = try SoftwareVideoDecoder(parameters: opened.parameters, format: opened.format, handler: handler)
        }
        defer { decoder.invalidate() }
        var submitted = 0
        var sawKeyframe = false
        var startPTS: MediaTime?
        let limit = time + .seconds(3)
        // Outputs are expected when read, a reorder window ahead of the decoder: a frame after the
        // target that decodes first (a P-frame before its B-frames) is then held by the orderer
        // until the frames before it are out, and cannot end the grab before the target frame
        // was even submitted.
        let window = VideoFeeder.lookaheadWindow(for: opened.format.codec)
        var pending: [Packet] = []
        var endOfInput = false
        while true {
            while pending.count < window, !endOfInput {
                guard let packet = try opened.nextPacket() else {
                    endOfInput = true
                    break
                }
                guard packet.streamIndex == opened.videoIndex else { continue }
                if !sawKeyframe {
                    guard packet.isKeyframe else { continue }
                    sawKeyframe = true
                    startPTS = packet.pts ?? packet.dts
                }
                let prepared = opened.format.prepare(packet)
                // RASL pictures after the CRA we start from reference the previous GOP and cannot decode.
                if skipLeadingFrom != nil, let startPTS, let pts = prepared.pts, pts < startPTS, opened.format.pictureFlags(prepared).isRASL {
                    continue
                }
                orderer.expect(prepared.cmPTS)
                pending.append(prepared)
            }
            guard !pending.isEmpty else { break }
            let prepared = pending.removeFirst()
            try decoder.decode(prepared, generation: 0, output: true)
            submitted += 1
            if submitted % 4 == 0, collector.state.withLock({ $0.passed }) { break }
            if let pts = prepared.pts, pts > limit { break }
            if kind == .software, let software = decoder as? SoftwareVideoDecoder {
                // Keep the job queue short so the check above sees frames as they come out.
                while software.pendingJobs > 8 { Thread.sleep(forTimeInterval: 0.0005) }
            }
        }
        decoder.drainSynchronously()
        orderer.flush().forEach { collector.handle(.frame($0)) }
        guard let frame = collector.state.withLock({ $0.best }) else {
            throw EngineError.decoderFailed("no frame at or before \(time) (\(submitted) packets submitted)")
        }
        return Grab(frame: frame, format: opened.format, startKeyframe: startKeyframe ?? startPTS, packetsSubmitted: submitted)
    }
}
