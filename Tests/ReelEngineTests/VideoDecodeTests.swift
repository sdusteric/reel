import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// Collects decoder output for assertions.
private final class FrameSink: Sendable {
    /// Retained frames. Holding pool buffers stalls the software decoder at its threshold, so
    /// sinks that only count keep `retainsFrames` false.
    let frames = Mutex<[DecodedFrame]>([])
    let seen = Mutex<[(time: MediaTime, generation: UInt64)]>([])
    let failures = Mutex<Int>(0)
    let dropped = Mutex<Int>(0)
    let retainsFrames: Bool

    init(retainsFrames: Bool = true) {
        self.retainsFrames = retainsFrames
    }

    var handler: DecodeHandler {
        { [self] event in
            switch event {
            case .frame(let frame):
                seen.withLock { $0.append((frame.time, frame.generation)) }
                if retainsFrames { frames.withLock { $0.append(frame) } }
            case .failed:
                failures.withLock { $0 += 1 }
            case .dropped:
                dropped.withLock { $0 += 1 }
            }
        }
    }

    var count: Int { seen.withLock { $0.count } }
    var times: [MediaTime] { seen.withLock { $0.map(\.time) } }
}

/// Serialized: run in parallel, its synchronous decode cases filled every cooperative pool
/// thread for the first seconds of `swift test` and held back other suites' timing checks.
@Suite(.serialized) struct VideoDecodeTests {
    private static func is10Bit(_ fixture: Fixture) -> Bool { [.hevc10, .hdr10, .nocues].contains(fixture) }

    @Test(arguments: Fixture.hardwareFixtures)
    func firstFrameDecodesWithVideoToolbox(_ fixture: Fixture) throws {
        let start = try fixture.videoStart()
        let grab = try FrameGrabber.grab(url: fixture.url(), at: start, decoder: .hardware)
        let frame = grab.frame
        #expect(frame.decoder == .hardware)
        #expect(frame.time == start)
        #expect(frame.width == fixture.size.width && frame.height == fixture.size.height)
        let expected = Self.is10Bit(fixture) ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        #expect(frame.pixelFormat == expected, "420v for 8-bit, x420 for 10-bit")
        let backed = frame.pixelBuffer.withUnsafeBuffer { CVPixelBufferGetIOSurface($0) != nil }
        #expect(backed)
        #expect(try FrameGrabber.image(from: frame.pixelBuffer).width == fixture.size.width)
    }

    @Test(arguments: Fixture.allCases)
    func firstFrameDecodesInSoftware(_ fixture: Fixture) throws {
        let start = try fixture.videoStart()
        let grab = try FrameGrabber.grab(url: fixture.url(), at: start, decoder: .software)
        #expect(grab.frame.time == start)
        let frame = grab.frame
        #expect(frame.decoder == .software)
        #expect(frame.width == fixture.size.width && frame.height == fixture.size.height)
        let expected = Self.is10Bit(fixture) ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        #expect(frame.pixelFormat == expected, "NV12 for 8-bit, P010 for 10-bit")
        #expect(frame.attachment(kCVImageBufferYCbCrMatrixKey) != nil, "colour attachments are set")
        let luma = try #require(FrameGrabber.lumaPlane(frame.pixelBuffer))
        let mean = luma.values.reduce(0, +) / Double(luma.values.count)
        #expect(mean > 0.05 && mean < 0.95, "testsrc2 is neither black nor white")
    }

    @Test(arguments: [VideoDecoderKind.hardware, .software])
    func hdr10ColourKeysReachTheDecodedBuffers(_ kind: VideoDecoderKind) throws {
        let frame = try FrameGrabber.grab(url: Fixture.hdr10.url(), at: .zero, decoder: kind).frame
        #expect(frame.attachment(kCVImageBufferTransferFunctionKey) == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(frame.attachment(kCVImageBufferColorPrimariesKey) == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(frame.attachment(kCVImageBufferYCbCrMatrixKey) == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        #expect(frame.attachmentData(kCVImageBufferMasteringDisplayColorVolumeKey)?.count == 24)
        #expect(frame.attachmentData(kCVImageBufferContentLightLevelInfoKey) == Data([0x03, 0xe8, 0x01, 0x90]))
    }

    /// Mid-GOP targets: the frame shown at `target` is `expected`.
    static let midGOPCases: [(Fixture, Double, Double)] = [
        (.hevc10, 5.02, 120.0 / 24.0),
        (.h264, 4.51, 4.5),
        (.av1, 2.51, 2.5),
        (.vp9, 1.51, 1.5),
        (.nocues, 15.02, 360.0 / 24.0),
    ]

    @Test(arguments: midGOPCases)
    func videoToolboxFrameAtAMidGOPTimeMatchesASequentialSoftwareDecode(_ fixture: Fixture, _ target: Double, _ expected: Double) throws {
        let url = try fixture.url()
        let seeked = try FrameGrabber.grab(url: url, at: .seconds(target), decoder: .hardware)
        #expect(abs(seeked.frame.time.seconds - expected) < 0.001, "landed on \(seeked.frame.time)")
        let startKey = try #require(seeked.startKeyframe)
        #expect(startKey < .seconds(target) && startKey > .seconds(target - 10.5))
        let reference = try FrameGrabber.grabSequential(url: url, at: .seconds(target))
        #expect(reference.frame.time == seeked.frame.time)
        let psnr = try #require(FrameGrabber.lumaPSNR(seeked.frame.pixelBuffer, reference.frame.pixelBuffer))
        #expect(psnr >= 35, "luma PSNR \(psnr) dB")
    }

    /// Shot mode's entry point: the decode runs off the caller and returns an image of the frame.
    @Test func engineFactoryGrabsTheFrameAsAnImage() async throws {
        let image = try await EngineFactory.grabFrame(url: Fixture.h264.url(), at: .seconds(1))
        #expect(image.width == 1920 && image.height == 1080)
    }

    @Test func rotatedMovieDecodesAtItsCodedSize() throws {
        let grab = try FrameGrabber.grab(url: Fixture.rot90.url(), at: .seconds(1), decoder: .hardware)
        #expect(grab.frame.width == 1280 && grab.frame.height == 720)
        #expect(grab.format.rotation == 270)
    }

    @Test func annexBTransportStreamDecodesInHardware() throws {
        let start = try Fixture.annexB.videoStart()
        let target = start + .seconds(1.2)
        let grab = try FrameGrabber.grab(url: Fixture.annexB.url(), at: target, decoder: .hardware)
        #expect(grab.startKeyframe.map { $0 > start } == true, "seeked to the second GOP")
        let reference = try FrameGrabber.grabSequential(url: Fixture.annexB.url(), at: target)
        #expect(grab.frame.time == reference.frame.time)
        let psnr = try #require(FrameGrabber.lumaPSNR(grab.frame.pixelBuffer, reference.frame.pixelBuffer))
        #expect(psnr >= 35, "luma PSNR \(psnr) dB")
    }

    /// The exact-seek path: pre-target frames decoded with DoNotOutput, non-reference ones not
    /// submitted at all, and only frames from the target on reach the handler.
    @Test(arguments: [Fixture.h264, .hevc10])
    func skippingNonReferenceFramesBeforeTheTargetLandsOnTheSameFrame(_ fixture: Fixture) throws {
        let url = try fixture.url()
        let demuxer = try Demuxer(url: url)
        let format = try #require(demuxer.videoFormat)
        let target = MediaTime.seconds(fixture == .h264 ? 9.9 : 10.2) // late in the first GOP
        let source = try MediaSource(url: url)
        let sink = FrameSink()
        let orderer = PresentationOrderer()
        let sinkHandler = sink.handler
        let decoder = try VTVideoDecoder(format: format) { event in
            switch event {
            case .frame(let frame): orderer.receive(frame).forEach { sinkHandler(.frame($0)) }
            case .failed(let pts, _, _, _), .dropped(let pts, _):
                sinkHandler(event)
                orderer.fail(pts).forEach { sinkHandler(.frame($0)) }
            }
        }
        defer { decoder.invalidate() }
        decoder.setRealTime(false)

        // The target frame pts is the largest packet pts at or before the target.
        var packets: [Packet] = []
        while let packet = try source.readPacket() {
            guard packet.streamIndex == source.videoStreamIndex else { continue }
            packets.append(format.prepare(packet))
            if let pts = packet.pts, pts > target + .seconds(1) { break }
        }
        let targetPTS = try #require(packets.compactMap(\.pts).filter { $0 <= target }.max())
        // Every output is expected before the first submit, as the engine registers packets when
        // it reads them: a frame that decodes before a later-read one with an earlier pts was
        // expected would otherwise pass the orderer out of order.
        for packet in packets {
            if let pts = packet.pts, pts >= targetPTS { orderer.expect(packet.cmPTS) }
        }
        var skipped = 0
        for packet in packets {
            let pts = try #require(packet.pts)
            if pts < targetPTS, format.isDisposable(packet) {
                skipped += 1
                continue
            }
            try decoder.decode(packet, generation: 1, output: pts >= targetPTS)
        }
        decoder.drainSynchronously()
        orderer.flush().forEach { sinkHandler(.frame($0)) }
        #expect(skipped > 0, "\(fixture) has non-reference frames to skip")
        let times = sink.times
        #expect(times.first == targetPTS, "first output frame is the target: \(times.prefix(12))")
        #expect(times == times.sorted(), "the orderer restores presentation order")
        #expect(sink.failures.withLock { $0 } == 0)

        let frame = try #require(sink.frames.withLock { $0.first })
        #expect(frame.time == targetPTS)
        let reference = try FrameGrabber.grabSequential(url: url, at: target)
        #expect(reference.frame.time == targetPTS)
        let psnr = try #require(FrameGrabber.lumaPSNR(frame.pixelBuffer, reference.frame.pixelBuffer))
        #expect(psnr >= 35, "luma PSNR \(psnr) dB")
    }

    @Test(arguments: [VideoDecoderKind.hardware, .software])
    func framesOfACancelledGenerationAreDropped(_ kind: VideoDecoderKind) throws {
        let url = try Fixture.syncH264.url()
        let demuxer = try Demuxer(url: url)
        let format = try #require(demuxer.videoFormat)
        let parameters = try #require(demuxer.videoParameters)
        let sink = FrameSink(retainsFrames: false)
        let decoder: any VideoDecoding = kind == .hardware
            ? try VTVideoDecoder(format: format, handler: sink.handler)
            : try SoftwareVideoDecoder(parameters: parameters, format: format, handler: sink.handler)
        defer { decoder.invalidate() }
        let source = try MediaSource(url: url)
        var packets: [Packet] = []
        while packets.count < 30, let packet = try source.readPacket() {
            if packet.streamIndex == source.videoStreamIndex { packets.append(format.prepare(packet)) }
        }
        decoder.cancel(olderThan: 2)
        for packet in packets { try decoder.decode(packet, generation: 1, output: true) }
        decoder.drainSynchronously()
        #expect(sink.count == 0, "generation 1 is older than the current generation 2")

        decoder.reset(generation: 2)
        for packet in packets { try decoder.decode(packet, generation: 2, output: true) }
        decoder.drainSynchronously()
        #expect(sink.count == 30)
        #expect(sink.seen.withLock { $0.allSatisfy { $0.generation == 2 } })
    }

    @Test func softwarePoolWaitsAtItsAllocationThresholdInsteadOfFailing() async throws {
        let url = try Fixture.flv1.url()
        let demuxer = try Demuxer(url: url)
        let parameters = try #require(demuxer.videoParameters)
        let sink = FrameSink()
        let decoder = try SoftwareVideoDecoder(parameters: parameters, format: demuxer.videoFormat, threads: 1, handler: sink.handler)
        defer { decoder.invalidate() }
        let source = try MediaSource(url: url)
        var submitted = 0
        while let packet = try source.readPacket() {
            guard packet.streamIndex == source.videoStreamIndex else { continue }
            try decoder.decode(packet, generation: 0, output: true)
            submitted += 1
        }
        #expect(submitted == 50)
        // The sink holds every frame, so the pool stops at its threshold and the thread waits.
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.count == SoftwareVideoDecoder.poolAllocationThreshold)
        #expect(sink.failures.withLock { $0 } == 0)
        // Releasing the frames lets decoding continue to the end.
        let deadline = ContinuousClock.now + .seconds(4)
        while sink.count < submitted, ContinuousClock.now < deadline {
            sink.frames.withLock { $0.removeAll() }
            try await Task.sleep(for: .milliseconds(5))
        }
        sink.frames.withLock { $0.removeAll() }
        await decoder.drain()
        #expect(sink.count == submitted)
    }

    @MainActor @Test func decodedFramesEnqueueOnAStandaloneLayerWithoutAWindow() async throws {
        let grab = try FrameGrabber.grab(url: Fixture.h264.url(), at: .seconds(1), decoder: .hardware)
        let target = HeadlessVideoTarget()
        let output = target.output
        target.synchronizer.setRate(0, time: grab.frame.presentationTime)

        await output.reserveSlot()
        #expect(output.framesAhead == 1)
        let first = await output.enqueue(grab.frame)
        #expect(first == .enqueued)
        #expect(output.framesAhead == 0)
        #expect(await output.lastEnqueuedTime == grab.frame.presentationTime)

        await output.setGeneration(5)
        let stale = await output.enqueue(grab.frame, releasingSlot: false)
        #expect(stale == .dropped, "a frame from generation 0 is older than 5")
        #expect(await output.enqueuedCount == 1)
        await output.flush(removingDisplayedImage: false)
    }

    /// After a switch from VideoToolbox to software the buffers keep their size, format and
    /// colour but not every extension; the cached format description is reused only when it
    /// matches the new buffer, so the software frames still reach the layer.
    @MainActor @Test func aSoftwareFrameAfterHardwareOnesIsStillEnqueued() async throws {
        let target = HeadlessVideoTarget()
        let output = target.output
        for (index, decoder) in [VideoDecoderKind.hardware, .software, .hardware].enumerated() {
            let grab = try FrameGrabber.grab(url: Fixture.h264.url(), at: .seconds(1 + Double(index)), decoder: decoder)
            target.synchronizer.setRate(0, time: grab.frame.presentationTime)
            await output.reserveSlot()
            let result = await output.enqueue(grab.frame)
            #expect(result == .enqueued, "\(decoder) frame \(index)")
        }
        await output.flush(removingDisplayedImage: false)
    }

    @MainActor @Test func outputReservesAtMostEightFramesAhead() async throws {
        let output = HeadlessVideoTarget().output
        for _ in 0..<VideoOutput.maxFramesAhead { await output.reserveSlot() }
        #expect(output.framesAhead == 8)
        let waiter = Task { await output.reserveSlot() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(output.framesAhead == 8, "the ninth reservation waits")
        await output.releaseSlot()
        await waiter.value
        #expect(output.framesAhead == 8)
    }

    @Test func sampleBuffersCarryTheStreamTimestamp() throws {
        let grab = try FrameGrabber.grab(url: Fixture.hevc10.url(), at: .seconds(2), decoder: .hardware)
        let format = try grab.frame.pixelBuffer.withUnsafeBuffer { try VideoOutput.formatDescription(for: $0) }
        let ready = try VideoOutput.readySampleBuffer(grab.frame, format: format)
        _ = ready
        let pts = grab.frame.presentationTime
        #expect(pts.timescale == 1_000, "mkv time base 1/1000 is kept")
        #expect(abs(pts.seconds - 2.0) < 0.001)
    }
}

@Suite struct PresentationOrdererTests {
    private static func frame(_ milliseconds: Int64) throws -> DecodedFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        return DecodedFrame(
            pixelBuffer: CVReadOnlyPixelBuffer(fresh: pixelBuffer),
            presentationTime: CMTime(value: milliseconds, timescale: 1_000),
            duration: CMTime(value: 40, timescale: 1_000),
            generation: 0,
            decoder: .hardware
        )
    }

    @Test func releasesDecodeOrderFramesInPresentationOrder() throws {
        let orderer = PresentationOrderer()
        for pts in [0, 120, 40, 80] as [Int64] { orderer.expect(CMTime(value: pts, timescale: 1_000)) }
        #expect(orderer.receive(try Self.frame(0)).map(\.time) == [.zero])
        #expect(orderer.receive(try Self.frame(120)).isEmpty)
        #expect(orderer.receive(try Self.frame(40)).map(\.time) == [.milliseconds(40)])
        #expect(orderer.receive(try Self.frame(80)).map(\.time) == [.milliseconds(80), .milliseconds(120)])
        #expect(orderer.pendingCount == 0)
    }

    @Test func aFailedFrameNoLongerHoldsBackLaterOnes() throws {
        let orderer = PresentationOrderer()
        for pts in [40, 80] as [Int64] { orderer.expect(CMTime(value: pts, timescale: 1_000)) }
        #expect(orderer.receive(try Self.frame(80)).isEmpty)
        #expect(orderer.fail(CMTime(value: 40, timescale: 1_000)).map(\.time) == [.milliseconds(80)])
    }

    @Test func unexpectedFramesPassAndFlushEmptiesInOrder() throws {
        let orderer = PresentationOrderer()
        #expect(orderer.receive(try Self.frame(500)).map(\.time) == [.milliseconds(500)])
        for pts in [0, 40, 80] as [Int64] { orderer.expect(CMTime(value: pts, timescale: 1_000)) }
        _ = orderer.receive(try Self.frame(80))
        _ = orderer.receive(try Self.frame(40))
        #expect(orderer.flush().map(\.time) == [.milliseconds(40), .milliseconds(80)])
        #expect(orderer.pendingCount == 0)
    }
}

/// Files whose container gives B-frames decode-order times (fixtures.sh, reorder/): MP4 without a
/// ctts box, an MKV remuxed from one, and AVI files (dts only). The presentation times must come
/// from the picture order count, or for MPEG-4 Part 2 from the VOP types. The ramp's luma rises every frame,
/// so a frame shown out of order is a luma step back.
@Suite(.serialized) struct DecodeOrderTimestampTests {
    static let hardwareFiles = [
        "reorder/hevc_open_gop_no_ctts.mp4", "reorder/h264_no_ctts.mp4", "reorder/hevc_no_ctts_remux.mkv", "reorder/h264_bframes.avi",
    ]
    static let files = hardwareFiles + ["reorder/mpeg4_bframes.avi"]

    private static func videoPackets(_ source: MediaSource) throws -> [Packet] {
        var packets: [Packet] = []
        while let packet = try source.readPacket() {
            if packet.streamIndex == source.videoStreamIndex { packets.append(packet) }
        }
        return packets
    }

    @Test(arguments: files)
    func repairedTimesKeepTheContainerTimesInPictureOrder(_ file: String) throws {
        let source = try MediaSource(url: fixtureURL(file))
        let packets = try Self.videoPackets(source)
        #expect(source.repairsTimestamps)
        #expect(packets.count == 96)
        let pts = packets.compactMap(\.pts)
        #expect(pts.count == packets.count, "every packet has a pts")
        #expect(pts != pts.sorted(), "B-frames moved")
        // One time per frame, 1/24 s apart (an MKV rounds to milliseconds).
        let sorted = pts.sorted()
        let steps = zip(sorted, sorted.dropFirst()).map { ($1 - $0).seconds }
        #expect(steps.allSatisfy { abs($0 - 1.0 / 24) < 0.0015 }, "steps \(steps)")
    }

    @Test(arguments: files)
    func aSeekToTheCutGivesTheSameTimesAsReadingThrough(_ file: String) throws {
        let url = try fixtureURL(file)
        let through = try Self.videoPackets(MediaSource(url: url))
        let byPosition = Dictionary(through.compactMap { packet in packet.position.map { ($0, packet.rawPTS) } }) { first, _ in first }
        let keyframes = through.filter(\.isKeyframe).compactMap(\.pts)
        let cut = try #require(keyframes.first { $0 > .seconds(1) }, "a keyframe after 1 s: \(keyframes)")

        let source = try MediaSource(url: url)
        try source.seek(toKeyframe: cut)
        let after = try Self.videoPackets(source)
        #expect(after.first?.isKeyframe == true)
        #expect(after.count > 40)
        for packet in after {
            let position = try #require(packet.position)
            #expect(packet.rawPTS == byPosition[position] ?? nil, "packet at \(position)")
        }
    }

    @Test(arguments: [Fixture.h264, .hevc10, .syncH264])
    func filesWithCompositionTimesAreLeftAlone(_ fixture: Fixture) throws {
        let repaired = try MediaSource(url: fixture.url())
        let packets = try Self.videoPackets(repaired)
        #expect(!repaired.repairsTimestamps)
        #expect(packets.contains { $0.rawPTS != $0.rawDTS })
    }

    /// The engine's path: VideoToolbox in decode order, then `PresentationOrderer` by pts.
    @Test(arguments: hardwareFiles)
    func hardwareFramesComeOutInDisplayOrder(_ file: String) throws {
        let url = try fixtureURL(file)
        let demuxer = try Demuxer(url: url)
        let format = try #require(demuxer.videoFormat)
        let source = try MediaSource(url: url)
        let packets = try Self.videoPackets(source).map { format.prepare($0) }
        let sink = FrameSink()
        let orderer = PresentationOrderer()
        let sinkHandler = sink.handler
        let decoder = try VTVideoDecoder(format: format) { event in
            switch event {
            case .frame(let frame): orderer.receive(frame).forEach { sinkHandler(.frame($0)) }
            case .failed(let pts, _, _, _), .dropped(let pts, _):
                sinkHandler(event)
                orderer.fail(pts).forEach { sinkHandler(.frame($0)) }
            }
        }
        defer { decoder.invalidate() }
        decoder.setRealTime(false)
        for packet in packets { orderer.expect(packet.cmPTS) }
        for packet in packets { try decoder.decode(packet, generation: 1, output: true) }
        decoder.drainSynchronously()
        orderer.flush().forEach { sinkHandler(.frame($0)) }

        let frames = sink.frames.withLock { $0 }
        #expect(frames.count == 96)
        #expect(sink.failures.withLock { $0 } == 0)
        let lumas = frames.compactMap { frame -> Double? in
            guard let plane = FrameGrabber.lumaPlane(frame.pixelBuffer) else { return nil }
            return plane.values.reduce(0, +) / Double(plane.values.count) * 255
        }
        #expect(lumas.count == frames.count)
        let stepsBack = zip(lumas, lumas.dropFirst()).enumerated().filter { $0.element.1 < $0.element.0 }.map(\.offset)
        #expect(stepsBack.isEmpty, "frames out of order after index \(stepsBack); luma \(lumas.map { Int($0) })")
    }

    /// Through the engine: an exact seek lands on the frame shown at the target and playback goes
    /// on in order. An XviD AVI with B-frames froze after every seek: no packet had a pts.
    @Test(arguments: files)
    func playbackAfterASeekLandsAndStaysInOrder(_ file: String) async throws {
        // The H.264 file's keyframe at 2 s is an open-GOP I-frame, not an IDR: VideoToolbox keeps
        // the references decoded before the seek, and frames after it come out wrong.
        try await withKnownIssue("VideoToolbox keeps references from before a seek to a non-IDR I-frame") {
            try await Self.seekAndPlay(file)
        } when: {
            file == "reorder/h264_no_ctts.mp4"
        }
    }

    static func seekAndPlay(_ file: String) async throws {
        let url = try fixtureURL(file)
        let engine = TestEngines.make()
        let seen = Mutex<[(generation: UInt64, time: MediaTime, luma: Double)]>([])
        await engine.setFrameObserver { frame in
            guard let time = MediaTime(frame.presentationTime), let plane = FrameGrabber.lumaPlane(frame.pixelBuffer) else { return }
            let luma = plane.values.reduce(0, +) / Double(plane.values.count) * 255
            seen.withLock { $0.append((frame.generation, time, luma)) }
        }
        _ = try await engine.open(url)
        let target = MediaTime.seconds(2.1)
        let report = try #require(await engine.seekAndWait(.exact(target)), "the seek landed")
        let landed = try #require(report.landedPTS)
        #expect(landed <= target && target - landed < .milliseconds(84), "landed at \(landed)")
        let generation = await engine.currentGeneration
        await engine.play()
        let deadline = ContinuousClock.now + .seconds(10)
        while seen.withLock({ $0.filter { $0.generation == generation }.count }) < 24, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await engine.close()
        let frames = seen.withLock { $0.filter { $0.generation == generation } }
        #expect(frames.count >= 24, "\(frames.count) frames after the seek")
        let times = frames.map(\.time)
        #expect(times == times.sorted() && Set(times).count == times.count, "times \(times)")
        let lumas = frames.map(\.luma)
        #expect(zip(lumas, lumas.dropFirst()).allSatisfy { $1 > $0 }, "luma \(lumas.map { Int($0) })")
    }
}
