import AVFoundation
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

    /// The frame as an image. HDR frames (PQ or HLG attachments) are tone-mapped to 8-bit sRGB
    /// by `HDRToneMapper`; SDR frames keep the colour space their attachments describe, so
    /// drawing or saving them converts through ColorSync as QuickTime does.
    public static func image(from pixelBuffer: CVReadOnlyPixelBuffer) throws -> CGImage {
        try pixelBuffer.withUnsafeBuffer { try image(from: $0) }
    }

    public static func image(from buffer: CVPixelBuffer) throws -> CGImage {
        if HDRToneMapper.isHDR(buffer) { return try HDRToneMapper.sdrImage(buffer) }
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard status == noErr, let image else {
            throw MediaStatusError(status: status, operation: "VTCreateCGImageFromCVPixelBuffer")
        }
        return image
    }

    /// The frame at `time` as AVFoundation renders it (`AVAssetImageGenerator`, exact time): the
    /// QuickTime pipeline Reel's colour is checked against (`reelctl color`, ColorPipelineTests).
    /// Only for files AVFoundation opens (mp4, mov); nothing is played and no audio is touched.
    ///
    /// `time` is on AVFoundation's timeline, which applies the edit list; FFmpeg's packet times can
    /// be offset from it (a B-frame mp4 starts at 2 frames), so match frames by index with
    /// `videoFrameTimes` and `referenceFrameTime` rather than by time.
    ///
    /// Throws `ReferenceError.dolbyVisionRecord` for a track whose sample description carries a
    /// Dolby Vision record (`dvcC`, `dvvC`, `dvwC`): AVFoundation then fails every frame (-12704 on
    /// the test fixtures, which carry no RPU), while Reel decodes the base layer from `hvcC` alone.
    /// No AVFoundation reference exists for such a file, and none is faked.
    public static func referenceImage(url: URL, at time: MediaTime) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let descriptions = try await track.load(.formatDescriptions)
            if descriptions.contains(where: carriesDolbyVisionRecord) { throw ReferenceError.dolbyVisionRecord }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = false
        return try await generator.image(at: CMTime(value: time.microseconds, timescale: 1_000_000)).image
    }

    public enum ReferenceError: LocalizedError, CustomStringConvertible {
        case dolbyVisionRecord
        case noVideoTrack

        public var description: String {
            switch self {
            case .dolbyVisionRecord:
                "AVFoundation rejects this track's Dolby Vision record; there is no QuickTime reference for it"
            case .noVideoTrack:
                "AVFoundation finds no video track"
            }
        }

        public var errorDescription: String? { description }
    }

    /// True when the format description's sample description extension atoms hold a Dolby Vision
    /// configuration record.
    static func carriesDolbyVisionRecord(_ description: CMFormatDescription) -> Bool {
        guard let atoms = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] else { return false }
        return atoms.keys.contains { ["dvcC", "dvvC", "dvwC"].contains($0) }
    }

    /// Presentation times of the first `count` video frames in display order, as Reel's demuxer
    /// reports them (packets only, nothing is decoded).
    public static func videoFrameTimes(url: URL, count: Int) throws -> [MediaTime] {
        let source = try MediaSource(url: url)
        guard let index = source.videoStreamIndex else { throw EngineError.noPlayableStream }
        var times: [MediaTime] = []
        // A reorder window beyond `count`, so every frame among the first `count` in display order is read.
        while times.count < count + 32, let packet = try source.readPacket() {
            guard packet.streamIndex == index, let pts = packet.pts else { continue }
            times.append(pts)
        }
        return Array(times.sorted().prefix(count))
    }

    /// The start of video frame `index` on AVFoundation's movie timeline, the one
    /// `AVAssetImageGenerator` takes: the track's start plus `index` nominal frame durations.
    /// AVFoundation's decoded frames start there (0 for an ffmpeg mp4 with B-frames, whose edit
    /// list removes the 2-frame delay), while its passthrough samples carry media times before
    /// the edit list. Constant frame rate files only.
    public static func referenceFrameTime(url: URL, index: Int) async throws -> MediaTime {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ReferenceError.noVideoTrack }
        let (range, rate) = try await track.load(.timeRange, .nominalFrameRate)
        guard rate > 0 else { throw ReferenceError.noVideoTrack }
        return MediaTime(seconds: range.start.seconds + Double(index) / Double(rate))
    }

    // MARK: Measurement

    /// Mean Y, Cb and Cr codes of a block of a 4:2:0 bi-planar buffer, in the stream's own code
    /// values (0 to 255 for 8-bit, 0 to 1023 for 10-bit). `size` luma pixels square around the
    /// centre; chroma is the matching `size / 2` block. Nil for other pixel formats.
    public static func meanCodes(_ buffer: CVPixelBuffer, centerX: Int, centerY: Int, size: Int = 16) -> YCbCrCodes? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: tenBit = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: tenBit = false
        default: return nil
        }
        guard CVPixelBufferGetPlaneCount(buffer) == 2, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        func sample(_ plane: Int, _ x: Int, _ y: Int) -> Double {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return 0 }
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
            if tenBit { return Double(row.assumingMemoryBound(to: UInt16.self)[x] >> 6) }
            return Double(row.assumingMemoryBound(to: UInt8.self)[x])
        }
        func block(_ plane: Int, centerX: Int, centerY: Int, size: Int, components: Int, offset: Int) -> Double {
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let half = max(1, size / 2)
            let xs = max(0, centerX - half)..<min(width, max(0, centerX - half) + max(1, size))
            let ys = max(0, centerY - half)..<min(height, max(0, centerY - half) + max(1, size))
            var total = 0.0
            var count = 0.0
            for y in ys {
                for x in xs {
                    total += sample(plane, x * components + offset, y)
                    count += 1
                }
            }
            return count > 0 ? total / count : 0
        }
        let chroma = max(1, size / 2)
        return YCbCrCodes(
            y: block(0, centerX: centerX, centerY: centerY, size: size, components: 1, offset: 0),
            cb: block(1, centerX: centerX / 2, centerY: centerY / 2, size: chroma, components: 2, offset: 0),
            cr: block(1, centerX: centerX / 2, centerY: centerY / 2, size: chroma, components: 2, offset: 1)
        )
    }

    public static func meanCodes(_ buffer: CVReadOnlyPixelBuffer, centerX: Int, centerY: Int, size: Int = 16) -> YCbCrCodes? {
        buffer.withUnsafeBuffer { meanCodes($0, centerX: centerX, centerY: centerY, size: size) }
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

/// Mean code values of a block of a YCbCr buffer.
public struct YCbCrCodes: Sendable, Codable, Hashable {
    public var y: Double
    public var cb: Double
    public var cr: Double

    public init(y: Double, cb: Double, cr: Double) {
        self.y = y
        self.cb = cb
        self.cr = cr
    }
}

/// An image drawn into an 8-bit sRGB bitmap, so reading it back goes through the same ColorSync
/// conversion any viewer applies. Top-left origin.
public struct SRGBRaster: Sendable {
    public let width: Int
    public let height: Int
    /// RGBA, premultiplied (opaque images are unaffected), row after row.
    public let bytes: [UInt8]

    public init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Largest minus smallest green value in a `size` square: 0 on a flat patch.
    public func range(centerX: Int, centerY: Int, size: Int = 16) -> Int {
        let half = max(1, size / 2)
        let x0 = min(max(0, centerX - half), width - 1)
        let y0 = min(max(0, centerY - half), height - 1)
        var low = UInt8.max
        var high = UInt8.min
        for y in y0..<min(height, y0 + max(1, size)) {
            for x in x0..<min(width, x0 + max(1, size)) {
                let value = bytes[(y * width + x) * 4 + 1]
                low = min(low, value)
                high = max(high, value)
            }
        }
        return high >= low ? Int(high - low) : 0
    }

    /// Mean sRGB value of a `size` square around a point (image pixels, top-left origin).
    public func mean(centerX: Int, centerY: Int, size: Int = 16) -> SRGBValue {
        let half = max(1, size / 2)
        let x0 = min(max(0, centerX - half), width - 1)
        let y0 = min(max(0, centerY - half), height - 1)
        let x1 = min(width, x0 + max(1, size))
        let y1 = min(height, y0 + max(1, size))
        var sums = (0.0, 0.0, 0.0)
        var count = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let index = (y * width + x) * 4
                sums.0 += Double(bytes[index])
                sums.1 += Double(bytes[index + 1])
                sums.2 += Double(bytes[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return SRGBValue(r: 0, g: 0, b: 0) }
        return SRGBValue(r: sums.0 / count, g: sums.1 / count, b: sums.2 / count)
    }
}

/// An 8-bit sRGB colour, as means (so fractional).
public struct SRGBValue: Sendable, Codable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// BT.709 luma of the 8-bit values.
    public var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// Largest of |r - g| and |g - b|.
    public var neutralSpread: Double { max(abs(r - g), abs(g - b)) }

    public var rounded: SRGBValue { SRGBValue(r: r.rounded(), g: g.rounded(), b: b.rounded()) }
}
