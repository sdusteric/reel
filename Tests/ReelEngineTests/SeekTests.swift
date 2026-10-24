import CoreMedia
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// Collects an engine's events for assertions.
final class EventLog: Sendable {
    private let storage = Mutex<[EngineEvent]>([])
    private let finished = Atomic<Bool>(false)

    /// Starts consuming `engine.events`; the task ends when the engine closes.
    @discardableResult
    func start(_ events: AsyncStream<EngineEvent>) -> Task<Void, Never> {
        Task { [self] in
            for await event in events { storage.withLock { $0.append(event) } }
            finished.store(true, ordering: .releasing)
        }
    }

    var all: [EngineEvent] { storage.withLock { $0 } }
    var isFinished: Bool { finished.load(ordering: .acquiring) }

    var reports: [SeekReport] {
        all.compactMap { event in
            if case .seekCompleted(let report) = event { return report }
            return nil
        }
    }

    var states: [PlaybackState] {
        all.compactMap { event in
            if case .stateChanged(let state) = event { return state }
            return nil
        }
    }

    /// Polls until `condition` holds or `timeout` passes.
    func wait(timeout: Duration = .seconds(10), _ condition: (EventLog) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(self) {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// Frames the engine presented, with their generation and when they were enqueued.
final class PresentedFrames: Sendable {
    struct Entry: Sendable {
        var pts: MediaTime
        var generation: UInt64
        var nanos: UInt64
    }

    let entries = Mutex<[Entry]>([])

    func record(_ frame: DecodedFrame) {
        let entry = Entry(pts: MediaTime(frame.presentationTime) ?? frame.time, generation: frame.generation, nanos: monotonicNanos())
        entries.withLock { $0.append(entry) }
    }
}

/// Every video frame pts of a fixture, sorted, and its keyframes.
struct FrameTable {
    var frames: [MediaTime]
    var keyframes: [MediaTime]

    init(_ url: URL) throws {
        let source = try MediaSource(url: url)
        var frames: [MediaTime] = []
        var keys: [MediaTime] = []
        while let packet = try source.readPacket() {
            guard packet.streamIndex == source.videoStreamIndex, let pts = packet.pts else { continue }
            frames.append(pts)
            if packet.isKeyframe { keys.append(pts) }
        }
        self.frames = frames.sorted()
        keyframes = keys.sorted()
    }

    /// The frame shown at `time`.
    func expected(at time: MediaTime) -> MediaTime? {
        frames.last { $0 <= time } ?? frames.first
    }

    /// The frame `offset` frames (in display order) from `time`'s frame.
    func frame(_ time: MediaTime, offset: Int) -> MediaTime? {
        guard let index = frames.firstIndex(of: time), frames.indices.contains(index + offset) else { return nil }
        return frames[index + offset]
    }
}

enum TestEngines {
    /// A headless engine: no audio renderer, no display sleep assertion, decoder by policy
    /// unless `force` is given.
    static func make(
        force: VideoDecoderKind? = nil,
        backgroundExactDelay: Duration = PlaybackEngine.backgroundExactDelay,
        storeLimits: PacketStore.Limits = .standard
    ) -> PlaybackEngine {
        var values = ProcessInfo.processInfo.environment
        values.removeValue(forKey: "REEL_FORCE_DECODER")
        values.removeValue(forKey: "REEL_ALLOW_AUDIO")
        if let force { values["REEL_FORCE_DECODER"] = force == .hardware ? "hw" : "sw" }
        return PlaybackEngine(configuration: .init(
            audioMode: .headless,
            environment: ReelEnvironment(values),
            preventsDisplaySleep: false,
            backgroundExactDelay: backgroundExactDelay,
            storeLimits: storeLimits
        ))
    }

    /// Polls until the engine stops reading the file (the store reached its read-ahead limit).
    static func waitUntilReadingStops(_ engine: PlaybackEngine, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var last = await engine.bytesRead
        var stable = 0
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let now = await engine.bytesRead
            stable = now == last ? stable + 1 : 0
            last = now
            if stable >= 4 { return true }
        }
        return false
    }
}

/// Engine seeks on the generated fixtures (design section 7.5).
@Suite struct SeekTests {
    @Test func rapidScrubsAreCoalescedToTheLatestTarget() async throws {
        let url = try Fixture.hevc10.url()
        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(url)
        let targets = (0..<12).map { MediaTime.seconds(1 + Double($0) * 4.5) }
        for target in targets { await engine.seek(.scrub(target)) }
        let index = await engine.keyframeIndex
        let lastKey = try #require(index.entry(atOrBefore: targets[targets.count - 1])?.pts)
        let landed = await log.wait { log in
            log.reports.contains { $0.kind == .scrub && $0.landedPTS == lastKey && !$0.cancelled }
        }
        #expect(landed, "the latest scrub lands on its keyframe")
        let scrubs = log.reports.filter { $0.kind == .scrub }
        #expect(scrubs.count < targets.count / 2, "\(scrubs.count) of \(targets.count) scrubs ran; the rest were coalesced")
        #expect(scrubs.last?.landedPTS == lastKey)
        #expect(scrubs.allSatisfy { $0.framesDecoded <= 1 }, "a scrub decodes the keyframe alone")
        await engine.close()
    }

    @Test func aScrubOntoTheKeyframeAlreadyShownDecodesNothing() async throws {
        // The drag never rests long enough for the background exact seek, which would replace
        // the keyframe on screen (covered by the next test).
        let engine = TestEngines.make(backgroundExactDelay: .seconds(3_600))
        _ = try await engine.open(Fixture.hevc10.url())
        let first = try #require(await engine.seekAndWait(.scrub(.seconds(22))))
        #expect(first.start == .keyframe)
        let second = try #require(await engine.seekAndWait(.scrub(.seconds(25))))
        #expect(second.start == .alreadyDisplayed)
        #expect(second.landedPTS == first.landedPTS)
        #expect(second.framesDecoded == 0)
        await engine.close()
    }

    @Test func aScrubAfterTheBackgroundExactSeekLandedDecodesTheKeyframeAgain() async throws {
        let engine = TestEngines.make(backgroundExactDelay: .milliseconds(10))
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(Fixture.hevc10.url())
        let first = try #require(await engine.seekAndWait(.scrub(.seconds(22))))
        #expect(first.start == .keyframe)
        let background = await log.wait { log in
            log.reports.contains { $0.kind == .exact && $0.generation > first.generation && $0.landedPTS != nil }
        }
        #expect(background, "the resting drag started an exact seek that landed")
        // The exact frame at 22 s replaced the keyframe, so the keyframe has to be decoded again.
        let second = try #require(await engine.seekAndWait(.scrub(.seconds(25))))
        #expect(second.start == .keyframe)
        #expect(second.landedPTS == first.landedPTS)
        await engine.close()
    }

    /// The decoder must reach the target even when it lies further past the keyframe than the
    /// store's read-ahead limit (a GOP longer than 20 s, here a 2 s limit on 10.4 s GOPs).
    @Test func anExactSeekFurtherThanTheReadAheadLimitLands() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let limits = PacketStore.Limits(behind: .seconds(30), behindBytes: 192 << 20, ahead: .seconds(2), aheadBytes: 192 << 20)
        let engine = TestEngines.make(storeLimits: limits)
        _ = try await engine.open(url)
        for target in [table.keyframes[1] + .seconds(8), table.keyframes[3] + .seconds(9.5)] {
            let report = try #require(await engine.seekAndWait(.exact(target), timeout: .seconds(10)), "exact seek to \(target) never landed")
            #expect(report.landedPTS == table.expected(at: target))
            #expect(await engine.playbackState == .paused)
        }
        await engine.close()
    }

    /// mkv without Cues: the index knows only what was read. Exact seeks and scrubs past it must
    /// find the real keyframe instead of decoding from (or showing) the last one read.
    @Test func seeksPastTheReadPartOfAFileWithoutCuesFindTheRealKeyframe() async throws {
        let url = try Fixture.nocues.url()
        let table = try FrameTable(url)
        let target = MediaTime.seconds(55)
        let keyframe = try #require(table.keyframes.last { $0 <= target })
        #expect(keyframe > .seconds(40), "the fixture is long enough for the test")

        let engine = TestEngines.make(backgroundExactDelay: .seconds(3_600))
        _ = try await engine.open(url)
        let exact = try #require(await engine.seekAndWait(.exact(target), timeout: .seconds(10)), "exact seek to 55 s never landed")
        #expect(exact.landedPTS == table.expected(at: target))
        #expect(exact.startKeyframePTS == keyframe)
        #expect(await engine.playbackState == .paused)

        for (scrub, expected) in [(MediaTime.seconds(39.6), table.keyframes.last { $0 <= .seconds(39.6) }), (.seconds(58.2), keyframe)] {
            let report = try #require(await engine.seekAndWait(.scrub(scrub), timeout: .seconds(10)))
            #expect(report.landedPTS == expected, "scrub to \(scrub)")
        }
        await engine.close()

        // A fresh engine whose first request is a scrub far past what was read.
        let fresh = TestEngines.make(backgroundExactDelay: .seconds(3_600))
        _ = try await fresh.open(url)
        let scrub = try #require(await fresh.seekAndWait(.scrub(target), timeout: .seconds(10)))
        #expect(scrub.landedPTS == keyframe)
        let clock = fresh.currentTime
        #expect(abs((clock - keyframe).microseconds) < 1_000, "the clock shows the keyframe on screen, not \(clock)")
        await fresh.close()
    }

    /// Continuing the live decoder is only right while the frame shown at the target is still
    /// ahead of it. A target just before the frame after the last one submitted is shown by that
    /// last frame, which the decoder already consumed: the seek must restart.
    @Test func continuingTheDecoderNeverLandsOnAnotherFrame() async throws {
        let url = try Fixture.h264.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make()
        _ = try await engine.open(url)
        let start = table.keyframes[1] + .seconds(0.5)

        _ = try #require(await engine.seekAndWait(.exact(start)))
        try await Task.sleep(for: .milliseconds(300))
        let submitted = try #require(await engine.parkDecoderForTesting())
        let following = try #require(table.frame(submitted, offset: 1))
        let inside = following - .microseconds(300)
        let restart = try #require(await engine.seekAndWait(.exact(inside)))
        #expect(restart.landedPTS == submitted, "target \(inside) is shown by \(submitted)")
        #expect(restart.start == .keyframe)

        _ = try #require(await engine.seekAndWait(.exact(start)))
        try await Task.sleep(for: .milliseconds(300))
        let again = try #require(await engine.parkDecoderForTesting())
        let next = try #require(table.frame(again, offset: 1))
        let continued = try #require(await engine.seekAndWait(.exact(next)))
        #expect(continued.start == .continueDecoder, "the frame after the last submitted one is still ahead")
        #expect(continued.landedPTS == next)
        await engine.close()
    }

    @Test func aNewExactSeekCancelsTheOneInFlightByGeneration() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        let presented = PresentedFrames()
        await engine.setFrameObserver { presented.record($0) }
        _ = try await engine.open(url)

        let first = try #require(table.frames.last { $0 < table.keyframes[3] })
        let second = try #require(table.frames.last { $0 < table.keyframes[5] })
        await engine.seek(.exact(first))
        let firstGeneration = await engine.currentGeneration
        let report = try #require(await engine.seekAndWait(.exact(second)))
        #expect(report.generation > firstGeneration)
        #expect(report.landedPTS == second)
        let superseded = try #require(log.reports.first { $0.generation == firstGeneration })
        #expect(superseded.cancelled)
        #expect(superseded.landedPTS == nil)
        let late = presented.entries.withLock { entries in
            entries.filter { $0.generation == firstGeneration && $0.nanos > report.requestedAtNanos }
        }
        #expect(late.isEmpty, "no frame of the cancelled seek reached the receiver after the new one started")
        await engine.close()
    }

    @Test(arguments: [Fixture.hevc10, .h264])
    func aNearSeekRightAfterAFarOneLandsWhileTheFarDemuxerSeekIsPending(_ fixture: Fixture) async throws {
        let url = try fixture.url()
        let table = try FrameTable(url)
        let limits = PacketStore.Limits(behind: .seconds(30), behindBytes: 192 << 20, ahead: .seconds(2), aheadBytes: 192 << 20)
        for round in 0..<3 {
            let engine = TestEngines.make(storeLimits: limits)
            _ = try await engine.open(url)
            #expect(await TestEngines.waitUntilReadingStops(engine))
            // The store holds the keyframe at 0 s and about 2 s after it. The far seek misses and
            // its demuxer seek is slowed down; the near target's keyframe is stored, but the
            // packets up to it must still be read, and the far seek must not reset the store first.
            await engine.setDemuxerSeekDelayForTesting(milliseconds: 150)
            await engine.seek(.exact(.seconds(45)))
            let near = MediaTime.seconds(5 + Double(round))
            let report = try #require(await engine.seekAndWait(.exact(near), timeout: .seconds(5)), "round \(round) never landed")
            #expect(report.landedPTS == table.expected(at: near), "round \(round)")
            await engine.close()
        }
    }

    @Test func backwardSeekIsServedFromTheStoreWithZeroBytesRead() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make()
        _ = try await engine.open(url)
        _ = try #require(await engine.seekAndWait(.exact(.seconds(12))))
        #expect(await TestEngines.waitUntilReadingStops(engine))
        _ = try #require(await engine.seekAndWait(.exact(.seconds(25))))
        #expect(await TestEngines.waitUntilReadingStops(engine))

        let target = MediaTime.seconds(15)
        let report = try #require(await engine.seekAndWait(.exact(target)))
        #expect(report.storeHit)
        #expect(report.bytesRead == 0, "the GOP at \(table.keyframes[1]) was still in the store")
        #expect(report.start == .keyframe)
        #expect(report.startKeyframePTS == table.keyframes[1])
        #expect(report.landedPTS == table.expected(at: target))
        await engine.close()
    }

    @Test func forwardSeekInsideTheGOPContinuesWithoutRestarting() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make()
        _ = try await engine.open(url)
        let first = try #require(await engine.seekAndWait(.exact(.seconds(11))))
        #expect(first.start == .keyframe)

        let target = MediaTime.seconds(14)
        let report = try #require(await engine.seekAndWait(.exact(target)))
        #expect(report.start == .continueDecoder, "the decoder was live and behind the target in the same GOP")
        #expect(report.landedPTS == table.expected(at: target))
        #expect(report.storeHit)
        #expect(report.framesDecoded < first.framesDecoded + 30, "continuing decodes only what lies ahead")
        let frame = try #require(await engine.lastLandedFrame())
        #expect(MediaTime(frame.presentationTime) == table.expected(at: target))
        await engine.close()
    }

    @Test func aTargetInTheNextGOPRestartsFromItsKeyframe() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make()
        _ = try await engine.open(url)
        _ = try #require(await engine.seekAndWait(.exact(.seconds(11))))
        let target = table.keyframes[2] + .seconds(1)
        let report = try #require(await engine.seekAndWait(.exact(target)))
        #expect(report.start == .keyframe)
        #expect(report.startKeyframePTS == table.keyframes[2])
        #expect(report.landedPTS == table.expected(at: target))
        await engine.close()
    }

    /// Open-GOP HEVC: the CRA's leading pictures come after it in decode order and reference the
    /// previous GOP. Frames on both sides of the CRA must land exactly and match a sequential decode.
    @Test(arguments: [-3, -1, 0, 1, 6])
    func exactSeekNearAnOpenGOPCRALandsOnTheRightFrame(_ offset: Int) async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let cra = table.keyframes[1]
        let target = try #require(table.frame(cra, offset: offset))
        let engine = TestEngines.make(force: .hardware)
        _ = try await engine.open(url)
        let report = try #require(await engine.seekAndWait(.exact(target)))
        #expect(report.landedPTS == target)
        if offset >= 0 {
            #expect(report.startKeyframePTS == cra, "a target at or after the CRA starts there, not a GOP earlier")
        } else {
            // From the previous keyframe, or continued from the live decoder in that GOP.
            #expect(report.startKeyframePTS != cra, "a leading picture of the CRA needs the previous GOP")
        }
        let frame = try #require(await engine.lastLandedFrame())
        await engine.close()

        let reference = try FrameGrabber.grabSequential(url: url, at: target)
        #expect(reference.frame.presentationTime == frame.presentationTime)
        let psnr = try #require(FrameGrabber.lumaPSNR(frame.pixelBuffer, reference.frame.pixelBuffer))
        #expect(psnr >= 35, "luma PSNR \(psnr) dB at \(target)")
    }

    @Test func framesBeforeEachCRALandExactlyAndSkipNonReferenceFrames() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make(force: .hardware)
        _ = try await engine.open(url)
        for keyIndex in [2, 4, 1] {
            let target = try #require(table.frames.last { $0 < table.keyframes[keyIndex] })
            let report = try #require(await engine.seekAndWait(.exact(target)), "seek to \(target) did not land")
            #expect(report.landedPTS == target)
            #expect(report.framesSkipped > 0, "x265 B-frames nothing references are not submitted")
        }
        await engine.close()
    }

    @Test func softwareDecoderSeeksLandOnTheSameFrames() async throws {
        let url = try Fixture.syncH264.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make(force: .software)
        _ = try await engine.open(url)
        #expect(await engine.videoDecoderKind == .software)
        for seconds in [7.3, 1.95, 15.51] {
            let target = MediaTime.seconds(seconds)
            let report = try #require(await engine.seekAndWait(.exact(target)))
            #expect(report.landedPTS == table.expected(at: target))
        }
        await engine.close()
    }

    @Test func av1SeekShowsAKeyframePreviewBeforeAFarTarget() async throws {
        let url = try Fixture.av1.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make(force: .hardware)
        _ = try await engine.open(url)
        let target = try #require(table.frames.last { $0 < table.keyframes[3] })
        let report = try #require(await engine.seekAndWait(.exact(target)))
        #expect(report.landedPTS == target)
        let preview = try #require(report.previewMilliseconds, "a full 4K GOP is predicted over 150 ms")
        #expect(preview < (report.targetMilliseconds ?? 0))
        await engine.close()
    }

    @Test func aSeekSupersededWhileWaitingForTheFeederStillReportsAsCancelled() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(url)
        for round in 0..<6 {
            let before = await engine.currentGeneration
            let first = MediaTime.seconds(8 + Double(round))
            let second = MediaTime.seconds(20 + Double(round))
            // Both calls enter the actor while the first waits for the old feeder to stop.
            async let one: Void = engine.seek(.exact(first))
            async let two: Void = engine.seek(.exact(second))
            _ = await (one, two)
            let after = await engine.currentGeneration
            #expect(after == before + 2, "round \(round)")
            let last = try #require(await engine.seekAndWait(.exact(second), timeout: .seconds(5)))
            #expect(last.landedPTS == table.expected(at: second), "round \(round)")
            let reported = await log.wait(timeout: .seconds(5)) { log in
                (before + 1...after).allSatisfy { generation in log.reports.contains { $0.generation == generation } }
            }
            #expect(reported, "round \(round): every generation of the two seeks reports")
            let superseded = try #require(log.reports.first { $0.generation == after - 1 })
            #expect(superseded.cancelled, "round \(round)")
        }
        await engine.close()
    }

    @Test func aKeyframePreviewThatIsAlsoTheTargetFrameLandsOnIt() async throws {
        let url = try Fixture.hevc10.url()
        let table = try FrameTable(url)
        let engine = TestEngines.make()
        _ = try await engine.open(url)
        await engine.setForceKeyframePreviewForTesting(true)
        for key in [table.keyframes[2], table.keyframes[4]] {
            let report = try #require(await engine.seekAndWait(.exact(key)))
            #expect(report.landedPTS == key, "landed on \(String(describing: report.landedPTS)), not the keyframe \(key)")
            #expect(report.start == .keyframe)
        }
        await engine.close()
    }
}
