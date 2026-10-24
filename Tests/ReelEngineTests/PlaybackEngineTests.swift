import CoreMedia
import CoreVideo
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// The engine's state machine, clock, outputs and hooks (design sections 7.1, 7.4 and 11.2).
@Suite struct PlaybackEngineTests {
    @Test func openShowsTheFirstFramePausedAndDescribesTheFile() async throws {
        let url = try Fixture.h264.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        let info = try await engine.open(url)
        #expect(info.videoStream?.codec == "h264")
        #expect(info.audioStream?.codec == "aac")
        #expect(info.videoDecoder == .hardware)
        #expect(await engine.playbackState == .paused)
        let report = try #require(await engine.lastReport)
        #expect(report.kind == .exact)
        #expect(report.landedPTS == table.frames.first)
        #expect(report.targetMilliseconds.map { $0 < 1_000 } == true)
        let states = log.states
        #expect(states.first == .opening)
        #expect(states.last == .paused)
        #expect(log.all.contains { if case .opened(let opened) = $0 { opened.url == url } else { false } })
        await engine.close()
    }

    @Test func headlessEnginesAttachNoAudioRendererAndHoldNoSleepAssertion() async throws {
        let engine = TestEngines.make()
        _ = try await engine.open(Fixture.syncH264.url())
        #expect(await engine.hasAudioOutput == false, "tests must stay silent")
        await engine.setVolume(100)
        await engine.setMuted(false)
        await engine.play()
        #expect(await engine.playbackState == .playing)
        #expect(await engine.holdsDisplaySleepAssertion == false)
        await engine.close()
    }

    @Test func playbackModeInATestProcessStillAttachesNoAudioRenderer() {
        let decision = AudioOutput.attachDecision(mode: .playback, allowsAudio: false, isTestProcess: AudioOutput.isTestProcess())
        #expect(decision == .none)
    }

    /// Design section 7.4: a flush the renderer suggests (device or configuration change) restarts
    /// audio from the current time in the same generation and leaves video alone. Driven by a
    /// synthetic event: no renderer is attached.
    @Test func aSuggestedAudioFlushRestartsAudioAtTheClockWithoutASeek() async throws {
        struct Delivered: Sendable {
            var pts: MediaTime
            var end: MediaTime
            var generation: UInt64
            var afterFlush: Bool
        }
        let engine = TestEngines.make()
        let flushed = Atomic<Bool>(false)
        let delivered = Mutex<[Delivered]>([])
        let framesAfterFlush = Atomic<Int>(0)
        await engine.setAudioObserver { buffer, generation in
            let entry = Delivered(pts: buffer.pts, end: buffer.end, generation: generation, afterFlush: flushed.load(ordering: .acquiring))
            delivered.withLock { $0.append(entry) }
        }
        await engine.setFrameObserver { _ in
            if flushed.load(ordering: .acquiring) { framesAfterFlush.add(1, ordering: .relaxed) }
        }
        _ = try await engine.open(Fixture.syncH264.url())
        await engine.play()
        // Audio decodes about 1 s ahead of the clock; let it get there.
        try await Task.sleep(for: .milliseconds(1_200))
        let generation = await engine.currentGeneration
        let reports = await engine.lastReport?.generation
        let decodedAhead = try #require(delivered.withLock { $0.map(\.end).max() })

        let clock = engine.currentTime
        flushed.store(true, ordering: .releasing)
        await engine.deliverAudioEventForTesting(.flushSuggested(.outputConfigurationChanged))
        try await Task.sleep(for: .milliseconds(500))
        let after = delivered.withLock { $0.filter(\.afterFlush) }
        let first = try #require(after.first, "audio restarted after the flush")
        #expect(decodedAhead > clock + .milliseconds(500), "audio was ahead of the clock before the flush")
        #expect(first.pts <= clock + .milliseconds(100) && first.end > clock - .milliseconds(100), "restarted at \(first.pts) for the clock at \(clock)")
        #expect(after.allSatisfy { $0.generation == generation }, "same generation: no seek")
        #expect(await engine.currentGeneration == generation)
        #expect(await engine.lastReport?.generation == reports, "no seek was reported")
        #expect(await engine.playbackState == .playing)
        #expect(framesAfterFlush.load(ordering: .relaxed) > 5, "video kept presenting")
        await engine.close()
    }

    /// The old audio feeder shares the generation, so a packet it submits after the restart's
    /// reset would reach the decoder out of order. The restart has to wait for it.
    @Test func aSuggestedAudioFlushWaitsForTheOldFeederBeforeRestarting() async throws {
        let engine = TestEngines.make()
        let flushed = Atomic<Bool>(false)
        let after = Mutex<[MediaTime]>([])
        await engine.setAudioObserver { buffer, _ in
            if flushed.load(ordering: .acquiring) { after.withLock { $0.append(buffer.pts) } }
        }
        _ = try await engine.open(Fixture.syncH264.url())
        await engine.play()
        try await Task.sleep(for: .milliseconds(1_200))
        // The feeder is paced about 1 s ahead; its next packet is held just before the submit.
        await engine.holdNextAudioSubmitForTesting(milliseconds: 400)
        try await Task.sleep(for: .milliseconds(150))
        await engine.deliverAudioEventForTesting(.flushSuggested(.outputConfigurationChanged))
        let clock = engine.currentTime
        flushed.store(true, ordering: .releasing)
        try await Task.sleep(for: .milliseconds(900))
        let pts = after.withLock { $0 }
        let first = try #require(pts.first, "audio restarted after the flush")
        #expect(first <= clock + .milliseconds(100), "restarted at \(first) for the clock at \(clock)")
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $0 < $1 }, "no packet of the old feeder arrived after the reset: \(pts.map(\.seconds))")
        await engine.close()
    }

    @Test func playAdvancesTheClockAndPauseHoldsIt() async throws {
        let engine = TestEngines.make()
        _ = try await engine.open(Fixture.syncH264.url())
        let start = engine.currentTime
        await engine.play()
        try await Task.sleep(for: .milliseconds(400))
        let playing = engine.currentTime
        #expect(await engine.playbackState == .playing)
        #expect((playing - start).seconds > 0.2, "clock moved \(playing - start)")
        await engine.pause()
        #expect(await engine.playbackState == .paused)
        let paused = engine.currentTime
        try await Task.sleep(for: .milliseconds(200))
        #expect(abs((engine.currentTime - paused).microseconds) < 2_000)
        await engine.close()
    }

    @Test func playbackReachesTheEndAndPlayStartsOver() async throws {
        let url = try Fixture.annexB.url()
        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        let updates = Mutex<[PositionUpdate]>([])
        await engine.setPositionHandler { update in updates.withLock { $0.append(update) } }
        _ = try await engine.open(url)
        await engine.setPlaybackRate(4)
        await engine.play()
        let ended = await log.wait(timeout: .seconds(8)) { $0.all.contains(.ended) }
        #expect(ended)
        #expect(await engine.playbackState == .ended)
        #expect(updates.withLock { $0.contains { $0.reason == .ended } })

        let replayed = ContinuousClock.now
        await engine.play()
        let restarted = await log.wait(timeout: .seconds(5)) { $0.states.last == .playing }
        #expect(restarted)
        let start = await engine.startTime
        let seek = log.reports.last { $0.kind == .exact }
        #expect(seek?.target == start && seek?.cancelled == false && seek?.landedPTS != nil, "play after the end seeks to the start: \(String(describing: seek))")
        // At 4x the clock can be at most 4 times the wall time since play() past the start.
        let elapsed = (ContinuousClock.now - replayed) / .seconds(1)
        let clock = engine.currentTime
        #expect(clock < start + .seconds(4 * elapsed + 0.5), "clock \(clock) after \(elapsed) s")
        await engine.close()
    }

    @Test func positionUpdatesArriveWhenASeekSettlesAndOnPauseAndClose() async throws {
        let url = try Fixture.syncHEVC.url()
        let engine = TestEngines.make()
        let updates = Mutex<[PositionUpdate]>([])
        await engine.setPositionHandler { update in updates.withLock { $0.append(update) } }
        _ = try await engine.open(url)
        _ = try #require(await engine.seekAndWait(.exact(.seconds(6.5))))
        await engine.play()
        try await Task.sleep(for: .milliseconds(150))
        await engine.pause()
        await engine.close()
        let reasons = updates.withLock { $0.map(\.reason) }
        #expect(reasons.contains(.seekSettled))
        #expect(reasons.contains(.paused))
        #expect(reasons.last == .closed)
        let settled = try #require(updates.withLock { $0.first { $0.reason == .seekSettled && $0.position == .seconds(6.5) } })
        #expect(settled.url == url)
        #expect(settled.duration.map { abs($0.seconds - 20) < 0.5 } == true)
    }

    @Test func openingAFileThatIsNotMediaFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reel-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "not-a-video.mkv")
        try Data("this is not a video".utf8).write(to: file)
        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        await #expect(throws: EngineError.self) { try await engine.open(file) }
        #expect(await engine.playbackState == .failed)
        #expect(await log.wait { $0.states.last == .failed })
        #expect(log.all.contains { if case .failed = $0 { true } else { false } })
        await engine.close()
    }

    @Test func closeFinishesTheEventStream() async throws {
        let engine = TestEngines.make()
        let log = EventLog()
        let task = log.start(engine.events)
        _ = try await engine.open(Fixture.flv1.url())
        await engine.close()
        await task.value
        #expect(log.isFinished)
        #expect(log.states.last == .idle)
        await #expect(throws: EngineError.self) { try await engine.open(Fixture.flv1.url()) }
    }

    @Test func openingAnotherFileReplacesTheFirst() async throws {
        let engine = TestEngines.make()
        _ = try await engine.open(Fixture.h264.url())
        _ = try #require(await engine.seekAndWait(.exact(.seconds(30))))
        let info = try await engine.open(Fixture.mpeg4.url())
        #expect(info.videoStream?.codec == "mpeg4")
        #expect(info.videoDecoder == .software, "MPEG-4 Part 2 has no VideoToolbox decoder")
        #expect(await engine.playbackState == .paused)
        let report = try #require(await engine.lastReport)
        #expect(report.landedPTS != nil)
        await engine.close()
    }

    @Test(arguments: [Fixture.syncH264, .syncHEVC])
    func beepsAndFlashesStayTogetherThroughTheEngine(_ fixture: Fixture) async throws {
        let engine = TestEngines.make()
        let flashes = Mutex<[MediaTime]>([])
        let onsets = Mutex<[MediaTime]>([])
        let lastLoud = Mutex<MediaTime?>(nil)
        await engine.setFrameObserver { frame in
            guard let pts = MediaTime(frame.presentationTime), Self.centreLuma(frame.pixelBuffer) > 128 else { return }
            flashes.withLock { $0.append(pts) }
        }
        await engine.setAudioObserver { buffer, _ in
            let samples = buffer.interleavedSamples()
            let channels = max(buffer.channelCount, 1)
            for index in 0..<buffer.frameCount where abs(samples[index * channels]) > 0.1 {
                let time = MediaTime(value: buffer.startSample + Int64(index), timeBaseNum: 1, timeBaseDen: Int32(buffer.sampleRate))
                let isOnset = lastLoud.withLock { last -> Bool in
                    defer { last = time }
                    return last.map { time - $0 > .milliseconds(300) } ?? true
                }
                if isOnset { onsets.withLock { $0.append(time) } }
            }
        }
        _ = try await engine.open(fixture.url())
        await engine.setPlaybackRate(8)
        await engine.play()
        // About 3 s at 8x; the wait only bounds a stuck pipeline (a busy machine decodes slower).
        let deadline = ContinuousClock.now + .seconds(60)
        while await engine.playbackState != .ended, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await engine.playbackState == .ended, "playback reached the end")
        await engine.close()
        let flashTimes = flashes.withLock { $0 }
        let onsetTimes = onsets.withLock { $0 }
        #expect(flashTimes.count >= 19, "one white frame per second: \(flashTimes.count)")
        for flash in flashTimes {
            let nearest = try #require(onsetTimes.min { abs(($0 - flash).microseconds) < abs(($1 - flash).microseconds) })
            #expect(abs((nearest - flash).milliseconds) <= 20, "beep at \(nearest) for the flash at \(flash)")
        }
    }

    /// The 8-bit luma sample in the middle of the picture (the sync fixtures are 8-bit).
    static func centreLuma(_ pixelBuffer: CVReadOnlyPixelBuffer) -> UInt8 {
        pixelBuffer.withUnsafeBuffer { buffer in
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return 0 }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
            let row = CVPixelBufferGetHeightOfPlane(buffer, 0) / 2
            let line = base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
            return line.assumingMemoryBound(to: UInt8.self)[CVPixelBufferGetWidthOfPlane(buffer, 0) / 2]
        }
    }

    /// Counted by the clock value each event carries, so a slow event consumer (a busy test
    /// process) does not change the count; the timer itself runs on its own dispatch queue.
    @Test func timeEventsFollowTheRequestedInterval() async throws {
        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(Fixture.syncH264.url())
        func times() -> [MediaTime] {
            log.all.compactMap { event in
                if case .time(let time) = event { return time }
                return nil
            }
        }
        /// Time events stamped inside `window`, once the log holds one stamped after it.
        func events(in window: ClosedRange<MediaTime>) async -> Int {
            let caughtUp = await log.wait { _ in times().contains { $0 > window.upperBound } }
            #expect(caughtUp, "a time event after \(window.upperBound) arrived")
            return times().filter { window.contains($0) }.count
        }

        await engine.setTimeUpdateInterval(0.1)
        await engine.play()
        var start = engine.currentTime
        try await Task.sleep(for: .milliseconds(600))
        var end = engine.currentTime
        var span = (end - start).seconds
        let fast = await events(in: start...end)
        #expect(Double(fast) >= span * 10 * 0.3 && Double(fast) <= span * 10 + 2, "\(fast) time events in \(span) s at 10 Hz")

        await engine.setTimeUpdateInterval(1)
        try await Task.sleep(for: .milliseconds(150))
        start = engine.currentTime
        try await Task.sleep(for: .milliseconds(600))
        end = engine.currentTime
        span = (end - start).seconds
        let slow = await events(in: start...end)
        #expect(Double(slow) <= span + 1, "\(slow) time events in \(span) s at 1 Hz")
        await engine.close()
    }

    /// Design section 5 lists wav, mp3, aac and flac: with no picture to wait for, an exact seek
    /// lands once the clock is set, and playback starts.
    @Test func audioOnlyFilesOpenPausedPlayAndSeek() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reel-audio-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "silence.wav")
        try Self.silentWAV(seconds: 10, sampleRate: 48_000).write(to: url)

        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        let info = try await engine.open(url)
        #expect(info.videoStreamIndex == nil)
        #expect(info.audioStreamIndex != nil)
        #expect(await engine.hasAudioOutput == false, "tests must stay silent")
        let opened = try #require(await engine.lastReport, "the seek to the start landed")
        #expect(!opened.cancelled)
        #expect(opened.landedPTS == .zero)
        #expect(await engine.playbackState == .paused)

        await engine.play()
        #expect(await engine.playbackState == .playing)
        let before = engine.currentTime
        try await Task.sleep(for: .milliseconds(300))
        #expect((engine.currentTime - before).seconds > 0.1, "the clock runs")

        let seek = try #require(await engine.seekAndWait(.exact(.seconds(5)), timeout: .seconds(5)))
        #expect(!seek.cancelled)
        #expect(seek.landedPTS == .seconds(5))
        let resumed = await log.wait(timeout: .seconds(5)) { _ in log.states.last == .playing }
        #expect(resumed, "playback resumes after the seek")

        await engine.pause()
        let scrub = try #require(await engine.seekAndWait(.scrub(.seconds(7)), timeout: .seconds(5)))
        #expect(scrub.landedPTS == .seconds(7))
        #expect(abs((engine.currentTime - .seconds(7)).microseconds) < 1_000, "the clock follows the drag")
        let paused = try #require(await engine.seekAndWait(.exact(.seconds(2)), timeout: .seconds(5)))
        #expect(paused.landedPTS == .seconds(2))
        #expect(await engine.playbackState == .paused)
        await engine.close()
    }

    /// A 16-bit mono PCM WAV file of silence.
    static func silentWAV(seconds: Int, sampleRate: Int) -> Data {
        let dataBytes = seconds * sampleRate * 2
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        append32(36 + dataBytes)
        append("WAVEfmt ")
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(sampleRate)
        append32(sampleRate * 2)
        append16(2)
        append16(16)
        append("data")
        append32(dataBytes)
        data.append(Data(count: dataBytes))
        return data
    }

    /// VideoToolbox in real-time mode may drop a frame under load (no error, no picture). The
    /// frames held behind it must go out and its decode credit must come back, or playback
    /// stalls once all eight credits are gone.
    @Test func aDroppedFrameReleasesItsCreditAndTheFramesHeldBehindIt() async throws {
        let shared = PipelineShared()
        shared.generation.store(1, ordering: .releasing)
        let failures = Atomic<Int>(0)
        shared.failureHandler.withLock { $0 = SendableCallback { _ in failures.add(1, ordering: .relaxed) } }
        let orderer = PresentationOrderer()
        let credits = FrameCredits(limit: 2)
        credits.reset(generation: 1)
        let (frames, sink) = AsyncStream.makeStream(of: DecodedFrame.self)
        let handler = PlaybackEngine.decodeHandler(shared: shared, orderer: orderer, credits: credits, sink: sink)
        #expect(await credits.acquire(generation: 1))
        #expect(await credits.acquire(generation: 1))
        let first = CMTime(value: 1, timescale: 30)
        let second = CMTime(value: 2, timescale: 30)
        orderer.expect(first)
        orderer.expect(second)

        handler(.frame(try Self.blankFrame(at: second, generation: 1)))
        #expect(orderer.pendingCount == 2, "the second frame waits for the first")
        handler(.dropped(presentationTime: first, generation: 1))
        sink.finish()
        var released: [CMTime] = []
        for await frame in frames { released.append(frame.presentationTime) }
        #expect(released == [second])
        #expect(credits.available == 1, "the dropped frame's credit came back")
        #expect(failures.load(ordering: .relaxed) == 0, "a drop is not a decode failure")
    }

    static func blankFrame(at time: CMTime, generation: UInt64) throws -> DecodedFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let pixelBuffer = try #require(status == kCVReturnSuccess ? buffer : nil)
        return DecodedFrame(
            pixelBuffer: CVReadOnlyPixelBuffer(fresh: pixelBuffer),
            presentationTime: time,
            duration: CMTime(value: 1, timescale: 30),
            generation: generation,
            decoder: .hardware
        )
    }

    @Test func displaySleepDisabledNeverTakesAnAssertion() {
        let sleep = DisplaySleep(enabled: false)
        #expect(sleep.preventSleep() == false)
        #expect(sleep.isPreventingSleep == false)
        sleep.allowSleep()
    }

    @Test func frameCreditsBoundDecodeAheadAndResetWithTheGeneration() async {
        let credits = FrameCredits(limit: 2)
        credits.reset(generation: 1)
        #expect(await credits.acquire(generation: 1))
        #expect(await credits.acquire(generation: 1))
        let waiter = Task { await credits.acquire(generation: 1) }
        try? await Task.sleep(for: .milliseconds(30))
        credits.reset(generation: 2)
        #expect(await waiter.value == false, "a waiter of an older generation gives up")
        #expect(credits.available == 2)
        credits.release(generation: 1)
        #expect(credits.available == 2, "releases of an older generation are ignored")
    }

    @Test func callbacksBehindALockSurviveManyReads() {
        let box = Mutex<SendableCallback<Int>?>(SendableCallback { _ in })
        for value in 0..<100_000 { box.withLock { $0 }?.call(value) }
        box.withLock { $0 = nil }
    }
}
