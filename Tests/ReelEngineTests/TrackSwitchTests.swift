import CoreGraphics
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// Fixtures of the M2 subtitle and track work (scripts/fixtures.sh).
enum SubtitleFixture: String, Sendable {
    case tracks = "subs_tracks.mkv"
    case sidecar = "subs_tracks.zh-Hans.srt"
    case pgs = "subs_pgs.mkv"
    case utf8 = "subs_utf8.srt"
    case gbk = "subs_gbk.srt"

    func url(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let url = Fixture.directory.appending(path: rawValue)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            Issue.record("Missing fixture \(rawValue): run scripts/fixtures.sh", sourceLocation: sourceLocation)
            throw FixtureMissing(name: rawValue)
        }
        return url
    }
}

/// Headless engines for the M2 suites: silent, no display sleep, nothing written outside a
/// temporary folder the test made.
enum M2Engines {
    static func make(
        force: VideoDecoderKind? = nil,
        external: Bool = true,
        prefetch: Bool = true,
        thumbnailCache: URL? = nil,
        environment extra: [String: String] = [:]
    ) -> PlaybackEngine {
        var values = ProcessInfo.processInfo.environment
        values.removeValue(forKey: "REEL_FORCE_DECODER")
        values.removeValue(forKey: "REEL_ALLOW_AUDIO")
        values.removeValue(forKey: "REEL_NO_THUMBNAILS")
        if let force { values["REEL_FORCE_DECODER"] = force == .hardware ? "hw" : "sw" }
        for (key, value) in extra { values[key] = value }
        return PlaybackEngine(configuration: .init(
            audioMode: .headless,
            environment: ReelEnvironment(values),
            preventsDisplaySleep: false,
            generatesThumbnails: thumbnailCache != nil,
            thumbnailCacheDirectory: thumbnailCache,
            discoversExternalSubtitles: external,
            prefetchesSubtitles: prefetch
        ))
    }

    /// Polls the presenter until `condition` holds for its output.
    static func waitForSubtitle(
        _ engine: PlaybackEngine,
        timeout: Duration = .seconds(5),
        _ condition: @escaping @Sendable (SubtitlePresenter.Output) -> Bool
    ) async -> SubtitlePresenter.Output? {
        let presenter = engine.subtitlePresenter
        guard await instantWhen(timeout: timeout, { condition(presenter.current) }) != nil else { return nil }
        return presenter.current
    }
}

/// A folder under the temporary directory, removed by its exact URL.
struct TemporaryFolder: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "reel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Track lists, the default choice and switching audio and subtitle tracks while open
/// (design sections 8.2, 8.6 and 9.7).
@Suite struct TrackSwitchTests {
    @Test func theSidecarWinsAndWithoutItTheSimplifiedChineseASSIsChosen() async throws {
        let url = try SubtitleFixture.tracks.url()
        let withSidecar = M2Engines.make()
        _ = try await withSidecar.open(url)
        let tracks = try #require(await withSidecar.trackState)
        #expect(tracks.selectedSubtitle == .external(try SubtitleFixture.sidecar.url()))
        #expect(tracks.audio.map(\.streamIndex) == [1, 2])
        #expect(tracks.selectedAudio == 1)
        #expect(tracks.subtitles.count == 5)
        await withSidecar.close()

        let embedded = M2Engines.make(external: false)
        _ = try await embedded.open(url)
        let only = try #require(await embedded.trackState)
        #expect(only.selectedSubtitle == .embedded(streamIndex: 3))
        #expect(only.selectedSubtitleTrack?.title == "简英双语")
        await embedded.close()
    }

    @Test func tracksChangedIsSentAfterOpenAndOnEverySelection() async throws {
        let engine = M2Engines.make(external: false)
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        await engine.selectSubtitle(.embedded(streamIndex: 5))
        await engine.setSubtitleDelay(0.5)
        let states = await waitForTrackStates(log, count: 3)
        #expect(states.first?.selectedSubtitle == .embedded(streamIndex: 3))
        #expect(states.last?.selectedSubtitle == .embedded(streamIndex: 5))
        #expect(states.last?.subtitleDelay == 0.5)
        await engine.close()
    }

    @Test func anAudioSwitchKeepsThePictureAndTheGeneration() async throws {
        let engine = M2Engines.make(external: false)
        let switched = Atomic<Bool>(false)
        let buffersAfter = Atomic<Int>(0)
        let framesAfter = Atomic<Int>(0)
        let firstAfter = Mutex<MediaTime?>(nil)
        await engine.setAudioObserver { buffer, _ in
            guard switched.load(ordering: .acquiring) else { return }
            buffersAfter.add(1, ordering: .relaxed)
            firstAfter.withLock { $0 = $0 ?? buffer.pts }
        }
        await engine.setFrameObserver { _ in
            if switched.load(ordering: .acquiring) { framesAfter.add(1, ordering: .relaxed) }
        }
        _ = try await engine.open(SubtitleFixture.tracks.url())
        #expect(await engine.audioCodecName == "eac3")
        await engine.play()
        try await Task.sleep(for: .milliseconds(600))
        let generation = await engine.currentGeneration
        let reports = await engine.lastReport?.generation
        await engine.selectAudioTrack(2)
        // The old track's consumer is gone once the call returns: later buffers are the new track's.
        let clock = engine.currentTime
        switched.store(true, ordering: .releasing)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await engine.audioCodecName == "aac")
        #expect(await engine.trackState?.selectedAudio == 2)
        #expect(await engine.mediaInfo?.audioStreamIndex == 2)
        #expect(await engine.currentGeneration == generation, "no seek")
        #expect(await engine.lastReport?.generation == reports)
        #expect(await engine.playbackState == .playing)
        #expect(buffersAfter.load(ordering: .relaxed) > 5, "the new track decodes")
        #expect(framesAfter.load(ordering: .relaxed) > 5, "video kept presenting")
        let first = try #require(firstAfter.withLock { $0 })
        #expect(first <= clock + .milliseconds(100) && first >= clock - .milliseconds(400), "the new track starts at the clock: \(first) for \(clock)")
        await engine.close()
    }

    @Test func choosingAnUnknownAudioStreamChangesNothing() async throws {
        let engine = M2Engines.make(external: false)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        await engine.selectAudioTrack(3)
        await engine.selectAudioTrack(1)
        #expect(await engine.trackState?.selectedAudio == 1)
        #expect(await engine.audioCodecName == "eac3")
        await engine.selectVideoTrack(0)
        await engine.selectVideoTrack(9)
        #expect(await engine.mediaInfo?.videoStreamIndex == 0)
        await engine.close()
    }

    @Test func theSelectedASSLineShowsAtItsTimeAndNothingBetweenLines() async throws {
        let engine = M2Engines.make(external: false)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        _ = await engine.seekAndWait(.exact(.seconds(2)))
        let shown = try #require(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil })
        let rect = try #require(shown.bitmap?.rect)
        #expect(shown.frameWidth == 1280 && shown.frameHeight == 720, "headless renders at the video size")
        #expect(abs(rect.centerX - 640) < 1280 * 0.05, "centred: \(rect)")
        #expect(rect.maxY > 720 * 3 / 4, "bottom aligned: \(rect)")
        _ = await engine.seekAndWait(.exact(.seconds(3.5)))
        #expect(await M2Engines.waitForSubtitle(engine) { $0.bitmap == nil } != nil, "nothing between events")
        await engine.close()
    }

    @Test func switchingSubtitlesRendersTheNewTrackAtTheCurrentTime() async throws {
        let engine = M2Engines.make(external: false)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        _ = await engine.seekAndWait(.exact(.seconds(2)))
        let ass = try #require(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil })
        await engine.selectSubtitle(.off)
        #expect(await M2Engines.waitForSubtitle(engine) { $0.bitmap == nil } != nil)
        await engine.selectSubtitle(.embedded(streamIndex: 5))
        let srt = try #require(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil })
        // One English line against two bilingual lines.
        #expect((srt.bitmap?.rect.height ?? 0) < (ass.bitmap?.rect.height ?? 0))
        #expect(await engine.trackState?.selectedSubtitle == .embedded(streamIndex: 5))
        await engine.close()
    }

    @Test func aScrubShowsTheLineAtThePointer() async throws {
        let engine = M2Engines.make(external: false)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        #expect(await M2Engines.waitForSubtitle(engine) { $0.publishCount > 0 && $0.bitmap == nil } != nil)
        // The keyframe on screen is at 0 s, before the first line; the pointer is at 2 s.
        _ = await engine.seekAndWait(.scrub(.seconds(2)))
        #expect(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil } != nil)
        await engine.close()
    }

    @Test func theSubtitleDelayMovesTheLinesAndTheirEventTimes() async throws {
        let engine = M2Engines.make(external: false)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        let events = try await waitForEvents(engine, atLeast: 2)
        #expect(events.first?.start == .seconds(1))
        await engine.setSubtitleDelay(2.5)
        let shifted = await engine.subtitleEvents()
        #expect(shifted.first?.start == .seconds(3.5))
        // At 2 s the clock minus the delay is before the first line.
        _ = await engine.seekAndWait(.exact(.seconds(2)))
        #expect(await M2Engines.waitForSubtitle(engine) { $0.publishCount > 0 && $0.bitmap == nil } != nil)
        _ = await engine.seekAndWait(.exact(.seconds(4)))
        #expect(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil } != nil)
        await engine.close()
    }

    @Test func nextAndPreviousLineSeekToEventStarts() async throws {
        let engine = M2Engines.make(external: false)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        _ = try await waitForEvents(engine, atLeast: 2)
        _ = await engine.seekAndWait(.exact(.seconds(2)))
        let next = await engine.seekSubtitleLine(forward: true)
        #expect(next == .seconds(4))
        try await Task.sleep(for: .milliseconds(300))
        let previous = await engine.seekSubtitleLine(forward: false)
        #expect(previous == .seconds(1))
        await engine.close()
    }

    @Test func liftingMovesBottomLinesAboveTheInset() async throws {
        let engine = M2Engines.make(external: false)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        await engine.selectSubtitle(.embedded(streamIndex: 5))
        _ = await engine.seekAndWait(.exact(.seconds(2)))
        let resting = try #require(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil }?.bitmap?.rect)
        await engine.setSubtitleAvoidance(bottomInsetPoints: 200)
        let lifted = try #require(await M2Engines.waitForSubtitle(engine) { ($0.bitmap?.rect.maxY ?? 720) < resting.maxY }?.bitmap?.rect)
        // The renderer lifts the line's margin edge to the inset; outline and shadow hang below
        // it by the same amount as at rest (the margin is 40 on the 720 reference).
        let restingOverhang = resting.maxY - (720 - Int(SubtitleStyle.bottomMargin))
        #expect(abs((lifted.maxY - (720 - 200)) - restingOverhang) <= 4, "lifted \(lifted), resting \(resting)")
        await engine.setSubtitleAvoidance(bottomInsetPoints: nil)
        #expect(await M2Engines.waitForSubtitle(engine) { $0.bitmap?.rect == resting } != nil)
        await engine.close()
    }

    @Test func sizeAndVisibilityApplyToTheRenderedLine() async throws {
        let engine = M2Engines.make(external: false)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        await engine.selectSubtitle(.embedded(streamIndex: 5))
        _ = await engine.seekAndWait(.exact(.seconds(2)))
        let normal = try #require(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil }?.bitmap?.rect)
        await engine.setSubtitleScale(1.5)
        let larger = try #require(await M2Engines.waitForSubtitle(engine) { ($0.bitmap?.rect.height ?? 0) > normal.height + 5 }?.bitmap?.rect)
        #expect(larger.width > normal.width)
        await engine.setSubtitlesVisible(false)
        #expect(await M2Engines.waitForSubtitle(engine) { $0.bitmap == nil } != nil)
        #expect(await engine.trackState?.subtitlesVisible == false)
        #expect(await engine.trackState?.subtitleScale == 1.5)
        await engine.close()
    }

    @Test func anAddedExternalFileIsListedLoadedAndShown() async throws {
        let engine = M2Engines.make(external: false)
        _ = try await engine.open(SubtitleFixture.tracks.url())
        let file = try SubtitleFixture.gbk.url()
        await engine.selectSubtitle(.external(file))
        let tracks = try #require(await engine.trackState)
        #expect(tracks.subtitles.contains { $0.id == .external(file) })
        #expect(tracks.selectedSubtitle == .external(file))
        _ = await engine.seekAndWait(.exact(.seconds(2)))
        #expect(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil } != nil)
        // The charset found shows on the track's second line (section 8.3).
        let charset = await pollValue { await engine.trackState?.subtitles.first { $0.id == .external(file) }?.charset }
        #expect(charset == "GB18030")
        await engine.close()
    }

    @Test func aPGSTrackShowsItsDisplaySetAtTheTargetAndClears() async throws {
        let engine = M2Engines.make()
        _ = try await engine.open(SubtitleFixture.pgs.url())
        #expect(await engine.trackState?.selectedSubtitle == .off, "Japanese only: subtitles start off")
        await engine.selectSubtitle(.embedded(streamIndex: 1))
        _ = await engine.seekAndWait(.exact(.seconds(2)))
        let shown = try #require(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil })
        let rect = try #require(shown.bitmap?.rect)
        // logs/pgs_rects.json: the first set is 600x90 at (660, 900) on a 1920x1080 canvas.
        #expect(abs(rect.x - 660) <= 2 && abs(rect.y - 900) <= 2 && abs(rect.width - 600) <= 2 && abs(rect.height - 90) <= 2, "\(rect)")
        _ = await engine.seekAndWait(.exact(.seconds(3.5)))
        #expect(await M2Engines.waitForSubtitle(engine) { $0.bitmap == nil } != nil, "the clear set ends it")
        await engine.close()
    }

    @Test func aPGSSetThatStartedBeforeTheSeekKeyframeIsReadBack() async throws {
        let engine = M2Engines.make()
        _ = try await engine.open(SubtitleFixture.pgs.url())
        await engine.selectSubtitle(.embedded(streamIndex: 1))
        // Straight to the second set, which starts at 4 s.
        _ = await engine.seekAndWait(.exact(.seconds(5.5)))
        let shown = try #require(await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil })
        #expect(abs((shown.bitmap?.rect.width ?? 0) - 1000) <= 2)
        await engine.close()
    }

    private func waitForTrackStates(_ log: EventLog, count: Int) async -> [TrackState] {
        func states() -> [TrackState] {
            log.all.compactMap { event in
                if case .tracksChanged(let state) = event { return state }
                return nil
            }
        }
        _ = await log.wait(timeout: .seconds(5)) { _ in states().count >= count }
        return states()
    }

    private func waitForEvents(_ engine: PlaybackEngine, atLeast count: Int) async throws -> [SubtitleEventTime] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let events = await engine.subtitleEvents()
            if events.count >= count { return events }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await engine.subtitleEvents()
    }

    private func pollValue<Value: Sendable>(timeout: Duration = .seconds(5), _ read: @Sendable () async -> Value?) async -> Value? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = await read() { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
