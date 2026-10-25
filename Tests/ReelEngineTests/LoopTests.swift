import Foundation
import ReelCore
import Testing
@testable import ReelEngine

/// A-B loop and file loop in the engine (design section 9.12, D49): reaching B seeks to A, the end
/// of a looping file seeks to the start, and a looping engine never reports the end.
@Suite struct LoopTests {
    private static func episode() throws -> URL {
        let url = Fixture.directory.appending(path: "episodes/Northern.Line.S01E01.mkv")
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            Issue.record("Missing fixture episodes/Northern.Line.S01E01.mkv: run scripts/fixtures.sh")
            throw FixtureMissing(name: "episodes/Northern.Line.S01E01.mkv")
        }
        return url
    }

    @Test func fileLoopRestartsAtTheStartInsteadOfEnding() async throws {
        let engine = M2Engines.make()
        let log = EventLog()
        log.start(engine.events)
        let info = try await engine.open(Self.episode())
        let duration = try #require(info.duration)
        await engine.setLoop(LoopState(fileLoop: true))
        await engine.setRate(4)
        await engine.play()
        let restarted = await log.wait(timeout: .seconds(duration.seconds + 5)) { log in
            log.reports.contains { $0.kind == .exact && $0.target == .zero && !$0.cancelled && $0.generation > 1 }
        }
        #expect(restarted, "seeked back to the start")
        #expect(!log.all.contains(.ended), "a looping file never ends")
        let state = await engine.playbackState
        #expect(state == .playing || state == .seeking)
        #expect(log.all.contains(.loopChanged(LoopState(fileLoop: true))))
        await engine.close()
    }

    @Test func reachingBSeeksBackToA() async throws {
        let engine = M2Engines.make()
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(Self.episode())
        let a = MediaTime.seconds(0.5)
        let b = MediaTime.seconds(1.2)
        await engine.setLoop(LoopState(start: a, end: b))
        _ = await engine.seekAndWait(.exact(a))
        await engine.play()
        var latest = MediaTime.zero
        let deadline = ContinuousClock.now + .seconds(2.5)
        while ContinuousClock.now < deadline {
            latest = max(latest, engine.currentTime)
            try await Task.sleep(for: .milliseconds(10))
        }
        let loops = log.reports.filter { $0.kind == .exact && $0.target == a && !$0.cancelled }
        #expect(loops.count >= 3, "the seek to A and at least two loops: \(loops.count)")
        #expect(latest < b + .milliseconds(150), "the clock never ran far past B: \(latest)")
        #expect(!log.all.contains(.ended))
        await engine.close()
    }

    @Test func anAStartAloneLoopsFromAAtTheEnd() async throws {
        let engine = M2Engines.make()
        let log = EventLog()
        log.start(engine.events)
        let info = try await engine.open(Self.episode())
        let duration = try #require(info.duration)
        let a = MediaTime.seconds(1)
        var loop = LoopState()
        loop.toggleABLoop(at: a)
        #expect(loop.phase == .startSet)
        await engine.setLoop(loop)
        await engine.setRate(4)
        await engine.play()
        let looped = await log.wait(timeout: .seconds(duration.seconds + 5)) { log in
            log.reports.contains { $0.kind == .exact && $0.target == a && !$0.cancelled }
        }
        #expect(looped, "the end seeks back to A")
        #expect(!log.all.contains(.ended), "no end while a loop point is set")
        await engine.close()
    }

    @Test func clearingTheLoopLetsPlaybackEnd() async throws {
        let engine = M2Engines.make()
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(Self.episode())
        await engine.setLoop(LoopState(fileLoop: true))
        await engine.setLoop(.off)
        await engine.setRate(4)
        await engine.play()
        #expect(await log.wait(timeout: .seconds(5)) { $0.all.contains(.ended) })
        #expect(await engine.playbackState == .ended)
        await engine.close()
    }

    @Test func aBBeforeAIsSwappedAndAnnounced() async throws {
        let engine = M2Engines.make()
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(Self.episode())
        await engine.setLoop(LoopState(start: .seconds(2), end: .seconds(1)))
        let loop = await engine.loopState
        #expect(loop.start == .seconds(1) && loop.end == .seconds(2))
        #expect(await log.wait(timeout: .seconds(2)) { $0.all.contains(.loopChanged(loop)) })
        await engine.close()
    }

    @Test func eachFileStartsWithoutALoop() async throws {
        let engine = M2Engines.make()
        _ = try await engine.open(Self.episode())
        await engine.setLoop(LoopState(fileLoop: true))
        _ = try await engine.open(Self.episode())
        #expect(await engine.loopState == .off)
        await engine.close()
    }
}
