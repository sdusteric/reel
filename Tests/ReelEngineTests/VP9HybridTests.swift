import CoreMedia
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// The VP9 hybrid (design section 7.3, D46): exact seeks that decode more than 30 frames run on
/// libavcodec, playback and scrubs on VideoToolbox, and a software landing hands over to the live
/// hardware session at the next keyframe without flushing what is on screen. Serialized: each
/// test decodes 4K VP9 on 16 threads, which would starve the timing tests running beside it.
@Suite(.serialized) struct VP9HybridTests {
    /// The frame just before the keyframe at `keyframeIndex`: decoding it needs the whole GOP.
    private static func worstCase(_ table: FrameTable, keyframeIndex: Int) throws -> MediaTime {
        let key = table.keyframes[keyframeIndex]
        return try #require(table.frames.last { $0 < key })
    }

    @Test func aLongExactSeekDecodesInSoftwareAndLandsOnTheExpectedFrame() async throws {
        let url = try Fixture.vp9.url()
        let table = try FrameTable(url)
        let engine = M2Engines.make()
        _ = try await engine.open(url)
        #expect(await engine.videoDecoderKind == .hardware, "playback stays on VideoToolbox")
        let target = try Self.worstCase(table, keyframeIndex: 2)
        let before = engine.decoderHandoffs
        let report = try #require(await engine.seekAndWait(.exact(target)))
        #expect(report.landedPTS == table.expected(at: target))
        #expect(report.framesDecoded > DecoderPolicy.hybridSeekFrameThreshold)
        #expect(report.decoder == .software, "the report names the decoder the run started on")
        // The target is the frame before a keyframe, so the hand-off follows the landing at once
        // and may be counted after the report was made: the report holds a snapshot of the count.
        let handoffs = try #require(report.decoderHandoffs, "the report carries the hand-off count")
        #expect(handoffs >= before && handoffs <= engine.decoderHandoffs, "report \(handoffs), before \(before), now \(engine.decoderHandoffs)")
        let handedOver = await instantWhen(timeout: .seconds(10)) { engine.decoderHandoffs > before }
        #expect(handedOver != nil, "the hybrid handed over to VideoToolbox at the next keyframe")
        let landed = try #require(await engine.lastLandedFrame())
        #expect(landed.decoder == .software)
        await engine.close()
    }

    @Test func playbackHandsOverToHardwareAtTheNextKeyframe() async throws {
        let url = try Fixture.vp9.url()
        let table = try FrameTable(url)
        let engine = M2Engines.make()
        let presented = Mutex<[(MediaTime, VideoDecoderKind)]>([])
        await engine.setFrameObserver { frame in
            let pts = MediaTime(frame.presentationTime) ?? frame.time
            presented.withLock { $0.append((pts, frame.decoder)) }
        }
        _ = try await engine.open(url)
        // Mid-GOP, about a second before the next keyframe.
        let key = table.keyframes[1]
        let next = table.keyframes[2]
        let target = try #require(table.expected(at: next - .seconds(1)))
        #expect(target > key)
        let before = engine.decoderHandoffs
        let report = try #require(await engine.seekAndWait(.exact(target)))
        #expect(report.landedPTS == target)
        presented.withLock { $0.removeAll() }
        await engine.play()
        let handedOver = await instantWhen(timeout: .seconds(8)) { engine.decoderHandoffs > before }
        #expect(handedOver != nil, "a hand-off happened")
        _ = await instantWhen(timeout: .seconds(5)) { presented.withLock { $0.contains { $0.0 > next + .milliseconds(200) } } }
        await engine.pause()
        let frames = presented.withLock { $0 }
        let software = frames.filter { $0.0 < next }
        let hardware = frames.filter { $0.0 >= next }
        #expect(!software.isEmpty && software.allSatisfy { $0.1 == .software }, "software until the keyframe")
        #expect(!hardware.isEmpty && hardware.allSatisfy { $0.1 == .hardware }, "VideoToolbox from the keyframe on")
        // No frame was skipped or repeated across the hand-off.
        let times = frames.map(\.0)
        #expect(times == times.sorted() && Set(times).count == times.count)
        if let firstHardware = hardware.first?.0, let lastSoftware = software.last?.0 {
            #expect(table.frames.firstIndex(of: firstHardware) == table.frames.firstIndex(of: lastSoftware).map { $0 + 1 })
        }
        await engine.close()
    }

    /// Play after an exact landing: paused, the receiver holds only one 4K frame past the shown
    /// one, so the frames due next must not wait for it to ask, or the first ones after a software
    /// landing at 60 fps reach it after the clock has passed their time.
    @Test(arguments: [Fixture.vp9, .av1, .hevc10])
    func playAfterAnExactLandingEnqueuesEveryFrameBeforeItsTime(_ fixture: Fixture) async throws {
        let url = try fixture.url()
        let table = try FrameTable(url)
        let engine = M2Engines.make()
        let enqueued = Mutex<[(pts: MediaTime, clock: MediaTime, decoder: VideoDecoderKind)]>([])
        await engine.setFrameObserver { frame in
            let pts = MediaTime(frame.presentationTime) ?? frame.time
            let clock = engine.currentTime
            enqueued.withLock { $0.append((pts, clock, frame.decoder)) }
        }
        _ = try await engine.open(url)
        let target = try Self.worstCase(table, keyframeIndex: 2) - .seconds(1)
        let landedAt = try #require(table.expected(at: target))
        let report = try #require(await engine.seekAndWait(.exact(landedAt)))
        #expect(report.landedPTS == landedAt)
        if url.lastPathComponent.hasPrefix("vp9") {
            #expect(await engine.lastLandedFrame()?.decoder == .software, "the VP9 landing is the hybrid's software one")
        }
        try await Task.sleep(for: .milliseconds(300))
        await engine.play()
        _ = await instantWhen(timeout: .seconds(5)) { enqueued.withLock { $0.contains { $0.pts > landedAt + .seconds(0.5) } } }
        await engine.pause()
        let frames = enqueued.withLock { $0 }.filter { $0.pts > landedAt && $0.pts <= landedAt + .seconds(0.5) }
        #expect(frames.count >= 10)
        let late = frames.filter { $0.pts < $0.clock }
        #expect(late.isEmpty, "late (pts, clock, decoder): \(late.prefix(5).map { ($0.pts.seconds, $0.clock.seconds, $0.decoder) })")
        await engine.close()
    }

    @Test func aShortExactSeekAndAScrubStayOnHardware() async throws {
        let url = try Fixture.vp9.url()
        let table = try FrameTable(url)
        let engine = M2Engines.make()
        _ = try await engine.open(url)
        let key = table.keyframes[3]
        let near = try #require(table.frames.first { $0 > key + .milliseconds(150) })
        let report = try #require(await engine.seekAndWait(.exact(near)))
        #expect(report.landedPTS == near)
        #expect(report.decoder == .hardware)
        #expect(await engine.lastLandedFrame()?.decoder == .hardware)
        let scrub = try #require(await engine.seekAndWait(.scrub(table.keyframes[5] + .seconds(1))))
        #expect(scrub.landedPTS == table.keyframes[5])
        await engine.close()
    }

    @Test func theSoftwareLandingMatchesASequentialDecode() async throws {
        let url = try Fixture.vp9.url()
        let table = try FrameTable(url)
        let engine = M2Engines.make()
        _ = try await engine.open(url)
        let target = try Self.worstCase(table, keyframeIndex: 1)
        _ = try #require(await engine.seekAndWait(.exact(target)))
        let landed = try #require(await engine.lastLandedFrame())
        await engine.close()
        let reference = try await Task.detached { try FrameGrabber.grabSequential(url: url, at: target) }.value
        #expect(MediaTime(reference.frame.presentationTime) == target)
        let psnr = try #require(FrameGrabber.lumaPSNR(landed.pixelBuffer, reference.frame.pixelBuffer))
        #expect(psnr >= 35, "PSNR \(psnr) dB")
    }

    @Test func aForcedDecoderRunsNoHybrid() async throws {
        let url = try Fixture.vp9.url()
        let table = try FrameTable(url)
        let engine = M2Engines.make(force: .hardware)
        _ = try await engine.open(url)
        let target = try Self.worstCase(table, keyframeIndex: 1)
        let report = try #require(await engine.seekAndWait(.exact(target), timeout: .seconds(15)))
        #expect(report.landedPTS == target)
        #expect(await engine.lastLandedFrame()?.decoder == .hardware)
        #expect(engine.decoderHandoffs == 0)
        await engine.close()
    }

    @Test func otherCodecsHaveNoHybridDecoder() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = M2Engines.make()
        _ = try await engine.open(url)
        let target = try Self.worstCase(table, keyframeIndex: 1)
        _ = try #require(await engine.seekAndWait(.exact(target)))
        #expect(await engine.lastLandedFrame()?.decoder == .hardware)
        await engine.close()
    }
}
