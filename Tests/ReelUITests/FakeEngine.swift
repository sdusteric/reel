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
    }

    struct Options {
        var duration = MediaTime.seconds(600)
        var frameRate = Rational(24, 1)
        var openError: EngineError?
        /// Answer each exact seek with a `.seekCompleted` that lands on the target.
        var completesExactSeeks = true
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
            streams: [video, audio],
            videoStreamIndex: 0,
            audioStreamIndex: 1,
            videoDecoder: .hardware,
            keyframeCount: 60
        )
    }

    func open(_ url: URL) async throws -> MediaInfo {
        record(.open(url))
        if let error = options.openError {
            continuation.yield(.failed(error))
            throw error
        }
        let info = mediaInfo(for: url)
        continuation.yield(.opened(info))
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

/// Polls `condition` on the main actor until it holds or two seconds pass.
@MainActor
func waitUntil(
    _ description: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + .seconds(2)
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
    let resume = ResumeStore(fileURL: scratch.file("resume.json"))
    let state = StateStore(fileURL: scratch.file("state.json"))
    let dependencies = PlayerModel.Dependencies(
        makeEngine: { _ in engine },
        settings: { settings },
        resumeStore: resume,
        stateStore: state,
        iina: IINAWatchLater(directory: iinaDirectory),
        now: { clock.now },
        sleep: longSleep
    )
    return (PlayerModel(dependencies: dependencies), resume, state)
}

/// Opens `file` and waits until the fake engine's events up to "playing" have been handled, so a
/// test's own injected events cannot race them.
@MainActor
func openAndSettle(_ model: PlayerModel, _ file: URL) async {
    await model.open(file)
    await waitUntil("playing") { model.playbackState == .playing }
}
