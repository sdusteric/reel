import CoreMedia
import CReelDeps
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// Damaged and odd files (design section 7.10): classified open failures, damaged data skipped
/// with a count, the end of the data of a file cut short, a vanished drive, and the open watchdog.
@Suite struct RobustnessTests {
    // MARK: Open failures

    /// Opens `url` on a fresh engine and returns the `.problem` it reported and the error.
    static func failedOpen(_ url: URL, engine: PlaybackEngine = TestEngines.make()) async throws -> (problem: MediaProblem?, error: EngineError?) {
        let log = EventLog()
        log.start(engine.events)
        var thrown: EngineError?
        do {
            _ = try await engine.open(url)
            Issue.record("\(url.lastPathComponent) opened")
        } catch let error as EngineError {
            thrown = error
        }
        _ = await log.wait { log in log.all.contains { if case .failed = $0 { true } else { false } } }
        await engine.close()
        let problem = log.all.compactMap { event -> MediaProblem? in
            if case .problem(let problem) = event { return problem }
            return nil
        }.first
        return (problem, thrown)
    }

    @Test(arguments: [OddFixture.zero, .text, .random])
    func filesThatAreNotMediaFailAsNotMedia(_ fixture: OddFixture) async throws {
        let (problem, error) = try await RobustnessTests.failedOpen(fixture.url())
        let found = try #require(problem)
        #expect(found == .notMedia)
        #expect(!found.title.isEmpty && !found.explanation.isEmpty)
        // The technical detail carries FFmpeg's reason.
        #expect(error?.errorDescription?.isEmpty == false)
    }

    @Test func proResIsAnUnsupportedCodecNamedAsPeopleKnowIt() async throws {
        let (problem, _) = try await RobustnessTests.failedOpen(OddFixture.prores.url())
        #expect(problem == .unsupportedCodec("ProRes"))
        #expect(problem?.explanation == "The video uses ProRes, which Reel can't decode.")
    }

    @Test(arguments: ["corpus/hevc.head4k.mkv", "corpus/h264_faststart.head4k.mp4", "corpus/vp9.trunc01.webm"])
    func aContainerHeaderThenTheEndOfTheFileIsCutShort(_ path: String) async throws {
        let (problem, error) = try await RobustnessTests.failedOpen(fixtureURL(path))
        #expect(problem == .cutShort)
        #expect(error?.errorDescription?.contains("header found, then the file ends after") == true, "\(error?.errorDescription ?? "-")")
    }

    @Test func aFileThatCannotBeReadIsUnreadable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reel-robustness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "locked.mp4")
        try FileManager.default.copyItem(at: Fixture.rot90.url(), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false)) }
        let (problem, _) = try await RobustnessTests.failedOpen(file)
        guard case .unreadable(let reason)? = problem else {
            Issue.record("expected unreadable, got \(String(describing: problem))")
            return
        }
        #expect(reason.contains("Permission denied"), "\(reason)")
        #expect(problem?.title == "This file couldn't be read")
    }

    /// A path under /Volumes/<name> whose volume is not mounted fails at once as `.volumeGone`;
    /// the check runs before the path is touched (the name is made up and nothing is read).
    @Test func aFileOnAVolumeThatIsNotMountedIsVolumeGone() async throws {
        let engine = TestEngines.make()
        await engine.setVolumeCheckForTesting { url in
            MountedVolumes.missingVolume(of: url, mounted: { ["Macintosh HD"] })
        }
        let url = URL(filePath: "/Volumes/Reel Test Drive \(UUID().uuidString.prefix(6))/Northern.Line.S01E01.mkv")
        let (problem, _) = try await RobustnessTests.failedOpen(url, engine: engine)
        guard case .volumeGone(let name)? = problem else {
            Issue.record("expected volumeGone, got \(String(describing: problem))")
            return
        }
        #expect(name.hasPrefix("Reel Test Drive"))
        #expect(problem?.buttons == [.closeFile, .tryAgain])
    }

    @Test func missingVolumesAreOnlyThoseUnderVolumesThatAreNotMounted() {
        let mounted: () -> Set<String> = { ["Media"] }
        #expect(MountedVolumes.missingVolume(of: URL(filePath: "/Volumes/Media/a.mkv"), mounted: mounted) == nil)
        #expect(MountedVolumes.missingVolume(of: URL(filePath: "/Volumes/Archive/a.mkv"), mounted: mounted) == "Archive")
        #expect(MountedVolumes.missingVolume(of: URL(filePath: "/Users/someone/a.mkv"), mounted: mounted) == nil)
    }

    /// An open with no result within the timeout fails as `.unreadable("timed out")` (the
    /// watchdog is 10 s; the test shortens it and holds the open back).
    @Test func anOpenWithNoResultInTimeFailsAsTimedOut() async throws {
        var values = ProcessInfo.processInfo.environment
        values.removeValue(forKey: "REEL_ALLOW_AUDIO")
        let engine = PlaybackEngine(configuration: .init(
            audioMode: .headless,
            environment: ReelEnvironment(values),
            preventsDisplaySleep: false,
            openTimeout: .milliseconds(300)
        ))
        #expect(engine.configuration.openTimeout == .milliseconds(300))
        #expect(PlaybackEngine.openTimeout == .seconds(10))
        await engine.setOpenDelayForTesting(.seconds(5))
        let log = EventLog()
        log.start(engine.events)
        // Only the open is timed, and on its own executor: the engine is a default actor, so its
        // code runs there too. The parallel suite queues hundreds of synchronous decode tests on
        // the cooperative pool, which held this open's continuations for up to 4 s; the
        // watchdog itself runs on a thread and a Dispatch timer (`blockingResult`).
        let timed = try await withTaskExecutorPreference(DedicatedTaskExecutor(label: "reel.tests.open-timeout")) {
            let started = ContinuousClock.now
            var thrown: EngineError?
            do {
                _ = try await engine.open(Fixture.rot90.url())
                Issue.record("the open did not fail")
            } catch let error as EngineError {
                thrown = error
            }
            return (thrown, ContinuousClock.now - started)
        }
        let (thrown, elapsed) = timed
        #expect(thrown == .io("timed out"))
        #expect(elapsed < .seconds(3), "the open gave up near its deadline (\(elapsed))")
        _ = await log.wait { log in log.all.contains { if case .failed = $0 { true } else { false } } }
        await engine.close()
        let problem = log.all.compactMap { event -> MediaProblem? in
            if case .problem(let problem) = event { return problem }
            return nil
        }.first
        #expect(problem == .unreadable("timed out"))
    }

    @Test func blockingWorkWithNoResultInTimeIsAbandonedAtTheDeadline() async {
        let release = Atomic<Bool>(false)
        let (outcome, elapsed) = await withTaskExecutorPreference(DedicatedTaskExecutor(label: "reel.tests.blocking-result")) {
            let started = ContinuousClock.now
            let outcome = await PlaybackEngine.blockingResult(within: .milliseconds(100)) { () -> Int in
                while !release.load(ordering: .acquiring) { Thread.sleep(forTimeInterval: 0.005) }
                return 1
            }
            return (outcome.map { (try? $0.get()) ?? -1 }, ContinuousClock.now - started)
        }
        release.store(true, ordering: .releasing)
        #expect(outcome == nil)
        #expect(elapsed < .seconds(2), "\(elapsed)")
        let finished = await PlaybackEngine.blockingResult(within: .seconds(30)) { () -> Int in 7 }
        #expect((try? finished?.get()) == 7)
    }

    @Test func aReadInterruptStopsCallsPastItsDeadline() {
        let interrupt = ReadInterrupt()
        #expect(!interrupt.shouldInterrupt())
        interrupt.setDeadline(after: .zero)
        Thread.sleep(forTimeInterval: 0.002)
        #expect(interrupt.shouldInterrupt())
        #expect(interrupt.timedOut)
        interrupt.setDeadline(after: nil)
        let stopped = ReadInterrupt()
        stopped.abort()
        #expect(stopped.shouldInterrupt() && !stopped.timedOut)
    }

    // MARK: Damaged data

    /// Plays `url` at rate 4 until it ends; returns the engine (closed), its events and the end.
    static func playToEnd(_ url: URL, timeout: Duration = .seconds(20)) async throws -> (log: EventLog, damaged: Int, end: MediaTime?, info: MediaInfo) {
        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        let info = try await engine.open(url)
        await engine.setRate(4)
        await engine.play()
        let ended = await log.wait(timeout: timeout) { log in log.all.contains { $0 == .ended } }
        #expect(ended, "\(url.lastPathComponent) played to its end")
        let end = ended ? engine.currentTime : nil
        let damaged = engine.damagedFrames
        await engine.close()
        return (log, damaged, end, info)
    }

    @Test(arguments: ["corpus/hevc.zeromid.mkv", "corpus/h264_faststart.zeromid.mp4", "corpus/vp9.zeromid.webm", "corpus/vp9.overwrite50.webm", "corpus/mpeg4.zeromid.avi"])
    func aDamagedFilePlaysPastTheDamageToItsEndAndCountsDamagedFrames(_ path: String) async throws {
        let (log, damaged, end, info) = try await RobustnessTests.playToEnd(fixtureURL(path))
        #expect(damaged > 0, "damaged frames counted")
        let duration = (info.startTime ?? .zero) + (info.duration ?? .zero)
        let reached = try #require(end)
        #expect(reached + .seconds(1) >= duration, "reached \(reached) of \(duration)")
        let damageEvents = log.all.filter { if case .damaged = $0 { true } else { false } }
        #expect(!damageEvents.isEmpty || damaged > 0)
        // At most one event per kind per 10 s: a 2 s file has at most one of each.
        #expect(damageEvents.count <= 2, "\(damageEvents.count) damage events")
    }

    /// x265's default open GOP: after damage, video resumes at a CRA whose RASL pictures
    /// reference the skipped GOP. They are skipped as at a seek start, so one damaged spot costs
    /// about one GOP (12 frames here) instead of failing GOP after GOP to the end of the file.
    @Test func damageInAnOpenGOPFileCostsAboutOneGOP() async throws {
        let (_, damaged, end, info) = try await RobustnessTests.playToEnd(fixtureURL("corpus/hevc.overwrite25.mkv"))
        #expect(damaged > 0)
        #expect(damaged <= 24, "\(damaged) damaged frames for one 4 KB overwrite in 0.5 s GOPs")
        let duration = (info.startTime ?? .zero) + (info.duration ?? .zero)
        let reached = try #require(end)
        #expect(reached + .seconds(1) >= duration)
    }

    /// Matroska cluster checksums (FFmpeg's demuxer skips them): the overwritten cluster of
    /// hevc.overwrite50.mkv fails, the others and the intact file pass, a cluster cut short is
    /// never reported, and WebM (no CRC-32 elements from ffmpeg) is never reported.
    @Test func matroskaClusterChecksumsFindTheOverwrittenCluster() throws {
        let damaged = try #require(MatroskaClusterCheck(url: fixtureURL("corpus/hevc.overwrite50.mkv")))
        defer { damaged.close() }
        let overwrite: Int64 = 355_867 / 2
        #expect(damaged.checksumFails(position: overwrite))
        #expect(!damaged.checksumFails(position: 10_000))
        #expect(!damaged.checksumFails(position: 300_000))
        let intact = try #require(MatroskaClusterCheck(url: fixtureURL("corpus/hevc.mkv")))
        defer { intact.close() }
        #expect(![10_000, overwrite, 300_000].contains { intact.checksumFails(position: $0) })
        let cut = try #require(MatroskaClusterCheck(url: fixtureURL("corpus/hevc.trunc50.mkv")))
        defer { cut.close() }
        #expect(!cut.checksumFails(position: overwrite - 2_000))
        let webm = try #require(MatroskaClusterCheck(url: fixtureURL("corpus/vp9.overwrite50.webm")))
        defer { webm.close() }
        #expect(!webm.checksumFails(position: 366_000))
        #expect(MatroskaClusterCheck(url: try fixtureURL("corpus/h264_faststart.mp4")) == nil)
    }

    @Test func damageEventsAreLimitedToOnePerKindEveryTenSeconds() {
        let tracker = DamageTracker()
        let events = Mutex<[(MediaTime?, DamageKind)]>([])
        tracker.setEventSink { time, kind in events.withLock { $0.append((time, kind)) } }
        let start: UInt64 = 1_000_000_000_000
        tracker.record(.video, at: .seconds(12), now: start)
        tracker.record(.video, at: .seconds(13), count: 4, now: start + 1_000_000_000)
        tracker.record(.audio, at: .seconds(13), now: start + 2_000_000_000)
        tracker.record(.video, at: .seconds(30), now: start + 11_000_000_000)
        tracker.record(.video, at: nil, count: 3, emitsEvent: false, now: start + 30_000_000_000)
        #expect(tracker.videoFrames == 9)
        #expect(tracker.audioPackets == 1)
        let sent = events.withLock { $0 }
        #expect(sent.map(\.1) == [.video, .audio, .video])
        #expect(sent.first?.0 == .seconds(12))
    }

    /// A corrupt audio packet is dropped and the next one starts at its own time instead of
    /// continuing the running sample count (section 7.10).
    @Test func aCorruptAudioPacketIsDroppedAndTheClockReanchors() throws {
        let source = try MediaSource(url: Fixture.syncH264.url())
        let index = try #require(source.audioStreamIndex)
        let stream = try #require(source.stream(index))
        let decoder = try AudioDecoder(stream: stream)
        var packets: [Packet] = []
        while packets.count < 12, let packet = try source.readPacket() {
            if packet.streamIndex == index { packets.append(packet) }
        }
        try #require(packets.count == 12)
        for packet in packets.prefix(8) { _ = try decoder.decode(packet) }
        let garbage = try #require(Packet(copying: packets[8], payload: [UInt8](repeating: 0xFF, count: packets[8].size)))
        let corruptOutput = try decoder.decode(garbage)
        #expect(decoder.corruptPackets == 1)
        #expect(decoder.lastCorruptTime == packets[8].time)
        // Whatever came out before the bad packet ends at or before it.
        #expect(corruptOutput.allSatisfy { $0.end <= (packets[8].time ?? .zero) + .milliseconds(1) })
        let next = try decoder.decode(packets[9])
        let first = try #require(next.first)
        let expected = try #require(packets[9].time)
        #expect(abs(first.pts.microseconds - expected.microseconds) <= 1_000, "re-anchored at \(first.pts), packet at \(expected)")
    }

    // MARK: Data end

    /// Every truncated faststart MP4 and Matroska file whose manifest has a `dataEnd` reports one
    /// within 1 s of it.
    @Test func truncatedFilesReportTheirDataEndWithinASecondOfTheManifest() async throws {
        let manifest = try CorpusManifest.load()
        let truncated = manifest.files.filter { entry in
            entry.dataEnd != nil && entry.mutation.hasPrefix("trunc")
                && (entry.base == "h264_faststart.mp4" || entry.family == "matroska")
        }
        #expect(truncated.count >= 6)
        for entry in truncated {
            let engine = TestEngines.make()
            let log = EventLog()
            log.start(engine.events)
            _ = try await engine.open(manifest.url(entry))
            // A short file is read to its end within moments of opening.
            let found = await log.wait(timeout: .seconds(10)) { log in log.all.contains { if case .dataEnd = $0 { true } else { false } } }
            let reported = log.all.compactMap { event -> MediaTime? in
                if case .dataEnd(let time) = event { return time }
                return nil
            }.first
            #expect(found, "\(entry.file) reported its data end")
            if let reported, let expected = entry.dataEnd {
                #expect(abs(reported.seconds - expected) <= 1.0, "\(entry.file): \(reported.seconds) s, manifest \(expected) s")
                #expect(await engine.dataEnd == reported)
            }
            await engine.close()
        }
    }

    @Test func completeFilesHaveNoDataEnd() async throws {
        for path in ["corpus/h264_faststart.mp4", "corpus/hevc.mkv", "corpus/vp9.webm", "corpus/h264.ts", "odd/many_tracks.mkv"] {
            let engine = TestEngines.make()
            let log = EventLog()
            log.start(engine.events)
            _ = try await engine.open(fixtureURL(path))
            _ = await TestEngines.waitUntilReadingStops(engine)
            #expect(await engine.dataEnd == nil, "\(path)")
            #expect(!log.all.contains { if case .dataEnd = $0 { true } else { false } }, "\(path)")
            #expect(engine.damagedFrames == 0, "\(path)")
            await engine.close()
        }
    }

    @Test func aSeekPastTheDataEndLandsOnTheLastFrame() async throws {
        let engine = TestEngines.make()
        _ = try await engine.open(fixtureURL("corpus/h264_faststart.trunc90.mp4"))
        let dataEnd = try #require(await engine.dataEnd)
        let report = try #require(await engine.seekAndWait(.exact(.seconds(1.9))))
        let landed = try #require(report.landedPTS)
        #expect(landed <= dataEnd + .milliseconds(50), "landed \(landed), data ends \(dataEnd)")
        #expect(landed + .milliseconds(200) >= dataEnd, "landed on the last frame (\(landed)), data ends \(dataEnd)")
        await engine.close()
    }

    /// The end of the data is the end of the file: playback ends there, and the position saved
    /// for resume says the file ends there too (so it counts as finished).
    @Test func playbackEndsWhereTheDataEnds() async throws {
        let engine = TestEngines.make()
        let ended = Mutex<PositionUpdate?>(nil)
        await engine.setPositionHandler { update in
            if update.reason == .ended { ended.withLock { $0 = update } }
        }
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(fixtureURL("corpus/hevc.trunc50.mkv"))
        await engine.setRate(4)
        await engine.play()
        #expect(await log.wait(timeout: .seconds(20)) { log in log.all.contains { $0 == .ended } })
        let dataEnd = try #require(await engine.dataEnd)
        let update = try #require(ended.withLock { $0 })
        #expect(abs(update.position.seconds - dataEnd.seconds) < 0.2, "ended at \(update.position), data ends \(dataEnd)")
        #expect(update.duration.map { abs($0.seconds - dataEnd.seconds) < 0.01 } == true, "saved duration \(String(describing: update.duration))")
        await engine.close()
    }

    // MARK: Drive loss

    /// A read error while the file's volume is gone pauses on the last frame and reports
    /// `.volumeGone` instead of ending the file (the drive is simulated: an injected EIO and a
    /// volume check that says the drive went away).
    @Test func aReadErrorAfterTheDriveIsGonePausesAndReportsVolumeGone() async throws {
        let engine = TestEngines.make()
        let driveGone = Atomic<Bool>(false)
        await engine.setVolumeCheckForTesting { _ in driveGone.load(ordering: .acquiring) ? "Media" : nil }
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(Fixture.h264.url())
        // Let the read-ahead finish, so the next read comes from the play below.
        _ = await TestEngines.waitUntilReadingStops(engine)
        driveGone.store(true, ordering: .releasing)
        await engine.setReadFaultForTesting(reel_averror(EIO))
        await engine.play()
        let reported = await log.wait(timeout: .seconds(10)) { log in
            log.all.contains { $0 == .problem(.volumeGone("Media")) }
        }
        #expect(reported)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await engine.playbackState == .paused)
        #expect(!log.all.contains { $0 == .ended }, "a vanished drive is not the end of the file")
        #expect(await engine.lastLandedFrame() != nil, "the last frame stays")
        await engine.close()
    }
}

/// Runs a task's jobs, and the jobs of default actors it calls, on one serial queue instead of
/// the cooperative pool, so a timing check is not queued behind the rest of the parallel suite.
final class DedicatedTaskExecutor: TaskExecutor {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
