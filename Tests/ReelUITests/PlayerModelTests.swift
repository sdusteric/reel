import Foundation
import ReelCore
import Testing
@testable import ReelUI

@MainActor
@Suite struct PlayerModelTests {
    @Test func startsEmptyAndIdle() throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        #expect(model.playbackState == .idle)
        #expect(!model.hasMedia)
        #expect(model.volume == 47, "first-run volume is the user's IINA level")
        #expect(model.showRemainingTime)
        #expect(model.controllerCenterX == 0.49)
        #expect(model.controllerBottomY == 0.11)
    }

    @Test func openingAFileConfiguresTheEngineAndPlays() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        let file = try scratch.makeMediaFile("Show S01E01.mkv")
        await model.open(file)
        await model.waitForEngineCommands()
        #expect(engine.calls == [.open(file), .volume(47), .muted(false), .timeInterval(0.1), .play])
        #expect(model.hasMedia)
        #expect(model.title == "Show S01E01.mkv")
        #expect(model.duration == .seconds(600))
        #expect(model.isPlaying)
        await waitUntil("engine reports playing") { model.playbackState == .playing }
        #expect(model.trailingLabel == "-10:00")
        #expect(model.elapsedLabel == "00:00")
    }

    @Test func togglePauseFlipsAtOnceAndFollowsTheEngine() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        await waitUntil("playing") { model.playbackState == .playing }
        model.togglePause()
        #expect(!model.isPlaying, "the button changes before the engine answers")
        await waitUntil("paused") { model.playbackState == .paused }
        model.togglePause()
        #expect(model.isPlaying)
        await waitUntil("playing again") { model.playbackState == .playing }
        model.handle(.stateChanged(.paused))
        #expect(!model.isPlaying, "an engine-side pause updates the button")
        #expect(engine.calls.filter { $0 == .pause }.count == 1)
    }

    @Test func aFailedOpenShowsTheErrorAndReturnsToEmpty() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.openError = .unsupportedCodec("cinepak")
        let engine = FakeEngine(options: options)
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await model.open(try scratch.makeMediaFile("old.avi"))
        #expect(model.playbackState == .failed)
        #expect(!model.hasMedia)
        #expect(model.errorMessage == "Unsupported codec: cinepak")
        #expect(engine.calls.last == .close)
        model.togglePause()
        #expect(!model.isPlaying)
    }

    @Test func clockUpdatesMoveThePlayheadExceptWhileASeekIsPending() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.completesExactSeeks = false
        let engine = FakeEngine(options: options)
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.handle(.time(.seconds(12)))
        #expect(model.position == .seconds(12))
        model.seek(by: 5)
        #expect(model.position == .seconds(17), "the bar moves before any decode")
        model.handle(.time(.seconds(12.1)))
        #expect(model.position == .seconds(17), "a stale clock reading must not pull the bar back")
        model.handle(.seekCompleted(SeekReport(
            kind: .exact, target: .seconds(17), generation: 1, requestedAtNanos: 0, landedPTS: .seconds(16.99)
        )))
        #expect(model.position == .seconds(16.99))
        model.handle(.time(.seconds(17.5)))
        #expect(model.position == .seconds(17.5))
    }

    @Test func keyboardSeeksAreExactClampedAndShowTheTimeInTheOSD() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.handle(.time(.seconds(12)))
        model.seek(by: 5)
        #expect(model.osd == OSDMessage(kind: .seek, text: "00:17 / 10:00"))
        model.seek(by: -600)
        #expect(model.position == .zero)
        model.seek(by: 6_000)
        #expect(model.position == .seconds(600))
        await model.waitForEngineCommands()
        #expect(engine.seeks == [.exact(.seconds(17)), .exact(.zero), .exact(.seconds(600))])
    }

    @Test func repeatedSeeksBuildOnThePendingTarget() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.completesExactSeeks = false
        let engine = FakeEngine(options: options)
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.seek(by: 5)
        model.seek(by: 5)
        model.seek(by: 5)
        await model.waitForEngineCommands()
        #expect(engine.seeks.last == .exact(.seconds(15)), "key repeat accumulates instead of re-seeking from a stale clock")
    }

    @Test func frameStepPausesAndMovesOneFrame() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.handle(.time(.seconds(10)))
        model.frameStep(forward: true)
        #expect(!model.isPlaying)
        model.frameStep(forward: false)
        await model.waitForEngineCommands()
        let frame = MediaTime(value: 1, timeBaseNum: 1, timeBaseDen: 24)
        #expect(engine.seeks == [.exact(.seconds(10) + frame), .exact(.seconds(10))])
        #expect(engine.calls.contains(.pause))
    }

    @Test func volumeChangesClampShowTheOSDAndAreRemembered() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, state) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.adjustVolume(by: 5)
        #expect(model.volume == 52)
        #expect(model.osd == OSDMessage(kind: .volume, text: "Volume 52"))
        model.adjustVolume(by: 80)
        #expect(model.volume == 100)
        model.adjustVolume(by: -150)
        #expect(model.volume == 0)
        model.toggleMute()
        #expect(model.isMuted)
        #expect(model.osd?.text == "Muted")
        await model.waitForEngineCommands()
        #expect(engine.calls.suffix(4) == [.volume(52), .volume(100), .volume(0), .muted(true)])
        model.saveForTermination()
        let reloaded = StateStore(fileURL: state.fileURL)
        try reloaded.load()
        #expect(reloaded.state.volume == 0)
    }

    @Test func remainingTimeToggleIsRemembered() throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, state) = makeModel(engine: FakeEngine(), scratch: scratch)
        model.toggleRemainingTime()
        #expect(!model.showRemainingTime)
        #expect(model.trailingLabel == "--:--")
        try state.flush()
        let reloaded = StateStore(fileURL: state.fileURL)
        try reloaded.load()
        #expect(!reloaded.state.showRemainingTime)
    }

    @Test func resumesFromReelsOwnEntryWithStartOver() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.duration = .seconds(3_600)
        let engine = FakeEngine(options: options)
        let (model, resume, _) = makeModel(engine: engine, scratch: scratch)
        let file = try scratch.makeMediaFile("movie.mkv")
        let key = try ContentKey(contentsOf: file)
        try resume.record(key: key, position: .seconds(1_390), duration: .seconds(3_600), path: "/old/place/movie.mkv")
        await model.open(file)
        await model.waitForEngineCommands()
        #expect(engine.seeks == [.exact(.seconds(1_390))])
        #expect(engine.calls.last == .play, "the resume seek is queued before play")
        #expect(model.osd == OSDMessage(kind: .resume, text: "Resumed at 23:10", showsStartOver: true))
        #expect(model.resumeMarker == .seconds(1_390))

        model.startOver()
        await model.waitForEngineCommands()
        #expect(engine.seeks.last == .exact(.zero))
        #expect(model.osd == nil)
        #expect(model.resumeMarker == nil)
        #expect(resume.entry(for: key) == nil)
    }

    @Test func fallsBackToIINAWatchLaterReadOnly() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let iina = scratch.url.appending(path: "fake-watch-later", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: iina, withIntermediateDirectories: true)
        let file = try scratch.makeMediaFile("episode.mkv")
        let name = IINAWatchLater.fileName(forPath: file.path(percentEncoded: false))
        let watchLater = iina.appending(path: name, directoryHint: .notDirectory)
        try Data("# mpv watch later\nstart=95.500000\nvolume=47\n".utf8).write(to: watchLater)
        let before = try Data(contentsOf: watchLater)

        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch, iinaDirectory: iina)
        await model.open(file)
        await model.waitForEngineCommands()
        #expect(engine.seeks == [.exact(.seconds(95.5))])
        #expect(model.osd?.text == "Resumed at 01:35")
        #expect(try Data(contentsOf: watchLater) == before, "IINA's file is never written")
    }

    @Test func resumeSettingOffOpensAtTheStart() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        var settings = Settings()
        settings.resumePlayback = false
        let (model, resume, _) = makeModel(engine: engine, scratch: scratch, settings: settings)
        let file = try scratch.makeMediaFile("movie.mkv")
        try resume.record(key: try ContentKey(contentsOf: file), position: .seconds(300), duration: .seconds(600), path: "/m")
        await model.open(file)
        await model.waitForEngineCommands()
        #expect(engine.seeks.isEmpty)
        #expect(model.osd == nil)
    }

    @Test func closingSavesTheResumePositionAndReturnsToEmpty() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, resume, _) = makeModel(engine: engine, scratch: scratch)
        let file = try scratch.makeMediaFile("movie.mkv")
        await openAndSettle(model, file)
        model.handle(.time(.seconds(321)))
        await model.close()
        #expect(model.playbackState == .idle)
        #expect(!model.hasMedia)
        #expect(model.title == nil)
        #expect(engine.calls.last == .close)
        let reloaded = ResumeStore(fileURL: resume.fileURL)
        try reloaded.load()
        #expect(reloaded.entry(for: try ContentKey(contentsOf: file))?.position == .seconds(321))
    }

    @Test func savesEveryFiveSecondsWhilePlaying() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let clock = TestClock()
        let (model, resume, _) = makeModel(engine: engine, scratch: scratch, clock: clock)
        let file = try scratch.makeMediaFile("movie.mkv")
        let key = try ContentKey(contentsOf: file)
        await model.open(file)
        await waitUntil("playing") { model.playbackState == .playing }
        clock.advance(by: 5)
        model.handle(.time(.seconds(40)))
        #expect(resume.entry(for: key)?.position == .seconds(40))
        clock.advance(by: 2)
        model.handle(.time(.seconds(42)))
        #expect(resume.entry(for: key)?.position == .seconds(40), "not again within 5 s")
        clock.advance(by: 3)
        model.handle(.time(.seconds(45)))
        #expect(resume.entry(for: key)?.position == .seconds(45))
    }

    @Test func endOfFileDeletesTheEntryAndPlayRestarts() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, resume, _) = makeModel(engine: engine, scratch: scratch)
        let file = try scratch.makeMediaFile("movie.mkv")
        let key = try ContentKey(contentsOf: file)
        try resume.record(key: key, position: .seconds(100), duration: .seconds(600), path: "/m")
        await openAndSettle(model, file)
        model.handle(.ended)
        #expect(model.playbackState == .ended)
        #expect(!model.isPlaying)
        #expect(model.position == .seconds(600))
        #expect(resume.entry(for: key) == nil, "finished files are forgotten")
        model.togglePause()
        await model.waitForEngineCommands()
        #expect(engine.seeks.last == .exact(.zero))
        #expect(engine.calls.last == .play)
    }

    @Test func openingAnotherFileClosesTheFirstEngine() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let first = FakeEngine()
        let second = FakeEngine()
        var engines = [first, second]
        let dependencies = PlayerModel.Dependencies(
            makeEngine: { _ in engines.removeFirst() },
            resumeStore: ResumeStore(fileURL: scratch.file("resume.json")),
            sleep: longSleep
        )
        let model = PlayerModel(dependencies: dependencies)
        await model.open(try scratch.makeMediaFile("one.mkv"))
        await model.open(try scratch.makeMediaFile("two.mkv"))
        #expect(first.calls.last == .close)
        #expect(model.title == "two.mkv")
        await model.waitForEngineCommands()
        #expect(second.calls.last == .play)
    }

    @Test func engineFailureIsShown() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.handle(.failed(.decoderFailed("boom")))
        #expect(model.playbackState == .failed)
        #expect(model.errorMessage == "Decoding failed: boom")
        #expect(!model.isPlaying)
    }
}

extension PlayerModelTests {
    @Test func ignoresASavedPositionNearTheEnd() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, resume, _) = makeModel(engine: engine, scratch: scratch)
        let file = try scratch.makeMediaFile("movie.mkv")
        // Saved against a longer duration; this file is 600 s, so 590 s is within the last 30 s.
        try resume.record(key: try ContentKey(contentsOf: file), position: .seconds(590), duration: .seconds(3_600), path: "/m")
        await model.open(file)
        await model.waitForEngineCommands()
        #expect(engine.seeks.isEmpty)
    }
}
