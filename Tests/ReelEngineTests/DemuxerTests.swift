import CoreMedia
import Foundation
import ReelCore
import Testing
@testable import ReelEngine

@Suite struct DemuxerTests {
    @Test(arguments: Fixture.allCases)
    func opensEveryFixtureAndSelectsItsStreams(_ fixture: Fixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        let info = demuxer.info
        let video = try #require(info.videoStream)
        #expect(video.codec == fixture.videoCodec)
        #expect(video.video?.width == fixture.size.width && video.video?.height == fixture.size.height)
        if let rate = video.video?.frameRate {
            #expect(abs(rate.doubleValue - fixture.frameRate) < 0.01)
        }
        if fixture == .hdr10 {
            #expect(info.audioStream == nil)
        } else {
            #expect(info.audioStream != nil)
        }
        if fixture != .nocues {
            #expect((info.duration?.seconds ?? 0) > 1.5)
        }
        // The first video packets were read at open, so the store already holds the first GOP.
        #expect(demuxer.store.storedKeyframes.first != nil)
        #expect(demuxer.keyframeIndex.first?.pts == demuxer.store.storedKeyframes.first)
    }

    @Test func probeLimitsAreFiveMegabytesAndTwoSeconds() {
        #expect(MediaSource.probeSize == 5_000_000)
        #expect(MediaSource.analyzeDurationMicroseconds == 2_000_000)
    }

    @Test(arguments: [Fixture.h264, .hevc10, .av1])
    func containerIndexGivesPresentationTimesOfEveryKeyframe(_ fixture: Fixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        let indexed = demuxer.keyframeIndex.entries.map(\.pts)
        #expect(indexed.count >= 4)

        // Read every key packet and compare with what the index said before reading.
        let source = try MediaSource(url: fixture.url())
        var actual: [MediaTime] = []
        while let packet = try source.readPacket() {
            if packet.streamIndex == source.videoStreamIndex, packet.isKeyframe, let pts = packet.pts { actual.append(pts) }
        }
        #expect(indexed == actual, "index pts must equal the key packets' presentation pts")
        let gop = fixture == .av1 ? 5.0 : (fixture == .h264 ? 10.0 : 250.0 / 24.0)
        for (number, pts) in indexed.enumerated() {
            #expect(abs(pts.seconds - Double(number) * gop) < 0.02, "keyframe \(number) at \(pts)")
        }
    }

    @Test func hevcKeyframesAreClassifiedAsIDRThenCRA() async throws {
        let demuxer = try Demuxer(url: Fixture.hevc10.url(), limits: .init(ahead: .seconds(25)))
        demuxer.start()
        defer { demuxer.stop() }
        let filled = await demuxer.waitUntil { !demuxer.store.wantsMoreData }
        #expect(filled)
        let kinds = demuxer.keyframeIndex.entries.prefix(3).map(\.kind)
        #expect(kinds == [.idr, .cra, .cra], "x265 open-GOP fixture starts with an IDR and continues with CRAs")
    }

    @Test func fileWithoutCuesBuildsItsIndexWhileReading() async throws {
        let demuxer = try Demuxer(url: Fixture.nocues.url(), limits: .init(ahead: .seconds(25)))
        // Without Cues only the keyframes the demuxer has read so far are known.
        let atOpen = demuxer.keyframeIndex.count
        #expect(atOpen <= 2)
        demuxer.start()
        defer { demuxer.stop() }
        let indexed = await demuxer.waitUntil { demuxer.keyframeIndex.count >= max(3, atOpen + 1) }
        #expect(indexed)
        let entries = demuxer.keyframeIndex.entries
        #expect(abs(entries[1].pts.seconds - 250.0 / 24.0) < 0.02)
        #expect(entries[1].pos != nil)
    }

    @Test(arguments: [(Fixture.h264, true), (.hevc10, true), (.nocues, false), (.annexB, false)])
    func indexIsCompleteOnlyWithAContainerIndexThatReachesTheEnd(_ fixture: Fixture, complete: Bool) throws {
        let demuxer = try Demuxer(url: fixture.url())
        #expect(demuxer.hasCompleteIndex == complete)
    }

    @Test func keyframesAreKnownOnlyWhereTheFileWithoutCuesWasRead() async throws {
        let demuxer = try Demuxer(url: Fixture.nocues.url())
        #expect(demuxer.keyframe(atOrBefore: .seconds(0.1)).known, "the first packets were read at open")
        #expect(!demuxer.keyframe(atOrBefore: .seconds(55)).known)
        demuxer.start()
        defer { demuxer.stop() }
        #expect(await demuxer.waitUntil { !demuxer.store.wantsMoreData })
        #expect(demuxer.keyframe(atOrBefore: .seconds(15)).known)
        #expect(!demuxer.keyframe(atOrBefore: .seconds(55)).known)

        // A seek to a time past the index lands on the real keyframe before it.
        demuxer.seek(toKeyframe: .seconds(55), readThrough: .seconds(55), generation: 1)
        #expect(await demuxer.waitUntil { demuxer.completedSeekGeneration >= 1 && !demuxer.store.wantsMoreData })
        let lookup = demuxer.keyframe(atOrBefore: .seconds(55))
        #expect(lookup.known)
        #expect(abs((lookup.entry?.pts.seconds ?? 0) - 1_250.0 / 24.0) < 0.02, "keyframe \(String(describing: lookup.entry))")
        // The stretch between what was read at open and the seek is still unknown.
        #expect(!demuxer.keyframe(atOrBefore: .seconds(45)).known)
    }

    @Test func readThroughReadsPastTheReadAheadLimit() async throws {
        let limits = PacketStore.Limits(behind: .seconds(30), behindBytes: 192 << 20, ahead: .seconds(2), aheadBytes: 192 << 20)
        let demuxer = try Demuxer(url: Fixture.h264.url(), limits: limits)
        demuxer.start()
        defer { demuxer.stop() }
        let store = demuxer.store
        #expect(await demuxer.waitUntil { !store.wantsMoreData })
        let limited = try #require(store.storedRange)
        #expect(limited.upperBound < .seconds(4), "stored \(limited)")

        store.setPlayhead(.zero, readThrough: .seconds(15))
        #expect(await demuxer.waitUntil { !store.wantsMoreData })
        let through = try #require(store.storedRange)
        #expect(through.upperBound >= .seconds(15) && through.upperBound < .seconds(17), "stored \(through)")

        store.requestMoreData()
        #expect(await demuxer.waitUntil { !store.wantsMoreData })
        let more = try #require(store.storedRange)
        #expect(more.upperBound >= through.upperBound + .seconds(0.9), "stored \(more)")
        #expect(store.storedKeyframes.first == .zero, "nothing was evicted: the playhead stayed at the keyframe")
    }

    @Test func readAheadStopsAtTwentySecondsAndResumesWhenThePlayheadMoves() async throws {
        let demuxer = try Demuxer(url: Fixture.h264.url())
        demuxer.start()
        defer { demuxer.stop() }
        let store = demuxer.store
        #expect(await demuxer.waitUntil { !store.wantsMoreData })
        let range = try #require(store.storedRange)
        #expect(range.lowerBound == .zero)
        #expect(range.upperBound >= .seconds(19.9) && range.upperBound < .seconds(21.5), "stored \(range)")
        #expect(!store.isAtEndOfFile)

        store.setPlayhead(.seconds(45))
        #expect(await demuxer.waitUntil { !store.wantsMoreData })
        let later = try #require(store.storedRange)
        #expect(store.isAtEndOfFile || later.upperBound >= .seconds(59))
        // 30 s behind 45 s: the GOP at 0 s ends at 10 s, more than 30 s back, so it is gone.
        #expect(later.lowerBound == .seconds(10))
        #expect(store.storedKeyframes == [.seconds(10), .seconds(20), .seconds(30), .seconds(40), .seconds(50)])
    }

    @Test func byteLimitEvictsOldGOPsBeforeTheTimeLimit() async throws {
        let limits = PacketStore.Limits(behind: .seconds(30), behindBytes: 30 << 20, ahead: .seconds(10), aheadBytes: 192 << 20)
        let demuxer = try Demuxer(url: Fixture.h264.url(), limits: limits)
        demuxer.start()
        defer { demuxer.stop() }
        let store = demuxer.store
        #expect(await demuxer.waitUntil { !store.wantsMoreData })
        store.setPlayhead(.seconds(31))
        #expect(await demuxer.waitUntil { !store.wantsMoreData })
        // Each 10 s GOP is about 25 MB at 20 Mbps, so only one complete GOP fits in 30 MB behind.
        #expect(store.storedKeyframes.first == .seconds(20), "kept \(store.storedKeyframes)")
    }

    @Test func seekInsideTheStoreNeedsNoIO() async throws {
        let demuxer = try Demuxer(url: Fixture.h264.url())
        demuxer.start()
        defer { demuxer.stop() }
        let store = demuxer.store
        #expect(await demuxer.waitUntil { !store.wantsMoreData })
        let epoch = store.epoch
        let bytes = demuxer.bytesRead
        let hit = demuxer.seek(toKeyframe: .seconds(10), generation: 1)
        #expect(hit)
        #expect(store.epoch == epoch)
        #expect(store.covers(keyframe: .seconds(10), through: .seconds(19)))
        try await Task.sleep(for: .milliseconds(50))
        // Moving the playhead to 10 s only reads ahead; nothing before 10 s is read again.
        #expect(store.storedKeyframes.first == .zero)
        #expect(demuxer.bytesRead >= bytes)
    }

    @Test func seekOutsideTheStoreResetsAndRefillsFromTheKeyframe() async throws {
        let demuxer = try Demuxer(url: Fixture.hevc10.url())
        demuxer.start()
        defer { demuxer.stop() }
        let store = demuxer.store
        let keyframe = try #require(demuxer.keyframeIndex.entry(atOrBefore: .seconds(45))?.pts)
        let epoch = store.epoch
        let started = ContinuousClock.now
        let hit = demuxer.seek(toKeyframe: keyframe, generation: 7)
        #expect(!hit)
        let covered = try #require(await instantWhen { store.covers(keyframe: keyframe, through: keyframe) })
        let elapsed = covered - started
        // About 7 ms alone; the bound allows for the parallel 4K decodes of the other suites.
        #expect(elapsed < .seconds(2), "seek preempts read-ahead (took \(elapsed))")
        #expect(demuxer.completedSeekGeneration == 7)
        #expect(store.epoch == epoch + 1)
        #expect(store.storedKeyframes.first == keyframe)

        var cursor = try #require(store.videoCursor(atKeyframe: keyframe))
        guard case .packet(let first) = store.next(&cursor) else {
            Issue.record("no packet at the keyframe")
            return
        }
        #expect(first.isKeyframe && first.pts == keyframe)
    }

    @Test func aQueuedOlderSeekDoesNotResetTheStoreUnderANewerOne() async throws {
        // The thread is not started yet, so the far seek stays queued.
        let demuxer = try Demuxer(url: Fixture.h264.url())
        let store = demuxer.store
        #expect(store.covers(keyframe: .zero, through: .zero), "the first GOP was read at open")
        let epoch = store.epoch
        #expect(!demuxer.seek(toKeyframe: .seconds(50), readThrough: .seconds(50), generation: 1))
        // The store still covers 0 s, but the queued seek would reset it: not a hit.
        #expect(!demuxer.seek(toKeyframe: .zero, readThrough: .seconds(1), generation: 2))
        #expect(demuxer.hasPendingSeek)
        demuxer.start()
        defer { demuxer.stop() }
        #expect(await demuxer.waitUntil { demuxer.completedSeekGeneration >= 2 })
        #expect(!demuxer.hasPendingSeek)
        #expect(store.epoch == epoch, "the stale seek was dropped and the newer one needed no I/O")
        #expect(store.storedKeyframes.first == .zero)
        #expect(store.videoCursor(atKeyframe: .zero) != nil)
    }

    @Test func aRunningOlderSeekIsFollowedByTheNewerOne() async throws {
        let demuxer = try Demuxer(url: Fixture.hevc10.url())
        let store = demuxer.store
        demuxer.start()
        defer { demuxer.stop() }
        #expect(await demuxer.waitUntil { !store.wantsMoreData })
        let far = try #require(demuxer.keyframeIndex.entry(atOrBefore: .seconds(45))?.pts)
        let near = try #require(demuxer.keyframeIndex.entry(atOrBefore: .seconds(1))?.pts)
        for generation in stride(from: UInt64(1), through: 40, by: 2) {
            // The far seek is queued or already running when the near one arrives.
            #expect(!demuxer.seek(toKeyframe: far, readThrough: far, generation: generation))
            let hit = demuxer.seek(toKeyframe: near, readThrough: near, generation: generation + 1)
            #expect(!hit, "a seek is pending, so the store cannot be trusted")
            #expect(await demuxer.waitUntil { demuxer.completedSeekGeneration >= generation + 1 })
            #expect(store.videoCursor(atKeyframe: near) != nil, "round \(generation): stored \(store.storedKeyframes)")
            #expect(store.covers(keyframe: near, through: near))
        }
    }

    @Test func oldCursorsAreInvalidatedByAReset() async throws {
        let demuxer = try Demuxer(url: Fixture.h264.url())
        let store = demuxer.store
        var cursor = try #require(store.videoCursorAtStart())
        guard case .packet = store.next(&cursor) else {
            Issue.record("expected the first packet")
            return
        }
        demuxer.start()
        defer { demuxer.stop() }
        demuxer.seek(toKeyframe: .seconds(50), generation: 2)
        #expect(await demuxer.waitUntil { store.storedKeyframes.first == .seconds(50) })
        guard case .invalidated = store.next(&cursor) else {
            Issue.record("cursor from the old epoch should be invalidated")
            return
        }
    }

    @Test func videoCursorReadsDecodeOrderAcrossGOPsAndWaitsForMore() async throws {
        let demuxer = try Demuxer(url: Fixture.syncH264.url())
        let store = demuxer.store
        var cursor = try #require(store.videoCursorAtStart())
        demuxer.start()
        defer { demuxer.stop() }
        var count = 0
        var keyframes = 0
        var lastDTS: MediaTime?
        while count < 150 {
            let change = store.changeCount
            switch store.next(&cursor) {
            case .packet(let packet):
                count += 1
                if packet.isKeyframe { keyframes += 1 }
                if let dts = packet.dts, let previous = lastDTS { #expect(dts > previous) }
                lastDTS = packet.dts
            case .needMore:
                await store.waitForChange(since: change)
            case .endOfStream, .invalidated:
                Issue.record("unexpected end")
                count = 150
            }
        }
        #expect(keyframes == 3, "60-frame GOPs: keyframes at frames 0, 60 and 120")
    }

    @Test func audioCursorFindsThePacketAtATime() async throws {
        let demuxer = try Demuxer(url: Fixture.syncH264.url())
        demuxer.start()
        defer { demuxer.stop() }
        let store = demuxer.store
        #expect(await demuxer.waitUntil { store.isAtEndOfFile })
        let audioIndex = try #require(demuxer.info.audioStreamIndex)
        var cursor = store.audioCursor(streamIndex: audioIndex, at: .seconds(5))
        guard case .packet(let packet) = store.next(&cursor) else {
            Issue.record("no audio packet")
            return
        }
        let time = try #require(packet.time)
        #expect(time <= .seconds(5) && time > .seconds(4.9))
        #expect(demuxer.audioParameters?.codecName == "aac")
    }

    @Test func stopEndsTheThread() async throws {
        let demuxer = try Demuxer(url: Fixture.h264.url())
        demuxer.start()
        demuxer.stop()
        #expect(await demuxer.waitUntil(timeout: .seconds(2)) { demuxer.isFinished })
    }

    @Test func blockBuffersShareThePacketMemoryAndReleaseIt() throws {
        let source = try MediaSource(url: Fixture.h264.url())
        let format = try #require(try Demuxer(url: Fixture.h264.url()).videoFormat)
        let description = try #require(format.formatDescription)
        weak var released: Packet?
        try autoreleasepool {
            var packet: Packet? = try source.readPacket()
            while let current = packet, current.streamIndex != source.videoStreamIndex { packet = try source.readPacket() }
            let video = try #require(packet)
            released = video
            var sample: CMSampleBuffer? = try video.makeSampleBuffer(format: description)
            let block = try #require(sample.flatMap { CMSampleBufferGetDataBuffer($0) })
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer)
            #expect(UnsafeRawPointer(pointer) == video.bytes.baseAddress, "zero copy")
            #expect(CMSampleBufferGetPresentationTimeStamp(try #require(sample)) == video.cmPTS)
            packet = nil
            #expect(released != nil, "the sample buffer keeps the packet alive")
            sample = nil
        }
        #expect(released == nil, "freeing the block buffer releases the packet")
    }
}
