import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelUI

/// A `PlayerEngine` that records every command and answers with plausible events. No decoding,
/// no audio, no window.
final class FakeEngine: PlayerEngine {
    enum Call: Equatable {
        case open(URL)
        case play, pause
        case seek(SeekRequest)
        case volume(Double)
        case muted(Bool)
        case timeInterval(Double)
        case close
        // M2
        case audioTrack(Int)
        case videoTrack(Int)
        case subtitle(SubtitleSelection)
        case subtitleDelay(Double)
        case audioDelay(Double)
        case subtitleScale(Double)
        case subtitlePosition(Double)
        case subtitlesVisible(Bool)
        case subtitleAvoidance(Double?)
        case rate(Double)
        case loop(LoopState)
        case thumbnail(MediaTime)
        case subtitleEvents
        // M3
        case occluded(Bool)
        case outputDevice(String?)
        case energyCounters
    }

    struct Options {
        var duration = MediaTime.seconds(600)
        var frameRate = Rational(24, 1)
        var openError: EngineError?
        /// Answer each exact seek with a `.seekCompleted` that lands on the target.
        var completesExactSeeks = true
        /// Extra streams (subtitles, more audio) added after the default video and audio.
        var extraStreams: [StreamInfo] = []
        /// Returned by `thumbnail(at:)` (the last at or before the time).
        var thumbnails: [ThumbnailImage] = []
        /// Returned by `subtitleEvents()`.
        var subtitleEvents: [SubtitleEventTime] = []
        /// Answer track, rate and loop commands with the matching events.
        var echoesM2Commands = true
        /// (M3) Sent after `.opened`; nil sends none.
        var dynamicRange: DynamicRange?
        /// (M3) Added to the opened `MediaInfo`.
        var dolbyVision: DolbyVisionConfig?
        /// (M3) Returned by `energyCounters()`.
        var counters = EnergyCounters.zero
    }

    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let options: Options
    private let log = Mutex<[Call]>([])

    init(options: Options = Options()) {
        self.options = options
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
    }

    var calls: [Call] { log.withLock { $0 } }
    var seeks: [SeekRequest] {
        calls.compactMap { call in
            if case .seek(let request) = call { return request }
            return nil
        }
    }

    /// Sends an event as if the engine produced it.
    func emit(_ event: EngineEvent) {
        continuation.yield(event)
    }

    func mediaInfo(for url: URL) -> MediaInfo {
        let video = StreamInfo(
            index: 0,
            kind: .video,
            codec: "hevc",
            timeBase: Rational(1, 1_000),
            video: VideoParameters(width: 1920, height: 1080, frameRate: options.frameRate, bitDepth: 10)
        )
        let audio = StreamInfo(
            index: 1,
            kind: .audio,
            codec: "ac3",
            timeBase: Rational(1, 1_000),
            audio: AudioParameters(sampleRate: 48_000, channels: 6)
        )
        return MediaInfo(
            url: url,
            formatName: "matroska,webm",
            duration: options.duration,
            streams: [video, audio] + options.extraStreams,
            videoStreamIndex: 0,
            audioStreamIndex: 1,
            videoDecoder: .hardware,
            keyframeCount: 60,
            dolbyVision: options.dolbyVision
        )
    }

    func open(_ url: URL) async throws -> MediaInfo {
        record(.open(url))
        if let error = options.openError {
            continuation.yield(.failed(error))
            throw error
        }
        let info = mediaInfo(for: url)
        let tracks = TrackState(info: info)
        trackState.withLock { $0 = tracks }
        continuation.yield(.opened(info))
        if let range = options.dynamicRange { continuation.yield(.dynamicRange(range)) }
        continuation.yield(.tracksChanged(tracks))
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

    func seek(_ request: SeekRequest) async {
        record(.seek(request))
        guard request.isExact, options.completesExactSeeks else { return }
        continuation.yield(.seekCompleted(SeekReport(
            kind: .exact,
            target: request.target,
            generation: UInt64(seeks.count),
            requestedAtNanos: 0,
            targetMilliseconds: 1,
            landedPTS: request.target
        )))
    }

    func setVolume(_ volume: Double) async { record(.volume(volume)) }
    func setMuted(_ muted: Bool) async { record(.muted(muted)) }
    func setTimeUpdateInterval(_ seconds: Double) async { record(.timeInterval(seconds)) }

    func close() async {
        record(.close)
        continuation.finish()
    }

    // MARK: M2

    /// The track state the fake reports; updated by the M2 commands.
    private let trackState = Mutex<TrackState?>(nil)

    var currentTracks: TrackState? { trackState.withLock { $0 } }

    func selectAudioTrack(_ streamIndex: Int) async {
        record(.audioTrack(streamIndex))
        updateTracks { $0.selectedAudio = streamIndex }
    }

    func selectVideoTrack(_ streamIndex: Int) async {
        record(.videoTrack(streamIndex))
        updateTracks { $0.selectedVideo = streamIndex }
    }

    func selectSubtitle(_ selection: SubtitleSelection) async {
        record(.subtitle(selection))
        updateTracks { state in
            if case .external(let url) = selection, !state.subtitles.contains(where: { $0.id == .external(url) }) {
                state.subtitles.append(SubtitleTrack(id: .external(url), format: SubtitleFormat(fileExtension: url.pathExtension) ?? .srt))
            }
            state.selectedSubtitle = selection
        }
    }

    func setSubtitleDelay(_ seconds: Double) async {
        record(.subtitleDelay(seconds))
        updateTracks { $0.subtitleDelay = seconds }
    }

    func setAudioDelay(_ seconds: Double) async {
        record(.audioDelay(seconds))
        updateTracks { $0.audioDelay = seconds }
    }

    func setSubtitleScale(_ factor: Double) async {
        record(.subtitleScale(factor))
        updateTracks { $0.subtitleScale = factor }
    }

    func setSubtitlePosition(_ percent: Double) async {
        record(.subtitlePosition(percent))
        updateTracks { $0.subtitlePosition = percent }
    }

    func setSubtitlesVisible(_ visible: Bool) async {
        record(.subtitlesVisible(visible))
        updateTracks { $0.subtitlesVisible = visible }
    }

    func setSubtitleAvoidance(bottomInsetPoints: Double?) async {
        record(.subtitleAvoidance(bottomInsetPoints))
    }

    func setRate(_ rate: Double) async {
        record(.rate(rate))
        if options.echoesM2Commands { continuation.yield(.rateChanged(rate)) }
    }

    func setLoop(_ loop: LoopState) async {
        record(.loop(loop))
        if options.echoesM2Commands { continuation.yield(.loopChanged(loop)) }
    }

    func thumbnail(at time: MediaTime) async -> ThumbnailImage? {
        record(.thumbnail(time))
        return options.thumbnails.last { $0.pts <= time }
    }

    func subtitleEvents() async -> [SubtitleEventTime] {
        record(.subtitleEvents)
        return options.subtitleEvents
    }

    // MARK: M3

    func setOccluded(_ occluded: Bool) async { record(.occluded(occluded)) }
    func setOutputDevice(_ uid: String?) async { record(.outputDevice(uid)) }

    func energyCounters() async -> EnergyCounters {
        record(.energyCounters)
        return options.counters
    }

    /// Applies `change` to the track state (built from the last opened file) and emits it.
    private func updateTracks(_ change: (inout TrackState) -> Void) {
        let state = trackState.withLock { stored -> TrackState? in
            guard var state = stored else { return nil }
            change(&state)
            stored = state
            return state
        }
        if let state, options.echoesM2Commands { continuation.yield(.tracksChanged(state)) }
    }

    private func record(_ call: Call) {
        log.withLock { $0.append(call) }
    }
}

/// A monotonic clock in seconds that tests move by hand.
@MainActor
final class TestClock {
    var now: TimeInterval = 1_000

    func advance(by seconds: TimeInterval) {
        now += seconds
    }
}

/// A unique temp directory for one test, removed by its exact path.
struct UIScratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "reel-ui-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name, directoryHint: .notDirectory)
    }

    /// Writes a small file to stand in for a video (only the content key reads it).
    func makeMediaFile(_ name: String, bytes: Int = 4_096) throws -> URL {
        let file = file(name)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: file)
        return file
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("could not remove \(url.path(percentEncoded: false)): \(error)")
        }
    }
}

/// Timers in tests wait an hour, so nothing fires unless the test drives it.
let longSleep: @Sendable (TimeInterval) async -> Void = { _ in
    try? await Task.sleep(for: .seconds(3_600))
}

/// Polls `condition` on the main actor until it holds or 20 seconds pass.
@MainActor
func waitUntil(
    _ description: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    // Only bounds a hang: the condition is checked every 2 ms, and a loaded test run (4K decode
    // suites beside this one) can delay the model's detached open steps by more than a second.
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// Builds a model on a fake engine with stores in `scratch` and IINA carry-over pointed at a
/// fake folder (never IINA's real one).
@MainActor
func makeModel(
    engine: FakeEngine,
    scratch: UIScratch,
    clock: TestClock = TestClock(),
    settings: Settings = Settings(),
    iinaDirectory: URL? = nil
) -> (PlayerModel, ResumeStore, StateStore) {
    makeModel(engineFactory: { _ in engine }, scratch: scratch, clock: clock, settings: settings, iinaDirectory: iinaDirectory)
}

/// Like `makeModel(engine:)` with a new engine per opened file, as the app has (a closed fake
/// engine finishes its event stream), and the folder scan of `EpisodeList.scan` over `scratch`.
@MainActor
func makeModel(
    engineFactory: @escaping @Sendable (URL) -> FakeEngine,
    scratch: UIScratch,
    clock: TestClock = TestClock(),
    settings: Settings = Settings(),
    iinaDirectory: URL? = nil,
    sleep: @escaping @Sendable (TimeInterval) async -> Void = longSleep
) -> (PlayerModel, ResumeStore, StateStore) {
    let resume = ResumeStore(fileURL: scratch.file("resume.json"))
    let state = StateStore(fileURL: scratch.file("state.json"))
    let dependencies = PlayerModel.Dependencies(
        makeEngine: { engineFactory($0) },
        settings: { settings },
        resumeStore: resume,
        stateStore: state,
        iina: IINAWatchLater(directory: iinaDirectory),
        episodeList: { url in try? EpisodeList.scan(current: url) },
        now: { clock.now },
        sleep: sleep
    )
    return (PlayerModel(dependencies: dependencies), resume, state)
}

/// Hands out one `FakeEngine` per opened file and remembers them in order.
final class EngineBox: @unchecked Sendable {
    // Used from the main actor in tests and from the model's open path, one call at a time.
    private let lock = NSLock()
    private var engines: [FakeEngine] = []
    private let options: @Sendable (URL) -> FakeEngine.Options

    init(options: @escaping @Sendable (URL) -> FakeEngine.Options = { _ in FakeEngine.Options() }) {
        self.options = options
    }

    func make(_ url: URL) -> FakeEngine {
        let engine = FakeEngine(options: options(url))
        lock.withLock { engines.append(engine) }
        return engine
    }

    var all: [FakeEngine] { lock.withLock { engines } }
}

/// Opens `file` and waits until the fake engine's events up to "playing" have been handled, so a
/// test's own injected events cannot race them.
@MainActor
func openAndSettle(_ model: PlayerModel, _ file: URL) async {
    await model.open(file)
    await waitUntil("playing") { model.playbackState == .playing }
}
