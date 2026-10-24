import CReelDeps
import Foundation
import ReelCore
import Testing
@testable import ReelEngine

@Suite struct AudioTimestampTests {
    static let syncFixtures = ["sync_h264_aac.mp4", "sync_hevc_opus.mkv"]
    static let tolerance = MediaTime.milliseconds(1)

    // MARK: Clock

    @Test func clockAnchorsOnTheFirstPacketThenCountsSamples() {
        var clock = AudioClock(sampleRate: 48_000)
        #expect(clock.place(count: 960, packetSample: 4_800) == .init(start: 4_800, isDiscontinuity: false))
        // mkv stores 1 ms timestamps: 20 ms later arrives as 5759 or 5761, never exactly 5760.
        #expect(clock.place(count: 960, packetSample: 5_759) == .init(start: 5_760, isDiscontinuity: false))
        #expect(clock.place(count: 960, packetSample: 6_770) == .init(start: 6_720, isDiscontinuity: false))
        #expect(clock.place(count: 960, packetSample: nil) == .init(start: 7_680, isDiscontinuity: false))
        #expect(clock.nextSample == 8_640)
    }

    @Test func clockReanchorsWhenAPacketIsMoreThanFortyMillisecondsAway() {
        var clock = AudioClock(sampleRate: 48_000)
        _ = clock.place(count: 960, packetSample: 0)
        // 40 ms exactly (1920 samples) is still continuous; one sample more re-anchors.
        #expect(clock.place(count: 960, packetSample: 960 + 1_920) == .init(start: 960, isDiscontinuity: false))
        #expect(clock.place(count: 960, packetSample: 1_920 + 1_921) == .init(start: 3_841, isDiscontinuity: true))
        #expect(clock.place(count: 960, packetSample: 0) == .init(start: 0, isDiscontinuity: true))
        clock.reset()
        #expect(clock.nextSample == nil)
        #expect(clock.place(count: 10, packetSample: nil) == .init(start: 0, isDiscontinuity: false))
    }

    @Test func coarseContainerTimesSnapBackOntoTheOpusFrameGrid() {
        // Opus in mkv: packet k starts at k * 960 - 312 samples, stored rounded to whole ms.
        let origin: Int64 = -312
        #expect(AudioClock.snap(-336, step: 120, origin: origin, maxCorrection: 48) == -312) // -7 ms
        #expect(AudioClock.snap(595_872, step: 120, origin: origin, maxCorrection: 48) == 595_848) // 12414 ms
        #expect(AudioClock.snap(595_848, step: 120, origin: origin, maxCorrection: 48) == 595_848)
        // A packet off the grid by more than one tick is left alone.
        #expect(AudioClock.snap(595_908, step: 120, origin: origin, maxCorrection: 48) == 595_908)
    }

    @Test func trimDropsWholeBuffersBeforeTheTargetAndCutsTheStraddlingOne() {
        #expect(AudioTrim.leadingFramesToDrop(start: 0, count: 960, target: 960) == nil)
        #expect(AudioTrim.leadingFramesToDrop(start: 0, count: 960, target: 959) == 959)
        #expect(AudioTrim.leadingFramesToDrop(start: 960, count: 960, target: 960) == 0)
        #expect(AudioTrim.leadingFramesToDrop(start: 2_000, count: 960, target: 960) == 0)
    }

    // MARK: Decoder timestamps on synthetic PCM

    @Test func millisecondContainerTimestampsDoNotAccumulateRounding() throws {
        let stream = SyntheticPCMStream(timeBase: AVRational(num: 1, den: 1_000))
        let decoder = try stream.makeDecoder()
        // 1000-frame packets at 48 kHz are 20.833 ms; their 1 ms pts are rounded every time.
        var buffers = try stream.decodeContiguous(decoder, packets: 200, frames: 1_000)
        buffers += try decoder.finish()
        #expect(AudioTestSupport.gaps(buffers).isEmpty)
        #expect(buffers.first?.startSample == 0)
        let last = try #require(buffers.last)
        #expect(last.startSample + Int64(last.frameCount) == 200_000)
    }

    @Test func aGapLargerThanFortyMillisecondsStartsANewBuffer() throws {
        let stream = SyntheticPCMStream()
        let decoder = try stream.makeDecoder()
        var buffers = try stream.decodeContiguous(decoder, packets: 10, frames: 40)
        // A splice 100 ms later: the 400 pending frames are emitted, then timing follows the packet.
        buffers += try stream.decodeContiguous(decoder, packets: 30, frames: 40, start: 400 + 4_800)
        buffers += try decoder.finish()
        #expect(buffers.map(\.startSample) == [0, 5_200, 6_160])
        #expect(buffers.map(\.frameCount) == [400, 960, 240])
    }

    @Test func seekResetTrimsTheFirstBufferToTheTargetSample() throws {
        let stream = SyntheticPCMStream()
        let decoder = try stream.makeDecoder()
        _ = try stream.decodeContiguous(decoder, packets: 5, frames: 1_024)
        // Seek to 1.0 s with one 1024-frame packet of preroll before it.
        decoder.reset(dropBefore: .seconds(1))
        var buffers = try stream.decodeContiguous(decoder, packets: 4, frames: 1_024, start: 48_000 - 1_500)
        buffers += try decoder.finish()
        let first = try #require(buffers.first)
        #expect(first.startSample == 48_000)
        #expect(first.pts == .seconds(1))
        #expect(first.interleavedSamples().first == 48_000, "the sample at the target comes first")
        #expect(AudioTestSupport.gaps(buffers).isEmpty)
        #expect(buffers.reduce(0) { $0 + $1.frameCount } == 4 * 1_024 - 1_500)
    }

    @Test func packetsWithoutTimestampsContinueFromTheRunningClock() throws {
        let stream = SyntheticPCMStream()
        let decoder = try stream.makeDecoder()
        var buffers: [DecodedAudioBuffer] = []
        for index in 0..<4 {
            var packet: UnsafeMutablePointer<AVPacket>? = try stream.packet(
                frames: 960, ptsSample: index == 0 ? 9_600 : nil, firstValue: 0)
            defer { av_packet_free(&packet) }
            buffers += try decoder.decode(try #require(packet))
        }
        #expect(buffers.map(\.startSample) == [9_600, 10_560, 11_520, 12_480])
    }

    // MARK: Fixtures

    @Test(arguments: syncFixtures)
    func primingAndPreSkipAreRemovedSoAudioStartsAtZero(_ name: String) throws {
        let (_, buffers) = try AudioTestSupport.decodeAll(name)
        let first = try #require(buffers.first)
        #expect(first.startSample == 0, "AAC priming (mp4 edit list) and Opus pre-skip are dropped")
        let total = buffers.reduce(0) { $0 + $1.frameCount }
        #expect(abs(total - 20 * 48_000) <= 1_024, "about 20 s of audio, got \(total) frames")
    }

    @Test(arguments: syncFixtures)
    func beepOnsetsLandOnWholeSecondsWhenPlayedFromTheStart(_ name: String) throws {
        let (_, buffers) = try AudioTestSupport.decodeAll(name)
        let onsets = AudioTestSupport.beepOnsets(buffers)
        #expect(onsets.count == 20, "one beep per second, found \(onsets)")
        for onset in onsets {
            #expect(AudioTestSupport.offsetFromWholeSecond(onset) <= Self.tolerance, "\(name): beep at \(onset)")
        }
        #expect(onsets.first.map { $0 < .milliseconds(1) } == true)
    }

    @Test(arguments: syncFixtures)
    func beepOnsetsLandOnWholeSecondsAfterSeeks(_ name: String) throws {
        let reader = try AudioFixtureReader(url: try AudioTestMedia.fixture(name))
        let decoder = try reader.makeDecoder()
        let targets: [MediaTime] = [.seconds(12.5), .seconds(3.25), .seconds(7), .seconds(16.999), .seconds(0.5), .seconds(9.97)]
        for target in targets {
            let buffers = try AudioTestSupport.decode(reader: reader, decoder: decoder, from: target, length: .seconds(2.2))
            let first = try #require(buffers.first)
            let targetSample = target.value(timeBaseNum: 1, timeBaseDen: Int32(first.sampleRate))
            #expect(first.startSample == targetSample, "\(name): first sample after seek to \(target) is at \(first.pts)")
            #expect(AudioTestSupport.gaps(buffers).isEmpty)
            let onsets = AudioTestSupport.beepOnsets(buffers)
            #expect(onsets.count >= 2, "\(name): beeps after \(target): \(onsets)")
            for onset in onsets {
                #expect(AudioTestSupport.offsetFromWholeSecond(onset) <= Self.tolerance, "\(name): after seek to \(target), beep at \(onset)")
            }
        }
    }
}
