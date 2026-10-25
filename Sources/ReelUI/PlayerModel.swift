import CoreGraphics
import Foundation
import Observation
import ReelCore

/// A message in the top-left OSD (design section 9.5).
public struct OSDMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case volume, mute, seek, frameStep, resume
        // M2
        case speed, subtitleDelay, audioDelay, subtitleSize, subtitlePosition, track, loop, fileLoop
        case screenshot, episode
    }

    public var kind: Kind
    public var text: String
    /// The resume OSD carries a "Start Over" button.
    public var showsStartOver: Bool
    /// The screenshot OSD carries a "Show" button that reveals the file.
    public var showsReveal: Bool
    /// An SF Symbol name; nil uses the kind's own.
    public var symbol: String?

    public init(
        kind: Kind,
        text: String,
        showsStartOver: Bool = false,
        showsReveal: Bool = false,
        symbol: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.showsStartOver = showsStartOver
        self.showsReveal = showsReveal
        self.symbol = symbol
    }
}

/// Where the user asked for a seek from; keyboard seeks show the time in the OSD.
public enum SeekSource: Sendable {
    case keyboard, pointer, resume
}

/// Commands to the engine, run one at a time in the order they were issued.
enum EngineCommand: Sendable {
    case play, pause
    case seek(SeekRequest)
    case volume(Double)
    case muted(Bool)
    case timeInterval(Double)
    /// Any other engine command, kept in the same order as the rest.
    case run(@Sendable (any PlayerEngine) async -> Void)
    case barrier(CheckedContinuation<Void, Never>)
}

/// One open engine: its serial command queue and its event loop.
final class EngineSession {
    let engine: any PlayerEngine
    private let continuation: AsyncStream<EngineCommand>.Continuation
    private var consumer: Task<Void, Never>?
    private var eventLoop: Task<Void, Never>?

    init(engine: any PlayerEngine, onEvent: @escaping (EngineEvent) -> Void) {
        self.engine = engine
        let (stream, continuation) = AsyncStream.makeStream(of: EngineCommand.self)
        self.continuation = continuation
        consumer = Task {
            for await command in stream {
                await EngineSession.run(command, on: engine)
            }
        }
        eventLoop = Task {
            for await event in engine.events {
                onEvent(event)
            }
        }
    }

    func send(_ command: EngineCommand) {
        continuation.yield(command)
    }

    /// Returns once every command sent before it has been handed to the engine.
    func barrier() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            if case .terminated = continuation.yield(.barrier(waiter)) {
                waiter.resume()
            }
        }
    }

    func close() async {
        continuation.finish()
        await consumer?.value
        await engine.close()
        eventLoop?.cancel()
    }

    private static func run(_ command: EngineCommand, on engine: any PlayerEngine) async {
        switch command {
        case .play: await engine.play()
        case .pause: await engine.pause()
        case .seek(let request): await engine.seek(request)
        case .volume(let volume): await engine.setVolume(volume)
        case .muted(let muted): await engine.setMuted(muted)
        case .timeInterval(let seconds): await engine.setTimeUpdateInterval(seconds)
        case .run(let body): await body(engine)
        case .barrier(let waiter): waiter.resume()
        }
    }
}

/// The player's UI state and the commands the window, keyboard and controller send
/// (design sections 7.5, 9 and 11). Talks to the engine only through `PlayerEngine`.
@Observable
public final class PlayerModel {
    public struct Dependencies {
        /// Returns a fresh engine for a file, with its outputs attached and not yet opened. The app
        /// builds a `PlaybackEngine` on its display layer; tests pass a fake.
        public var makeEngine: (URL) async -> any PlayerEngine
        public var settings: () -> Settings
        public var resumeStore: ResumeStore?
        public var stateStore: StateStore?
        public var iina: IINAWatchLater
        public var contentKey: @Sendable (URL) throws -> ContentKey
        public var log: ReelLog
        /// The playable files in the open file's folder (design 9.8). Runs off the main actor; nil
        /// when the folder cannot be read. The app supplies `EpisodeList.scan`; tests pass a list
        /// built from fake URLs.
        public var episodeList: @Sendable (URL) -> EpisodeList?
        /// A frame about 30 s into a file, for the next-episode card (D39). Nil shows a plain tile.
        public var episodeThumbnail: @Sendable (URL) async -> CGImage?
        /// The wall clock, for "Ends at 22:47" in fullscreen.
        public var wallClock: () -> Date
        /// Monotonic seconds.
        public var now: () -> TimeInterval
        /// How timers wait (OSD hide, seek progress ring, drag rest). Tests pass a long sleep.
        public var sleep: (TimeInterval) async -> Void

        public init(
            makeEngine: @escaping (URL) async -> any PlayerEngine,
            settings: @escaping () -> Settings = { Settings() },
            resumeStore: ResumeStore? = nil,
            stateStore: StateStore? = nil,
            iina: IINAWatchLater = IINAWatchLater(directory: nil),
            contentKey: @escaping @Sendable (URL) throws -> ContentKey = { try ContentKey(contentsOf: $0) },
            log: ReelLog = .disabled,
            episodeList: @escaping @Sendable (URL) -> EpisodeList? = { _ in nil },
            episodeThumbnail: @escaping @Sendable (URL) async -> CGImage? = { _ in nil },
            wallClock: @escaping () -> Date = { Date() },
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            sleep: @escaping (TimeInterval) async -> Void = { seconds in
                try? await Task.sleep(for: .seconds(seconds))
            }
        ) {
            self.makeEngine = makeEngine
            self.settings = settings
            self.resumeStore = resumeStore
            self.stateStore = stateStore
            self.iina = iina
            self.contentKey = contentKey
            self.log = log
            self.episodeList = episodeList
            self.episodeThumbnail = episodeThumbnail
            self.wallClock = wallClock
            self.now = now
            self.sleep = sleep
        }
    }

    // MARK: Timing constants (design 7.5, 9.5, 11.2)

    public static let keyboardSeekStep: Double = 5
    public static let buttonSeekStep: Double = 10
    public static let osdHoldDuration: TimeInterval = 0.9
    public static let resumeOSDDuration: TimeInterval = 5
    public static let seekProgressDelay: TimeInterval = 0.4
    public static let pendingSeekTimeout: TimeInterval = 5
    public static let dragRestDelay: TimeInterval = 0.15
    public static let periodicSaveInterval: TimeInterval = 5
    public static let visibleTimeInterval: Double = 0.1
    public static let hiddenTimeInterval: Double = 1
    /// How long the screenshot OSD keeps its Show button.
    public static let screenshotOSDDuration: TimeInterval = 3
    /// Files tried when the next episode cannot be opened (design 9.8).
    public static let episodeSkipLimit = 3
    /// The most thumbnails kept decoded for the hover pill.
    static let thumbnailCacheLimit = 64

    // MARK: State

    public internal(set) var playbackState: PlaybackState = .idle
    public internal(set) var media: MediaInfo?
    /// The title shown in the title bar area. Set as soon as a file starts opening.
    public internal(set) var title: String?
    /// The playhead the UI shows. Moves at once on seek input, before any decode.
    public internal(set) var position: MediaTime = .zero
    public internal(set) var storedRange: ClosedRange<MediaTime>?
    /// 0 to 100 on the mpv scale.
    public internal(set) var volume: Double = VolumeCurve.firstRunVolume
    public internal(set) var isMuted = false
    public internal(set) var showRemainingTime = true
    /// Play intent: flips on input at once, then follows the engine's state.
    public internal(set) var isPlaying = false
    public internal(set) var isScrubbing = false
    /// Pointer position over the seek bar as a fraction of its width, for the hover pill.
    public internal(set) var seekHoverFraction: Double?
    public internal(set) var osd: OSDMessage?
    /// An exact seek has not landed after 400 ms: the OSD shows a progress ring.
    public internal(set) var showsSeekProgress = false
    /// The saved position this file resumed from, marked on the seek bar.
    public internal(set) var resumeMarker: MediaTime?
    public internal(set) var errorMessage: String?
    public internal(set) var controllerCenterX = RememberedState.defaultControllerCenterX
    public internal(set) var controllerBottomY = RememberedState.defaultControllerBottomY

    // M2 state (design sections 8, 9.3 to 9.12)

    /// The track lists and selections the engine last reported.
    public internal(set) var tracks: TrackState?
    /// The playback rate in force; it carries across files in a session and resets on launch (D45).
    public internal(set) var rate: Double = 1
    public internal(set) var loop: LoopState = .off
    public internal(set) var subtitleDelay: Double = 0
    public internal(set) var audioDelay: Double = 0
    /// Size and position of text subtitles; the size is remembered across launches.
    public internal(set) var subtitleStyle = SubtitleStyle()
    public internal(set) var thumbnailProgress: ThumbnailProgress?
    /// The files next to the open one, in natural order. Nil until scanned or when unreadable.
    public internal(set) var episodes: EpisodeList?
    /// The panel open above the controller, if any.
    public internal(set) var activePanel: ControllerPanel?
    /// The keyboard-highlighted row of the open track panel.
    public internal(set) var panelHighlight: Int?
    /// The thumbnail under the seek bar's pointer; nil shows the time pill alone.
    public internal(set) var hoverThumbnail: CGImage?
    public internal(set) var isPictureInPictureActive = false
    /// The frame from when Picture in Picture started, for the window's placeholder.
    public internal(set) var pictureInPictureSnapshot: CGImage?
    public internal(set) var isFullscreen = false
    /// The Playback menu's "Auto-Advance to Next Episode".
    public internal(set) var autoAdvanceEnabled = true

    public let chrome: ChromeVisibility
    /// The end-of-episode countdown and its card.
    public let autoAdvance: AutoAdvance

    /// Called when the play intent changes (the app holds a display sleep assertion while true).
    @ObservationIgnored public var onPlayingChange: ((Bool) -> Void)?
    /// Called when the chrome shows or hides (the app fades the traffic lights and cursor).
    @ObservationIgnored public var onChromeVisibilityChange: ((Bool) -> Void)?
    /// Called once a file has opened, with its info (the app sizes the window).
    @ObservationIgnored public var onOpened: ((MediaInfo) -> Void)?
    /// Asks the app to enter or leave Picture in Picture (`true` enters).
    @ObservationIgnored public var onPictureInPictureRequest: ((Bool) -> Void)?
    /// Asks the app for an Open panel for a subtitle file (Add Subtitle File).
    @ObservationIgnored public var onAddSubtitleFile: (() -> Void)?
    /// Reveals a saved screenshot in Finder.
    @ObservationIgnored public var onRevealScreenshot: ((URL) -> Void)?

    @ObservationIgnored let dependencies: Dependencies
    @ObservationIgnored private(set) var session: EngineSession?
    @ObservationIgnored private(set) var contentKey: ContentKey?
    @ObservationIgnored private var pendingExact: MediaTime?
    @ObservationIgnored private var pendingExactToken: UInt64 = 0
    @ObservationIgnored private var lastScrubTarget: MediaTime?
    @ObservationIgnored private var restExactTarget: MediaTime?
    @ObservationIgnored private var restTask: Task<Void, Never>?
    @ObservationIgnored private var osdTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var lastPeriodicSave: TimeInterval = 0
    @ObservationIgnored private var openToken: UInt64 = 0
    @ObservationIgnored var pendingChoices: PendingChoices?
    @ObservationIgnored var userEdits = ResumeChoices.empty
    @ObservationIgnored var chosenAudio: TrackIdentity?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailImages: [Int64: CGImage] = [:]
    @ObservationIgnored private var avoidanceTask: Task<Void, Never>?
    @ObservationIgnored private var lastAvoidance: Double?
    @ObservationIgnored private var lastScreenshot: URL?

    public init(dependencies: Dependencies, chrome: ChromeVisibility? = nil) {
        self.dependencies = dependencies
        self.chrome = chrome ?? ChromeVisibility(now: dependencies.now, sleep: dependencies.sleep)
        autoAdvance = AutoAdvance(now: dependencies.now, sleep: dependencies.sleep)
        if let state = dependencies.stateStore?.state {
            volume = state.volume
            showRemainingTime = state.showRemainingTime
            controllerCenterX = state.controllerCenterX
            controllerBottomY = state.controllerBottomY
            subtitleStyle = SubtitleStyle(size: state.subtitleSize)
            autoAdvanceEnabled = state.autoAdvance
        } else {
            showRemainingTime = dependencies.settings().showRemainingTime
        }
        self.chrome.onChange = { [weak self] visible in
            self?.chromeVisibilityChanged(visible)
        }
        autoAdvance.onStart = { [weak self] _ in
            guard let self else { return }
            Task { await self.playNextEpisode() }
        }
    }

    // MARK: Derived

    public var hasMedia: Bool { media != nil }
    public var duration: MediaTime? { media?.duration }

    public var playedFraction: Double {
        guard let duration, duration > .zero else { return 0 }
        return min(max(position.seconds / duration.seconds, 0), 1)
    }

    public var elapsedLabel: String { TimeFormat.elapsed(position, duration: duration) }

    /// `-12:34` or the total, by the remembered toggle.
    public var trailingLabel: String {
        if showRemainingTime { return TimeFormat.remaining(position, duration: duration) }
        guard let duration else { return "--:--" }
        return TimeFormat.clock(duration, duration: duration)
    }

    public func time(atFraction fraction: Double) -> MediaTime {
        guard let duration, duration > .zero else { return .zero }
        let clamped = min(max(fraction, 0), 1)
        return MediaTime(microseconds: Int64((Double(duration.microseconds) * clamped).rounded()))
    }

    public func fraction(of time: MediaTime) -> Double {
        guard let duration, duration > .zero else { return 0 }
        return min(max(time.seconds / duration.seconds, 0), 1)
    }

    // MARK: Open and close

    /// What `open(_:carry:)` ended with.
    enum OpenResult {
        case opened, failed, superseded
    }

    /// Opens `url`, replacing the current file. Resumes from a saved position when the setting
    /// is on, then plays.
    public func open(_ url: URL) async {
        _ = await open(url, carry: nil)
    }

    /// `carry` is the previous episode's choices (design 9.8, D40); a resume entry with its own
    /// choices wins over it.
    func open(_ url: URL, carry: PendingChoices?) async -> OpenResult {
        openToken &+= 1
        let token = openToken
        await closeSession(saving: true)
        resetForNewFile()
        title = url.lastPathComponent
        playbackState = .opening
        let engine = await dependencies.makeEngine(url)
        guard token == openToken else {
            await engine.close()
            return .superseded
        }
        let session = EngineSession(engine: engine) { [weak self] event in
            self?.handle(event)
        }
        self.session = session

        let scanEpisodes = dependencies.episodeList
        let episodeScan = Task.detached { scanEpisodes(url) }
        let keyFunction = dependencies.contentKey
        let keyResult = await Task.detached { Result { try keyFunction(url) } }.value
        guard token == openToken else { return .superseded }
        switch keyResult {
        case .success(let key): contentKey = key
        case .failure(let error): dependencies.log.error("content key for \(url.lastPathComponent): \(error)")
        }
        if let key = contentKey, let entry = dependencies.resumeStore?.entry(for: key), !entry.choices.isEmpty {
            userEdits = entry.choices
            pendingChoices = PendingChoices(choices: entry.choices, audio: nil, sameFile: true)
        } else {
            pendingChoices = carry
        }

        let info: MediaInfo
        do {
            info = try await session.engine.open(url)
        } catch {
            guard token == openToken else { return .superseded }
            dependencies.log.error("open \(url.lastPathComponent) failed: \(error)")
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            playbackState = .failed
            await closeSession(saving: false)
            return .failed
        }
        guard token == openToken else { return .superseded }
        apply(info)
        if playbackState == .opening { playbackState = .ready }
        session.send(.volume(volume))
        session.send(.muted(isMuted))
        session.send(.timeInterval(chrome.isVisible ? PlayerModel.visibleTimeInterval : PlayerModel.hiddenTimeInterval))
        if !PlaybackSpeed.isNormal(rate) {
            let rate = rate
            session.send(.run { await $0.setRate(rate) })
        }
        if subtitleStyle.size != SubtitleStyle.baseSize {
            let scale = subtitleStyle.scale
            session.send(.run { await $0.setSubtitleScale(scale) })
        }
        if let resume = resumePosition(for: url, duration: info.duration) {
            resumeMarker = resume
            requestExact(resume, source: .resume)
            showOSD(OSDMessage(
                kind: .resume,
                text: "Resumed at \(TimeFormat.clock(resume, duration: resume))",
                showsStartOver: true
            ), hold: PlayerModel.resumeOSDDuration)
        }
        play()
        onOpened?(info)
        let scanned = await episodeScan.value
        guard token == openToken else { return .superseded }
        episodes = scanned
        // A very short file can end before the folder scan returns.
        if playbackState == .ended, !autoAdvance.isActive { beginAutoAdvanceIfPossible() }
        return .opened
    }

    /// Closes the file and returns to the empty state, saving the resume position.
    public func close() async {
        openToken &+= 1
        await closeSession(saving: true)
        resetForNewFile()
        episodes = nil
        playbackState = .idle
        title = nil
        chrome.setPlaying(false)
    }

    /// Saves everything synchronously (quit and `applicationWillTerminate`).
    public func saveForTermination() {
        saveResume(flush: true)
        flushState()
    }

    /// Saves, then stops the engine. Call before quitting.
    public func shutdown() async {
        saveForTermination()
        await closeSession(saving: false)
    }

    // MARK: Playback

    public func togglePause() {
        guard hasMedia else { return }
        if isPlaying { pause() } else { play() }
    }

    public func play() {
        guard hasMedia, let session else { return }
        autoAdvance.cancel()
        if playbackState == .ended {
            requestExact(.zero, source: .pointer)
        }
        setPlayIntent(true)
        session.send(.play)
    }

    public func pause() {
        guard hasMedia, let session else { return }
        setPlayIntent(false)
        session.send(.pause)
        saveResume(flush: true)
    }

    // MARK: Seeking

    /// Relative exact seek (arrow keys, the back and forward buttons, Shift+PgUp/PgDn).
    public func seek(by seconds: Double, source: SeekSource = .keyboard) {
        guard hasMedia else { return }
        let base = pendingExact ?? position
        seek(to: base + .seconds(seconds), source: source)
    }

    /// Exact seek to an absolute time (seek bar click, release, keyboard).
    public func seek(to time: MediaTime, source: SeekSource = .pointer) {
        guard hasMedia else { return }
        requestExact(time, source: source)
        if source == .keyboard {
            showOSD(OSDMessage(kind: .seek, text: TimeFormat.positionOverTotal(position, duration: duration)))
        }
    }

    /// A keyframe preview while dragging the seek bar or scrolling. Moves the thumb at once.
    public func scrub(to time: MediaTime) {
        guard hasMedia, let session else { return }
        let target = clamp(time)
        if !isScrubbing {
            isScrubbing = true
            chrome.setDragging(true)
            restExactTarget = nil
        }
        position = target
        lastScrubTarget = target
        session.send(.seek(.scrub(target)))
        scheduleRestExact(for: target)
    }

    /// Ends a drag or scroll gesture with one exact seek, unless the drag rested at this spot
    /// long enough that the exact seek already started.
    public func endScrub(at time: MediaTime) {
        guard hasMedia else { return }
        let target = clamp(time)
        restTask?.cancel()
        restTask = nil
        let alreadySent = restExactTarget == target
        isScrubbing = false
        chrome.setDragging(false)
        lastScrubTarget = nil
        restExactTarget = nil
        if alreadySent {
            position = target
        } else {
            requestExact(target, source: .pointer)
        }
    }

    /// `.` and `,`: one frame forward or back, pausing first like mpv.
    public func frameStep(forward: Bool) {
        guard hasMedia else { return }
        if isPlaying { pause() }
        let step = media?.videoStream?.video?.frameDuration ?? .microseconds(33_333)
        let base = pendingExact ?? position
        requestExact(forward ? base + step : base - step, source: .keyboard)
        showOSD(OSDMessage(kind: .frameStep, text: TimeFormat.positionOverTotal(position, duration: duration)))
    }

    /// The resume OSD's Start Over button: back to the beginning and forget the saved position.
    public func startOver() {
        guard hasMedia else { return }
        resumeMarker = nil
        osdTask?.cancel()
        osd = nil
        if let key = contentKey, let store = dependencies.resumeStore {
            do {
                try store.remove(key: key)
            } catch {
                dependencies.log.error("resume remove failed: \(error)")
            }
        }
        requestExact(.zero, source: .pointer)
    }

    // MARK: Volume

    public func adjustVolume(by delta: Double) {
        setVolume(volume + delta)
    }

    public func setVolume(_ value: Double, showOSD shows: Bool = true) {
        let clamped = min(max(value.isFinite ? value : volume, 0), 100)
        volume = clamped
        session?.send(.volume(clamped))
        persistState { $0.volume = clamped }
        if shows {
            showOSD(OSDMessage(kind: .volume, text: "Volume \(Int(clamped.rounded()))"))
        }
    }

    public func toggleMute() {
        isMuted.toggle()
        session?.send(.muted(isMuted))
        showOSD(OSDMessage(kind: .mute, text: isMuted ? "Muted" : "Volume \(Int(volume.rounded()))"))
    }

    // MARK: Controller

    /// Clicking the right-hand time label toggles remaining and total; remembered.
    public func toggleRemainingTime() {
        setShowRemainingTime(!showRemainingTime)
    }

    public func setShowRemainingTime(_ value: Bool) {
        showRemainingTime = value
        persistState { $0.showRemainingTime = value }
    }

    /// Stores the controller position as fractions of the window (centre x, bottom y).
    public func moveController(centerX: Double, bottomY: Double) {
        controllerCenterX = min(max(centerX, 0), 1)
        controllerBottomY = min(max(bottomY, 0), 1)
        persistState {
            $0.controllerCenterX = centerX
            $0.controllerBottomY = bottomY
        }
    }

    public func resetControllerPosition() {
        moveController(centerX: RememberedState.defaultControllerCenterX, bottomY: RememberedState.defaultControllerBottomY)
    }

    public func setSeekHover(_ fraction: Double?) {
        seekHoverFraction = fraction.map { min(max($0, 0), 1) }
        refreshHoverThumbnail()
    }

    // MARK: Engine events

    public func handle(_ event: EngineEvent) {
        switch event {
        case .stateChanged(let state):
            playbackState = state
            switch state {
            case .playing:
                autoAdvance.cancel()
                setPlayIntent(true)
            case .paused, .ended, .failed, .idle: setPlayIntent(false)
            case .opening, .ready, .seeking:
                // Transitional: the play intent the user set stays until the engine settles.
                return
            }
        case .opened(let info):
            apply(info)
        case .time(let time):
            if !isScrubbing, pendingExact == nil {
                position = clamp(time)
            }
            if isPlaying, dependencies.now() - lastPeriodicSave >= PlayerModel.periodicSaveInterval {
                lastPeriodicSave = dependencies.now()
                saveResume(flush: false)
            }
        case .seekCompleted(let report):
            guard report.kind == .exact, !report.cancelled else { return }
            if pendingExact != nil {
                pendingExact = nil
                showsSeekProgress = false
                progressTask?.cancel()
                if !isScrubbing {
                    position = clamp(report.landedPTS ?? report.target)
                }
            }
            saveResume(flush: false)
        case .storedRange(let range):
            storedRange = range
        case .decoderChanged(let kind, let reason):
            dependencies.log.info("video decoder now \(kind.rawValue): \(reason)")
        case .tracksChanged(let state):
            tracks = state
            if let pending = pendingChoices {
                pendingChoices = nil
                applyPending(pending, to: state)
            }
        case .rateChanged(let value):
            rate = value
        case .loopChanged(let state):
            loop = state
        case .thumbnailsProgress(let done, let total):
            thumbnailProgress = ThumbnailProgress(done: done, total: total)
        case .subtitleTrackFailed(let id, let reason):
            dependencies.log.error("subtitle track \(id) failed: \(reason)")
            if let index = tracks?.subtitles.firstIndex(where: { $0.id == id }) {
                tracks?.subtitles[index].unsupportedReason = reason
            }
        case .ended:
            playbackState = .ended
            setPlayIntent(false)
            if let duration { position = duration }
            saveResume(flush: true)
            beginAutoAdvanceIfPossible()
        case .failed(let error):
            dependencies.log.error("engine failed: \(error)")
            errorMessage = error.errorDescription
            playbackState = .failed
            setPlayIntent(false)
        }
    }

    // MARK: Resume

    /// Records the position (debounced to one write per second); `flush` writes now.
    public func saveResume(flush: Bool) {
        guard let key = contentKey, let media, let duration = media.duration,
              let store = dependencies.resumeStore, dependencies.settings().resumePlayback else { return }
        do {
            try store.record(
                key: key,
                position: pendingExact ?? position,
                duration: duration,
                audioStreamIndex: media.audioStreamIndex,
                choices: userEdits.isEmpty ? nil : userEdits,
                path: media.url.path(percentEncoded: false)
            )
            if flush { try store.flush() }
        } catch {
            dependencies.log.error("resume save failed: \(error)")
        }
    }

    func resumePosition(for url: URL, duration: MediaTime?) -> MediaTime? {
        guard dependencies.settings().resumePlayback else { return nil }
        var candidate: MediaTime?
        if let key = contentKey, let entry = dependencies.resumeStore?.entry(for: key) {
            candidate = entry.position
        } else {
            do {
                candidate = try dependencies.iina.startPosition(forFileAt: url)
            } catch {
                dependencies.log.error("IINA watch_later read failed: \(error)")
            }
        }
        guard let candidate, candidate >= ResumeStore.minimumPosition else { return nil }
        if let duration, duration > .zero, duration - candidate < ResumeStore.finishedMargin { return nil }
        return candidate
    }

    // MARK: Tests and shots

    /// Waits until every command issued so far has reached the engine.
    public func waitForEngineCommands() async {
        await session?.barrier()
    }

    // MARK: Private

    private func apply(_ info: MediaInfo) {
        media = info
        title = info.title
        errorMessage = nil
    }

    private func resetForNewFile() {
        media = nil
        contentKey = nil
        position = .zero
        storedRange = nil
        isScrubbing = false
        seekHoverFraction = nil
        osdTask?.cancel()
        osd = nil
        progressTask?.cancel()
        restTask?.cancel()
        showsSeekProgress = false
        pendingExact = nil
        resumeMarker = nil
        errorMessage = nil
        lastScrubTarget = nil
        restExactTarget = nil
        setPlayIntent(false)
        resetTrackState()
    }

    private func closeSession(saving: Bool) async {
        guard let session else { return }
        if saving { saveResume(flush: true) }
        self.session = nil
        await session.close()
    }

    private func setPlayIntent(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        chrome.setPlaying(playing)
        onPlayingChange?(playing)
    }

    private func clamp(_ time: MediaTime) -> MediaTime {
        var result = max(time, .zero)
        if let duration, duration > .zero { result = min(result, duration) }
        return result
    }

    private func requestExact(_ time: MediaTime, source: SeekSource) {
        guard let session else { return }
        autoAdvance.cancel()
        let target = clamp(time)
        position = target
        pendingExact = target
        pendingExactToken &+= 1
        let token = pendingExactToken
        showsSeekProgress = false
        session.send(.seek(.exact(target)))
        if source == .keyboard { chrome.playbackKeyPressed() }
        progressTask?.cancel()
        let sleep = dependencies.sleep
        progressTask = Task { [weak self] in
            await sleep(PlayerModel.seekProgressDelay)
            guard !Task.isCancelled, let self, self.pendingExactToken == token, self.pendingExact != nil else { return }
            self.showsSeekProgress = true
            await sleep(PlayerModel.pendingSeekTimeout - PlayerModel.seekProgressDelay)
            guard !Task.isCancelled, self.pendingExactToken == token else { return }
            // The engine never confirmed this seek; let clock updates move the bar again.
            self.pendingExact = nil
            self.showsSeekProgress = false
        }
    }

    private func scheduleRestExact(for target: MediaTime) {
        restTask?.cancel()
        let sleep = dependencies.sleep
        restTask = Task { [weak self] in
            await sleep(PlayerModel.dragRestDelay)
            guard !Task.isCancelled, let self, self.isScrubbing, self.lastScrubTarget == target,
                  self.restExactTarget != target, let session = self.session else { return }
            self.restExactTarget = target
            session.send(.seek(.exact(target)))
        }
    }

    /// Shows or updates the OSD. An update while visible changes the text in place.
    func showOSD(_ message: OSDMessage, hold: TimeInterval = PlayerModel.osdHoldDuration) {
        osd = message
        osdTask?.cancel()
        let sleep = dependencies.sleep
        osdTask = Task { [weak self] in
            await sleep(hold)
            guard !Task.isCancelled else { return }
            self?.osd = nil
        }
    }

    private func chromeVisibilityChanged(_ visible: Bool) {
        session?.send(.timeInterval(visible ? PlayerModel.visibleTimeInterval : PlayerModel.hiddenTimeInterval))
        onChromeVisibilityChange?(visible)
    }

    private func persistState(_ change: (inout RememberedState) -> Void) {
        guard let store = dependencies.stateStore else { return }
        do {
            try store.update(change)
        } catch {
            dependencies.log.error("state save failed: \(error)")
        }
    }

    private func flushState() {
        guard let store = dependencies.stateStore else { return }
        do {
            try store.flush()
        } catch {
            dependencies.log.error("state save failed: \(error)")
        }
    }
}

/// Choices to apply once the next file's tracks are known: the previous episode's (design 9.8,
/// D40) or the ones saved with its own resume entry.
struct PendingChoices: Equatable {
    var choices: ResumeChoices
    var audio: TrackIdentity?
    /// The choices were saved for this very file, so stream indices can be trusted.
    var sameFile: Bool
}

/// Background thumbnail generation progress.
public struct ThumbnailProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

// MARK: M2 commands and state (design sections 8, 9.3 to 9.12)

extension PlayerModel {
    // MARK: Derived

    /// Previous and next show only when the file has neighbours (D28); they are disabled at the ends.
    public var showsEpisodeButtons: Bool {
        guard let episodes else { return false }
        return !episodes.isAlone && episodes.currentIndex != nil
    }

    public var hasNextEpisode: Bool { episodes?.next != nil }
    public var hasPreviousEpisode: Bool { episodes?.previous != nil }

    /// `captions.bubble.fill` while a subtitle track is on.
    public var subtitlesAreOn: Bool {
        guard let tracks else { return false }
        return tracks.selectedSubtitle != .off && tracks.subtitlesVisible
    }

    public var subtitleAccessibilityValue: String {
        guard subtitlesAreOn, let track = tracks?.selectedSubtitleTrack else { return "Off" }
        return track.label().title
    }

    public var audioAccessibilityValue: String {
        tracks?.selectedAudioTrack?.label().title ?? ""
    }

    /// "1.5 times".
    public var speedAccessibilityValue: String {
        PlaybackSpeed.label(rate).replacing("\u{00D7}", with: " times")
    }

    /// "Ends at 22:47": the wall-clock end time at the current speed (fullscreen only).
    public var endsAtLabel: String? {
        guard hasMedia, let duration else { return nil }
        let remaining = max(0, (duration - position).seconds) / max(rate, PlaybackSpeed.minimum)
        let end = dependencies.wallClock().addingTimeInterval(remaining)
        return "Ends at " + end.formatted(date: .omitted, time: .shortened)
    }

    /// The rows of the open track panel.
    var panelRows: [TrackRow] {
        switch activePanel {
        case .subtitles?: TrackPanelContent.subtitleRows(tracks)
        case .audio?: TrackPanelContent.audioRows(tracks)
        case .speed?, nil: []
        }
    }

    // MARK: Panels

    public func togglePanel(_ panel: ControllerPanel) {
        if activePanel == panel { closePanel() } else { openPanel(panel) }
    }

    public func openPanel(_ panel: ControllerPanel) {
        guard hasMedia else { return }
        activePanel = panel
        panelHighlight = panelRows.firstIndex(where: \.isSelected)
        chrome.setPanelOpen(true)
    }

    public func closePanel() {
        guard activePanel != nil else { return }
        activePanel = nil
        panelHighlight = nil
        chrome.setPanelOpen(false)
    }

    /// Up and Down move, Return chooses, Esc closes. Returns whether a panel took the key.
    @discardableResult
    public func handlePanelKey(_ key: PanelKey) -> Bool {
        guard let panel = activePanel else { return false }
        switch key {
        case .escape:
            closePanel()
        case .up, .down:
            let delta = key == .down ? 1 : -1
            if panel == .speed {
                stepSpeed(by: -delta)
            } else {
                moveHighlight(by: delta)
            }
        case .confirm:
            if panel == .speed {
                closePanel()
            } else if let index = panelHighlight, panelRows.indices.contains(index) {
                choose(panelRows[index])
            }
        }
        return true
    }

    private func moveHighlight(by delta: Int) {
        let rows = panelRows
        let enabled = rows.indices.filter { rows[$0].isEnabled }
        guard !enabled.isEmpty else { return }
        let current = panelHighlight.flatMap { enabled.firstIndex(of: $0) }
        let start = current ?? (delta > 0 ? -1 : enabled.count)
        panelHighlight = enabled[min(max(start + delta, 0), enabled.count - 1)]
    }

    /// A row chosen with the pointer or Return; the track panels close on choice.
    func choose(_ row: TrackRow) {
        guard row.isEnabled else { return }
        switch row.choice {
        case .subtitle(let selection): selectSubtitle(selection)
        case .audio(let index): selectAudio(index)
        }
        closePanel()
    }

    // MARK: Tracks

    public func selectSubtitle(_ selection: SubtitleSelection) {
        guard hasMedia else { return }
        setSubtitleSelection(selection)
        if selection != .off, tracks?.subtitlesVisible == false {
            tracks?.subtitlesVisible = true
            send { await $0.setSubtitlesVisible(true) }
        }
    }

    /// Shows an external subtitle file (Add Subtitle File): the engine lists it and selects it.
    public func useSubtitleFile(_ url: URL) {
        selectSubtitle(.external(url))
    }

    /// Asks the app to show its Open panel for a subtitle file.
    public func addSubtitleFile() {
        closePanel()
        onAddSubtitleFile?()
    }

    public func selectAudio(_ streamIndex: Int) {
        guard hasMedia else { return }
        setAudioSelection(streamIndex)
    }

    /// Ctrl+Cmd+S: Off, then each supported track, then Off. The OSD names the choice.
    public func cycleSubtitle() {
        guard hasMedia, let tracks else { return }
        let selection = tracks.nextSubtitleSelection()
        selectSubtitle(selection)
        if let track = self.tracks?.selectedSubtitleTrack, selection != .off {
            showOSD(OSDMessage(
                kind: .track,
                text: "Subtitles: " + TrackPanelContent.shortName(track.label()),
                symbol: "captions.bubble.fill"
            ))
        } else {
            showOSD(OSDMessage(kind: .track, text: "Subtitles Off", symbol: "captions.bubble"))
        }
    }

    /// Ctrl+Cmd+A.
    public func cycleAudio() {
        guard hasMedia, let tracks, let next = tracks.nextAudioStream() else { return }
        setAudioSelection(next)
        if let track = self.tracks?.selectedAudioTrack {
            showOSD(OSDMessage(kind: .track, text: "Audio: " + TrackPanelContent.shortName(track.label()), symbol: "waveform"))
        }
    }

    /// Ctrl+Cmd+V; nothing with fewer than two video tracks.
    public func cycleVideo() {
        guard hasMedia, let tracks, let next = tracks.nextVideoStream() else { return }
        self.tracks?.selectedVideo = next
        send { await $0.selectVideoTrack(next) }
        if let track = tracks.video.first(where: { $0.streamIndex == next }) {
            showOSD(OSDMessage(
                kind: .track,
                text: "Video: \(track.codec.uppercased()) \(track.width)x\(track.height)",
                symbol: "film"
            ))
        }
    }

    public func toggleSubtitlesVisible() {
        guard hasMedia, let tracks else { return }
        let visible = !tracks.subtitlesVisible
        self.tracks?.subtitlesVisible = visible
        send { await $0.setSubtitlesVisible(visible) }
        showOSD(OSDMessage(kind: .track, text: visible ? "Subtitles Shown" : "Subtitles Hidden", symbol: "captions.bubble"))
    }

    /// Shift+Right and Shift+Left: the next or previous subtitle line.
    public func stepSubtitleLine(forward: Bool) async {
        guard let engine = session?.engine else { return }
        let events = await engine.subtitleEvents()
        let time = pendingExact ?? position
        let target = forward
            ? SubtitleLines.next(after: time, in: events)
            : SubtitleLines.previous(before: time, in: events)
        if let target { seek(to: target, source: .keyboard) }
    }

    private func setSubtitleSelection(_ selection: SubtitleSelection) {
        tracks?.selectedSubtitle = selection
        userEdits.subtitle = subtitleChoice(for: selection)
        send { await $0.selectSubtitle(selection) }
    }

    private func setAudioSelection(_ streamIndex: Int) {
        tracks?.selectedAudio = streamIndex
        media?.audioStreamIndex = streamIndex
        chosenAudio = tracks?.audio.first { $0.streamIndex == streamIndex }?.identity
        send { await $0.selectAudioTrack(streamIndex) }
    }

    private func subtitleChoice(for selection: SubtitleSelection) -> SubtitleChoice {
        guard let id = selection.trackID else { return .off }
        if let track = tracks?.subtitles.first(where: { $0.id == id }) { return .track(track.identity) }
        if case .external(let url) = id {
            return .track(TrackIdentity(externalFileName: url.lastPathComponent, codec: SubtitleFormat(fileExtension: url.pathExtension)?.rawValue))
        }
        return .off
    }

    // MARK: Delays, size and position

    /// The panel stepper: 0.1 s per press, `multiplier` 5 for Alt-click. No OSD (the panel shows it).
    public func stepSubtitleDelay(by multiplier: Double) {
        setSubtitleDelay(SubtitleStyle.adjustedDelay(subtitleDelay, by: 0.1 * multiplier), announce: false)
    }

    public func stepAudioDelay(by multiplier: Double) {
        setAudioDelay(SubtitleStyle.adjustedDelay(audioDelay, by: 0.1 * multiplier), announce: false)
    }

    /// Keys: `z`-style adds in seconds, with an OSD.
    public func adjustSubtitleDelay(by seconds: Double) {
        setSubtitleDelay(SubtitleStyle.adjustedDelay(subtitleDelay, by: seconds))
    }

    public func adjustAudioDelay(by seconds: Double) {
        setAudioDelay(SubtitleStyle.adjustedDelay(audioDelay, by: seconds))
    }

    public func setSubtitleDelay(_ seconds: Double, announce: Bool = true) {
        guard hasMedia else { return }
        subtitleDelay = seconds
        userEdits.subtitleDelay = seconds
        send { await $0.setSubtitleDelay(seconds) }
        if announce { showOSD(OSDMessage(kind: .subtitleDelay, text: SubtitleStyle.subtitleDelayOSDText(seconds))) }
    }

    public func setAudioDelay(_ seconds: Double, announce: Bool = true) {
        guard hasMedia else { return }
        audioDelay = seconds
        userEdits.audioDelay = seconds
        send { await $0.setAudioDelay(seconds) }
        if announce { showOSD(OSDMessage(kind: .audioDelay, text: SubtitleStyle.audioDelayOSDText(seconds))) }
    }

    /// One size step on the 45 scale per press (45, 50, 55); remembered for new files.
    public func stepSubtitleSize(by steps: Int, announce: Bool = false) {
        guard steps != 0 else { return }
        subtitleStyle.stepSize(by: steps)
        applyStyleSize(announce: announce)
    }

    /// `add sub-scale 0.1` from input.conf is one step.
    public func adjustSubtitleScale(delta: Double) {
        stepSubtitleSize(by: SubtitleStyle.steps(forScaleDelta: delta), announce: true)
    }

    public func moveSubtitle(by delta: Double) {
        guard hasMedia else { return }
        subtitleStyle.movePosition(by: delta)
        let position = subtitleStyle.position
        userEdits.subtitlePosition = position
        send { await $0.setSubtitlePosition(position) }
        showOSD(OSDMessage(kind: .subtitlePosition, text: subtitleStyle.positionOSDText))
    }

    public func resetSubtitleStyle() {
        guard hasMedia else { return }
        subtitleStyle.reset()
        userEdits.subtitlePosition = nil
        applyStyleSize(announce: false)
        let position = subtitleStyle.position
        send { await $0.setSubtitlePosition(position) }
        showOSD(OSDMessage(kind: .subtitleSize, text: subtitleStyle.sizeOSDText))
    }

    private func applyStyleSize(announce: Bool) {
        let size = subtitleStyle.size
        let scale = subtitleStyle.scale
        userEdits.subtitleSize = size
        persistState { $0.subtitleSize = size }
        send { await $0.setSubtitleScale(scale) }
        if announce { showOSD(OSDMessage(kind: .subtitleSize, text: subtitleStyle.sizeOSDText)) }
    }

    // MARK: Speed

    /// Sets the rate (0.25 to 4). The engine confirms with `.rateChanged`.
    public func setRate(_ value: Double, announce: Bool = false) {
        guard hasMedia else { return }
        let clamped = PlaybackSpeed.clamp(value)
        rate = clamped
        send { await $0.setRate(clamped) }
        if announce { showOSD(OSDMessage(kind: .speed, text: PlaybackSpeed.osdText(clamped))) }
    }

    /// The Fine stepper: 0.05 per press.
    public func stepSpeed(by steps: Int) {
        setRate(PlaybackSpeed.stepped(rate, by: steps))
    }

    public func doubleSpeed() { setRate(PlaybackSpeed.doubled(rate), announce: true) }
    public func halveSpeed() { setRate(PlaybackSpeed.halved(rate), announce: true) }
    public func increaseSpeed() { setRate(PlaybackSpeed.faster(rate), announce: true) }
    public func decreaseSpeed() { setRate(PlaybackSpeed.slower(rate), announce: true) }
    public func resetSpeed() { setRate(PlaybackSpeed.normal, announce: true) }

    // MARK: Loops

    /// Cmd+L: set A, then B, then clear.
    public func toggleABLoop() {
        guard hasMedia else { return }
        var next = loop
        next.toggleABLoop(at: pendingExact ?? position)
        guard next != loop else { return }
        setLoop(next)
        showOSD(OSDMessage(kind: .loop, text: next.abOSDText(duration: duration)))
    }

    /// Shift+Cmd+L.
    public func toggleFileLoop() {
        guard hasMedia else { return }
        var next = loop
        next.toggleFileLoop()
        setLoop(next)
        showOSD(OSDMessage(kind: .fileLoop, text: next.fileLoopOSDText))
    }

    private func setLoop(_ state: LoopState) {
        loop = state
        if !state.allowsAutoAdvance { autoAdvance.cancel() }
        send { await $0.setLoop(state) }
    }

    // MARK: Episodes

    public func playNextEpisode() async {
        await openEpisode(forward: true)
    }

    public func playPreviousEpisode() async {
        await openEpisode(forward: false)
    }

    public func setAutoAdvanceEnabled(_ enabled: Bool) {
        autoAdvanceEnabled = enabled
        persistState { $0.autoAdvance = enabled }
        if !enabled { autoAdvance.cancel() }
    }

    /// Scans the open file's folder again (the app calls this when the folder changes).
    public func refreshEpisodes() async {
        guard let url = media?.url else { return }
        let scan = dependencies.episodeList
        let token = openToken
        let list = await Task.detached { scan(url) }.value
        guard token == openToken else { return }
        episodes = list
    }

    /// Opens the next or previous file with the choices carried over. A file that fails to open
    /// is skipped, up to three, with an OSD naming it.
    private func openEpisode(forward: Bool) async {
        guard let list = episodes, let index = list.currentIndex else { return }
        let limit = PlayerModel.episodeSkipLimit
        let candidates = forward
            ? Array(list.files[(index + 1)...].prefix(limit))
            : Array(list.files[..<index].reversed().prefix(limit))
        guard !candidates.isEmpty else { return }
        autoAdvance.cancel()
        let carry = carriedChoices()
        var skipped: [String] = []
        for url in candidates {
            switch await open(url, carry: carry) {
            case .opened:
                let name = EpisodeList.episodeName(for: url)
                let text = skipped.isEmpty ? name : "Skipped \(skipped.joined(separator: ", ")). Opened \(name)"
                showOSD(OSDMessage(kind: .episode, text: text))
                return
            case .superseded:
                return
            case .failed:
                skipped.append(url.lastPathComponent)
                showOSD(OSDMessage(kind: .episode, text: "Skipped \(skipped.joined(separator: ", "))"))
            }
        }
    }

    /// What the next episode inherits (D40): the subtitle and audio the user chose, changed delays
    /// and position. Speed, size and volume live on the model and carry by themselves.
    func carriedChoices() -> PendingChoices {
        var choices = ResumeChoices()
        choices.subtitle = userEdits.subtitle
        if subtitleDelay != 0 { choices.subtitleDelay = subtitleDelay }
        if audioDelay != 0 { choices.audioDelay = audioDelay }
        choices.subtitlePosition = userEdits.subtitlePosition
        return PendingChoices(choices: choices, audio: chosenAudio, sameFile: false)
    }

    /// At the end of a file: show the card when a next file exists and no loop is set (D49).
    func beginAutoAdvanceIfPossible() {
        guard autoAdvanceEnabled, loop.allowsAutoAdvance, let next = episodes?.next else { return }
        autoAdvance.begin(next: next)
        let provider = dependencies.episodeThumbnail
        Task { [weak self] in
            let image = await provider(next)
            guard let self, self.autoAdvance.isActive, self.autoAdvance.nextURL == next else { return }
            self.autoAdvance.thumbnail = image
        }
    }

    // MARK: Picture in Picture and fullscreen

    /// The controller button, the menu and Ctrl+Cmd+P.
    public func togglePictureInPicture() {
        guard hasMedia else { return }
        onPictureInPictureRequest?(!isPictureInPictureActive)
    }

    /// The app reports the real state, with the frame to blur for the window's placeholder.
    public func setPictureInPicture(active: Bool, snapshot: CGImage? = nil) {
        isPictureInPictureActive = active
        pictureInPictureSnapshot = active ? snapshot : nil
    }

    public func setFullscreen(_ fullscreen: Bool) {
        isFullscreen = fullscreen
    }

    // MARK: Screenshot and messages

    /// The OSD after Cmd+S: "Screenshot Saved" with a Show button for 3 s.
    public func showScreenshotSaved(at url: URL) {
        lastScreenshot = url
        showOSD(
            OSDMessage(kind: .screenshot, text: "Screenshot Saved", showsReveal: true),
            hold: PlayerModel.screenshotOSDDuration
        )
    }

    func revealScreenshot() {
        if let lastScreenshot { onRevealScreenshot?(lastScreenshot) }
    }

    /// Any other message the app wants in the OSD.
    public func postOSD(_ message: OSDMessage, hold: TimeInterval = PlayerModel.osdHoldDuration) {
        showOSD(message, hold: hold)
    }

    // MARK: Subtitle lift (design 8.5, D32)

    /// Works out the lift from the controller and tells the engine. Up at once while the chrome is
    /// visible and overlaps the subtitle band; back down after the chrome has faded out (0.35 s),
    /// or at once when the controller no longer overlaps.
    public func updateSubtitleAvoidance(windowSize: CGSize, controllerFrame: CGRect?) {
        guard hasMedia, session != nil else { return }
        let visible = chrome.isVisible
        let wanted = SubtitleAvoidance.inset(
            style: subtitleStyle,
            windowSize: windowSize,
            controllerFrame: visible ? controllerFrame : nil
        )
        if let wanted {
            avoidanceTask?.cancel()
            avoidanceTask = nil
            sendAvoidance(wanted)
        } else if lastAvoidance != nil {
            if visible {
                avoidanceTask?.cancel()
                avoidanceTask = nil
                sendAvoidance(nil)
            } else if avoidanceTask == nil {
                let sleep = dependencies.sleep
                avoidanceTask = Task { [weak self] in
                    await sleep(ChromeVisibility.fadeOutDuration)
                    guard !Task.isCancelled, let self else { return }
                    self.avoidanceTask = nil
                    self.sendAvoidance(nil)
                }
            }
        }
    }

    private func sendAvoidance(_ inset: Double?) {
        guard inset != lastAvoidance else { return }
        lastAvoidance = inset
        send { await $0.setSubtitleAvoidance(bottomInsetPoints: inset) }
    }

    // MARK: Thumbnails (design 9.4)

    func refreshHoverThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        guard let fraction = seekHoverFraction, let engine = session?.engine, hasMedia else {
            hoverThumbnail = nil
            return
        }
        let time = self.time(atFraction: fraction)
        thumbnailTask = Task { [weak self] in
            let image = await engine.thumbnail(at: time)
            guard !Task.isCancelled, let self else { return }
            self.hoverThumbnail = image.flatMap { self.decodedThumbnail($0) }
        }
    }

    private func decodedThumbnail(_ image: ThumbnailImage) -> CGImage? {
        let key = image.pts.microseconds
        if let cached = thumbnailImages[key] { return cached }
        guard let decoded = ThumbnailDecoder.image(from: image.jpeg) else { return nil }
        if thumbnailImages.count >= PlayerModel.thumbnailCacheLimit { thumbnailImages.removeAll() }
        thumbnailImages[key] = decoded
        return decoded
    }

    // MARK: Internals

    private func send(_ body: @escaping @Sendable (any PlayerEngine) async -> Void) {
        session?.send(.run(body))
    }

    /// Everything per-file goes back to its default when a file opens or closes.
    func resetTrackState() {
        tracks = nil
        loop = .off
        subtitleDelay = 0
        audioDelay = 0
        subtitleStyle.position = SubtitleStyle.defaultPosition
        thumbnailProgress = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        hoverThumbnail = nil
        thumbnailImages.removeAll()
        pendingChoices = nil
        userEdits = .empty
        chosenAudio = nil
        avoidanceTask?.cancel()
        avoidanceTask = nil
        lastAvoidance = nil
        autoAdvance.cancel()
        closePanel()
    }

    /// Applies carried or resumed choices to the freshly reported tracks.
    func applyPending(_ pending: PendingChoices, to state: TrackState) {
        let choices = pending.choices
        switch choices.subtitle {
        case .off?:
            if state.selectedSubtitle != .off { setSubtitleSelection(.off) }
        case .track(let identity)?:
            if let id = TrackPreference.match(identity, in: state.subtitles, sameFile: pending.sameFile) {
                let selection = SubtitleSelection(id)
                if selection != state.selectedSubtitle { setSubtitleSelection(selection) }
            }
        case nil:
            break
        }
        if let audio = pending.audio,
           let index = TrackPreference.match(audio, in: state.audio, sameFile: pending.sameFile),
           index != state.selectedAudio {
            setAudioSelection(index)
        }
        if let delay = choices.subtitleDelay { setSubtitleDelay(delay, announce: false) }
        if let delay = choices.audioDelay { setAudioDelay(delay, announce: false) }
        if let size = choices.subtitleSize, size != subtitleStyle.size {
            subtitleStyle = SubtitleStyle(size: size, position: subtitleStyle.position)
            applyStyleSize(announce: false)
        }
        if let position = choices.subtitlePosition, position != subtitleStyle.position {
            subtitleStyle.position = position
            userEdits.subtitlePosition = position
            send { await $0.setSubtitlePosition(position) }
        }
    }
}
