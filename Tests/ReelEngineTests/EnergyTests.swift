import AVFoundation
import CoreMedia
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// The engine side of the energy policy (design section 7.9, D58 to D60): paused is idle,
/// occlusion stops video and resyncs on reveal, timers sleep when nothing is due. The budgets
/// themselves are measured by `reelctl energy-bench`.
@Suite struct EnergyTests {
    /// A silent headless engine; `occlusionDelay` is shortened so the suite runs quickly.
    static func make(occlusionDelay: Duration = .milliseconds(300), thumbnailCache: URL? = nil) -> PlaybackEngine {
        var values = ProcessInfo.processInfo.environment
        values.removeValue(forKey: "REEL_FORCE_DECODER")
        values.removeValue(forKey: "REEL_ALLOW_AUDIO")
        values.removeValue(forKey: "REEL_NO_THUMBNAILS")
        return PlaybackEngine(configuration: .init(
            audioMode: .headless,
            environment: ReelEnvironment(values),
            preventsDisplaySleep: false,
            generatesThumbnails: thumbnailCache != nil,
            thumbnailCacheDirectory: thumbnailCache,
            occlusionDelay: occlusionDelay
        ))
    }

    static func timeEvents(_ log: EventLog) -> [MediaTime] {
        log.all.compactMap { event in
            if case .time(let time) = event { return time }
            return nil
        }
    }

    /// Settles a paused engine: the read-ahead fill and the audio feed finish first.
    static func settle(_ engine: PlaybackEngine) async {
        #expect(await TestEngines.waitUntilReadingStops(engine), "the read-ahead fill finished")
        try? await Task.sleep(for: .milliseconds(800))
    }

    // MARK: Paused

    @Test func pausedForThreeSecondsDecodesReadsAndSendsNothing() async throws {
        let engine = Self.make()
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(Fixture.hevc10.url())
        await engine.play()
        try await Task.sleep(for: .seconds(1))
        await engine.pause()
        #expect(await engine.playbackState == .paused)
        await Self.settle(engine)

        let before = await engine.energyCounters()
        let eventsBefore = log.all.count
        try await Task.sleep(for: .seconds(3))
        let window = await engine.energyCounters() - before
        #expect(window.framesDecoded == 0, "frames decoded while paused: \(window.framesDecoded)")
        #expect(window.packetsRead == 0, "packets read while paused: \(window.packetsRead)")
        #expect(window.timeEvents == 0, "time events while paused: \(window.timeEvents)")
        #expect(window.subtitleRenders == 0)
        #expect(log.all.count == eventsBefore, "no event of any kind while paused")
        let decision = await engine.energyDecision
        #expect(decision.timeEvents == .onChangeOnly)
        #expect(!decision.holdsDisplaySleepAssertion && !decision.holdsActivity)
        await engine.close()
    }

    /// A paused exact seek shows its frame and stops: nothing is decoded after it, one time event
    /// comes with each state change and none periodically. Play continues from the frame after it.
    @Test func aPausedSeekStopsAfterTheShownFrameAndPlayContinuesFromIt() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = Self.make()
        let log = EventLog()
        log.start(engine.events)
        let presented = PresentedFrames()
        await engine.setFrameObserver { presented.record($0) }
        _ = try await engine.open(url)
        let target = MediaTime.seconds(30.2)
        let timesBefore = Self.timeEvents(log).count
        let report = try #require(await engine.seekAndWait(.exact(target)))
        let landed = try #require(report.landedPTS)
        #expect(landed == table.expected(at: target))
        await Self.settle(engine)
        let seekTimes = Self.timeEvents(log).count - timesBefore
        #expect(seekTimes >= 1 && seekTimes <= 4, "time events for one paused seek: \(seekTimes)")

        let before = await engine.energyCounters()
        try await Task.sleep(for: .seconds(1.5))
        let idle = await engine.energyCounters() - before
        #expect(idle.framesDecoded == 0 && idle.packetsRead == 0 && idle.timeEvents == 0, "\(idle)")

        let generation = await engine.currentGeneration
        let presentedBefore = presented.entries.withLock { $0.count }
        await engine.play()
        let flowing = await instantWhen(timeout: .seconds(10)) { presented.entries.withLock { $0.count } >= presentedBefore + 24 }
        #expect(flowing != nil, "frames flow after play")
        // Frames queued ahead before the feeder stopped, then the ones decoded after play.
        let after = presented.entries.withLock { $0 }.filter { $0.generation == generation && $0.pts > landed }.map(\.pts)
        let expected = (1...12).compactMap { table.frame(landed, offset: $0) }
        #expect(Array(after.prefix(expected.count)) == expected, "play continues with the frames after the shown one")
        #expect(await engine.currentGeneration == generation, "play after a pause needs no seek")
        await engine.close()
    }

    /// Audio stops feeding while paused and continues after the last buffer on play: no buffer is
    /// repeated or skipped.
    @Test func pauseAndPlayContinueAudioWithoutAGapOrOverlap() async throws {
        struct Buffer: Sendable {
            var pts: MediaTime
            var end: MediaTime
            var restart: UInt64
        }
        let engine = Self.make()
        let buffers = Mutex<[Buffer]>([])
        await engine.setAudioObserver { buffer, _ in
            let entry = Buffer(pts: buffer.pts, end: buffer.end, restart: buffer.restart)
            buffers.withLock { $0.append(entry) }
        }
        _ = try await engine.open(Fixture.syncH264.url())
        await engine.play()
        try await Task.sleep(for: .seconds(1))
        await engine.pause()
        await Self.settle(engine)
        let pausedCount = buffers.withLock { $0.count }
        try await Task.sleep(for: .seconds(1))
        #expect(buffers.withLock { $0.count } == pausedCount, "no audio decoded while paused")
        let lastEnd = try #require(buffers.withLock { $0.map(\.end).max() })

        await engine.play()
        let more = await instantWhen(timeout: .seconds(10)) { buffers.withLock { $0.count } > pausedCount + 10 }
        #expect(more != nil, "audio flows after play")
        let resumed = buffers.withLock { Array($0.dropFirst(pausedCount)) }
        let first = try #require(resumed.first)
        #expect(abs((first.pts - lastEnd).microseconds) <= 1_000, "audio continues at \(lastEnd), got \(first.pts)")
        for (previous, next) in zip(resumed, resumed.dropFirst()) where previous.restart == next.restart {
            #expect(abs((next.pts - previous.end).microseconds) <= 1_000, "contiguous after play: \(previous.end) then \(next.pts)")
        }
        await engine.close()
    }

    // MARK: Occlusion

    @Test func occlusionStopsVideoFramesWhileAudioAndTheClockGoOn() async throws {
        let engine = Self.make()
        let log = EventLog()
        log.start(engine.events)
        let audio = Atomic<Int>(0)
        await engine.setAudioObserver { _, _ in audio.add(1, ordering: .relaxed) }
        _ = try await engine.open(Fixture.hevc10.url())
        await engine.play()
        try await Task.sleep(for: .seconds(1))
        await engine.setOccluded(true)
        #expect(await engine.isVideoStoppedForOcclusion == false, "video goes on until the delay passes")
        var waited = 0
        while await !engine.isVideoStoppedForOcclusion, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(await engine.isVideoStoppedForOcclusion)
        #expect(await engine.isVideoRendererDetachedForTesting, "the layer is off the running clock")
        try await Task.sleep(for: .milliseconds(200))

        let before = await engine.energyCounters()
        let audioBefore = audio.load(ordering: .relaxed)
        let clockBefore = engine.currentTime
        let timesBefore = Self.timeEvents(log).count
        try await Task.sleep(for: .seconds(2))
        let window = await engine.energyCounters() - before
        #expect(window.framesDecoded == 0, "video frames decoded while occluded: \(window.framesDecoded)")
        #expect(audio.load(ordering: .relaxed) > audioBefore + 20, "audio keeps decoding")
        let advanced = (engine.currentTime - clockBefore).seconds
        #expect(advanced > 1.5 && advanced < 2.5, "the clock runs: \(advanced) s")
        let times = Self.timeEvents(log).count - timesBefore
        #expect(times >= 1 && times <= 3, "time events at 1 Hz while occluded: \(times)")
        #expect(await engine.playbackState == .playing)
        let decision = await engine.energyDecision
        #expect(!decision.videoDecode && decision.audioDecode && decision.timeEvents == .interval(seconds: 1))
        await engine.close()
    }

    /// While video is stopped for occlusion the file ends at the demuxed video end, never at a
    /// shorter audio end or (no audio, no container duration) at zero.
    @Test func whileOccludedTheEndWaitsForTheVideoTheDemuxerRead() {
        let fourteen = MediaTime.seconds(14)
        // 14 s of video, 4 s of audio: the demuxer has not reached the end yet, so no end.
        #expect(PlaybackEngine.endTime(
            videoStoppedForOcclusion: true, demuxedVideoEnd: nil, decodedVideoEnd: .seconds(3), audioEnd: .seconds(4), containerEnd: fourteen
        ) == nil)
        // Video only, no container duration (a live mkv): no end until the video end is known.
        #expect(PlaybackEngine.endTime(
            videoStoppedForOcclusion: true, demuxedVideoEnd: nil, decodedVideoEnd: nil, audioEnd: nil, containerEnd: nil
        ) == nil)
        #expect(PlaybackEngine.endTime(
            videoStoppedForOcclusion: true, demuxedVideoEnd: fourteen, decodedVideoEnd: .seconds(3), audioEnd: .seconds(4), containerEnd: nil
        ) == fourteen)
        // Visible: the decoded ends, then the container.
        #expect(PlaybackEngine.endTime(
            videoStoppedForOcclusion: false, demuxedVideoEnd: nil, decodedVideoEnd: fourteen, audioEnd: .seconds(4), containerEnd: nil
        ) == fourteen)
        #expect(PlaybackEngine.endTime(
            videoStoppedForOcclusion: false, demuxedVideoEnd: nil, decodedVideoEnd: nil, audioEnd: nil, containerEnd: fourteen
        ) == fourteen)
    }

    /// The store keeps the end of the last video packet once the demuxer reaches the end of the
    /// file, so an occluded engine knows where the video ends without decoding it.
    @Test func theStoreKnowsWhereTheVideoEndsOnceTheFileIsRead() async throws {
        let demuxer = try Demuxer(url: OddFixture.videoOnly.url(), limits: .init(ahead: .seconds(25)))
        #expect(demuxer.store.videoEndOfFile == nil)
        demuxer.start()
        defer { demuxer.stop() }
        let read = await demuxer.waitUntil { demuxer.store.isAtEndOfFile }
        #expect(read)
        let end = try #require(demuxer.store.videoEndOfFile)
        #expect(abs(end.seconds - 3.0) < 0.05, "video ends at \(end)")
    }

    /// Clearing the flag runs an exact seek to the clock; it lands on the frame the clock shows
    /// and video flows again on a layer back on the synchronizer.
    @Test func revealingTheWindowResyncsToTheFrameAtTheClock() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = Self.make()
        _ = try await engine.open(url)
        await engine.play()
        try await Task.sleep(for: .seconds(1))
        await engine.setOccluded(true)
        var waited = 0
        while await !engine.isVideoStoppedForOcclusion, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        try await Task.sleep(for: .seconds(1.5))
        let clock = engine.currentTime
        let report = try #require(await engine.setOccludedAndWait(false, timeout: .seconds(10)))
        #expect(!report.cancelled && report.kind == .exact)
        #expect(report.target >= clock, "the resync seeks to the clock, \(report.target) after \(clock)")
        #expect(report.landedPTS == table.expected(at: report.target), "landed on \(report.landedPTS?.description ?? "-") for \(report.target)")
        // A sanity bound: energy-bench gates the 300 ms on a quiet process.
        #expect((report.targetMilliseconds ?? .infinity) < 3_000)
        #expect(await engine.isVideoStoppedForOcclusion == false)
        #expect(await engine.isVideoRendererDetachedForTesting == false)
        #expect(await engine.playbackState == .playing)

        let before = await engine.energyCounters()
        try await Task.sleep(for: .seconds(1))
        let window = await engine.energyCounters() - before
        #expect(window.framesDecoded >= 15, "video decodes again: \(window.framesDecoded)")
        let rendererTime = try #require(await engine.displayLayerTimeForTesting())
        #expect(abs(rendererTime - engine.currentTime.seconds) < 0.2, "the layer follows the clock again")
        await engine.close()
    }

    @Test func occlusionHasNoEffectWhilePaused() async throws {
        let engine = Self.make(occlusionDelay: .milliseconds(100))
        _ = try await engine.open(Fixture.h264.url())
        await engine.setOccluded(true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await engine.isVideoStoppedForOcclusion == false, "paused: nothing to stop")
        await engine.play()
        var waited = 0
        while await !engine.isVideoStoppedForOcclusion, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(await engine.isVideoStoppedForOcclusion, "playing while hidden: video stops")
        await engine.close()
    }

    // MARK: Thumbnails

    @Test func pausedThumbnailsWaitForThePointer() async throws {
        let folder = try TemporaryFolder()
        let engine = Self.make(thumbnailCache: folder.url)
        await engine.setPointerRecent(false)
        _ = try await engine.open(Fixture.hevc10.url())
        let generator = try #require(await engine.thumbnailGenerator)
        try await Task.sleep(for: .milliseconds(500))
        let done = generator.progress.done
        try await Task.sleep(for: .seconds(1))
        #expect(generator.progress.done == done, "paused without pointer movement: suspended")
        #expect(generator.report == nil)
        await engine.setPointerRecent(true)
        let report = await generator.finished()
        #expect(report.outcome == .completed)
        await engine.close()
    }

    @Test func lowPowerModeStopsThumbnailsAfterTheCoarsePass() async throws {
        let folder = try TemporaryFolder()
        let engine = Self.make(thumbnailCache: folder.url)
        await engine.setLowPowerForTesting(true)
        // Ten keyframes: the coarse pass takes slots 0 and 8.
        _ = try await engine.open(Fixture.syncH264.url())
        let generator = try #require(await engine.thumbnailGenerator)
        let report = await generator.finished()
        #expect(report.planned > 8)
        #expect(report.generated > 0 && report.generated < report.planned, "\(report.generated) of \(report.planned)")
        #expect(report.generated == (report.planned + 7) / 8, "every 8th position only")
        let counters = await engine.energyCounters()
        #expect(counters.thumbnailsDecoded == report.generated)
        await engine.close()
    }

    // MARK: Timers

    @Test func anInactiveTimeEventTimerNeverFires() async throws {
        let (stream, sink) = AsyncStream.makeStream(of: EngineEvent.self)
        _ = stream
        let counters = EngineCounters()
        let timer = TimeEventTimer(interval: 0.02, synchronizer: AVSampleBufferRenderSynchronizer(), sink: sink, counters: counters)
        try await Task.sleep(for: .milliseconds(200))
        #expect(counters.timeEvents.load(ordering: .relaxed) == 0)
        timer.setActive(true)
        try await Task.sleep(for: .milliseconds(300))
        let active = counters.timeEvents.load(ordering: .relaxed)
        #expect(active >= 3, "fires while active: \(active)")
        timer.setActive(false)
        try await Task.sleep(for: .milliseconds(60))
        let stopped = counters.timeEvents.load(ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(300))
        #expect(counters.timeEvents.load(ordering: .relaxed) == stopped, "no events once inactive")
        timer.cancel()
    }

    /// Section 7.9: subtitles render every display frame only while an event shows or is due
    /// within 1 s; between events the timer sleeps.
    @Test func theSubtitleTimerSleepsUntilAnEventIsDue() async throws {
        let clock = Mutex(MediaTime.seconds(10))
        let presenter = SubtitlePresenter { clock.withLock { $0 } }
        let store = SubtitleTrackStore()
        let id = TrackID.embedded(streamIndex: 2)
        store.begin(id, header: "", format: .srt)
        store.add([SubtitleTextEvent(start: .seconds(20), end: .seconds(22), fields: "0,0,Default,,0,0,0,,Hello")], to: id)
        presenter.reset(store: store, videoWidth: 1280, videoHeight: 720)
        presenter.select(id, format: .srt)
        presenter.update { settings in
            settings.holding = false
            settings.playing = true
        }
        try await Task.sleep(for: .milliseconds(300))
        let idle = presenter.current.renderCount
        try await Task.sleep(for: .milliseconds(500))
        #expect(presenter.current.renderCount - idle <= 1, "nothing due for 9 s: the timer sleeps")

        clock.withLock { $0 = .seconds(19.5) }
        presenter.requestRender()
        try await Task.sleep(for: .milliseconds(100))
        let due = presenter.current.renderCount
        try await Task.sleep(for: .milliseconds(500))
        #expect(presenter.current.renderCount - due >= 10, "an event due within 1 s renders every frame")

        presenter.update { $0.suspended = true }
        try await Task.sleep(for: .milliseconds(100))
        let suspended = presenter.current.renderCount
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.current.renderCount == suspended, "occluded: no renders")
    }

    @Test func aDisabledDisplaySleepHoldsNeitherAssertionNorActivity() {
        let sleep = DisplaySleep(enabled: false)
        #expect(sleep.preventSleep() == false)
        #expect(!sleep.isPreventingSleep && !sleep.holdsActivity)
        sleep.allowSleep()
    }

    /// The demuxer thread waits on a condition without a timeout: an idle demuxer reads nothing
    /// and still stops at once.
    @Test func anIdleDemuxerWaitsWithoutPollingAndStops() async throws {
        let demuxer = try Demuxer(url: Fixture.h264.url(), limits: PacketStore.Limits(ahead: .seconds(2)))
        demuxer.start()
        #expect(await demuxer.waitUntil { demuxer.store.wantsMoreData == false }, "the read-ahead fill finished")
        try await Task.sleep(for: .milliseconds(200))
        let idle = demuxer.packetsRead
        try await Task.sleep(for: .milliseconds(500))
        #expect(demuxer.packetsRead == idle)
        demuxer.store.setPlayhead(.seconds(3))
        #expect(await demuxer.waitUntil { demuxer.packetsRead > idle }, "a playhead move wakes it")
        demuxer.stop()
        #expect(await demuxer.waitUntil { demuxer.isFinished }, "stop wakes the waiting thread")
    }
}
