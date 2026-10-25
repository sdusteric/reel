import CoreGraphics
import Foundation
import ImageIO
import ReelCore
import Synchronization
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

// MARK: M2 behaviour

extension PlayerModelTests {
    @Test func loopsFollowCmdLAndShiftCmdL() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))

        model.handle(.time(.seconds(60)))
        model.toggleABLoop()
        #expect(model.loop.phase == .startSet)
        #expect(model.osd?.text == "Loop from 01:00")
        model.handle(.time(.seconds(130)))
        model.toggleABLoop()
        #expect(model.loop.range == MediaTime.seconds(60)...MediaTime.seconds(130))
        #expect(model.osd?.text == "Loop 01:00 to 02:10")
        model.toggleABLoop()
        #expect(model.loop == .off)
        #expect(model.osd?.text == "Loop Off")

        model.toggleFileLoop()
        #expect(model.osd?.text == "Loop File On")
        #expect(model.osd?.kind == .fileLoop)
        await model.waitForEngineCommands()
        #expect(engine.calls.filter { if case .loop = $0 { true } else { false } }.count == 4)
        #expect(engine.calls.last == .loop(LoopState(fileLoop: true)))
    }

    @Test func aLoopPointEqualToAIsIgnored() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.handle(.time(.seconds(60)))
        model.toggleABLoop()
        model.toggleABLoop()
        #expect(model.loop.phase == .startSet)
    }

    @Test func engineEventsFeedTracksRateAndLoop() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.handle(.rateChanged(2))
        #expect(model.rate == 2)
        model.handle(.loopChanged(LoopState(fileLoop: true)))
        #expect(model.loop.fileLoop)
        model.handle(.thumbnailsProgress(done: 12, total: 40))
        #expect(model.thumbnailProgress == ThumbnailProgress(done: 12, total: 40))
        let missing = URL(filePath: "/x/y.srt")
        model.handle(.tracksChanged(TrackState(subtitles: [SubtitleTrack(id: .external(missing), format: .srt)])))
        model.handle(.subtitleTrackFailed(.external(missing), reason: "Unreadable"))
        #expect(model.tracks?.subtitles.first?.unsupportedReason == "Unreadable")
    }

    @Test func speedCarriesToTheNextOpenAndIsClampedForTheEngine() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let first = FakeEngine()
        let second = FakeEngine()
        let engines = [first, second]
        let (model, _, _) = makeModel(engineFactory: { url in url.lastPathComponent == "a.mkv" ? engines[0] : engines[1] }, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.setRate(0.1)
        #expect(model.rate == 0.25)
        model.setRate(1.25)
        await model.open(try scratch.makeMediaFile("b.mkv"))
        await model.waitForEngineCommands()
        #expect(second.calls.contains(.rate(1.25)), "the speed carries within a session (D45)")
    }

    @Test func subtitleSizeIsRememberedAndResentOnTheNextFile() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, state) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.adjustSubtitleScale(delta: 0.1)
        #expect(model.osd?.text == "Subtitle Size 50")
        #expect(state.state.subtitleSize == 50)
        model.moveSubtitle(by: -1)
        model.moveSubtitle(by: -1)
        #expect(model.osd?.text == "Subtitle Position 2%")
        model.resetSubtitleStyle()
        #expect(model.subtitleStyle == SubtitleStyle())
        #expect(state.state.subtitleSize == 45)
    }

    @Test func delaysShowSignedOSDsAndSurviveResetToZero() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.adjustSubtitleDelay(by: 0.5)
        #expect(model.osd?.text == "Subtitle Delay +0.5 s")
        model.adjustAudioDelay(by: -0.1)
        #expect(model.osd?.text == "Audio Delay -0.1 s")
        model.setSubtitleDelay(0)
        #expect(model.osd?.text == "Subtitle Delay 0.0 s")
    }

    @Test func choicesAreSavedWithTheResumePositionAndComeBack() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.extraStreams = [
            StreamInfo(index: 2, kind: .subtitle, codec: "ass", timeBase: Rational(1, 1_000), language: "zho"),
            StreamInfo(index: 3, kind: .subtitle, codec: "subrip", timeBase: Rational(1, 1_000), language: "eng"),
        ]
        let file = try scratch.makeMediaFile("a.mkv")
        let first = FakeEngine(options: options)
        let (model, resume, _) = makeModel(engine: first, scratch: scratch)
        await openAndSettle(model, file)
        await waitUntil("tracks") { model.tracks != nil }
        model.selectSubtitle(.embedded(streamIndex: 3))
        model.setSubtitleDelay(1.5)
        model.handle(.time(.seconds(120)))
        model.saveResume(flush: true)
        let entry = try #require(resume.entry(for: try ContentKey(contentsOf: file)))
        #expect(entry.subtitleDelay == 1.5)
        guard case .track(let identity)? = entry.subtitle else {
            Issue.record("the subtitle choice was not saved")
            return
        }
        #expect(identity.language == "eng")

        let second = FakeEngine(options: options)
        let (again, reloaded, _) = makeModel(engine: second, scratch: scratch)
        try reloaded.load()
        await again.open(file)
        await waitUntil("the saved choice is applied") { second.calls.contains(.subtitle(.embedded(streamIndex: 3))) }
        await again.waitForEngineCommands()
        #expect(second.calls.contains(.subtitleDelay(1.5)))
    }

    @Test func episodeButtonsHideForAFileAloneAndDisableAtTheEnds() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let alone = try scratch.makeMediaFile("Only.mkv")
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, alone)
        #expect(!model.showsEpisodeButtons)
        await model.playNextEpisode()
        #expect(model.title == "Only.mkv", "next on a lone file does nothing")
    }

    @Test func episodeButtonsShowForASeasonAndFollowTheEnds() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let first = try scratch.makeMediaFile("Show.S01E01.mkv")
        _ = try scratch.makeMediaFile("Show.S01E02.mkv")
        let boxes = EngineBox()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        await openAndSettle(model, first)
        #expect(model.showsEpisodeButtons)
        #expect(!model.hasPreviousEpisode)
        #expect(model.hasNextEpisode)
        await model.playPreviousEpisode()
        #expect(boxes.all.count == 1, "previous on the first episode does nothing")
        await model.playNextEpisode()
        #expect(model.osd?.text == "Show S01E02")
        #expect(!model.hasNextEpisode)
        #expect(model.hasPreviousEpisode)
    }

    @Test func hoverLoadsTheThumbnailFromTheEngine() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.thumbnails = [
            ThumbnailImage(jpeg: try Self.jpeg(width: 384, height: 216), pts: .seconds(300), width: 384, height: 216),
        ]
        let engine = FakeEngine(options: options)
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))

        model.setSeekHover(0.6)
        await waitUntil("the thumbnail arrives") { model.hoverThumbnail != nil }
        #expect(engine.calls.contains(.thumbnail(.seconds(360))))
        #expect(model.hoverThumbnail?.width == 384)
        #expect(ThumbnailPill.imageHeight(width: 384, height: 216) == 108)
        #expect(ThumbnailPill.imageHeight(width: 100, height: 100) == 144, "clamped to 144")
        #expect(ThumbnailPill.imageHeight(width: 400, height: 100) == 80, "clamped to 80")

        model.setSeekHover(0.1)
        await waitUntil("no thumbnail before the first keyframe") { model.hoverThumbnail == nil }
        model.setSeekHover(0.6)
        await waitUntil("it comes back") { model.hoverThumbnail != nil }
        model.setSeekHover(nil)
        #expect(model.hoverThumbnail == nil)
    }

    @Test func fullscreenEndsAtUsesTheSpeed() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let resume = ResumeStore(fileURL: scratch.file("resume.json"))
        let dependencies = PlayerModel.Dependencies(
            makeEngine: { _ in engine },
            resumeStore: resume,
            wallClock: { reference },
            sleep: longSleep
        )
        let model = PlayerModel(dependencies: dependencies)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        let normal = try #require(model.endsAtLabel)
        #expect(normal == "Ends at " + reference.addingTimeInterval(600).formatted(date: .omitted, time: .shortened))
        model.setRate(2)
        #expect(model.endsAtLabel == "Ends at " + reference.addingTimeInterval(300).formatted(date: .omitted, time: .shortened))
        model.setFullscreen(true)
        #expect(model.isFullscreen)
    }

    @Test func pictureInPictureAndScreenshotHooks() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        var requests: [Bool] = []
        model.onPictureInPictureRequest = { requests.append($0) }
        model.togglePictureInPicture()
        model.setPictureInPicture(active: true, snapshot: ShotRenderer.placeholderFrame(width: 8, height: 8))
        model.togglePictureInPicture()
        #expect(requests == [true, false])
        #expect(model.pictureInPictureSnapshot != nil)
        model.setPictureInPicture(active: false)
        #expect(model.pictureInPictureSnapshot == nil)

        var revealed: [URL] = []
        model.onRevealScreenshot = { revealed.append($0) }
        let saved = scratch.file("shot.png")
        model.showScreenshotSaved(at: saved)
        #expect(model.osd?.text == "Screenshot Saved")
        #expect(model.osd?.showsReveal == true)
        model.revealScreenshot()
        #expect(revealed == [saved])
    }

    @Test func openingAnotherFileClearsPerFileState() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engineFactory: { _ in FakeEngine() }, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.setSubtitleDelay(2)
        model.toggleFileLoop()
        model.openPanel(.audio)
        await model.open(try scratch.makeMediaFile("b.mkv"))
        #expect(model.subtitleDelay == 0)
        #expect(model.loop == .off)
        #expect(model.activePanel == nil)
        #expect(!model.chrome.isPanelOpen)
    }

    private static func jpeg(width: Int, height: Int) throws -> Data {
        let image = try #require(ShotRenderer.placeholderFrame(width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Milestone 3 model behaviour (design 7.7 to 7.11, 9.13, 9.14).
@MainActor
@Suite struct PlayerModelM3Tests {
    private static let dolbyVision5 = DolbyVisionConfig(profile: 5, level: 6, rpu: true, el: false, bl: true, compatibilityID: 0)
    private static let dolbyVision81 = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 1)

    @Test func seeksPastTheEndOfTheDataLandOnItAndSayWhy() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("cut.mkv"))
        model.handle(.dataEnd(.seconds(380)))
        #expect(model.effectiveEnd == .seconds(380))
        #expect(abs((model.dataEndFraction ?? 0) - 380.0 / 600.0) < 0.0001)
        model.seek(to: .seconds(500))
        #expect(model.position == .seconds(380))
        #expect(model.osd?.text == "No data after 06:20")
        #expect(model.osd?.symbol == OSDMessage.warningSymbol)
        await model.waitForEngineCommands()
        #expect(engine.seeks == [.exact(.seconds(380))])
        model.osd = nil
        model.seek(by: -100, source: .keyboard)
        #expect(model.position == .seconds(280))
        #expect(model.osd?.kind == .seek, "a seek inside the data keeps the position OSD")
    }

    @Test func timesCountToTheEndOfTheData() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("cut.mkv"))
        model.handle(.time(.seconds(300)))
        #expect(model.trailingLabel == "-05:00")
        model.handle(.dataEnd(.seconds(380)))
        #expect(model.trailingLabel == "-01:20", "remaining time counts to dataEnd")
        model.handle(.time(.seconds(500)))
        #expect(model.position == .seconds(380), "the clock never runs past the data")
        model.setShowRemainingTime(false)
        #expect(model.trailingLabel == "10:00", "the total stays the header duration")
        model.handle(.ended)
        #expect(model.position == .seconds(380))
    }

    @Test func aDataEndAtTheDurationChangesNothing() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("whole.mkv"))
        model.handle(.dataEnd(.seconds(600)))
        #expect(model.dataEndFraction == nil)
        #expect(model.missingTailText(atFraction: 0.99) == nil)
        model.seek(to: .seconds(600))
        #expect(model.osd == nil)
    }

    @Test func damagedOSDsAreLimitedToOnePerKindEveryTenSeconds() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let clock = TestClock()
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch, clock: clock)
        await openAndSettle(model, try scratch.makeMediaFile("bad.mkv"))
        model.handle(.damaged(at: .seconds(724), kind: .video))
        #expect(model.osd?.text == "Skipped damaged video at 12:04")
        #expect(model.osd?.symbol == OSDMessage.warningSymbol)
        model.osd = nil
        clock.advance(by: 4)
        model.handle(.damaged(at: .seconds(730), kind: .video))
        #expect(model.osd == nil, "a second video region within 10 s only counts")
        model.handle(.damaged(at: .seconds(731), kind: .audio))
        #expect(model.osd?.text == "Skipped damaged audio at 12:11", "audio has its own limit")
        model.osd = nil
        clock.advance(by: 7)
        model.handle(.damaged(at: .seconds(740), kind: .video))
        #expect(model.osd?.text == "Skipped damaged video at 12:20")
        #expect(model.damagedCount == 4)
    }

    @Test func theVKeyNamesItselfAndVisibilityResetsOnTheNextFile() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.extraStreams = [StreamInfo(index: 2, kind: .subtitle, codec: "subrip", timeBase: Rational(1, 1_000), language: "eng")]
        let (model, _, _) = makeModel(engineFactory: { [options] _ in FakeEngine(options: options) }, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        await waitUntil("tracks") { model.tracks != nil }
        model.toggleSubtitlesVisible()
        #expect(model.osd?.text == "Subtitles Hidden, press V to show")
        #expect(model.tracks?.subtitlesVisible == false)
        await model.open(try scratch.makeMediaFile("b.mkv"))
        await waitUntil("tracks of the next file") { model.tracks != nil }
        #expect(model.tracks?.subtitlesVisible == true, "a stray v never carries over")
        model.toggleSubtitlesVisible()
        model.toggleSubtitlesVisible()
        #expect(model.osd?.text == "Subtitles Shown")
    }

    @Test func theDolbyVisionNoteShowsOncePerFilePerSession() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.dolbyVision = PlayerModelM3Tests.dolbyVision5
        let (model, _, _) = makeModel(engineFactory: { [options] _ in FakeEngine(options: options) }, scratch: scratch)
        var announcements: [String] = []
        model.onAnnouncement = { announcements.append($0) }
        let first = try scratch.makeMediaFile("harbour.mp4")
        await model.open(first)
        #expect(model.dolbyVisionNoteVisible)
        #expect(model.dynamicRangePlan.note)
        #expect(model.dynamicRangePlan.tag == "Dolby Vision 5")
        #expect(announcements == ["\(DolbyVisionPolicy.noteTitle). \(DolbyVisionPolicy.noteBody)"])
        model.dismissDolbyVisionNote()
        #expect(!model.dolbyVisionNoteVisible)
        await model.open(first)
        #expect(!model.dolbyVisionNoteVisible, "the same file again in this session does not repeat it")
        await model.open(try scratch.makeMediaFile("other.mp4"))
        #expect(model.dolbyVisionNoteVisible)
        #expect(announcements.count == 2)
        model.showInfoFromNote()
        #expect(!model.dolbyVisionNoteVisible)
        #expect(model.videoInfoVisible)
    }

    @Test func theNoteClosesItselfAfterTenSeconds() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.dolbyVision = PlayerModelM3Tests.dolbyVision5
        let waits = Mutex<[TimeInterval]>([])
        let (model, _, _) = makeModel(
            engineFactory: { [options] _ in FakeEngine(options: options) },
            scratch: scratch,
            sleep: { seconds in
                waits.withLock { $0.append(seconds) }
                if seconds == DolbyVisionPolicy.noteSeconds { return }
                await longSleep(seconds)
            }
        )
        var shown = 0
        model.onAnnouncement = { _ in shown += 1 }
        await model.open(try scratch.makeMediaFile("harbour.mp4"))
        await waitUntil("the note times out") { !model.dolbyVisionNoteVisible }
        #expect(shown == 1)
        #expect(waits.withLock { $0.contains(10) })
    }

    @Test func aProfile8FileGetsNoNoteAndAnHDR10Plan() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.dolbyVision = PlayerModelM3Tests.dolbyVision81
        let (model, _, _) = makeModel(engineFactory: { [options] _ in FakeEngine(options: options) }, scratch: scratch)
        await model.open(try scratch.makeMediaFile("dv81.mp4"))
        #expect(!model.dolbyVisionNoteVisible)
        #expect(model.dynamicRangePlan.layer == .high)
        #expect(model.dynamicRangePlan.tag == "Dolby Vision")
        #expect(!model.dynamicRangePlan.warning)
    }

    @Test func escapeClosesTheNoteThenVideoInfo() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.dolbyVision = PlayerModelM3Tests.dolbyVision5
        let (model, _, _) = makeModel(engineFactory: { [options] _ in FakeEngine(options: options) }, scratch: scratch)
        #expect(!model.dismissTransient())
        model.toggleVideoInfo()
        #expect(!model.videoInfoVisible, "nothing to describe without a file")
        await model.open(try scratch.makeMediaFile("harbour.mp4"))
        model.toggleVideoInfo()
        #expect(model.videoInfoVisible)
        #expect(model.dismissTransient())
        #expect(!model.dolbyVisionNoteVisible)
        #expect(model.videoInfoVisible, "the first Esc only closes the note")
        #expect(model.dismissTransient())
        #expect(!model.dolbyVisionNoteVisible && !model.videoInfoVisible)
        #expect(!model.dismissTransient())
    }

    @Test func theRangePlanFollowsTheSettingAndTheDisplayWithoutReopening() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.dynamicRange = .hdr10
        let engine = FakeEngine(options: options)
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("hdr.mkv"))
        await waitUntil("range") { model.dynamicRange == .hdr10 }
        await model.waitForEngineCommands()
        let calls = engine.calls
        #expect(model.dynamicRangePlan.layer == .high)
        #expect(model.dynamicRangePlan.tagDetail == nil)
        model.setDisplay(.sdr)
        #expect(model.dynamicRangePlan.layer == .high, "the display never reconfigures the layer")
        #expect(model.dynamicRangePlan.tagDetail == "SDR")
        model.setDisplay(.external)
        #expect(model.dynamicRangePlan.tagDetail == nil)
        model.setHDRSetting(.limited)
        #expect(model.dynamicRangePlan.layer == .constrainedHigh)
        model.setHDRSetting(.off)
        #expect(model.dynamicRangePlan.layer == .standard)
        #expect(model.dynamicRangePlan.tagDetail == "SDR")
        #expect(engine.calls == calls, "no engine command and no reopen")
    }

    @Test func theRangeSettingStartsFromTheStoredSetting() throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch, settings: Settings(highDynamicRange: .limited))
        #expect(model.hdrSetting == .limited)
    }

    @Test func anOpenFailureBecomesAClassifiedProblem() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let cases: [(EngineError, MediaProblem)] = [
            (.notMedia("Invalid data found when processing input"), .notMedia),
            (.cutShort("End of file"), .cutShort),
            (.unsupportedCodec("prores"), .unsupportedCodec("ProRes")),
            (.noPlayableStream, .noPlayableStream),
            (.io("Input/output error"), .unreadable("Input/output error")),
        ]
        for (error, expected) in cases {
            var options = FakeEngine.Options()
            options.openError = error
            let (model, _, _) = makeModel(engine: FakeEngine(options: options), scratch: scratch)
            await model.open(try scratch.makeMediaFile("bad.mkv"))
            #expect(model.problem == expected, "\(error)")
            #expect(model.showsFailureCard)
            #expect(model.problemDetail?.isEmpty == false)
            #expect(model.playbackState == .failed)
            #expect(model.title == "bad.mkv", "the title bar keeps the file name")
            #expect(model.errorMessage == error.errorDescription)
        }
    }

    @Test func aFailureClearsOnTheNextOpen() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var bad = FakeEngine.Options()
        bad.openError = .notMedia("x")
        let (model, _, _) = makeModel(
            engineFactory: { [bad] in $0.lastPathComponent == "bad.mkv" ? FakeEngine(options: bad) : FakeEngine() },
            scratch: scratch
        )
        await model.open(try scratch.makeMediaFile("bad.mkv"))
        #expect(model.problem == .notMedia)
        await model.open(try scratch.makeMediaFile("good.mkv"))
        #expect(model.problem == nil)
        #expect(model.problemDetail == nil)
        #expect(model.hasMedia)
    }

    @Test func aDisconnectedDrivePausesOnTheFrameAndTryAgainReopens() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engines = EngineBox()
        let (model, resume, _) = makeModel(engineFactory: { engines.make($0) }, scratch: scratch)
        let file = try scratch.makeMediaFile("show.mkv")
        await openAndSettle(model, file)
        model.handle(.time(.seconds(300)))
        model.handle(.problem(.volumeGone("Eric X9 Pro")))
        #expect(model.isVolumeGone)
        #expect(model.hasMedia, "the last frame stays")
        #expect(!model.isPlaying)
        #expect(model.problemExplanation == "Reel saved your place at 05:00 and will continue when the drive is connected again.")
        #expect(try resume.entry(for: ContentKey(contentsOf: file))?.position == .seconds(300))
        await model.waitForEngineCommands()
        #expect(engines.all[0].calls.contains(.pause))
        await model.performProblemAction(.tryAgain)
        #expect(engines.all.count == 2, "a new engine reopens the same file")
        #expect(model.problem == nil)
        #expect(model.title == "show.mkv")
    }

    @Test func theCardButtonsReachTheApp() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.openError = .cutShort("End of file")
        let (model, _, _) = makeModel(engine: FakeEngine(options: options), scratch: scratch)
        var revealed: [URL] = []
        var openPanels = 0
        model.onRevealFile = { revealed.append($0) }
        model.onOpenAnotherFile = { openPanels += 1 }
        let file = try scratch.makeMediaFile("short.mkv")
        await model.open(file)
        await model.performProblemAction(.showInFinder)
        await model.performProblemAction(.openAnotherFile)
        #expect(revealed == [file])
        #expect(openPanels == 1)
        await model.performProblemAction(.closeFile)
        #expect(model.problem == nil)
        #expect(model.playbackState == .idle)
        #expect(model.title == nil)
    }

    @Test func anAudioTrackThatCannotBeDecodedIsListedAsDisabled() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        await waitUntil("tracks") { model.tracks != nil }
        model.audioTrackFailed(streamIndex: 1, reason: "No decoder for AC-3")
        #expect(model.osd?.text.hasPrefix("Audio can't be played: ") == true)
        #expect(model.osd?.symbol == OSDMessage.warningSymbol)
        model.openPanel(.audio)
        let row = try #require(model.panelRows.first)
        #expect(!row.isEnabled)
        #expect(row.detail == "No decoder for AC-3")
        #expect(model.isPlaying, "the video keeps playing")
    }

    @Test func theEnginesAudioFailureEventDisablesTheTrack() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        await waitUntil("tracks") { model.tracks != nil }
        model.handle(.audioTrackFailed(streamIndex: 1, reason: "Unsupported codec: truehd"))
        #expect(model.osd?.text.hasPrefix("Audio can't be played: ") == true)
        model.openPanel(.audio)
        let row = try #require(model.panelRows.first)
        #expect(!row.isEnabled)
        #expect(row.detail == "Unsupported codec: truehd")
    }

    /// The engine sends `.problem` (no detail for notMedia and cutShort) and then `.failed`, whose
    /// reason becomes the card's detail line.
    @Test func aProblemWithoutDetailTakesTheReasonOfTheFailure() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        model.handle(.problem(.notMedia))
        #expect(model.problemDetail == nil)
        let error = EngineError.notMedia("Invalid data found when processing input")
        model.handle(.failed(error))
        #expect(model.problem == .notMedia)
        #expect(model.problemDetail == error.errorDescription)
    }

    @Test func perFileM3StateIsClearedOnTheNextOpen() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engineFactory: { _ in FakeEngine() }, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.handle(.dataEnd(.seconds(100)))
        model.handle(.damaged(at: .seconds(5), kind: .video))
        model.setDroppedFrames(3)
        await model.open(try scratch.makeMediaFile("b.mkv"))
        #expect(model.dataEnd == nil)
        #expect(model.damagedCount == 0)
        #expect(model.droppedFrames == 0)
    }
}
