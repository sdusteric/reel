import CoreMedia
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// Unusual but valid files must play (design section 7.10): each odd/ file opens and an exact
/// seek to one second lands, and the particular oddity of each is handled.
@Suite struct OddFileTests {
    static let playable = OddFixture.allCases.filter { $0.expectedProblem == nil }

    @Test(arguments: OddFileTests.playable)
    func opensAndAnExactSeekToOneSecondLands(_ fixture: OddFixture) async throws {
        let engine = TestEngines.make()
        let info = try await engine.open(fixture.url())
        let start = await engine.startTime
        let end = (info.startTime ?? .zero) + (info.duration ?? .zero)
        let target = min(start + .seconds(1), end)
        let report = try #require(await engine.seekAndWait(.exact(target)), "\(fixture) seek landed")
        #expect(!report.cancelled)
        if info.videoStream != nil {
            let landed = try #require(report.landedPTS)
            #expect(landed <= target + .milliseconds(1), "\(fixture): landed \(landed) for \(target)")
            #expect(target - landed < .milliseconds(500), "\(fixture): landed \(landed) for \(target)")
            #expect(await engine.lastLandedFrame() != nil)
        }
        #expect(await engine.playbackState == .paused)
        await engine.close()
    }

    @Test func aResolutionChangeInMPEGTSDecodesTheNewSizeInHardware() async throws {
        let engine = TestEngines.make()
        let info = try await engine.open(OddFixture.resolutionChange.url())
        #expect(info.videoDecoder == .hardware)
        let start = await engine.startTime
        let first = try #require(await engine.seekAndWait(.exact(start + .seconds(1))))
        #expect(first.landedPTS != nil)
        #expect(await engine.lastLandedFrame()?.width == 1280)
        let second = try #require(await engine.seekAndWait(.exact(start + .seconds(2.2))))
        let frame = try #require(await engine.lastLandedFrame())
        #expect(second.landedPTS != nil)
        #expect(frame.width == 1920 && frame.height == 1080)
        #expect(frame.decoder == .hardware)
        #expect(engine.damagedFrames == 0, "a new format is not damage")
        await engine.close()
    }

    @Test func aResolutionChangePlaysThroughWithoutDamage() async throws {
        let engine = TestEngines.make()
        let sizes = Mutex<[Int]>([])
        await engine.setFrameObserver { frame in sizes.withLock { $0.append(frame.width) } }
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(OddFixture.resolutionChange.url())
        await engine.setRate(4)
        await engine.play()
        #expect(await log.wait(timeout: .seconds(15)) { log in log.all.contains { $0 == .ended } })
        let widths = sizes.withLock { $0 }
        #expect(widths.contains(1280) && widths.contains(1920))
        #expect(widths.firstIndex(of: 1920).map { index in widths[index...].allSatisfy { $0 == 1920 } } == true)
        #expect(engine.damagedFrames == 0)
        await engine.close()
    }

    /// The channel layout changes from stereo to 5.1 half way: the audio format is made anew and
    /// the first buffer in it says so, so a renderer flushes before taking it.
    @Test func anAudioLayoutChangeStartsANewFormat() async throws {
        let engine = TestEngines.make()
        let buffers = Mutex<[(channels: Int, newFormat: Bool)]>([])
        await engine.setAudioObserver { buffer, _ in
            buffers.withLock { $0.append((buffer.channelCount, buffer.startsNewFormat)) }
        }
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(OddFixture.layoutChange.url())
        await engine.setRate(4)
        await engine.play()
        #expect(await log.wait(timeout: .seconds(15)) { log in log.all.contains { $0 == .ended } })
        let seen = buffers.withLock { $0 }
        let firstSix = try #require(seen.firstIndex { $0.channels == 6 })
        #expect(seen.prefix(firstSix).allSatisfy { $0.channels == 2 && !$0.newFormat })
        #expect(seen[firstSix].newFormat)
        #expect(seen[(firstSix + 1)...].allSatisfy { $0.channels == 6 && !$0.newFormat })
        await engine.close()
    }

    @Test func anMPEGTSFileAcrossTheTimestampWrapPlaysToItsEnd() async throws {
        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        let info = try await engine.open(OddFixture.timestampWrap.url())
        #expect(abs((info.duration?.seconds ?? 0) - 3.0) < 0.1)
        await engine.setRate(4)
        await engine.play()
        #expect(await log.wait(timeout: .seconds(15)) { log in log.all.contains { $0 == .ended } })
        let end = (info.startTime ?? .zero) + (info.duration ?? .zero)
        #expect(engine.currentTime + .milliseconds(200) >= end)
        await engine.close()
    }

    /// An intra-refresh stream has one keyframe, the start: seeks decode from there and show no
    /// keyframe preview (it would flash the first frame of the file).
    @Test func intraRefreshSeeksFromTheStreamStartWithoutAPreview() async throws {
        let engine = TestEngines.make()
        let info = try await engine.open(OddFixture.intraRefresh.url())
        #expect(info.keyframeCount == 1)
        let first = try #require(await engine.seekAndWait(.exact(.seconds(2.5))))
        #expect(first.previewMilliseconds == nil)
        #expect(first.landedPTS.map { abs($0.seconds - 2.5) < 0.05 } == true)
        // Backwards: nothing to continue from, so the decode restarts at the stream start.
        let back = try #require(await engine.seekAndWait(.exact(.seconds(2.0))))
        #expect(back.start == .keyframe)
        #expect(back.startKeyframePTS == (await engine.keyframeIndex).first?.pts)
        #expect(back.previewMilliseconds == nil)
        #expect(back.landedPTS.map { abs($0.seconds - 2.0) < 0.05 } == true)
        await engine.close()
    }

    @Test func oddDimensionsPlayInSoftware() async throws {
        let engine = TestEngines.make()
        let info = try await engine.open(OddFixture.oddDimensions.url())
        #expect(info.videoStream?.video?.width == 1921)
        #expect(await engine.videoDecoderKind == .software)
        let report = try #require(await engine.seekAndWait(.exact(.seconds(1))))
        #expect(report.landedPTS != nil)
        await engine.close()
    }

    @Test func sixtyFourTracksAreListed() async throws {
        let engine = TestEngines.make()
        _ = try await engine.open(OddFixture.manyTracks.url())
        let tracks = try #require(await engine.trackState)
        #expect(tracks.audio.count == 32)
        #expect(tracks.subtitles.filter { !$0.isExternal }.count == 32)
        await engine.close()
    }
}
