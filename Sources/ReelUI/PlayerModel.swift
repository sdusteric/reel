import Foundation
import Observation
import ReelCore

/// A message in the top-left OSD (design section 9.5).
public struct OSDMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case volume, mute, seek, frameStep, resume
    }

    public var kind: Kind
    public var text: String
    /// The resume OSD carries a "Start Over" button.
    public var showsStartOver: Bool

    public init(kind: Kind, text: String, showsStartOver: Bool = false) {
        self.kind = kind
        self.text = text
        self.showsStartOver = showsStartOver
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

    public let chrome: ChromeVisibility

    /// Called when the play intent changes (the app holds a display sleep assertion while true).
    @ObservationIgnored public var onPlayingChange: ((Bool) -> Void)?
    /// Called when the chrome shows or hides (the app fades the traffic lights and cursor).
    @ObservationIgnored public var onChromeVisibilityChange: ((Bool) -> Void)?
    /// Called once a file has opened, with its info (the app sizes the window).
    @ObservationIgnored public var onOpened: ((MediaInfo) -> Void)?

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

    public init(dependencies: Dependencies, chrome: ChromeVisibility? = nil) {
        self.dependencies = dependencies
        self.chrome = chrome ?? ChromeVisibility(now: dependencies.now, sleep: dependencies.sleep)
        if let state = dependencies.stateStore?.state {
            volume = state.volume
            showRemainingTime = state.showRemainingTime
            controllerCenterX = state.controllerCenterX
            controllerBottomY = state.controllerBottomY
        } else {
            showRemainingTime = dependencies.settings().showRemainingTime
        }
        self.chrome.onChange = { [weak self] visible in
            self?.chromeVisibilityChanged(visible)
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

    /// Opens `url`, replacing the current file. Resumes from a saved position when the setting
    /// is on, then plays.
    public func open(_ url: URL) async {
        openToken &+= 1
        let token = openToken
        await closeSession(saving: true)
        resetForNewFile()
        title = url.lastPathComponent
        playbackState = .opening
        let engine = await dependencies.makeEngine(url)
        guard token == openToken else {
            await engine.close()
            return
        }
        let session = EngineSession(engine: engine) { [weak self] event in
            self?.handle(event)
        }
        self.session = session

        let keyFunction = dependencies.contentKey
        let keyResult = await Task.detached { Result { try keyFunction(url) } }.value
        guard token == openToken else { return }
        switch keyResult {
        case .success(let key): contentKey = key
        case .failure(let error): dependencies.log.error("content key for \(url.lastPathComponent): \(error)")
        }

        let info: MediaInfo
        do {
            info = try await session.engine.open(url)
        } catch {
            guard token == openToken else { return }
            dependencies.log.error("open \(url.lastPathComponent) failed: \(error)")
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            playbackState = .failed
            await closeSession(saving: false)
            return
        }
        guard token == openToken else { return }
        apply(info)
        if playbackState == .opening { playbackState = .ready }
        session.send(.volume(volume))
        session.send(.muted(isMuted))
        session.send(.timeInterval(chrome.isVisible ? PlayerModel.visibleTimeInterval : PlayerModel.hiddenTimeInterval))
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
    }

    /// Closes the file and returns to the empty state, saving the resume position.
    public func close() async {
        openToken &+= 1
        await closeSession(saving: true)
        resetForNewFile()
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
    }

    // MARK: Engine events

    public func handle(_ event: EngineEvent) {
        switch event {
        case .stateChanged(let state):
            playbackState = state
            switch state {
            case .playing: setPlayIntent(true)
            case .paused, .ended, .failed, .idle: setPlayIntent(false)
            case .opening, .ready, .seeking: break
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
        case .ended:
            playbackState = .ended
            setPlayIntent(false)
            if let duration { position = duration }
            saveResume(flush: true)
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
    private func showOSD(_ message: OSDMessage, hold: TimeInterval = PlayerModel.osdHoldDuration) {
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
