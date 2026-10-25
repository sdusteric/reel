import CoreMedia
import Foundation
import ReelCore
import ReelUI
import Synchronization
import Testing
@testable import Reel

/// A `PlayerEngine` that records commands and answers with plausible events. No decoding, no
/// audio, no window.
nonisolated final class StubEngine: PlayerEngine {
    enum Call: Equatable {
        case open(URL), play, pause, seek(SeekRequest), close
    }

    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let log = Mutex<[Call]>([])

    init() {
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
    }

    var calls: [Call] { log.withLock { $0 } }

    private func record(_ call: Call) {
        log.withLock { $0.append(call) }
    }

    func open(_ url: URL) async throws -> MediaInfo {
        record(.open(url))
        let video = StreamInfo(
            index: 0, kind: .video, codec: "hevc", timeBase: Rational(1, 1_000),
            video: VideoParameters(width: 1920, height: 1080, frameRate: Rational(24, 1), bitDepth: 10)
        )
        let info = MediaInfo(
            url: url, formatName: "matroska,webm", duration: .seconds(600), streams: [video],
            videoStreamIndex: 0, audioStreamIndex: nil, videoDecoder: .hardware, keyframeCount: 60
        )
        continuation.yield(.opened(info))
        continuation.yield(.tracksChanged(TrackState(info: info)))
        continuation.yield(.stateChanged(.paused))
        return info
    }

    func play() async {
        record(.play)
        continuation.yield(.stateChanged(.playing))
    }

    func pause() async {
        record(.pause)
        continuation.yield(.stateChanged(.paused))
    }

    func seek(_ request: SeekRequest) async { record(.seek(request)) }
    func setVolume(_ volume: Double) async {}
    func setMuted(_ muted: Bool) async {}
    func setTimeUpdateInterval(_ seconds: Double) async {}

    func close() async {
        record(.close)
        continuation.finish()
    }
}

/// Stands in for `MPNowPlayingInfoCenter`.
final class FakeNowPlayingPublisher: NowPlayingPublishing {
    var published: [NowPlayingState?] = []

    func publish(_ state: NowPlayingState?) {
        published.append(state)
    }
}

/// Stands in for `MPRemoteCommandCenter`.
final class FakeRemoteCommands: RemoteCommandRegistering {
    var handler: (@MainActor (RemoteCommand) -> Void)?
    var registrations = 0
    var unregistrations = 0
    var episodeCommands: (next: Bool, previous: Bool)?

    func register(handler: @escaping @MainActor (RemoteCommand) -> Void) {
        registrations += 1
        self.handler = handler
    }

    func setEpisodeCommandsEnabled(next: Bool, previous: Bool) {
        episodeCommands = (next, previous)
    }

    func unregister() {
        unregistrations += 1
        handler = nil
    }
}

/// A temp folder of small stand-in video files, removed by its exact path.
struct AppScratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "reel-app-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeFile(_ name: String) throws -> URL {
        let file = url.appending(path: name, directoryHint: .notDirectory)
        try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: file)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Polls `condition` until it holds or 20 seconds pass.
func eventually(_ description: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    // Bounds a hang only; the model's open runs detached steps a loaded test run can delay.
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// The stub engines a model made, in order.
nonisolated final class EngineList: Sendable {
    private let engines = Mutex<[StubEngine]>([])

    func add(_ engine: StubEngine) { engines.withLock { $0.append(engine) } }
    var all: [StubEngine] { engines.withLock { $0 } }
}

/// A model on stub engines, one per opened file, over the real folder scan.
func makeAppModel(engines: EngineList = EngineList()) -> PlayerModel {
    let dependencies = PlayerModel.Dependencies(
        makeEngine: { _ in
            let engine = StubEngine()
            engines.add(engine)
            return engine
        },
        episodeList: { url in try? EpisodeList.scan(current: url) },
        sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) }
    )
    return PlayerModel(dependencies: dependencies)
}

@Suite struct NowPlayingTests {
    static func state(title: String = "Northern Line S01E02", elapsed: Double = 0, playing: Bool = true) -> NowPlayingState {
        NowPlayingState(title: title, duration: 600, elapsed: elapsed, rate: 1, isPlaying: playing, hasNext: true, hasPrevious: false, artwork: nil)
    }

    @Test func registersOnlyWhileAFileIsOpenAndReleasesTheKeysOnClose() throws {
        let publisher = FakeNowPlayingPublisher()
        let commands = FakeRemoteCommands()
        let nowPlaying = NowPlaying(publisher: publisher, commands: commands, sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) })
        let model = makeAppModel()
        nowPlaying.update(nil, model: model)
        #expect(commands.registrations == 0 && publisher.published.isEmpty, "nothing open: the media keys stay free (D44)")

        nowPlaying.update(Self.state(), model: model)
        #expect(nowPlaying.isRegistered)
        #expect(commands.registrations == 1)
        #expect(publisher.published.count == 1)
        nowPlaying.update(Self.state(), model: model)
        #expect(publisher.published.count == 1, "an unchanged state is not published again")
        nowPlaying.update(Self.state(elapsed: 12, playing: false), model: model)
        #expect(publisher.published.count == 2)
        #expect(commands.registrations == 1, "registered once per open file")
        #expect(commands.episodeCommands?.next == true && commands.episodeCommands?.previous == false)

        nowPlaying.clear()
        #expect(!nowPlaying.isRegistered)
        #expect(commands.unregistrations == 1)
        #expect(publisher.published.last == .some(nil), "close clears the info")
    }

    @Test func stateNamesTheEpisodeAndFollowsThePlayer() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        for name in ["Northern.Line.S01E01.mkv", "Northern.Line.S01E03.mkv"] { _ = try scratch.makeFile(name) }
        let file = try scratch.makeFile("Northern.Line.S01E02.1080p.mkv")
        let model = makeAppModel()
        #expect(NowPlaying.state(for: model, artwork: nil) == nil)
        await model.open(file)
        await eventually("playing") { model.playbackState == .playing }
        await eventually("episodes") { model.hasNextEpisode }
        let state = try #require(NowPlaying.state(for: model, artwork: Data([1, 2, 3])))
        #expect(state.title == "Northern Line S01E02")
        #expect(state.duration == 600)
        #expect(state.isPlaying)
        #expect(state.hasNext && state.hasPrevious)
        #expect(state.artwork == Data([1, 2, 3]))
    }

    @Test func remoteCommandsDriveThePlayer() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let first = try scratch.makeFile("Northern.Line.S01E01.mkv")
        let second = try scratch.makeFile("Northern.Line.S01E02.mkv")
        let engines = EngineList()
        let model = makeAppModel(engines: engines)
        await model.open(first)
        await eventually("playing") { model.playbackState == .playing }
        let commands = FakeRemoteCommands()
        let nowPlaying = NowPlaying(publisher: FakeNowPlayingPublisher(), commands: commands, sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) })
        nowPlaying.update(NowPlaying.state(for: model, artwork: nil), model: model)
        let handler = try #require(commands.handler)
        let engine = try #require(engines.all.first)

        handler(.pause)
        await eventually("paused") { engine.calls.contains(.pause) }
        handler(.togglePlayPause)
        await eventually("playing again") { engine.calls.filter { $0 == .play }.count >= 2 }
        handler(.changePosition(30))
        await eventually("seek to 30 s") { engine.calls.contains { if case .seek(let request) = $0 { request.target == .seconds(30) } else { false } } }
        handler(.nextTrack)
        await eventually("next episode opened") { engines.all.count == 2 }
        guard case .open(let opened)? = engines.all.last?.calls.first else {
            Issue.record("the second engine did not open a file")
            return
        }
        #expect(opened.lastPathComponent == second.lastPathComponent)
    }
}

@Suite struct PictureInPictureTests {
    @Test func playbackDelegateMapsToThePlayerWithoutStartingPiP() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let engines = EngineList()
        let model = makeAppModel(engines: engines)
        await model.open(try scratch.makeFile("movie.mkv"))
        await eventually("playing") { model.playbackState == .playing }
        let engine = try #require(engines.all.first)
        let pip = PictureInPicture(model: model, log: .disabled)
        #expect(!pip.isActive, "no controller exists until the user asks")

        pip.refresh()
        #expect(pip.currentSnapshot.duration == 600)
        #expect(!pip.currentSnapshot.isPaused)
        #expect(PictureInPicture.timeRange(duration: 600) == CMTimeRange(start: .zero, duration: CMTime(seconds: 600, preferredTimescale: 600)))
        #expect(PictureInPicture.timeRange(duration: nil).duration == .positiveInfinity)

        pip.setPlaying(false)
        await eventually("paused") { engine.calls.contains(.pause) }
        #expect(pip.currentSnapshot.isPaused)
        pip.skip(by: 10)
        await eventually("skip seek") { engine.calls.contains { if case .seek = $0 { true } else { false } } }

        var reported: [Bool] = []
        pip.onActiveChange = { reported.append($0) }
        pip.didChange(active: true)
        #expect(model.isPictureInPictureActive)
        pip.didChange(active: false)
        #expect(!model.isPictureInPictureActive)
        #expect(reported == [true, false], "the engine is told to start and stop compositing subtitles")
    }

    @Test func theToggleAsksTheAppOnlyWithAFileOpen() async throws {
        let model = makeAppModel()
        var requests: [Bool] = []
        model.onPictureInPictureRequest = { requests.append($0) }
        model.togglePictureInPicture()
        #expect(requests.isEmpty)
        let scratch = try AppScratch()
        defer { scratch.remove() }
        await model.open(try scratch.makeFile("movie.mkv"))
        await eventually("playing") { model.playbackState == .playing }
        model.togglePictureInPicture()
        #expect(requests == [true])
    }
}
