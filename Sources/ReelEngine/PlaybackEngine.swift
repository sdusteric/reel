import AVFoundation
import CoreGraphics
import CoreMedia
import CReelDeps
import Foundation
import QuartzCore
import ReelCore
import Synchronization
import VideoToolbox

/// A playback position worth remembering (design section 11.2). The app hands these to
/// `ResumeStore`; the engine sends one every 5 s while playing, on pause, when a seek settles,
/// at the end of the file and on close.
public struct PositionUpdate: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        case periodic, paused, seekSettled, ended, closed
    }

    public var url: URL
    public var position: MediaTime
    public var duration: MediaTime?
    public var audioStreamIndex: Int?
    public var reason: Reason
    /// The track choices and subtitle settings in force, for the resume entry's choices (M2).
    public var tracks: TrackState?
    public var loop: LoopState

    public init(
        url: URL,
        position: MediaTime,
        duration: MediaTime?,
        audioStreamIndex: Int?,
        reason: Reason,
        tracks: TrackState? = nil,
        loop: LoopState = .off
    ) {
        self.url = url
        self.position = position
        self.duration = duration
        self.audioStreamIndex = audioStreamIndex
        self.reason = reason
        self.tracks = tracks
        self.loop = loop
    }
}

/// The playback engine (design sections 7.1 and 7.5): demuxer thread, video decoder, audio decode
/// thread and one `AVSampleBufferRenderSynchronizer` as the clock, driven by a seek generation
/// counter. All commands go through this actor.
public actor PlaybackEngine: PlayerEngine {
    public struct Configuration: Sendable, Hashable {
        /// `.playback` attaches an audible audio renderer (the app); `.headless` attaches none
        /// unless `REEL_ALLOW_AUDIO=1`, and then a silent one.
        public var audioMode: AudioOutput.Mode
        public var environment: ReelEnvironment
        /// The "Hardware decoding" setting.
        public var hardwareDecoding: Bool
        /// The "Show a keyframe preview while seeking" setting.
        public var keyframePreview: Bool
        /// Hold a display sleep assertion while playing.
        public var preventsDisplaySleep: Bool
        /// How long a drag rests before the exact seek starts in the background.
        public var backgroundExactDelay: Duration
        /// Read-ahead and keep-behind limits of the packet store.
        public var storeLimits: PacketStore.Limits
        /// Seek-bar thumbnails in the background after the first frame (design section 9.4).
        /// `REEL_NO_THUMBNAILS=1` turns them off whatever this says.
        public var generatesThumbnails: Bool
        /// Where thumbnail packs go; nil uses `REEL_HOME/Caches/thumbnails` of `environment`.
        public var thumbnailCacheDirectory: URL?
        /// List the video's folder (and Subs/, Subtitles/) for sidecar subtitle files.
        public var discoversExternalSubtitles: Bool
        /// Read every text subtitle event in the background after open (D34).
        public var prefetchesSubtitles: Bool
        /// The VP9 hybrid (D46). Off only for benches that compare against pure hardware.
        public var hybridDecoding: Bool
        /// The VP9 tile check beside VideoToolbox (section 7.10), within `CheckBudget`.
        public var checksVP9Tiles: Bool
        /// How long `setOccluded(true)` waits before video decode stops (section 7.9).
        public var occlusionDelay: Duration
        /// An open that has not produced a result by then fails as `.unreadable("timed out")`
        /// (section 7.10).
        public var openTimeout: Duration

        public init(
            audioMode: AudioOutput.Mode,
            environment: ReelEnvironment = ReelEnvironment(),
            hardwareDecoding: Bool = true,
            keyframePreview: Bool = true,
            preventsDisplaySleep: Bool,
            backgroundExactDelay: Duration = PlaybackEngine.backgroundExactDelay,
            storeLimits: PacketStore.Limits = .standard,
            generatesThumbnails: Bool = false,
            thumbnailCacheDirectory: URL? = nil,
            discoversExternalSubtitles: Bool = true,
            prefetchesSubtitles: Bool = true,
            hybridDecoding: Bool = true,
            checksVP9Tiles: Bool = true,
            occlusionDelay: Duration = .milliseconds(Int(EnergyPolicy.occlusionDelay * 1_000)),
            openTimeout: Duration = PlaybackEngine.openTimeout
        ) {
            self.audioMode = audioMode
            self.environment = environment
            self.hardwareDecoding = hardwareDecoding
            self.keyframePreview = keyframePreview
            self.preventsDisplaySleep = preventsDisplaySleep
            self.backgroundExactDelay = backgroundExactDelay
            self.storeLimits = storeLimits
            self.generatesThumbnails = generatesThumbnails
            self.thumbnailCacheDirectory = thumbnailCacheDirectory
            self.discoversExternalSubtitles = discoversExternalSubtitles
            self.prefetchesSubtitles = prefetchesSubtitles
            self.hybridDecoding = hybridDecoding
            self.checksVP9Tiles = checksVP9Tiles
            self.occlusionDelay = occlusionDelay
            self.openTimeout = openTimeout
        }

        /// The app.
        public static var playback: Configuration {
            Configuration(audioMode: .playback, preventsDisplaySleep: true, generatesThumbnails: true)
        }
        /// Tests, benches and reelctl: silent, no display sleep assertion, no thumbnail cache.
        public static var headless: Configuration { Configuration(audioMode: .headless, preventsDisplaySleep: false) }

        var thumbnailsEnabled: Bool { generatesThumbnails && !environment.thumbnailsDisabled }
    }

    public static let positionSaveInterval = MediaTime.seconds(5)
    /// The open watchdog (section 7.10).
    public static let openTimeout: Duration = .seconds(10)
    /// A seek whose video ended without a frame landing settles on the last frame after this long.
    static let endOfDataLandingDelay: UInt64 = 200_000_000
    /// Frame threads of the VP9 hybrid's software decoder: 16 (FFmpeg's recommended maximum)
    /// decode the 4K60 fixture's 300-frame GOP in about 0.5 s, against 0.75 s with the 6
    /// performance cores; each thread holds back one more frame before the first comes out.
    static let hybridThreads = min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 16)
    /// A drag that rests this long starts the exact seek in the background (design section 7.5).
    public static let backgroundExactDelay: Duration = .milliseconds(150)
    /// Playback resumes after a seek once audio is primed, or after this long without it.
    public static let audioPrimeTimeout: Duration = .milliseconds(250)
    /// A scrub that has not landed by then no longer blocks the next one.
    public static let scrubWatchdog: Duration = .seconds(1)
    /// End of file, the store playhead and periodic saves are checked this often while playing,
    /// whatever the time event interval.
    static let housekeepingInterval = 0.1
    /// While paused the stored range is published this often until the read-ahead fill is done;
    /// then the housekeeping task parks (section 7.9).
    static let pausedFillInterval = 1.0
    /// While occluded only end of file and the playhead need checking, so less often.
    static let occludedHousekeepingInterval = 0.25
    /// Playback moves the store's playhead (and wakes the demuxer) in steps this long.
    static let playheadStep = MediaTime.milliseconds(500)
    /// A paused engine stops feeding audio this long after it settles, once the feed has had time
    /// to decode the second ahead that playback resumes with.
    static let pausedAudioSettle: Duration = .milliseconds(500)

    public nonisolated let events: AsyncStream<EngineEvent>
    /// The clock. The app adds its display layer to it with `attach(displayLayer:)`.
    public nonisolated let synchronizer: AVSampleBufferRenderSynchronizer
    public nonisolated let configuration: Configuration

    private let eventSink: AsyncStream<EngineEvent>.Continuation
    private let shared = PipelineShared()
    private let displaySleep: DisplaySleep

    private struct VideoSession {
        let format: VideoFormat
        var decoder: any VideoDecoding
        /// The VP9 hybrid's software decoder for long exact seeks (D46); nil for other streams.
        var hybrid: SoftwareVideoDecoder?
        let orderer: PresentationOrderer
        let credits: FrameCredits
        let sink: AsyncStream<DecodedFrame>.Continuation
        var profile: DecodeProfile
        var skippableEstimated = false
        let forced: Bool
    }

    private struct AudioSession {
        let thread: AudioDecodeThread
        let streamIndex: Int
        let codec: String
    }

    private struct Session {
        let url: URL
        var info: MediaInfo
        let demuxer: Demuxer
        var video: VideoSession?
        var audio: AudioSession?
        /// Presentation time of the first frame (mpegts files start later than zero).
        let start: MediaTime
        var tracks: TrackState
        let subtitles: SubtitleTrackStore
        var prefetcher: SubtitlePrefetcher?
        var thumbnails: ThumbnailGenerator?
    }

    private var session: Session?
    private var state: PlaybackState = .idle
    private var generation: UInt64 = 0
    private var planner: SeekPlanner
    private var forceKeyframePreviewForTesting = false
    /// Tests: the clock time the last in-generation audio restart started at.
    private(set) var lastAudioRestartTimeForTesting: MediaTime?
    private var coalescer = ScrubCoalescer()
    private var resumeAfterSeek = false
    private var displayedKeyframe: MediaTime?
    private var lastScrubTarget: MediaTime?
    private var backgroundExactGeneration: UInt64?
    /// The background exact seek landed while the drag was still held; release settles it.
    private var backgroundExactLanded = false
    private var playbackRate: Float = 1
    private var volume = VolumeCurve.firstRunVolume
    private var muted = false
    private var timeInterval: Double = 0.1
    private var lastPeriodicSave: MediaTime?
    private var lastStoredRange: ClosedRange<MediaTime>?
    private var lastStoredRangeNanos: UInt64 = 0
    private var lastPlayheadUpdate: MediaTime?
    private let timeEvents: TimeEventTimer
    private var closed = false
    /// Work counted since open (`energyCounters()`).
    private let counters = EngineCounters()
    private var subtitleRenderBase = 0
    /// Wakes the parked housekeeping task; it holds no reference to the engine while parked.
    private let tickerWakes: AsyncStream<Void>
    private let tickerWakeSink: AsyncStream<Void>.Continuation

    // M3 energy state (section 7.9).
    /// The app's occlusion flag, and whether `occlusionDelay` has passed since it was set.
    private var occluded = false
    private var occlusionElapsed = false
    private var occlusionTask: Task<Void, Never>?
    /// Video decode was stopped for occlusion; the picture is stale until a resync seek.
    private var videoStoppedForOcclusion = false
    /// The audio stream whose decoder failed to open last, and why (sent as `.audioTrackFailed`).
    private var audioFailure: (streamIndex: Int, reason: String)?
    /// The pointer moved in the window recently (the app sets it). Unset engines behave as M2 did
    /// and keep paused thumbnails running.
    private var pointerRecent = true
    private var lowPowerOverride: Bool?
    private var seekHoldsThumbnails = false
    private var energyHoldsThumbnails = false
    private var subtitlesSuspended = false
    /// Audio feeding stopped while paused; playback continues from the last decoded buffer.
    private var audioFeedSuspended = false
    private var audioSuspendTask: Task<Void, Never>?
    private var audioRestartsInFlight = 0
    private var stoppingVideo = false
    /// Paused: the video feeder is stopped after the shown frame and restarts on play.
    private var feederParkedForPause = false
    private var feederParkTask: Task<Void, Never>?

    private var feederTask: Task<VideoFeedState, Never>?
    private var parkedFeed: VideoFeedState?
    private var presenterTask: Task<Void, Never>?
    private var audioConsumerTask: Task<Void, Never>?
    private var audioFeedTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var backgroundExactTask: Task<Void, Never>?
    private var audioResumeTask: Task<Void, Never>?
    private var scrubWatchdogTask: Task<Void, Never>?
    private var audioEventsTask: Task<Void, Never>?
    /// The display layer the video receiver feeds: the app's, or a standalone one.
    private var videoLayer: VideoLayerHolder?
    /// While occluded the layer leaves the synchronizer (`detachVideoRenderer`).
    private var videoRendererDetached = false
    private var rendererDetachTask: Task<Void, Never>?

    // M2 state (design sections 8, 9.7 to 9.12).
    /// Subtitle rendering on its own serial queue; the app's layer is attached to it.
    public nonisolated let subtitlePresenter: SubtitlePresenter
    private var audioDelay = MediaTime.zero
    private var loop = LoopState.off
    private var loopBoundaryObserver: Any?
    /// B's boundary observer fires here rather than on the main queue, which the app's UI (and a
    /// test process's main-actor suites) can keep busy past B.
    private let loopBoundaryQueue = DispatchQueue(label: "reel.loop-boundary", qos: .userInitiated)
    private var thumbnailsPaused = false
    private var subtitleFeedTask: Task<Void, Never>?
    private var subtitleLoadTask: Task<Void, Never>?
    private var bitmapBackfillTask: Task<Void, Never>?
    private var bitmapBackfilled: ClosedRange<MediaTime>?
    private var subtitleEventCount = 0
    private var reportedCharsets: [TrackID: String] = [:]

    private var positionHandler: (@Sendable (PositionUpdate) -> Void)?
    // M3 robustness state (section 7.10).
    /// Says which volume a file's path is on when that volume is gone; tests replace it.
    private var volumeCheck: @Sendable (URL) -> String? = { MountedVolumes.missingVolume(of: $0) }
    /// Tests: the open waits this long before reading, like a drive that does not answer.
    private var openDelayForTesting: Duration?

    private var reportWaiters: [UInt64: [CheckedContinuation<SeekReport?, Never>]] = [:]
    private var completedReports: [UInt64: SeekReport] = [:]
    public private(set) var lastReport: SeekReport?

    public init(configuration: Configuration = .playback) {
        self.configuration = configuration
        synchronizer = AVSampleBufferRenderSynchronizer()
        (events, eventSink) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(4_096))
        (tickerWakes, tickerWakeSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        displaySleep = DisplaySleep(enabled: configuration.preventsDisplaySleep)
        planner = SeekPlanner(keyframePreviewEnabled: configuration.keyframePreview)
        timeEvents = TimeEventTimer(interval: 0.1, synchronizer: synchronizer, sink: eventSink, counters: counters)
        let synchronizer = self.synchronizer
        subtitlePresenter = SubtitlePresenter(clock: { MediaTime(synchronizer.currentTime()) ?? .zero })
        let sink = eventSink
        subtitlePresenter.setFailureHandler { track, reason in
            sink.yield(.subtitleTrackFailed(track, reason: reason))
        }
        shared.damage.setEventSink { time, kind in
            sink.yield(.damaged(at: time ?? (MediaTime(synchronizer.currentTime()) ?? .zero), kind: kind))
        }
    }

    deinit {
        timeEvents.cancel()
        tickerWakeSink.finish()
    }

    // MARK: Attaching outputs

    /// Adds the app's display layer to the synchronizer. Call before `open`; without it the engine
    /// renders into a standalone layer that is in no window.
    @MainActor
    public func attach(displayLayer layer: AVSampleBufferDisplayLayer) async {
        let receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        await installVideoReceiver(receiver, keeping: VideoLayerHolder(layer))
    }

    /// Adds the app's subtitle layer: a layer above the display layer, sized like it, with
    /// `contentsScale` set to the backing scale. The engine draws into a sublayer of it.
    @MainActor
    public func attach(subtitleLayer layer: CALayer) {
        subtitlePresenter.attach(layer)
    }

    /// Call after the subtitle layer changed size (window resize, fullscreen), so a paused
    /// subtitle is drawn again at the new size.
    @MainActor
    public func subtitleLayerDidLayout() {
        subtitlePresenter.layerDidLayout()
    }

    @MainActor
    private func attachVideoLayerHolder() async {
        let holder = VideoLayerHolder()
        let receiver = synchronizer.sampleBufferReceiver(adding: holder.layer.sampleBufferRenderer)
        await installVideoReceiver(receiver, keeping: holder)
    }

    private func installVideoReceiver(_ receiver: sending AVSampleBufferVideoRenderer.Receiver, keeping holder: VideoLayerHolder) async {
        let synchronizer = self.synchronizer
        let output = VideoOutput(receiver: receiver, clock: { MediaTime(synchronizer.currentTime()) ?? .zero })
        await output.setGeneration(generation)
        shared.videoOutput.withLock { $0 = output }
        videoLayer = holder
    }

    /// Adds the layer back to the synchronizer with a new receiver and output.
    @MainActor
    private func reattach(_ holder: VideoLayerHolder) async {
        let receiver = synchronizer.sampleBufferReceiver(adding: holder.layer.sampleBufferRenderer)
        await installVideoReceiver(receiver, keeping: holder)
    }

    /// A display layer attached to a running clock wakes the process about 50 times a second
    /// even with nothing queued (measured with energy-bench), so while occluded it leaves the
    /// synchronizer. The output is finished then; `reattachVideoRenderer` installs a new one.
    private func detachVideoRenderer() {
        guard !videoRendererDetached, videoLayer != nil, let output = shared.videoOutput.withLock({ $0 }) else { return }
        videoRendererDetached = true
        let synchronizer = self.synchronizer
        rendererDetachTask = Task {
            await output.detach(from: synchronizer)
        }
        trace("occluded: display layer detached from the clock")
    }

    /// Before any seek or close: the layer goes back on the clock with a fresh output.
    private func reattachVideoRenderer() async {
        guard videoRendererDetached else { return }
        await rendererDetachTask?.value
        rendererDetachTask = nil
        guard videoRendererDetached, let holder = videoLayer else { return }
        videoRendererDetached = false
        await reattach(holder)
        trace("display layer back on the clock")
    }

    /// Tests: the time of the display layer's renderer timebase, which follows the
    /// synchronizer while the layer is attached to it.
    @MainActor
    func displayLayerTimeForTesting() async -> Double? {
        let holder = await videoLayer
        return holder?.layer.sampleBufferRenderer.timebase.time.seconds
    }

    /// Tests: true while the display layer is off the clock for occlusion.
    var isVideoRendererDetachedForTesting: Bool { videoRendererDetached }

    // MARK: Observers (benches, tests and the app's resume store)

    public func setPositionHandler(_ handler: (@Sendable (PositionUpdate) -> Void)?) {
        positionHandler = handler
    }

    /// Called for every video frame of the current generation that the receiver accepted.
    public func setFrameObserver(_ observer: (@Sendable (DecodedFrame) -> Void)?) {
        shared.frameObserver.withLock { $0 = observer.map { SendableCallback($0) } }
    }

    /// Called for every decoded audio buffer of the current generation, with its generation.
    public func setAudioObserver(_ observer: (@Sendable (DecodedAudioBuffer, UInt64) -> Void)?) {
        shared.audioObserver.withLock { $0 = observer.map { observer in SendableCallback { observer($0.buffer, $0.generation) } } }
    }

    // MARK: State

    public var playbackState: PlaybackState { state }
    public var mediaInfo: MediaInfo? { session?.info }
    public var currentGeneration: UInt64 { generation }
    public var keyframeIndex: KeyframeIndex { session?.demuxer.keyframeIndex ?? KeyframeIndex() }
    public var videoDecoderKind: VideoDecoderKind? { session?.video?.decoder.kind }
    /// Compressed bytes read from the file since open.
    public var bytesRead: Int64 { session?.demuxer.bytesRead ?? 0 }
    public var storedRange: ClosedRange<MediaTime>? { session?.demuxer.store.storedRange }
    /// Presentation time of the first video frame.
    public var startTime: MediaTime { session?.start ?? .zero }

    /// True when an audio renderer is attached (never in tests or reelctl without REEL_ALLOW_AUDIO=1).
    var hasAudioOutput: Bool { shared.audioOutput.withLock { $0 != nil } }
    var holdsDisplaySleepAssertion: Bool { displaySleep.isPreventingSleep }

    /// The synchronizer clock.
    public nonisolated var currentTime: MediaTime {
        MediaTime(synchronizer.currentTime()) ?? .zero
    }

    /// The frame the last exact seek landed on (for frame checks in benches and tests).
    public func lastLandedFrame() -> DecodedFrame? {
        shared.lastLandedFrame.withLock { $0 }
    }

    // MARK: PlayerEngine

    @discardableResult
    public func open(_ url: URL) async throws -> MediaInfo {
        try await open(url, preferredVideoStream: nil)
    }

    private func open(_ url: URL, preferredVideoStream: Int?) async throws -> MediaInfo {
        guard !closed else { throw EngineError.notOpen }
        if session != nil { await closeSession() }
        setState(.opening)
        trace("open \(url.lastPathComponent)")
        // A file on a drive that is gone fails at once, without touching the path (section 7.10).
        if let volume = volumeCheck(url) {
            try fail(EngineError.io("the volume \(volume) is not mounted"), url: url)
        }
        let demuxer: Demuxer
        let external: [SubtitleTrack]
        do {
            (demuxer, external) = try await openDemuxer(url, preferredVideoStream: preferredVideoStream)
        } catch {
            try fail(error, url: url)
        }
        trace("open: demuxer ready")
        var info = demuxer.info
        var video: VideoSession?
        if let format = demuxer.videoFormat, let parameters = demuxer.videoParameters {
            do {
                video = try makeVideoSession(format: format, parameters: parameters)
            } catch {
                demuxer.stop()
                try fail(error, url: url)
            }
            info.videoDecoder = video?.decoder.kind
        }
        audioFailure = nil
        let audio = info.audioStreamIndex.flatMap { makeAudioSession(demuxer, streamIndex: $0) }
        if video == nil, audio == nil {
            demuxer.stop()
            try fail(EngineError.noPlayableStream, url: url)
        }
        if audio != nil, shared.audioOutput.withLock({ $0 }) == nil,
           let output = AudioOutput.attach(to: synchronizer, mode: configuration.audioMode, environment: configuration.environment) {
            // Attached before the first enqueue, so the clock follows the audio device.
            await output.setVolume(volume)
            await output.setMuted(muted)
            shared.audioOutput.withLock { $0 = output }
            audioEventsTask = Task { [weak self] in
                for await event in output.events {
                    await self?.handleAudioEvent(event)
                }
            }
        }
        if shared.videoOutput.withLock({ $0 }) == nil {
            await attachVideoLayerHolder()
        }
        trace("open: decoders and outputs ready")
        let start = demuxer.keyframeIndex.first?.pts ?? demuxer.store.storedKeyframes.first ?? info.startTime ?? .zero
        var tracks = TrackState(info: info, external: external)
        tracks.selectedAudio = audio?.streamIndex
        let subtitles = SubtitleTrackStore()
        session = Session(
            url: url, info: info, demuxer: demuxer, video: video, audio: audio, start: start,
            tracks: tracks, subtitles: subtitles, prefetcher: nil, thumbnails: nil
        )
        resetPerFileSettings(info: info, store: subtitles)
        counters.reset()
        shared.damage.reset()
        shared.goodFrames.store(0, ordering: .relaxed)
        shared.videoAwaitsKeyframe.store(false, ordering: .relaxed)
        shared.dataEndReported.store(false, ordering: .relaxed)
        shared.dataEnd.withLock { $0 = nil }
        subtitleRenderBase = subtitlePresenter.current.renderCount
        demuxer.start()
        startWorkers()
        eventSink.yield(.opened(info))
        eventSink.yield(.tracksChanged(tracks))
        if audio == nil, let failure = audioFailure {
            eventSink.yield(.audioTrackFailed(streamIndex: failure.streamIndex, reason: failure.reason))
        }
        installRobustnessHandlers(demuxer)
        setState(.ready)
        resumeAfterSeek = false
        if let generation = await beginExact(.exact(start), requestedAt: monotonicNanos(), resume: false) {
            _ = await waitForReport(generation: generation, timeout: .seconds(5))
        }
        startBackgroundWork()
        applySubtitleSelection()
        return info
    }

    /// Opens the demuxer off the actor with the open watchdog (section 7.10): reads past the
    /// deadline are interrupted, and a call that blocks somewhere else is abandoned a second
    /// later. Either way the open fails with `.io("timed out")`.
    private func openDemuxer(_ url: URL, preferredVideoStream: Int?) async throws -> (Demuxer, [SubtitleTrack]) {
        let limits = configuration.storeLimits
        let discovers = configuration.discoversExternalSubtitles
        let timeout = configuration.openTimeout
        let delay = openDelayForTesting
        let volumeCheck = self.volumeCheck
        let interrupt = ReadInterrupt()
        interrupt.setDeadline(after: timeout)
        let outcome = await PlaybackEngine.blockingResult(within: timeout + .seconds(1)) { () throws -> (Demuxer, [SubtitleTrack]) in
            if let delay {
                let until = ContinuousClock.now + delay
                while ContinuousClock.now < until {
                    if interrupt.shouldInterrupt() { throw EngineError.io("timed out") }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            let demuxer = try Demuxer(
                url: url, limits: limits, preferredVideoStream: preferredVideoStream, interrupt: interrupt, volumeCheck: volumeCheck
            )
            // From now on only `stop()` interrupts its reads.
            interrupt.setDeadline(after: nil)
            let external = discovers ? ExternalSubtitles.scan(for: url).map(\.track) : []
            return (demuxer, external)
        }
        switch outcome {
        case .success(let value)?:
            return value
        case .failure(let error)?:
            if interrupt.timedOut { throw EngineError.io("timed out") }
            throw error
        case nil:
            interrupt.abort()
            trace("open of \(url.lastPathComponent) abandoned after \(timeout)")
            throw EngineError.io("timed out")
        }
    }

    /// Runs blocking `work` on its own thread and returns its result, or nil when it has none
    /// within `timeout` (the thread keeps running until the work returns). Neither the work nor
    /// the timer runs on the cooperative pool: an open blocked on a dead drive holds no pool
    /// thread, and a pool kept busy by other work cannot hold the watchdog past its deadline.
    static func blockingResult<Value: Sendable>(
        within timeout: Duration,
        _ work: @escaping @Sendable () throws -> Value
    ) async -> Result<Value, any Error>? {
        let once = Mutex<CheckedContinuation<Result<Value, any Error>?, Never>?>(nil)
        return await withCheckedContinuation { continuation in
            once.withLock { $0 = continuation }
            let thread = Thread {
                let result = Result { try work() }
                once.withLock { $0.take() }?.resume(returning: result)
            }
            thread.name = "reel.open"
            thread.qualityOfService = .userInitiated
            thread.start()
            let nanos = Int(max(0, timeout / .nanoseconds(1)))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .nanoseconds(nanos)) {
                once.withLock { $0.take() }?.resume(returning: nil)
            }
        }
    }

    /// Tests: replaces the check that says a file's volume is gone (section 7.10).
    func setVolumeCheckForTesting(_ check: @escaping @Sendable (URL) -> String?) {
        volumeCheck = check
    }

    /// Tests: the open file's next read fails with this FFmpeg code (one shot).
    func setReadFaultForTesting(_ code: Int32) {
        session?.demuxer.readFaultForTesting.store(code, ordering: .relaxed)
    }

    /// Tests: every open waits `delay` before reading the file.
    func setOpenDelayForTesting(_ delay: Duration?) {
        openDelayForTesting = delay
    }

    /// `.dataEnd` for a file cut short, damaged data the demuxer skipped and a drive that went
    /// away while reading (section 7.10). Installed after `.opened`, so events follow it.
    private func installRobustnessHandlers(_ demuxer: Demuxer) {
        let sink = eventSink
        let shared = self.shared
        let report: @Sendable (MediaTime) -> Void = { end in
            shared.dataEnd.withLock { $0 = end }
            if !shared.dataEndReported.exchange(true, ordering: .acquiringAndReleasing) { sink.yield(.dataEnd(end)) }
        }
        demuxer.setDataEndHandler(report)
        if let end = demuxer.dataEnd { report(end) }
        let damage = shared.damage
        demuxer.setDamageHandler { found in
            damage.record(found.video ? .video : .audio, at: found.at, count: found.count, emitsEvent: found.located)
        }
        demuxer.setVolumeLostHandler { [weak self] volume in
            Task { await self?.volumeLost(volume) }
        }
    }

    /// A read failed and the file's volume is gone (section 7.10): pause on the last frame (it
    /// stays on screen), save the position and report the problem. Nothing is flushed, so Try
    /// Again or the drive coming back reopens at the saved time.
    private func volumeLost(_ volume: String) {
        guard session != nil, state.hasMedia else { return }
        trace("volume \(volume) is gone: pausing")
        resumeAfterSeek = false
        synchronizer.rate = 0
        setRealTime(false)
        if state != .ended { setState(.paused) }
        sendPosition(.paused)
        eventSink.yield(.problem(.volumeGone(volume)))
    }

    /// The last presentation time with data, when the file holds less than its header says.
    public var dataEnd: MediaTime? { session?.demuxer.dataEnd }

    /// Damaged video frames and audio packets skipped since open (Video Info, section 9.13).
    public nonisolated var damagedFrames: Int { shared.damage.videoFrames + shared.damage.audioPackets }
    public nonisolated var damagedVideoFrames: Int { shared.damage.videoFrames }
    public nonisolated var damagedAudioPackets: Int { shared.damage.audioPackets }
    /// The VP9 tile check of the open file (section 7.10): packets parsed, packets found damaged,
    /// CPU milliseconds; nil when the file has none.
    public nonisolated var vp9TileCheckTotals: (checked: Int, damaged: Int, cpuMilliseconds: Double)? {
        shared.tileCheck.withLock { $0 }.map { check in
            let totals = check.totals
            return (totals.checked, totals.damaged, Double(totals.cpuNanos) / 1_000_000)
        }
    }

    /// Per-file settings start from their defaults; the app carries changed ones over (9.8).
    private func resetPerFileSettings(info: MediaInfo, store: SubtitleTrackStore) {
        audioDelay = .zero
        if loop != .off {
            loop = .off
            eventSink.yield(.loopChanged(loop))
        }
        updateLoopBoundary()
        bitmapBackfilled = nil
        subtitleEventCount = 0
        reportedCharsets = [:]
        let video = info.videoStream?.video
        subtitlePresenter.reset(store: store, videoWidth: video?.width ?? 0, videoHeight: video?.height ?? 0)
    }

    /// After the first frame: the subtitle prefetch and the thumbnails, which must not slow the open.
    private func startBackgroundWork() {
        guard var current = session else { return }
        if current.tracks.subtitles.contains(where: { $0.format.isText }) {
            // The first launch builds PingFang for libass (about a second); do it before a line is due.
            SubtitleFonts.prepareInBackground()
        }
        if configuration.prefetchesSubtitles, current.tracks.subtitles.contains(where: { !$0.isExternal && $0.format.isText }) {
            let prefetcher = SubtitlePrefetcher(url: current.url, store: current.subtitles)
            prefetcher.start()
            current.prefetcher = prefetcher
        }
        if configuration.thumbnailsEnabled, current.video != nil {
            let cache = configuration.thumbnailCacheDirectory.map { ThumbnailCache(directory: $0) }
                ?? ThumbnailCache(paths: configuration.environment.paths)
            current.thumbnails = startThumbnails(url: current.url, cache: cache)
        }
        session = current
    }

    private func startThumbnails(url: URL, cache: ThumbnailCache, beforeStart: ((ThumbnailGenerator) -> Void)? = nil) -> ThumbnailGenerator {
        // The content key reads 128 KiB; the generator thread computes nothing before start.
        let key = try? ContentKey(contentsOf: url)
        let generator = ThumbnailGenerator(url: url, key: key, cache: key == nil ? nil : cache)
        if thumbnailsPaused { generator.pause() }
        beforeStart?(generator)
        let sink = eventSink
        let counters = self.counters
        // Low Power Mode: the coarse pass only (every 8th position, D60).
        generator.start(coarseOnly: isLowPower) { done, total in
            counters.thumbnailsDecoded.add(1, ordering: .relaxed)
            if done == total || done % 8 == 0 { sink.yield(.thumbnailsProgress(done: done, total: total)) }
        }
        return generator
    }

    /// Benches: replaces the open file's thumbnail generator with a new one writing into
    /// `cacheDirectory` (an empty folder, so it generates), to make generation overlap a chosen
    /// phase. It pauses during seeks like the first one. Nil when nothing is open or the file
    /// has no video.
    @discardableResult
    public func restartThumbnails(cacheDirectory: URL) -> ThumbnailGenerator? {
        restartThumbnails(cacheDirectory: cacheDirectory, beforeStart: nil)
    }

    /// Tests: `beforeStart` sees the new generator before its thread starts.
    func restartThumbnails(cacheDirectory: URL, beforeStart: ((ThumbnailGenerator) -> Void)?) -> ThumbnailGenerator? {
        guard var current = session, current.video != nil else { return nil }
        current.thumbnails?.close()
        let generator = startThumbnails(url: current.url, cache: ThumbnailCache(directory: cacheDirectory), beforeStart: beforeStart)
        current.thumbnails = generator
        session = current
        return generator
    }

    public func play() async {
        guard session != nil else { return }
        switch state {
        case .playing:
            return
        case .seeking:
            resumeAfterSeek = true
            applyEnergy()
            if backgroundExactLanded {
                settleBackgroundExact()
            } else if !exactInFlight {
                let target = lastScrubTarget ?? currentTime
                _ = await beginExact(.exact(target), requestedAt: monotonicNanos(), resume: true)
            }
        case .ended:
            _ = await beginExact(.exact(session?.start ?? .zero), requestedAt: monotonicNanos(), resume: true)
        case .ready, .paused:
            await resumeParkedFeeder()
            guard state == .ready || state == .paused else { return }
            startPlaying(at: nil)
        case .idle, .opening, .failed:
            return
        }
    }

    public func pause() async {
        switch state {
        case .seeking:
            resumeAfterSeek = false
            applyEnergy()
        case .playing:
            synchronizer.rate = 0
            setRealTime(false)
            setState(.paused)
            sendPosition(.paused)
        default:
            return
        }
    }

    public func seek(_ request: SeekRequest) async {
        _ = await submit(request, requestedAt: monotonicNanos())
    }

    /// Starts a seek and waits until it lands or is superseded. Nil when a scrub was coalesced
    /// behind one in flight, or nothing landed within `timeout`.
    public func seekAndWait(_ request: SeekRequest, timeout: Duration = .seconds(10)) async -> SeekReport? {
        guard let generation = await submit(request, requestedAt: monotonicNanos()) else { return nil }
        return await waitForReport(generation: generation, timeout: timeout)
    }

    public func setVolume(_ volume: Double) async {
        self.volume = min(max(volume, 0), 100)
        await shared.audioOutput.withLock({ $0 })?.setVolume(self.volume)
    }

    public func setMuted(_ muted: Bool) async {
        self.muted = muted
        await shared.audioOutput.withLock({ $0 })?.setMuted(muted)
    }

    public func setTimeUpdateInterval(_ seconds: Double) async {
        timeInterval = min(max(seconds, 0.02), 5)
        applyEnergy()
    }

    /// Playback speed. M1 uses it only in benches (av-sync runs faster than real time).
    public func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0.1, min(rate, 16))
        let presenterRate = Double(playbackRate)
        subtitlePresenter.update { $0.rate = presenterRate }
        if state == .playing { synchronizer.rate = playbackRate }
    }

    public func close() async {
        guard !closed else { return }
        // Set before the first suspension, so an open or a second close cannot start on an engine that is closing.
        closed = true
        await closeSession()
        timeEvents.cancel()
        tickerTask?.cancel()
        tickerTask = nil
        audioEventsTask?.cancel()
        audioEventsTask = nil
        if let audio = shared.audioOutput.withLock({ $0 }) { await audio.stop() }
        shared.audioOutput.withLock { $0 = nil }
        synchronizer.rate = 0
        for (_, waiters) in reportWaiters { waiters.forEach { $0.resume(returning: nil) } }
        reportWaiters.removeAll()
        eventSink.finish()
    }

    // MARK: Energy (design section 7.9, D58 to D60)

    /// The audio renderer of this engine plays on `uid` (nil: the system default). Renderers
    /// attached later take `AudioOutput.preferredOutputDevice`, which the app sets first.
    public func setOutputDevice(_ uid: String?) async {
        await shared.audioOutput.withLock({ $0 })?.setOutputDevice(uid)
    }

    /// True: the window has not been visible. After `occlusionDelay` video
    /// decode stops while audio and the clock go on. False: an exact seek to the clock brings
    /// the picture back.
    public func setOccluded(_ occluded: Bool) async {
        _ = await applyOcclusion(occluded)
    }

    /// `setOccluded`, then waits for the resync seek clearing the flag starts. Nil when nothing
    /// needed a resync (video was still decoding) or it did not land within `timeout`.
    public func setOccludedAndWait(_ occluded: Bool, timeout: Duration = .seconds(5)) async -> SeekReport? {
        guard let generation = await applyOcclusion(occluded) else { return nil }
        return await waitForReport(generation: generation, timeout: timeout)
    }

    /// The pointer moved in the window within `EnergyPolicy.pointerRecentSeconds`; paused
    /// thumbnail generation runs only while true. The app sets it; an engine nobody sets it on
    /// keeps paused generation running, as in M2.
    public func setPointerRecent(_ recent: Bool) async {
        guard recent != pointerRecent else { return }
        pointerRecent = recent
        applyEnergy()
    }

    public func energyCounters() async -> EnergyCounters {
        EnergyCounters(
            framesDecoded: counters.framesDecoded.load(ordering: .relaxed),
            packetsRead: session?.demuxer.packetsRead ?? 0,
            subtitleRenders: subtitlePresenter.current.renderCount - subtitleRenderBase,
            timeEvents: counters.timeEvents.load(ordering: .relaxed),
            thumbnailsDecoded: counters.thumbnailsDecoded.load(ordering: .relaxed)
        )
    }

    /// What the energy policy allows now.
    public var energyDecision: EnergyDecision { EnergyPolicy.decide(energyInputs) }

    /// True while video decode is stopped because the window is hidden.
    public var isVideoStoppedForOcclusion: Bool { videoStoppedForOcclusion }

    private var energyInputs: EnergyInputs {
        EnergyInputs(
            playback: EnergyPlayback(state, playIntent: resumeAfterSeek),
            occluded: occlusionElapsed,
            pointerRecent: pointerRecent,
            lowPower: isLowPower,
            chromeVisible: timeInterval <= EnergyPolicy.chromeVisibleTimeInterval
        )
    }

    private var isLowPower: Bool { lowPowerOverride ?? ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Tests: Low Power Mode on or off whatever the system says; nil follows the system.
    func setLowPowerForTesting(_ lowPower: Bool?) {
        lowPowerOverride = lowPower
    }

    /// Applies the energy decision to everything that follows it: time events, the display sleep
    /// assertion and App Nap activity, subtitle renders, thumbnails, the audio feed while paused,
    /// housekeeping, and video decode while occluded.
    private func applyEnergy() {
        let inputs = energyInputs
        let decision = EnergyPolicy.decide(inputs)
        if let interval = decision.timeEvents.interval {
            // The app picks 10 Hz or 1 Hz with the chrome; occluded playback needs 1 Hz at most.
            timeEvents.setInterval(inputs.occluded ? max(timeInterval, interval) : timeInterval)
            timeEvents.setActive(true)
        } else {
            timeEvents.setActive(false)
        }
        if decision.holdsDisplaySleepAssertion {
            displaySleep.preventSleep()
        } else {
            displaySleep.allowSleep()
        }
        let suspendSubtitles = inputs.occluded && inputs.playback == .playing
        if suspendSubtitles != subtitlesSuspended {
            subtitlesSuspended = suspendSubtitles
            subtitlePresenter.update { $0.suspended = suspendSubtitles }
        }
        let holdThumbnails = !decision.thumbnails.runs
        if holdThumbnails != energyHoldsThumbnails {
            energyHoldsThumbnails = holdThumbnails
            updateThumbnailPause()
        }
        if state == .paused || state == .ready { scheduleAudioSuspension() }
        if state == .paused { parkFeederWhilePaused() }
        if housekeepingDelay() > 0 { tickerWakeSink.yield(()) }
        if videoStoppedForOcclusion, !inputs.occluded {
            Task { [weak self] in _ = await self?.resyncAfterOcclusion() }
        } else if inputs.occluded, state == .playing, !videoStoppedForOcclusion, !stoppingVideo, session?.video != nil {
            stoppingVideo = true
            Task { [weak self] in await self?.stopVideoForOcclusion() }
        }
    }

    /// Seconds until the next housekeeping tick; 0 parks the task until `applyEnergy` wakes it.
    private func housekeepingDelay() -> Double {
        switch state {
        case .playing where videoStoppedForOcclusion:
            return PlaybackEngine.occludedHousekeepingInterval
        case .playing, .seeking:
            return PlaybackEngine.housekeepingInterval
        case .paused, .ready:
            // The stored range is published while the read-ahead fill finishes; then it parks.
            return session?.demuxer.store.wantsMoreData == true ? PlaybackEngine.pausedFillInterval : 0
        case .idle, .opening, .ended, .failed:
            return 0
        }
    }

    private func applyOcclusion(_ value: Bool) async -> UInt64? {
        guard value != occluded else { return nil }
        occluded = value
        occlusionTask?.cancel()
        occlusionTask = nil
        if value {
            let delay = configuration.occlusionDelay
            occlusionTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.occlusionDelayPassed()
            }
            return nil
        }
        occlusionElapsed = false
        let resync = await resyncAfterOcclusion()
        applyEnergy()
        return resync
    }

    private func occlusionDelayPassed() {
        occlusionTask = nil
        guard occluded, !occlusionElapsed else { return }
        occlusionElapsed = true
        trace("occluded for \(configuration.occlusionDelay)")
        applyEnergy()
    }

    /// Video decode stops; audio, the clock and the frames already decoded go on (D59).
    private func stopVideoForOcclusion() async {
        defer { stoppingVideo = false }
        guard energyInputs.occluded, state == .playing, !videoStoppedForOcclusion, session?.video != nil else { return }
        let before = generation
        let feed = await stopFeeder()
        // A seek that started meanwhile owns the decoder now; its landing stops video again.
        guard generation == before else { return }
        parkedFeed = feed
        videoStoppedForOcclusion = true
        trace("occluded: video decode stopped at \(currentTime)")
        detachVideoRenderer()
        // Revealed or paused while the feeder stopped: bring the picture back at once.
        if !energyInputs.occluded { _ = await resyncAfterOcclusion() }
    }

    /// The window is visible again: an exact seek to the clock with the keyframe
    /// preview brings the picture back; its report is the resync latency.
    private func resyncAfterOcclusion() async -> UInt64? {
        guard videoStoppedForOcclusion else { return nil }
        videoStoppedForOcclusion = false
        guard session?.video != nil, state.hasMedia, state != .ended else { return nil }
        let target = currentTime
        trace("visible again: resync at \(target)")
        return await beginExact(.exact(target), requestedAt: monotonicNanos(), resume: wantsPlayback(nil))
    }

    /// Paused means no decode after the shown frame (section 7.9): the feeder stops where it is
    /// and keeps its position for the next seek (which may continue from it) or for play.
    private func parkFeederWhilePaused() {
        guard !feederParkedForPause, feederTask != nil, session?.video != nil else { return }
        feederParkedForPause = true
        let paused = generation
        feederParkTask = Task { [weak self] in await self?.parkFeeder(generation: paused) }
    }

    private func parkFeeder(generation paused: UInt64) async {
        // A seek or play that came first owns the feeder now: stopping it would strand that run.
        guard paused == generation, state == .paused else {
            feederParkedForPause = false
            return
        }
        let feed = await stopFeeder()
        guard paused == generation, state == .paused else {
            feederParkedForPause = false
            // A seek that started meanwhile waits for this park and continues from the state;
            // one that already runs its own feeder does not need it.
            if feederTask == nil { parkedFeed = feed }
            return
        }
        parkedFeed = feed
    }

    /// Play after a pause: the feeder continues from where it stopped, outputting every frame.
    private func resumeParkedFeeder() async {
        if let task = feederParkTask {
            await task.value
            feederParkTask = nil
        }
        guard feederParkedForPause else { return }
        feederParkedForPause = false
        guard let current = session, let video = current.video, feederTask == nil,
              let feed = parkedFeed, !feed.reachedEnd else { return }
        parkedFeed = nil
        let spec = FeedSpec(
            generation: generation, target: nil, keyframe: nil, preview: false, scrubOnly: false,
            awaitDemuxerSeek: false, decoder: feed.active ?? video.decoder.kind
        )
        startFeeder(feed, spec: spec, video: video, demuxer: current.demuxer)
    }

    /// While paused nothing consumes audio, so the feed stops once it has decoded the second
    /// ahead (instead of polling the clock); `resumeAudioFeed` continues after the last buffer.
    private func scheduleAudioSuspension() {
        guard !audioFeedSuspended, audioSuspendTask == nil, audioFeedTask != nil else { return }
        audioSuspendTask = Task { [weak self] in
            try? await Task.sleep(for: PlaybackEngine.pausedAudioSettle, tolerance: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await self?.suspendAudioFeedIfPaused()
        }
    }

    private func suspendAudioFeedIfPaused() {
        audioSuspendTask = nil
        guard state == .paused || state == .ready, !audioFeedSuspended, let feed = audioFeedTask else { return }
        guard audioRestartsInFlight == 0 else {
            scheduleAudioSuspension()
            return
        }
        feed.cancel()
        audioFeedTask = nil
        audioFeedSuspended = true
    }

    /// Playback starts after a pause: audio continues after the last buffer handed to the
    /// renderer, which still holds everything before it, so nothing is flushed or repeated.
    private func resumeAudioFeed() {
        audioSuspendTask?.cancel()
        audioSuspendTask = nil
        guard audioFeedSuspended else { return }
        audioFeedSuspended = false
        guard let current = session, let audio = current.audio, !shared.audioEnded.load(ordering: .acquiring) else { return }
        let clock = currentTime
        let from = shared.lastAudioEnd.withLock { $0 }.flatMap { $0 >= clock ? $0 : nil } ?? clock
        audio.thread.seek(dropBefore: from - audioDelay, generation: generation, timestampOffset: audioDelay)
        startAudioFeed(generation: generation, target: from, awaitDemuxerSeek: current.demuxer.hasPendingSeek)
    }

    // MARK: Tracks, subtitles, speed, loops (design sections 8, 9.7 to 9.12)

    /// The track lists and subtitle settings of the open file.
    public var trackState: TrackState? { session?.tracks }
    /// FFmpeg codec name of the audio stream playing.
    public var audioCodecName: String? { session?.audio?.codec }
    /// Software to hardware hand-offs of the VP9 hybrid since open (D46).
    public nonisolated var decoderHandoffs: Int { shared.decoderHandoffs.load(ordering: .relaxed) }
    /// The rate playback runs at (1 is normal).
    public var rate: Double { Double(playbackRate) }
    public var loopState: LoopState { loop }
    /// The thumbnail generator of the open file, when thumbnails are on.
    public var thumbnailGenerator: ThumbnailGenerator? { session?.thumbnails }
    /// The text events of the open file, shared with the prefetcher and the renderer.
    public var subtitleStore: SubtitleTrackStore? { session?.subtitles }

    public func selectAudioTrack(_ streamIndex: Int) async {
        guard var current = session, current.audio?.streamIndex != streamIndex,
              current.tracks.audio.contains(where: { $0.streamIndex == streamIndex }) else { return }
        let oldConsumer = audioConsumerTask
        audioFailure = nil
        guard let replacement = makeAudioSession(current.demuxer, streamIndex: streamIndex) else {
            if let failure = audioFailure {
                eventSink.yield(.audioTrackFailed(streamIndex: failure.streamIndex, reason: failure.reason))
            }
            return
        }
        let replaced = current.audio
        // Swapped in before any await, so a seek that starts meanwhile already feeds the new track.
        current.audio = replacement
        current.info.audioStreamIndex = streamIndex
        current.tracks.selectedAudio = streamIndex
        session = current
        emitTracks()
        await restartAudio(replaced: replaced, oldConsumer: oldConsumer)
    }

    /// Ctrl+Cmd+V: reopens the file on the other video stream at the same position, keeping the
    /// audio and subtitle choices, the delays and the loop.
    public func selectVideoTrack(_ streamIndex: Int) async {
        guard let current = session, current.info.videoStreamIndex != streamIndex,
              current.tracks.video.contains(where: { $0.streamIndex == streamIndex }) else { return }
        let position = currentTime
        let playing = wantsPlayback(nil)
        let kept = current.tracks
        let keptDelay = audioDelay
        let keptLoop = loop
        do {
            _ = try await open(current.url, preferredVideoStream: streamIndex)
        } catch {
            return
        }
        if let audio = kept.selectedAudio { await selectAudioTrack(audio) }
        if keptDelay != .zero { await setAudioDelay(keptDelay.seconds) }
        await setSubtitleDelay(kept.subtitleDelay)
        await setSubtitleScale(kept.subtitleScale)
        await setSubtitlePosition(kept.subtitlePosition)
        await setSubtitlesVisible(kept.subtitlesVisible)
        await selectSubtitle(kept.selectedSubtitle)
        await setLoop(keptLoop)
        _ = await beginExact(.exact(position), requestedAt: monotonicNanos(), resume: playing)
    }

    public func selectSubtitle(_ selection: SubtitleSelection) async {
        guard var current = session else { return }
        if case .external(let url) = selection, !current.tracks.subtitles.contains(where: { $0.id == .external(url) }) {
            current.tracks.subtitles.append(PlaybackEngine.externalTrack(url, video: current.url))
        }
        if let id = selection.trackID {
            guard let track = current.tracks.subtitles.first(where: { $0.id == id }), track.isSupported else {
                session = current
                emitTracks()
                return
            }
        }
        current.tracks.selectedSubtitle = selection
        session = current
        applySubtitleSelection()
        emitTracks()
    }

    /// A subtitle file the user added: parsed like a sidecar when its name matches the video.
    static func externalTrack(_ url: URL, video: URL) -> SubtitleTrack {
        if let parsed = ExternalSubtitles.discover(for: video, candidates: [url]).first { return parsed.track }
        let format = SubtitleFormat(fileExtension: url.pathExtension)
        let reason = format?.isText == true ? nil : "Not a supported subtitle file"
        return SubtitleTrack(id: .external(url), format: format ?? .other, unsupportedReason: reason)
    }

    public func setSubtitleDelay(_ seconds: Double) async {
        guard seconds.isFinite, session != nil else { return }
        session?.tracks.subtitleDelay = seconds
        subtitlePresenter.update { $0.delay = .seconds(seconds) }
        backfillBitmapSubtitles(around: currentTime)
        emitTracks()
    }

    public func setAudioDelay(_ seconds: Double) async {
        guard seconds.isFinite, session != nil else { return }
        let delay = MediaTime.seconds(seconds)
        session?.tracks.audioDelay = seconds
        emitTracks()
        guard delay != audioDelay else { return }
        audioDelay = delay
        if session?.audio != nil, state.hasMedia { await restartAudio() }
    }

    public func setSubtitleScale(_ factor: Double) async {
        guard factor.isFinite, factor > 0, session != nil else { return }
        let scale = min(max(factor, SubtitleStyle.minimumSize / SubtitleStyle.baseSize), SubtitleStyle.maximumSize / SubtitleStyle.baseSize)
        session?.tracks.subtitleScale = scale
        subtitlePresenter.update { $0.scale = scale }
        emitTracks()
    }

    public func setSubtitlePosition(_ percent: Double) async {
        guard percent.isFinite, session != nil else { return }
        let position = min(max(percent, SubtitleStyle.positionRange.lowerBound), SubtitleStyle.positionRange.upperBound)
        session?.tracks.subtitlePosition = position
        subtitlePresenter.update { $0.position = position }
        emitTracks()
    }

    public func setSubtitlesVisible(_ visible: Bool) async {
        guard session != nil else { return }
        session?.tracks.subtitlesVisible = visible
        subtitlePresenter.update { $0.visible = visible }
        emitTracks()
    }

    public func setSubtitleAvoidance(bottomInsetPoints: Double?) async {
        let inset = bottomInsetPoints.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        subtitlePresenter.update { $0.bottomInsetPoints = inset }
    }

    public func setSubtitleMinimumHeight(_ points: Double?) async {
        let minimum = points.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        subtitlePresenter.update { $0.minimumHeightPoints = minimum }
    }

    /// Playback rate 0.25 to 4 (`PlaybackSpeed`); audio keeps its pitch (`.timeDomain`).
    public func setRate(_ rate: Double) async {
        let clamped = PlaybackSpeed.clamp(rate)
        playbackRate = Float(clamped)
        subtitlePresenter.update { $0.rate = clamped }
        if state == .playing { synchronizer.rate = playbackRate }
        eventSink.yield(.rateChanged(clamped))
    }

    public func setLoop(_ newLoop: LoopState) async {
        var value = newLoop
        if let start = value.start, let end = value.end, end < start {
            value.start = end
            value.end = start
        }
        guard value != loop else { return }
        loop = value
        updateLoopBoundary()
        eventSink.yield(.loopChanged(value))
    }

    public func thumbnail(at time: MediaTime) async -> ThumbnailImage? {
        session?.thumbnails?.thumbnail(at: time)
    }

    /// Event times of the selected text track on the playback clock (shifted by the delay).
    public func subtitleEvents() async -> [SubtitleEventTime] {
        guard let current = session, let id = current.tracks.selectedSubtitle.trackID,
              current.tracks.selectedSubtitleTrack?.format.isText == true else { return [] }
        let delay = MediaTime.seconds(current.tracks.subtitleDelay)
        return current.subtitles.eventTimes(id).map { SubtitleEventTime(start: $0.start + delay, end: $0.end + delay) }
    }

    /// Shift+Right / Shift+Left: an exact seek to the start of the next or previous line.
    /// Returns the time sought to, or nil when there is no such line.
    @discardableResult
    public func seekSubtitleLine(forward: Bool) async -> MediaTime? {
        let events = await subtitleEvents()
        let now = currentTime
        guard let target = forward ? SubtitleLines.next(after: now, in: events) : SubtitleLines.previous(before: now, in: events) else {
            return nil
        }
        await seek(.exact(target))
        return target
    }

    /// Cmd+S: the frame on screen at its native size with the subtitle composited, as a PNG in
    /// `ReelEnvironment.screenshotsDirectory` (design section 9.12). Never waits for a decode.
    public func takeScreenshot() async throws -> URL {
        guard let current = session else { throw EngineError.notOpen }
        let time = currentTime
        guard let frame = shared.frameShown(at: time) ?? shared.lastLandedFrame.withLock({ $0 }) else {
            throw EngineError.decoderFailed("no frame is on screen")
        }
        let subtitle = await subtitlePresenter.snapshot(width: frame.width, height: frame.height)
        let directory = configuration.environment.screenshotsDirectory
        let stem = current.url.deletingPathExtension().lastPathComponent
        let position = MediaTime(frame.presentationTime) ?? time
        return try await Task.detached(priority: .userInitiated) {
            try Screenshot.save(frame: frame.pixelBuffer, subtitle: subtitle, directory: directory, stem: stem, position: position)
        }.value
    }

    private func emitTracks() {
        guard let tracks = session?.tracks else { return }
        eventSink.yield(.tracksChanged(tracks))
    }

    /// Starts showing the selected subtitle: an embedded track is fed from the store (and the
    /// prefetcher for text), an external file is read whole in the background.
    private func applySubtitleSelection() {
        subtitleFeedTask?.cancel()
        subtitleFeedTask = nil
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        bitmapBackfillTask?.cancel()
        bitmapBackfillTask = nil
        bitmapBackfilled = nil
        subtitleEventCount = 0
        subtitlePresenter.clearTimeline()
        guard let current = session, let id = current.tracks.selectedSubtitle.trackID,
              let track = current.tracks.subtitles.first(where: { $0.id == id }) else {
            subtitlePresenter.select(nil, format: nil)
            return
        }
        subtitlePresenter.update { settings in
            settings.delay = .seconds(current.tracks.subtitleDelay)
            settings.scale = current.tracks.subtitleScale
            settings.position = current.tracks.subtitlePosition
            settings.visible = current.tracks.subtitlesVisible
        }
        switch id {
        case .external(let url):
            subtitlePresenter.select(nil, format: nil)
            let store = current.subtitles
            let title = track.title
            subtitleLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let loaded = try ExternalSubtitleLoader.load(url, title: title, into: store)
                    guard !Task.isCancelled else { return }
                    await self?.externalSubtitleLoaded(id, format: loaded.format)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.subtitleTrackFailed(id, reason: error.localizedDescription)
                }
            }
        case .embedded(let index):
            guard let parameters = current.demuxer.streamParameters[index], track.format.isText || track.format.isBitmap else {
                subtitleTrackFailed(id, reason: "\(track.format.tag): no decoder")
                return
            }
            subtitlePresenter.select(id, format: track.format)
            let feeder = SubtitlePacketFeeder(
                packets: current.demuxer.store,
                streamIndex: index,
                parameters: parameters,
                fileName: current.url.lastPathComponent,
                title: track.title,
                language: track.language,
                tracks: current.subtitles,
                presenter: subtitlePresenter
            )
            subtitleFeedTask = Task.detached(priority: .utility) { [weak self] in
                if let failure = await feeder.run() { await self?.subtitleTrackFailed(id, reason: failure) }
            }
            backfillBitmapSubtitles(around: currentTime)
        }
    }

    private func externalSubtitleLoaded(_ id: TrackID, format: SubtitleFormat) {
        guard session?.tracks.selectedSubtitle.trackID == id else { return }
        subtitlePresenter.select(id, format: format)
        refreshSubtitleCharsets()
    }

    /// Section 8.7: the track is listed as disabled with the reason, and subtitles go off.
    private func subtitleTrackFailed(_ id: TrackID, reason: String) {
        guard var current = session, let index = current.tracks.subtitles.firstIndex(where: { $0.id == id }) else { return }
        current.tracks.subtitles[index].unsupportedReason = reason
        if current.tracks.selectedSubtitle.trackID == id {
            current.tracks.selectedSubtitle = .off
            subtitlePresenter.select(nil, format: nil)
        }
        session = current
        eventSink.yield(.subtitleTrackFailed(id, reason: reason))
        emitTracks()
    }

    /// PGS and DVD tracks are not prefetched: after a seek the display set showing at the target
    /// is found by reading back up to 10 s on a private demuxer (section 8.1).
    private func backfillBitmapSubtitles(around time: MediaTime) {
        guard let current = session, case .embedded(let index)? = current.tracks.selectedSubtitle.trackID,
              current.tracks.selectedSubtitleTrack?.format.isBitmap == true else { return }
        let subtitleTime = max(time - .seconds(current.tracks.subtitleDelay), .zero)
        let from = max(subtitleTime - .seconds(10), .zero)
        if let done = bitmapBackfilled, done.contains(from), done.contains(subtitleTime) { return }
        bitmapBackfilled = from...subtitleTime
        bitmapBackfillTask?.cancel()
        let url = current.url
        let presenter = subtitlePresenter
        bitmapBackfillTask = Task.detached(priority: .utility) {
            let sets = SubtitlePacketFeeder.readBitmapSets(url: url, streamIndex: index, from: from, through: subtitleTime + .seconds(1))
            guard !Task.isCancelled else { return }
            presenter.insert(sets)
        }
    }

    /// New events of the selected text track (prefetch or the store) show without waiting for
    /// the next frame tick while paused.
    private func refreshSubtitleEvents(session current: Session) {
        guard let id = current.tracks.selectedSubtitle.trackID else { return }
        let count = current.subtitles.track(id)?.events.count ?? 0
        guard count != subtitleEventCount else { return }
        subtitleEventCount = count
        subtitlePresenter.requestRender()
    }

    /// A text track found to be GB18030, Big5 or Latin-1 says so on its second line (8.3).
    private func refreshSubtitleCharsets() {
        guard var current = session else { return }
        var changed = false
        for index in current.tracks.subtitles.indices {
            let id = current.tracks.subtitles[index].id
            guard let charset = current.subtitles.charset(of: id), charset != .utf8,
                  current.tracks.subtitles[index].charset != charset.rawValue else { continue }
            current.tracks.subtitles[index].charset = charset.rawValue
            changed = true
        }
        guard changed else { return }
        session = current
        emitTracks()
    }

    // MARK: Loops

    private func updateLoopBoundary() {
        if let observer = loopBoundaryObserver {
            synchronizer.removeTimeObserver(observer)
            loopBoundaryObserver = nil
        }
        guard session != nil, let range = loop.range else { return }
        let target = range.lowerBound
        loopBoundaryObserver = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: range.upperBound.cmTime)], queue: loopBoundaryQueue) { [weak self] in
            Task { await self?.loopBoundaryReached(target: target) }
        }
    }

    /// B reached: an exact seek to A, normally a store hit landing in one GOP decode (9.12).
    private func loopBoundaryReached(target: MediaTime) async {
        guard state == .playing, let range = loop.range, range.lowerBound == target,
              currentTime + .milliseconds(50) >= range.upperBound else { return }
        trace("loop: B \(range.upperBound) reached, back to \(target)")
        _ = await beginExact(.exact(target), requestedAt: monotonicNanos(), resume: true)
    }

    private func restartLoop(at target: MediaTime, endedAt end: MediaTime) async {
        guard state == .playing, !loop.allowsAutoAdvance else { return }
        trace("loop: end \(end) reached, back to \(target)")
        _ = await beginExact(.exact(target), requestedAt: monotonicNanos(), resume: true)
    }

    // MARK: Thumbnails

    /// Seeks hold generation until the latest one reports; the energy policy holds it while
    /// paused without recent pointer movement, while occluded and after the end (section 7.9).
    private func pauseThumbnails() {
        seekHoldsThumbnails = true
        updateThumbnailPause()
    }

    private func resumeThumbnails() {
        seekHoldsThumbnails = false
        updateThumbnailPause()
    }

    private func updateThumbnailPause() {
        let paused = seekHoldsThumbnails || energyHoldsThumbnails
        guard paused != thumbnailsPaused else { return }
        thumbnailsPaused = paused
        if paused {
            session?.thumbnails?.pause()
        } else {
            session?.thumbnails?.resume()
        }
    }

    // MARK: Setup

    private func makeVideoSession(format: VideoFormat, parameters: CodecParameters) throws -> VideoSession {
        let orderer = PresentationOrderer()
        let credits = FrameCredits(limit: VideoOutput.maxFramesAhead)
        let (frames, sink) = AsyncStream.makeStream(of: DecodedFrame.self)
        let handler = PlaybackEngine.decodeHandler(shared: shared, orderer: orderer, credits: credits, sink: sink, counters: counters)

        let environment = configuration.environment
        var support = HardwareDecodeSupport.none
        switch format.codec {
        case .h264: support.h264 = format.isHardwareDecodeSupported
        case .hevc: support.hevc = format.isHardwareDecodeSupported
        case .vp9: support.vp9 = format.isHardwareDecodeSupported
        case .av1: support.av1 = format.isHardwareDecodeSupported
        case .other: break
        }
        let policy = DecoderPolicy(environment: environment, hardwareEnabled: configuration.hardwareDecoding, support: support)
        let traits = VideoStreamTraits(codec: format.codecName, bitDepth: format.bitDepth, chroma: PlaybackEngine.chroma(parameters))
        let decision = policy.decide(for: traits)
        var decoder: any VideoDecoding
        if decision.kind == .hardware {
            do {
                decoder = try VTVideoDecoder(format: format, handler: handler)
            } catch {
                if decision.reason == .forcedByEnvironment { throw error }
                decoder = try SoftwareVideoDecoder(parameters: parameters, format: format, handler: handler)
                eventSink.yield(.decoderChanged(.software, reason: "VideoToolbox session failed: \(error)"))
            }
        } else {
            decoder = try SoftwareVideoDecoder(parameters: parameters, format: format, handler: handler)
        }
        // VP9 hybrid (D46): a second, software decoder for long exact seeks, with more threads
        // than playback needs, since nothing else decodes while a seek is in flight.
        var hybrid: SoftwareVideoDecoder?
        if configuration.hybridDecoding, decoder.kind == .hardware, policy.allowsHybridSeeks(for: traits) {
            hybrid = try? SoftwareVideoDecoder(
                parameters: parameters,
                format: format,
                threads: PlaybackEngine.hybridThreads,
                handler: handler
            )
        }
        // MPEG-TS can change resolution at a keyframe; libavcodec follows on its own, VideoToolbox
        // needs a session per format (section 7.10).
        let formatDecoders = decoder.kind == .hardware && format.convertsAnnexB ? FormatDecoders(handler: handler, parameters: parameters) : nil
        shared.formatDecoders.withLock { $0?.invalidateAll(); $0 = formatDecoders }
        // VideoToolbox decodes damaged VP9 tile data without an error; a parse-only check sees it.
        let tileCheck = configuration.checksVP9Tiles && format.codec == .vp9 && decoder.kind == .hardware
            ? VP9TileCheck(parameters: parameters) : nil
        shared.tileCheck.withLock { $0 = tileCheck }
        let frameDuration = format.frameDuration ?? MediaTime(microseconds: 33_333)
        let profile = DecodeProfile(
            codec: format.codecName,
            decoder: decoder.kind,
            width: format.width,
            height: format.height,
            frameDuration: frameDuration,
            hybridSoftwareSeeks: hybrid != nil
        )
        presenterTask?.cancel()
        presenterTask = Task.detached(priority: .userInitiated) { [shared, weak self] in
            await PlaybackEngine.present(frames: frames, credits: credits, shared: shared, engine: self)
        }
        return VideoSession(
            format: format,
            decoder: decoder,
            hybrid: hybrid,
            orderer: orderer,
            credits: credits,
            sink: sink,
            profile: profile,
            forced: decision.reason == .forcedByEnvironment
        )
    }

    private static func chroma(_ parameters: CodecParameters) -> ChromaSubsampling {
        guard let descriptor = av_pix_fmt_desc_get(AVPixelFormat(rawValue: parameters.pointer.pointee.format)) else { return .yuv420 }
        switch (descriptor.pointee.log2_chroma_w, descriptor.pointee.log2_chroma_h) {
        case (1, 1): return .yuv420
        case (1, 0): return .yuv422
        case (0, 0): return .yuv444
        default: return .other
        }
    }

    static func decodeHandler(
        shared: PipelineShared,
        orderer: PresentationOrderer,
        credits: FrameCredits,
        sink: AsyncStream<DecodedFrame>.Continuation,
        counters: EngineCounters? = nil
    ) -> DecodeHandler {
        { event in
            switch event {
            case .frame(let frame):
                counters?.framesDecoded.add(1, ordering: .relaxed)
                shared.goodFrames.add(1, ordering: .relaxed)
                // Older frames would confuse the orderer's expectations of the current run.
                guard frame.generation >= shared.currentGeneration else { return }
                // A frame libavcodec concealed errors in is shown, but counts as damage (7.10):
                // H.263 and MPEG-4 Part 2 hide a damaged block instead of failing the frame.
                if frame.concealedErrors, shared.isDamage(at: frame.time) {
                    trace("decoder concealed damage at \(frame.time)")
                    shared.damage.record(.video, at: frame.time)
                }
                orderer.receive(frame).forEach { sink.yield($0) }
            case .failed(let pts, let generation, let status, let count):
                trace("decode failed g\(generation) at \(MediaTime(pts)?.description ?? "-"): status \(status), \(count) in a row")
                orderer.fail(pts).forEach { sink.yield($0) }
                credits.release(generation: generation)
                // Damage, once the decoder has shown it can decode this stream (section 7.10);
                // before that it is the decoder failing, which the software fallback handles.
                if generation >= shared.currentGeneration, shared.goodFrames.load(ordering: .relaxed) > 0, shared.isDamage(at: MediaTime(pts)) {
                    shared.damage.record(.video, at: MediaTime(pts))
                    shared.videoAwaitsKeyframe.store(true, ordering: .releasing)
                }
                shared.failureHandler.withLock { $0 }?.call((generation, count, status))
            case .dropped(let pts, let generation):
                guard generation >= shared.currentGeneration else { return }
                trace("decoder dropped the frame at \(MediaTime(pts)?.description ?? "-")")
                orderer.fail(pts).forEach { sink.yield($0) }
                credits.release(generation: generation)
            }
        }
    }

    private func makeAudioSession(_ demuxer: Demuxer, streamIndex index: Int) -> AudioSession? {
        guard let parameters = demuxer.streamParameters[index] ?? demuxer.audioParameters.flatMap({ $0.streamIndex == index ? $0 : nil })
        else { return nil }
        let decoder: AudioDecoder
        do {
            decoder = try AudioDecoder(
                codecParameters: parameters.pointer,
                timeBase: AVRational(num: parameters.timeBase.num, den: parameters.timeBase.den)
            )
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            trace("audio stream \(index) has no decoder: \(reason)")
            audioFailure = (index, reason)
            return nil
        }
        let codec = decoder.codecName
        decoder.timestampOffset = audioDelay
        let thread = AudioDecodeThread(decoder: decoder)
        let shared = self.shared
        thread.setDamageHandler { time, generation in
            guard shared.isCurrent(generation) else { return }
            shared.damage.record(.audio, at: time)
        }
        audioConsumerTask?.cancel()
        audioConsumerTask = Task.detached(priority: .userInitiated) { [shared, weak self] in
            await PlaybackEngine.consumeAudio(thread: thread, shared: shared, engine: self)
        }
        return AudioSession(thread: thread, streamIndex: index, codec: codec)
    }

    private func startWorkers() {
        shared.failureHandler.withLock { handler in
            handler = SendableCallback { [weak self] failure in
                Task { await self?.handleDecodeFailure(generation: failure.generation, consecutive: failure.consecutive, status: failure.status) }
            }
        }
        if tickerTask == nil {
            let wakes = tickerWakes
            tickerTask = Task { [weak self] in
                var parked = wakes.makeAsyncIterator()
                while !Task.isCancelled {
                    // Nil once the engine is gone; 0 parks until `applyEnergy` wakes the task.
                    guard let interval = await self?.housekeepingDelay() else { return }
                    if interval > 0 {
                        try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(EnergyPolicy.leeway(forInterval: interval)))
                    } else if await parked.next() == nil {
                        return
                    }
                    guard let self else { return }
                    await self.tick()
                }
            }
        }
    }

    /// An open failed: `.problem` with the classified `MediaProblem` (section 9.14), then
    /// `.failed` with the engine error, whose description is the technical detail line.
    private func fail(_ error: any Error, url: URL) throws -> Never {
        let engineError = (error as? EngineError) ?? .openFailed(String(describing: error))
        let problem: MediaProblem = volumeCheck(url).map { .volumeGone($0) }
            ?? MediaProblem.classify(from: engineError, path: "", mountedVolumes: [])
        trace("open failed: \(problem.kind): \(engineError.errorDescription ?? "")")
        setState(.failed)
        eventSink.yield(.problem(problem))
        eventSink.yield(.failed(engineError))
        throw engineError
    }

    private func closeSession() async {
        guard let current = session else { return }
        sendPosition(.closed)
        _ = nextGeneration()
        coalescer.cancel()
        for task in [audioFeedTask, backgroundExactTask, audioResumeTask, scrubWatchdogTask, subtitleFeedTask, subtitleLoadTask, bitmapBackfillTask] {
            task?.cancel()
        }
        subtitleFeedTask = nil
        subtitleLoadTask = nil
        bitmapBackfillTask = nil
        current.prefetcher?.cancel()
        current.thumbnails?.close()
        thumbnailsPaused = false
        seekHoldsThumbnails = false
        audioSuspendTask?.cancel()
        audioSuspendTask = nil
        audioFeedSuspended = false
        videoStoppedForOcclusion = false
        feederParkTask?.cancel()
        feederParkTask = nil
        feederParkedForPause = false
        subtitlePresenter.reset(store: nil, videoWidth: 0, videoHeight: 0)
        _ = await stopFeeder()
        parkedFeed = nil
        current.video?.decoder.invalidate()
        current.video?.hybrid?.invalidate()
        shared.formatDecoders.withLock { $0?.invalidateAll(); $0 = nil }
        shared.tileCheck.withLock { $0 = nil }
        current.video?.sink.finish()
        current.audio?.thread.stop()
        current.demuxer.stop()
        presenterTask = nil
        audioConsumerTask = nil
        synchronizer.rate = 0
        await reattachVideoRenderer()
        if let output = shared.videoOutput.withLock({ $0 }) {
            await output.flush(removingDisplayedImage: true)
        }
        if let audio = shared.audioOutput.withLock({ $0 }) { await audio.flush() }
        displaySleep.allowSleep()
        displayedKeyframe = nil
        lastScrubTarget = nil
        lastPeriodicSave = nil
        lastPlayheadUpdate = nil
        shared.recentFrames.withLock { $0.removeAll() }
        shared.lastLandedFrame.withLock { $0 = nil }
        session = nil
        updateLoopBoundary()
        setState(.idle)
    }

    // MARK: Requests

    private var exactInFlight: Bool {
        shared.run.withLock { run in
            guard let run, run.generation == generation else { return false }
            return run.request.isExact && run.targetLandedNanos == nil
        }
    }

    /// Starts a request; returns its generation, or nil when a scrub was stored as pending.
    private func submit(_ request: SeekRequest, requestedAt: UInt64) async -> UInt64? {
        guard session != nil, state.hasMedia else { return nil }
        switch request {
        case .scrub(let time):
            guard let started = coalescer.request(time) else { return nil }
            return await beginScrub(started, requestedAt: requestedAt)
        case .exact(let time):
            // The release of a drag that rested: the background exact seek already covers it.
            if let background = backgroundExactGeneration, background == generation,
               let run = shared.run.withLock({ $0 }), run.generation == background, run.request.target == time {
                if backgroundExactLanded {
                    settleBackgroundExact()
                } else {
                    // Still decoding: it lands as an ordinary exact seek.
                    backgroundExactGeneration = nil
                }
                return background
            }
            return await beginExact(request, requestedAt: requestedAt, resume: nil)
        }
    }

    /// Bumps the generation. Work and frames of older generations are dropped from now on; a seek
    /// that had not landed is reported as cancelled.
    private func nextGeneration() -> UInt64 {
        generation += 1
        shared.generation.store(generation, ordering: .releasing)
        // A seek restarts at a keyframe, so damage before it no longer holds video back.
        shared.videoAwaitsKeyframe.store(false, ordering: .releasing)
        backgroundExactGeneration = nil
        backgroundExactLanded = false
        let superseded = shared.run.withLock { run -> SeekRun? in
            guard let current = run, current.targetLandedNanos == nil else { return nil }
            run = nil
            return current
        }
        if let superseded {
            let report = superseded.report(bytesNow: session?.demuxer.bytesRead ?? 0, cancelled: true, handoffs: decoderHandoffs)
            complete(report)
        }
        return generation
    }

    private func clamp(_ time: MediaTime) -> MediaTime {
        guard let session else { return time }
        var result = max(time, session.start)
        if let duration = session.info.duration {
            let end = (session.info.startTime ?? .zero) + duration
            if end > session.start { result = min(result, end) }
        }
        // A seek past the end of the data lands on the last frame (section 7.10).
        if let dataEnd = session.demuxer.dataEnd { result = min(result, max(dataEnd, session.start)) }
        return result
    }

    private func wantsPlayback(_ resume: Bool?) -> Bool {
        if let resume { return resume }
        switch state {
        case .playing: return true
        case .seeking: return resumeAfterSeek
        default: return false
        }
    }

    /// Exact seek, design section 7.5 steps 1 to 4. Steps 5 to 8 complete in the feeder, the
    /// presenter and `handleLanding`.
    private func beginExact(_ request: SeekRequest, requestedAt: UInt64, resume: Bool?) async -> UInt64? {
        guard let current = session else { return nil }
        let target = clamp(request.target)
        coalescer.cancel()
        backgroundExactTask?.cancel()
        scrubWatchdogTask?.cancel()
        audioResumeTask?.cancel()
        resumeAfterSeek = wantsPlayback(resume)
        let generation = nextGeneration()
        if state != .opening { setState(.seeking) }
        synchronizer.setRate(0, time: target.cmTime)
        setRealTime(false)
        resetEndTracking()
        pauseThumbnails()
        // Text and picture change together: the subtitle updates when the target frame lands.
        subtitlePresenter.update { $0.holding = true }
        current.audio?.thread.seek(dropBefore: target - audioDelay, generation: generation, timestampOffset: audioDelay)
        audioFeedTask?.cancel()

        let demuxer = current.demuxer
        var run = SeekRun(
            generation: generation,
            request: request,
            clockTime: target,
            requestedAtNanos: requestedAt,
            start: .keyframe,
            startKeyframe: nil,
            storeHit: true,
            bytesAtStart: demuxer.bytesRead
        )
        var demuxerMiss = false
        // Installed before the first await: a seek that supersedes this one while it waits for the
        // feeder must find a run to report as cancelled.
        shared.run.withLock { $0 = run }
        if let video = current.video {
            await releaseQueuedFrames(generation: generation)
            // A park still in flight (a seek right after a paused landing) holds the feeder's
            // state between its stop and `parkedFeed`; wait for it, or the state is lost and the
            // seek restarts from the keyframe instead of continuing the decoder.
            if let task = feederParkTask {
                await task.value
                feederParkTask = nil
            }
            let previous = await stopFeeder()
            guard generation == self.generation else {
                parkedFeed = previous
                return generation
            }
            estimateSkippable()
            let profile = session?.video?.profile ?? video.profile
            run.decoder = video.decoder.kind
            let index = demuxer.keyframeIndex
            // Without a complete index the keyframe before the target may not have been read yet;
            // then the demuxer seeks to the target itself and finds it.
            let known = demuxer.keyframe(atOrBefore: target).known
            // A pending demuxer seek would reset the store under a continued decode.
            let continuable = known && !demuxer.hasPendingSeek
                ? PlaybackEngine.continuablePosition(previous, target: target, index: index, store: demuxer.store) : nil
            let plan = planner.planExact(target: target, index: index, decoder: continuable, profile: profile)
            trace("exact g\(generation) \(target): \(plan.start) from \(plan.startPTS), \(plan.framesToDecode) frames, preview \(plan.showsKeyframePreview)")
            let feedState: VideoFeedState
            let spec: FeedSpec
            run.decoder = plan.decoder
            if plan.start == .continueDecoder, let previous {
                run.start = .continueDecoder
                feedState = previous
                // The store reads ahead from its playhead; the decode continues from here to the target.
                demuxer.store.setPlayhead(target, readThrough: target)
                spec = FeedSpec(
                    generation: generation, target: target, keyframe: nil, preview: false, scrubOnly: false,
                    awaitDemuxerSeek: false, decoder: plan.decoder
                )
            } else {
                video.decoder.reset(generation: generation)
                video.hybrid?.reset(generation: generation)
                shared.formatDecoders.withLock { $0 }?.cancel(olderThan: generation)
                let keyframe = known ? (plan.keyframe?.pts ?? current.start) : target
                let hit = demuxer.seek(toKeyframe: keyframe, readThrough: target, generation: generation)
                demuxerMiss = !hit
                run.storeHit = hit
                run.startKeyframe = keyframe
                feedState = VideoFeedState()
                spec = FeedSpec(
                    generation: generation,
                    target: target,
                    keyframe: keyframe,
                    // An intra-refresh stream has one keyframe, the first frame of the file: a
                    // preview would flash the start of the file (section 7.10).
                    preview: (plan.showsKeyframePreview && !(demuxer.hasCompleteIndex && index.count <= 1)) || forceKeyframePreviewForTesting,
                    scrubOnly: false,
                    awaitDemuxerSeek: !hit,
                    decoder: plan.decoder
                )
            }
            video.orderer.reset()
            // A software run of the hybrid needs credits for every frame its threads hold back.
            let hybridCredits = plan.decoder == .software ? video.hybrid.map { $0.outputDelay + 2 } : nil
            video.credits.reset(generation: generation, limit: hybridCredits)
            shared.run.withLock { $0 = run }
            await prepareOutputs(generation: generation)
            guard generation == self.generation else { return generation }
            videoStoppedForOcclusion = false
            feederParkedForPause = false
            startFeeder(feedState, spec: spec, video: video, demuxer: demuxer)
        } else {
            let hit = demuxer.seek(toKeyframe: target, readThrough: target, generation: generation)
            demuxerMiss = !hit
            run.storeHit = hit
            shared.run.withLock { $0 = run }
            await prepareOutputs(generation: generation)
            guard generation == self.generation else { return generation }
        }
        startAudioFeed(generation: generation, target: target, awaitDemuxerSeek: demuxerMiss)
        if current.video == nil {
            // No picture to wait for: the clock is set, so the seek has landed. It completes on
            // the next turn of the actor, after the caller has recorded the generation (a
            // background exact seek must be known as one when it lands).
            Task { [weak self] in await self?.landWithoutVideo(generation: generation) }
        }
        return generation
    }

    /// Completes an exact seek of a file without video, like the presenter does for a frame.
    private func landWithoutVideo(generation landed: UInt64) {
        guard landed == generation else { return }
        let now = monotonicNanos()
        var didLand = false
        shared.updateRun(generation: landed) { run in
            guard run.targetLandedNanos == nil else { return }
            run.targetLandedNanos = now
            run.landedPTS = run.clockTime
            didLand = true
        }
        if didLand { handleLanding(.target(generation: landed)) }
    }

    /// The decoder position the planner may continue from. Design section 7.5 step 2 allows it
    /// only when no keyframe lies between it and the target: a restart from that keyframe decodes
    /// a subset of the same frames. The frame displayed at the target must also still be ahead
    /// of the decoder: when it was submitted already (the target lies within the last submitted
    /// frame, or a B-frame displayed earlier follows it in decode order), continuing would land on
    /// some other frame. That needs the store to hold the target's frame; otherwise it restarts.
    static func continuablePosition(_ feed: VideoFeedState?, target: MediaTime, index: KeyframeIndex, store: PacketStore) -> DecoderPosition? {
        guard let position = feed?.decoderPosition(storeEpoch: store.epoch), position.lastSubmittedPTS < target else { return nil }
        if let keyframe = index.entry(atOrBefore: target), keyframe.pts > position.lastSubmittedPTS { return nil }
        guard let shown = store.videoFramePTS(atOrBefore: target), shown > position.lastSubmittedPTS else { return nil }
        return position
    }

    /// Keyframe-only seek while dragging (design section 7.5, scrub steps 3 to 5).
    private func beginScrub(_ time: MediaTime, requestedAt: UInt64) async -> UInt64? {
        guard let current = session else { return nil }
        let target = clamp(time)
        backgroundExactTask?.cancel()
        audioResumeTask?.cancel()
        resumeAfterSeek = wantsPlayback(nil)
        let generation = nextGeneration()
        setState(.seeking)
        lastScrubTarget = target
        resetEndTracking()
        pauseThumbnails()
        // The line shown while scrubbing is the one at the pointer, not at the keyframe (8.6).
        subtitlePresenter.update { settings in
            settings.holding = false
            settings.scrubTime = target
        }
        current.audio?.thread.seek(dropBefore: nil, generation: generation)
        audioFeedTask?.cancel()
        let demuxer = current.demuxer
        var run = SeekRun(
            generation: generation,
            request: .scrub(time),
            clockTime: target,
            requestedAtNanos: requestedAt,
            start: .keyframe,
            startKeyframe: nil,
            storeHit: true,
            bytesAtStart: demuxer.bytesRead
        )
        guard let video = current.video else {
            // No picture: the clock follows the drag.
            synchronizer.setRate(0, time: target.cmTime)
            run.start = .alreadyDisplayed
            run.landedPTS = target
            run.targetLandedNanos = monotonicNanos()
            shared.run.withLock { $0 = run }
            complete(run.report(bytesNow: demuxer.bytesRead, cancelled: false, handoffs: decoderHandoffs))
            finishScrub(generation: generation)
            return generation
        }
        let keyframe: MediaTime
        // A keyframe the index does not know yet may lie between the last known one and the
        // target; the demuxer then seeks to the target and the feeder takes the keyframe it finds.
        let plan: ScrubPlan = demuxer.keyframe(atOrBefore: target).known
            ? planner.planScrub(target: target, index: demuxer.keyframeIndex, displayedKeyframe: displayedKeyframe)
            : .showKeyframe(KeyframeIndex.Entry(pts: target))
        switch plan {
        case .alreadyDisplayed:
            run.start = .alreadyDisplayed
            run.startKeyframe = displayedKeyframe
            run.landedPTS = displayedKeyframe
            run.targetLandedNanos = monotonicNanos()
            shared.run.withLock { $0 = run }
            complete(run.report(bytesNow: demuxer.bytesRead, cancelled: false, handoffs: decoderHandoffs))
            finishScrub(generation: generation)
            return generation
        case .noKeyframe:
            keyframe = current.start
        case .showKeyframe(let entry):
            keyframe = entry.pts
        }
        synchronizer.setRate(0, time: keyframe.cmTime)
        setRealTime(false)
        run.startKeyframe = keyframe
        shared.run.withLock { $0 = run }
        await releaseQueuedFrames(generation: generation)
        _ = await stopFeeder()
        guard generation == self.generation else { return generation }
        video.decoder.reset(generation: generation)
        video.hybrid?.reset(generation: generation)
        shared.formatDecoders.withLock { $0 }?.cancel(olderThan: generation)
        video.orderer.reset()
        video.credits.reset(generation: generation)
        let hit = demuxer.seek(toKeyframe: keyframe, generation: generation)
        run.storeHit = hit
        run.startKeyframe = keyframe
        shared.run.withLock { $0 = run }
        await prepareOutputs(generation: generation)
        guard generation == self.generation else { return generation }
        let spec = FeedSpec(
            generation: generation, target: nil, keyframe: keyframe, preview: false, scrubOnly: true,
            awaitDemuxerSeek: !hit, decoder: video.decoder.kind
        )
        videoStoppedForOcclusion = false
        feederParkedForPause = false
        startFeeder(VideoFeedState(), spec: spec, video: video, demuxer: demuxer)
        scrubWatchdogTask?.cancel()
        scrubWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: PlaybackEngine.scrubWatchdog)
            guard !Task.isCancelled else { return }
            await self?.scrubTimedOut(generation: generation)
        }
        return generation
    }

    /// Before the old feeder stops: the receiver gives back the frames it queued and only the
    /// frame on screen stays in `recentFrames`. A software decoder converts into a pool of 12
    /// buffers and waits for one to come back (up to 5 s), so a feeder draining at the end of the
    /// file while paused would otherwise hold up the seek.
    private func releaseQueuedFrames(generation: UInt64) async {
        guard !videoRendererDetached, let output = shared.videoOutput.withLock({ $0 }) else { return }
        await output.setGeneration(generation)
        await output.flush(removingDisplayedImage: false)
        let clock = currentTime
        shared.recentFrames.withLock { frames in
            let shown = frames.last { (MediaTime($0.presentationTime) ?? $0.time) <= clock + .milliseconds(1) } ?? frames.first
            frames = shown.map { [$0] } ?? []
        }
    }

    /// Step 1: the old picture stays (no image removal), queued frames and audio go.
    private func prepareOutputs(generation: UInt64) async {
        await reattachVideoRenderer()
        if let output = shared.videoOutput.withLock({ $0 }) {
            await output.setGeneration(generation)
            await output.flush(removingDisplayedImage: false)
        }
        if let audio = shared.audioOutput.withLock({ $0 }) { await audio.flush() }
    }

    private func resetEndTracking() {
        shared.videoEnded.store(false, ordering: .releasing)
        shared.audioEnded.store(false, ordering: .releasing)
        shared.lastVideoEnd.withLock { $0 = nil }
        shared.lastAudioEnd.withLock { $0 = nil }
    }

    // MARK: Feeder

    /// Tests: handles a renderer event as if the attached audio renderer had sent it. Tests attach
    /// no renderer (they stay silent), so this is the only way to reach the device-change path.
    func deliverAudioEventForTesting(_ event: AudioOutput.Event) async {
        await handleAudioEvent(event)
    }

    /// Tests: the audio decode thread's restart count. Buffers tagged with it were decoded after
    /// the latest restart; older ones may still reach the observer just after a restart begins.
    var audioRestartCountForTesting: UInt64? { session?.audio?.thread.restartCount }

    /// Tests: asks for a keyframe preview on every restarting exact seek, whatever the plan says.
    func setForceKeyframePreviewForTesting(_ enabled: Bool) {
        forceKeyframePreviewForTesting = enabled
    }

    /// Tests: the next audio packet the audio feeder submits is held back for `milliseconds`
    /// (not cancellable), like a feeder preempted between its last check and its submit.
    func holdNextAudioSubmitForTesting(milliseconds: Int) {
        shared.audioSubmitHoldForTesting.store(milliseconds, ordering: .relaxed)
    }

    /// Tests: makes every demuxer seek that needs I/O of the open file take `milliseconds` longer.
    func setDemuxerSeekDelayForTesting(milliseconds: Int) {
        session?.demuxer.seekDelayForTesting.store(milliseconds, ordering: .relaxed)
    }

    /// Tests: stops the feeder where it is, as the next seek would, and keeps its state for that
    /// seek. Returns the last pts submitted to the decoder.
    func parkDecoderForTesting() async -> MediaTime? {
        let state = await stopFeeder()
        parkedFeed = state
        return state?.lastSubmittedPTS
    }

    /// Stops the running feeder and returns the decoder position it reached.
    private func stopFeeder() async -> VideoFeedState? {
        if let task = feederTask {
            task.cancel()
            let state = await task.value
            if feederTask == task {
                feederTask = nil
                parkedFeed = state
            }
        }
        defer { parkedFeed = nil }
        return parkedFeed
    }

    private func startFeeder(_ state: VideoFeedState, spec: FeedSpec, video: VideoSession, demuxer: Demuxer) {
        let feeder = VideoFeeder(
            demuxer: demuxer,
            format: video.format,
            decoder: video.decoder,
            software: video.hybrid,
            orderer: video.orderer,
            credits: video.credits,
            shared: shared,
            frames: video.sink
        )
        feederTask = Task.detached(priority: .userInitiated) {
            await feeder.run(state, spec: spec)
        }
    }

    /// `target` is clock time; the feed starts at the media time that plays then (the audio delay).
    private func startAudioFeed(generation: UInt64, target clockTarget: MediaTime, awaitDemuxerSeek: Bool) {
        guard let current = session, let audio = current.audio else { return }
        audioFeedSuspended = false
        let delay = audioDelay
        let target = clockTarget - delay
        let synchronizer = self.synchronizer
        let feeder = PacedAudioFeeder(
            demuxer: current.demuxer,
            streamIndex: audio.streamIndex,
            thread: audio.thread,
            shared: shared,
            // Paced in media time: the packet at media time t plays at clock t + delay.
            clock: { (MediaTime(synchronizer.currentTime()) ?? .zero) - delay },
            rate: { Double(synchronizer.rate) }
        )
        audioFeedTask = Task.detached(priority: .userInitiated) {
            await feeder.run(generation: generation, from: target, awaitDemuxerSeek: awaitDemuxerSeek)
        }
    }

    private func setRealTime(_ realTime: Bool) {
        (session?.video?.decoder as? VTVideoDecoder)?.setRealTime(realTime)
    }

    /// Learns how many frames before a target need no decode, from the first GOP read.
    private func estimateSkippable() {
        guard var video = session?.video, !video.skippableEstimated, let store = session?.demuxer.store else { return }
        let keys = store.storedKeyframes
        guard keys.count >= 2, let packets = store.gopPackets(keyframe: keys[0]), packets.count > 2 else { return }
        let disposable = packets.dropFirst().filter { video.format.isDisposable($0) }.count
        video.profile.skippableFraction = Double(disposable) / Double(packets.count - 1)
        video.skippableEstimated = true
        session?.video = video
    }

    // MARK: Landing

    /// The presenter enqueued the preview or target frame of `landing`'s generation.
    fileprivate func handleLanding(_ landing: Landing) {
        guard case .target(let landed) = landing, landed == generation,
              let run = shared.run.withLock({ $0 }), run.generation == landed, let current = session else { return }
        let report = run.report(bytesNow: current.demuxer.bytesRead, cancelled: false, handoffs: decoderHandoffs)
        trace("landed g\(landed) \(run.request) at \(run.landedPTS?.description ?? "-") in \(report.targetMilliseconds ?? -1) ms")
        complete(report)
        if run.start == .keyframe, run.framesDecoded > 30, let milliseconds = report.targetMilliseconds, let video = current.video {
            planner.rates.record(
                codec: video.profile.codec,
                decoder: run.decoder,
                width: video.profile.width,
                height: video.profile.height,
                frames: run.framesDecoded,
                seconds: milliseconds / 1_000
            )
        }
        switch run.request.kind {
        case .scrub:
            displayedKeyframe = run.landedPTS
            // The clock shows the keyframe on screen (the feeder may have found a different one
            // than the index predicted).
            if let landedPTS = run.landedPTS { synchronizer.setRate(0, time: landedPTS.cmTime) }
            scrubWatchdogTask?.cancel()
            finishScrub(generation: landed)
        case .exact:
            displayedKeyframe = run.landedPTS.flatMap { pts in run.startKeyframe == pts ? pts : nil }
            subtitlePresenter.update { settings in
                settings.holding = false
                settings.scrubTime = nil
            }
            backfillBitmapSubtitles(around: run.clockTime)
            sendPosition(.seekSettled, at: run.clockTime)
            if landed == backgroundExactGeneration {
                // The pointer is still down: playback resumes only on release.
                backgroundExactLanded = true
            } else if resumeAfterSeek {
                resumeWhenAudioPrimed(generation: landed, at: run.clockTime)
            } else {
                setState(.paused)
            }
        }
    }

    private func finishScrub(generation landed: UInt64) {
        if let next = coalescer.finish() {
            Task { [weak self] in await self?.runPendingScrub(next) }
            return
        }
        guard let target = lastScrubTarget else { return }
        let delay = configuration.backgroundExactDelay
        backgroundExactTask?.cancel()
        backgroundExactTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.startBackgroundExact(after: landed, target: target)
        }
    }

    /// Runs the latest scrub that waited, unless an exact seek cancelled it in the meantime.
    private func runPendingScrub(_ time: MediaTime) async {
        guard coalescer.inFlight == time else { return }
        _ = await beginScrub(time, requestedAt: monotonicNanos())
    }

    private func startBackgroundExact(after scrubGeneration: UInt64, target: MediaTime) async {
        guard scrubGeneration == generation, state == .seeking else { return }
        let started = await beginExact(.exact(target), requestedAt: monotonicNanos(), resume: nil)
        backgroundExactGeneration = started
    }

    /// The drag was released on the position the background exact seek already shows.
    private func settleBackgroundExact() {
        guard let run = shared.run.withLock({ $0 }), run.generation == backgroundExactGeneration else { return }
        backgroundExactGeneration = nil
        backgroundExactLanded = false
        if resumeAfterSeek {
            resumeWhenAudioPrimed(generation: run.generation, at: run.clockTime)
        } else {
            setState(.paused)
        }
    }

    private func scrubTimedOut(generation timedOut: UInt64) {
        guard timedOut == generation, !(shared.run.withLock { $0?.targetLandedNanos != nil }) else { return }
        finishScrub(generation: timedOut)
    }

    /// Step 7: resume once audio is primed (or there is none, or it takes too long).
    private func resumeWhenAudioPrimed(generation landed: UInt64, at time: MediaTime) {
        let needsAudio = session?.audio != nil && !shared.audioEnded.load(ordering: .acquiring)
        if !needsAudio || shared.audioPrimedGeneration.load(ordering: .acquiring) == landed {
            startPlaying(at: time)
            return
        }
        audioResumeTask?.cancel()
        audioResumeTask = Task { [weak self] in
            try? await Task.sleep(for: PlaybackEngine.audioPrimeTimeout)
            guard !Task.isCancelled else { return }
            await self?.audioPrimed(generation: landed)
        }
    }

    fileprivate func audioPrimed(generation primed: UInt64) {
        guard primed == generation, state == .seeking, resumeAfterSeek,
              let run = shared.run.withLock({ $0 }), run.generation == primed, run.targetLandedNanos != nil else { return }
        audioResumeTask?.cancel()
        startPlaying(at: run.clockTime)
    }

    private func startPlaying(at time: MediaTime?) {
        resumeAudioFeed()
        if let time {
            synchronizer.setRate(playbackRate, time: time.cmTime)
        } else {
            synchronizer.rate = playbackRate
        }
        setRealTime(true)
        lastPeriodicSave = currentTime
        setState(.playing)
    }

    // MARK: Audio device events

    /// Design section 7.4: after a device or configuration change the renderer suggests a flush;
    /// audio restarts from the current time in the same generation, so video is not disturbed.
    /// Unverified on hardware (tests stay silent), so it is traced.
    private func handleAudioEvent(_ event: AudioOutput.Event) async {
        trace("audio renderer event \(event)")
        guard case .flushSuggested = event, session?.audio != nil, state == .playing || state == .paused else { return }
        await restartAudio()
    }

    /// Restarts audio at the clock in the current generation, so video is not disturbed: after a
    /// device change, an audio track switch (`replaced` is the old session, already swapped out)
    /// or a new audio delay.
    private func restartAudio(replaced: AudioSession? = nil, oldConsumer: Task<Void, Never>? = nil) async {
        audioRestartsInFlight += 1
        defer { audioRestartsInFlight -= 1 }
        // The old feeder must be gone before the reset: it shares this generation, so a packet it
        // submits afterwards would reach the decoder out of order.
        let previous = audioFeedTask
        let restartGeneration = generation
        previous?.cancel()
        replaced?.thread.stop()
        // Stops decoding ahead at once: buffers decoded before this are stale from now on.
        session?.audio?.thread.seek(dropBefore: nil, generation: generation)
        await previous?.value
        if let oldConsumer {
            // A buffer of the old track still on its way to the renderer must not land after the flush.
            if let output = shared.audioOutput.withLock({ $0 }) { await output.flush() }
            await oldConsumer.value
        }
        guard restartGeneration == generation, audioFeedTask == previous, let current = session, let audio = current.audio else {
            trace("audio restart abandoned: a seek started meanwhile")
            return
        }
        let clockTime = audioRestartTime()
        lastAudioRestartTimeForTesting = clockTime
        trace("audio restart at \(clockTime), delay \(audioDelay)")
        audio.thread.seek(dropBefore: clockTime - audioDelay, generation: generation, timestampOffset: audioDelay)
        shared.audioEnded.store(false, ordering: .releasing)
        if let output = shared.audioOutput.withLock({ $0 }) { await output.flush() }
        // The renderer holds nothing past the clock now; a paused feed resumes from here.
        shared.lastAudioEnd.withLock { $0 = nil }
        guard restartGeneration == generation, audioFeedTask == previous else { return }
        audioFeedSuspended = false
        startAudioFeed(generation: generation, target: clockTime, awaitDemuxerSeek: current.demuxer.hasPendingSeek)
        if state == .paused || state == .ready { scheduleAudioSuspension() }
    }

    /// The clock time audio restarts at: the seek target while a seek is in flight, else the clock.
    private func audioRestartTime() -> MediaTime {
        if state == .seeking, let run = shared.run.withLock({ $0 }), run.generation == generation { return run.clockTime }
        return currentTime
    }

    // MARK: Decoder failures

    /// Tests: the hardware decoder fails as if three frames in a row had failed, which switches
    /// the stream to software.
    func simulateHardwareFailuresForTesting() async {
        await handleDecodeFailure(generation: generation, consecutive: DecoderFailureTracker.failureLimit, status: -12909)
    }

    private func handleDecodeFailure(generation failed: UInt64, consecutive: Int, status: Int32) async {
        // A scrub decodes its keyframe alone: when that fails, nothing else will land it.
        if failed == generation, let run = shared.run.withLock({ $0 }), run.generation == failed,
           run.request.kind == .scrub, run.targetSubmitted, run.targetLandedNanos == nil {
            trace("scrub g\(failed) keyframe failed to decode (status \(status))")
            settleWithoutFrame(generation: failed, at: shared.recentFrames.withLock { $0.last }.flatMap { MediaTime($0.presentationTime) })
        }
        guard failed == generation, consecutive >= DecoderFailureTracker.failureLimit,
              var current = session, var video = current.video, video.decoder.kind == .hardware, !video.forced,
              let parameters = current.demuxer.videoParameters else { return }
        // Bad data in a stream VideoToolbox has decoded is damage: the feeder skips to the next
        // keyframe (section 7.10) and the hardware decoder stays.
        if status == kVTVideoDecoderBadDataErr, shared.goodFrames.load(ordering: .relaxed) > 0 { return }
        let handler = PlaybackEngine.decodeHandler(shared: shared, orderer: video.orderer, credits: video.credits, sink: video.sink, counters: counters)
        guard let software = try? SoftwareVideoDecoder(parameters: parameters, format: video.format, handler: handler) else { return }
        _ = await stopFeeder()
        parkedFeed = nil
        video.decoder.invalidate()
        video.hybrid?.invalidate()
        video.hybrid = nil
        // libavcodec follows in-band format changes itself.
        shared.formatDecoders.withLock { $0?.invalidateAll(); $0 = nil }
        shared.tileCheck.withLock { $0 = nil }
        video.decoder = software
        video.profile.decoder = .software
        video.profile.hybridSoftwareSeeks = false
        current.video = video
        current.info.videoDecoder = .software
        session = current
        eventSink.yield(.decoderChanged(.software, reason: "\(consecutive) consecutive VideoToolbox failures (status \(status))"))
        // Switching at a keyframe: restart the current position from its keyframe in software.
        let resume = state == .playing || (state == .seeking && resumeAfterSeek)
        _ = await beginExact(.exact(currentTime), requestedAt: monotonicNanos(), resume: resume)
    }

    // MARK: Reports

    private func complete(_ report: SeekReport) {
        // Thumbnails wait while any seek is in flight and go on after the latest one reports.
        if report.generation == generation {
            resumeThumbnails()
            if !report.cancelled { sendTime() }
        }
        lastReport = report
        completedReports[report.generation] = report
        if completedReports.count > 16, let oldest = completedReports.keys.min() {
            completedReports.removeValue(forKey: oldest)
        }
        eventSink.yield(.seekCompleted(report))
        reportWaiters.removeValue(forKey: report.generation)?.forEach { $0.resume(returning: report) }
    }

    private func waitForReport(generation awaited: UInt64, timeout: Duration) async -> SeekReport? {
        if let report = completedReports[awaited] { return report }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.expireWaiters(generation: awaited)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            reportWaiters[awaited, default: []].append(continuation)
        }
    }

    private func expireWaiters(generation expired: UInt64) {
        reportWaiters.removeValue(forKey: expired)?.forEach { $0.resume(returning: nil) }
    }

    // MARK: Clock tick

    private func tick() {
        guard let current = session, state.hasMedia else { return }
        let now = currentTime
        let nanos = monotonicNanos()
        if state == .playing {
            // The demuxer refills in steps of `playheadStep`, not a few packets every tick.
            if let moved = lastPlayheadUpdate, now >= moved, now - moved < PlaybackEngine.playheadStep {} else {
                lastPlayheadUpdate = now
                current.demuxer.store.setPlayhead(now)
            }
            if let last = lastPeriodicSave, now - last >= PlaybackEngine.positionSaveInterval || now < last {
                lastPeriodicSave = now
                sendPosition(.periodic, at: now)
            }
            if let target = loop.loopTarget(at: now) {
                // The boundary observer normally fires first; this catches a missed one.
                _ = Task { [weak self] in await self?.loopBoundaryReached(target: target) }
            }
            checkEnd(now: now, session: current)
            if !videoStoppedForOcclusion { releaseStalledFrames(now: now, session: current) }
        }
        if state == .seeking { landIfVideoEnded(now: nanos) }
        refreshSubtitleEvents(session: current)
        if nanos &- lastStoredRangeNanos > 1_000_000_000 {
            lastStoredRangeNanos = nanos
            refreshSubtitleCharsets()
            let range = current.demuxer.store.storedRange
            if range != lastStoredRange {
                lastStoredRange = range
                eventSink.yield(.storedRange(range))
            }
        }
    }

    /// A seek whose video stream ended without its target frame (every frame after the target
    /// failed to decode, or the data stopped first) settles on the last frame shown, so it never
    /// waits forever (section 7.10).
    private func landIfVideoEnded(now: UInt64) {
        guard shared.videoEnded.load(ordering: .acquiring),
              now &- shared.videoEndedNanos.load(ordering: .acquiring) > PlaybackEngine.endOfDataLandingDelay,
              let run = shared.run.withLock({ $0 }), run.generation == generation, run.targetLandedNanos == nil else { return }
        trace("seek g\(generation) settles at the end of the video data")
        settleWithoutFrame(generation: generation, at: shared.recentFrames.withLock { $0.last }.flatMap { MediaTime($0.presentationTime) })
    }

    /// Completes the seek of `generation` on the picture already shown (`shown`, else the
    /// requested time): no frame of its own will come.
    private func settleWithoutFrame(generation settled: UInt64, at shown: MediaTime?) {
        let now = monotonicNanos()
        var landed = false
        shared.updateRun(generation: settled) { run in
            guard run.targetLandedNanos == nil else { return }
            run.targetLandedNanos = now
            run.landedPTS = shown ?? run.clockTime
            landed = true
        }
        if landed { handleLanding(.target(generation: settled)) }
    }

    /// A frame the decoder never returned would hold every later one in the orderer. When the
    /// clock is a second past the last presented frame and no decode credit is free, the held
    /// frames are let through in order.
    private func releaseStalledFrames(now: MediaTime, session current: Session) {
        guard let video = current.video, !shared.videoEnded.load(ordering: .acquiring), video.credits.available == 0,
              let presented = shared.lastVideoEnd.withLock({ $0 }), now > presented + .seconds(1) else { return }
        let held = video.orderer.flush()
        trace("released \(held.count) frames held by the orderer at \(now)")
        held.forEach { video.sink.yield($0) }
    }

    /// Where the file ends once every playing stream is done, or nil when that is not known yet.
    /// While video is stopped for occlusion it is not decoded, so its end is the demuxer's: the
    /// last video packet read once the file is read to its end (`demuxedVideoEnd`). Until then the
    /// file has not ended, whatever audio does: audio may be shorter than the video, or absent.
    static func endTime(
        videoStoppedForOcclusion: Bool,
        demuxedVideoEnd: MediaTime?,
        decodedVideoEnd: MediaTime?,
        audioEnd: MediaTime?,
        containerEnd: MediaTime?
    ) -> MediaTime? {
        let videoEnd: MediaTime?
        if videoStoppedForOcclusion {
            guard let demuxedVideoEnd else { return nil }
            videoEnd = demuxedVideoEnd
        } else {
            videoEnd = decodedVideoEnd
        }
        return [videoEnd, audioEnd].compactMap { $0 }.max() ?? containerEnd ?? .zero
    }

    private func checkEnd(now: MediaTime, session current: Session) {
        let videoDone = videoStoppedForOcclusion || current.video.map { video in
            shared.videoEnded.load(ordering: .acquiring) && video.credits.available == video.credits.limit
        } ?? true
        let audioDone = current.audio == nil || shared.audioEnded.load(ordering: .acquiring)
        guard videoDone, audioDone else { return }
        guard let end = PlaybackEngine.endTime(
            videoStoppedForOcclusion: videoStoppedForOcclusion,
            demuxedVideoEnd: current.demuxer.store.videoEndOfFile,
            decodedVideoEnd: shared.lastVideoEnd.withLock { $0 },
            audioEnd: shared.lastAudioEnd.withLock { $0 },
            containerEnd: current.info.duration.map { (current.info.startTime ?? .zero) + $0 }
        ) else { return }
        guard now + .milliseconds(20) >= end else { return }
        // A loop of either kind restarts instead of ending, so auto-advance never sees an end (D49).
        if let restart = loop.endOfFileTarget.map({ max($0, current.start) }) ?? loop.start {
            Task { [weak self] in await self?.restartLoop(at: restart, endedAt: end) }
            resetEndTracking()
            return
        }
        synchronizer.rate = 0
        setRealTime(false)
        setState(.ended)
        eventSink.yield(.ended)
        sendPosition(.ended, at: end)
    }

    private func setState(_ newState: PlaybackState) {
        guard newState != state else { return }
        state = newState
        let playing = newState == .playing
        subtitlePresenter.update { $0.playing = playing }
        eventSink.yield(.stateChanged(newState))
        // One time event on each state change; periodic ones only while playing (section 7.9).
        if newState.hasMedia { sendTime() }
        applyEnergy()
    }

    private func sendTime() {
        counters.timeEvents.add(1, ordering: .relaxed)
        eventSink.yield(.time(currentTime))
    }

    private func sendPosition(_ reason: PositionUpdate.Reason, at time: MediaTime? = nil) {
        guard let handler = positionHandler, let current = session else { return }
        // A file cut short ends where its data ends, for resume as for auto-advance (7.10).
        var duration = current.info.duration
        if let dataEnd = current.demuxer.dataEnd, let promised = duration {
            duration = min(promised, max(.zero, dataEnd - (current.info.startTime ?? .zero)))
        }
        let update = PositionUpdate(
            url: current.url,
            position: time ?? currentTime,
            duration: duration,
            audioStreamIndex: current.info.audioStreamIndex,
            reason: reason,
            tracks: current.tracks,
            loop: loop
        )
        handler(update)
    }

    // MARK: Workers

    /// Enqueues decoded frames on the video receiver and reports the preview and target landings.
    private static func present(
        frames: AsyncStream<DecodedFrame>,
        credits: FrameCredits,
        shared: PipelineShared,
        engine: PlaybackEngine?
    ) async {
        for await frame in frames {
            guard shared.isCurrent(frame.generation), let output = shared.videoOutput.withLock({ $0 }) else {
                continue
            }
            let outcome = await output.enqueue(frame, releasingSlot: false)
            let now = monotonicNanos()
            credits.release(generation: frame.generation)
            guard outcome == .enqueued || outcome == .enqueuedWithDecodeFailures else {
                if case .failed(let reason) = outcome { trace("frame \(MediaTime(frame.presentationTime)?.description ?? "-") not enqueued: \(reason)") }
                continue
            }
            let landing = shared.recordPresented(frame, at: now)
            shared.frameObserver.withLock { $0 }?.call(frame)
            if let landing, let engine { await engine.handleLanding(landing) }
        }
    }

    /// Waits (at most 2 s) until the clock is within 20 ms of `time`, or the generation changes.
    private static func waitForClock(_ engine: PlaybackEngine, reaching time: MediaTime, generation: UInt64, shared: PipelineShared) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while engine.currentTime + .milliseconds(20) < time, shared.isCurrent(generation), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Enqueues decoded audio on the renderer, when one is attached, and reports priming.
    private static func consumeAudio(thread: AudioDecodeThread, shared: PipelineShared, engine: PlaybackEngine?) async {
        for await output in thread.outputs {
            switch output {
            case .buffer(let buffer, let generation):
                // Decoded before a restart of this generation: it would land after the flush.
                guard shared.isCurrent(generation), buffer.restart == thread.restartCount else { continue }
                if let audio = shared.audioOutput.withLock({ $0 }) {
                    if buffer.startsNewFormat, let engine {
                        // A new layout or rate (section 7.10): play out the old format, then flush
                        // it so the renderer starts the new one clean.
                        await PlaybackEngine.waitForClock(engine, reaching: buffer.pts, generation: generation, shared: shared)
                        await audio.flush()
                    }
                    let outcome = await audio.enqueue(buffer)
                    if outcome != .enqueued { continue }
                }
                shared.lastAudioEnd.withLock { $0 = max($0 ?? buffer.end, buffer.end) }
                shared.audioObserver.withLock { $0 }?.call((buffer, generation))
                if shared.audioPrimedGeneration.exchange(generation, ordering: .acquiringAndReleasing) != generation, let engine {
                    await engine.audioPrimed(generation: generation)
                }
            case .endOfStream(let generation):
                if shared.isCurrent(generation) { shared.audioEnded.store(true, ordering: .releasing) }
            case .failed:
                continue
            }
        }
    }
}

/// Sends `.time` events at the requested interval from a dispatch timer on its own serial queue.
/// The UI's clock follows these events; a sleeping task would need a free thread of the
/// cooperative pool to wake, and stalls whenever that pool is busy.
///
/// Unchecked Sendable: the timer source is created in init and only scheduled, resumed and
/// cancelled afterwards, which Dispatch allows from any thread; the flags are behind a Mutex.
final class TimeEventTimer: @unchecked Sendable {
    private struct State {
        var interval: Double
        var active = false
        var cancelled = false
    }

    private let state: Mutex<State>
    private let source: any DispatchSourceTimer

    /// Starts inactive: an inactive timer is scheduled at the distant future, so it never wakes.
    init(interval: Double, synchronizer: AVSampleBufferRenderSynchronizer, sink: AsyncStream<EngineEvent>.Continuation, counters: EngineCounters? = nil) {
        state = Mutex(State(interval: interval))
        source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "reel.time-events", qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self, state.withLock({ $0.active && !$0.cancelled }) else { return }
            counters?.timeEvents.add(1, ordering: .relaxed)
            sink.yield(.time(MediaTime(synchronizer.currentTime()) ?? .zero))
        }
        source.schedule(deadline: .distantFuture)
        source.resume()
    }

    var isActive: Bool { state.withLock { $0.active && !$0.cancelled } }

    func setInterval(_ interval: Double) {
        let reschedule = state.withLock { state -> Bool in
            guard !state.cancelled, state.interval != interval else { return false }
            state.interval = interval
            return state.active
        }
        if reschedule { schedule(interval) }
    }

    func setActive(_ active: Bool) {
        let change = state.withLock { state -> Double? in
            guard !state.cancelled, state.active != active else { return nil }
            state.active = active
            return state.interval
        }
        guard let interval = change else { return }
        if active {
            schedule(interval)
        } else {
            source.schedule(deadline: .distantFuture)
        }
    }

    func cancel() {
        let first = state.withLock { state -> Bool in
            defer { state.cancelled = true }
            return !state.cancelled
        }
        if first { source.cancel() }
    }

    /// 10% leeway lets the system coalesce the wakeups (D60).
    private func schedule(_ interval: Double) {
        let nanos = Int((interval * 1e9).rounded())
        let leeway = Int((EnergyPolicy.leeway(forInterval: interval) * 1e9).rounded())
        source.schedule(deadline: .now() + .nanoseconds(nanos), repeating: .nanoseconds(nanos), leeway: .nanoseconds(leeway))
    }
}

/// Work counted since open for `energyCounters()` (section 7.9). The packet count lives in the
/// demuxer and the subtitle render count in the presenter.
final class EngineCounters: Sendable {
    let framesDecoded = Atomic<Int>(0)
    let timeEvents = Atomic<Int>(0)
    let thumbnailsDecoded = Atomic<Int>(0)

    func reset() {
        framesDecoded.store(0, ordering: .relaxed)
        timeEvents.store(0, ordering: .relaxed)
        thumbnailsDecoded.store(0, ordering: .relaxed)
    }
}

/// Feeds audio packets from the store to the audio decode thread for one generation (design
/// section 7.5 step 6): from the target minus the codec preroll, up to `readAhead` ahead of the
/// clock. Section 7.9: instead of checking the clock every few milliseconds it refills in
/// batches, sleeping until only `refillAhead` is left, so steady playback wakes it about five
/// times a second and audio stays at least 0.8 s ahead.
struct PacedAudioFeeder: Sendable {
    static let readAhead = MediaTime.seconds(1)
    static let refillAhead = MediaTime.milliseconds(800)
    /// With the clock stopped there is no due time; the paused engine suspends the feed soon.
    static let stoppedClockWait = 0.25

    let demuxer: Demuxer
    let streamIndex: Int
    let thread: AudioDecodeThread
    let shared: PipelineShared
    let clock: @Sendable () -> MediaTime
    let rate: @Sendable () -> Double

    func run(generation: UInt64, from target: MediaTime, awaitDemuxerSeek: Bool) async {
        let store = demuxer.store
        func stale() -> Bool { Task.isCancelled || !shared.isCurrent(generation) }
        if awaitDemuxerSeek {
            while demuxer.completedSeekGeneration < generation {
                if stale() { return }
                try? await Task.sleep(for: .microseconds(500))
            }
        }
        let start = target - thread.preroll
        var cursor = store.audioCursor(streamIndex: streamIndex, at: start)
        while !stale() {
            let change = store.changeCount
            switch store.next(&cursor) {
            case .packet(let packet):
                if let time = packet.time, time + packet.duration < start { continue }
                if let time = packet.time, !(await waitUntilDue(time, target: target, stale: stale)) { return }
                let hold = shared.audioSubmitHoldForTesting.exchange(0, ordering: .relaxed)
                if hold > 0 { await Task.detached { try? await Task.sleep(for: .milliseconds(hold)) }.value }
                thread.submit(packet, generation: generation)
            case .needMore:
                await store.waitForChange(since: change)
            case .endOfStream:
                thread.finish(generation: generation)
                return
            case .invalidated:
                return
            }
        }
    }

    /// Sleeps while the packet at `time` is more than `readAhead` ahead of the clock, waking when
    /// `refillAhead` is left. False when the run went stale meanwhile.
    private func waitUntilDue(_ time: MediaTime, target: MediaTime, stale: () -> Bool) async -> Bool {
        while time > max(clock(), target) + PacedAudioFeeder.readAhead {
            let speed = rate()
            let wait: Double
            if speed > 0 {
                let ahead = time - max(clock(), target) - PacedAudioFeeder.refillAhead
                wait = max(ahead.seconds / speed, 0.005)
            } else {
                wait = PacedAudioFeeder.stoppedClockWait
            }
            try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(EnergyPolicy.leeway(forInterval: wait)))
            if stale() { return false }
        }
        return true
    }
}

/// The display layer the engine renders into: the app's, or one in no window for engines
/// without it (a bare `AVSampleBufferVideoRenderer` rejects enqueues, so the layer is needed even
/// when nothing shows). Kept so the layer can leave the clock while occluded and come back.
@MainActor
final class VideoLayerHolder {
    let layer: AVSampleBufferDisplayLayer

    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
    }

    /// Holds the app's layer, so the engine can take it off the clock and back (section 7.9).
    init(_ layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }
}

// MARK: - Subtitle output

/// The engine's subtitle output (design sections 8.5 and 8.6). Renders on its own serial queue,
/// at most once per display frame while playing and an event is showing or due within
/// `EnergyPolicy.subtitleLookahead`, and on demand otherwise (section 7.9); a render still running
/// when the next frame is due makes the timer skip that frame. The subtitle clock is the
/// synchronizer's time minus the subtitle delay. Text goes through libass (`SubtitleRenderer`),
/// PGS and DVD sets through the bitmap timeline. The result is set as the contents of a sublayer
/// of the app's subtitle layer (on the main actor), and kept for tests.
public final class SubtitlePresenter: Sendable {
    /// The subtitle layer's size in pixels and its backing scale.
    public struct Viewport: Sendable, Hashable {
        public var width: Int
        public var height: Int
        public var scale: Double

        public init(width: Int, height: Int, scale: Double) {
            self.width = width
            self.height = height
            self.scale = scale
        }
    }

    struct Settings: Sendable {
        var track: TrackID?
        var format: SubtitleFormat?
        var visible = true
        var delay = MediaTime.zero
        var scale = 1.0
        var position = SubtitleStyle.defaultPosition
        var bottomInsetPoints: Double?
        /// The mini player's floor for text sizes (`setSubtitleMinimumHeight`).
        var minimumHeightPoints: Double?
        var videoWidth = 0
        var videoHeight = 0
        var viewport: Viewport?
        /// An exact seek is in flight: the last image stays until the target frame lands.
        var holding = false
        /// A scrub shows the line at the pointer, not at the keyframe on screen.
        var scrubTime: MediaTime?
        var playing = false
        /// The window is hidden while playing: nothing renders (section 7.9).
        var suspended = false
        /// The playback rate, to turn media time until the next event into wall time.
        var rate = 1.0

        var timerWanted: Bool { playing && track != nil && visible && !holding && !suspended }
    }

    /// The last published subtitle, in output pixels of a `frameWidth` x `frameHeight` frame.
    public struct Output: Sendable {
        public var bitmap: SubtitleBitmap?
        public var frameWidth = 0
        public var frameHeight = 0
        /// Renders published so far.
        public var publishCount = 0
        public var renderCount = 0
        public var lastRenderMilliseconds: Double?
    }

    private struct BitmapKey: Hashable {
        var start: MediaTime
        var width: Int
        var height: Int
        var dy: Int
    }

    /// Touched only on `queue`.
    private struct RenderState {
        var renderer: SubtitleRenderer?
        var rendererUnavailable = false
        var bitmapKey: BitmapKey?
        var bitmapImage: SubtitleBitmap?
        var published = false
        var publishedEmpty = false
        var timer = TimerMode.off
    }

    private enum TimerMode: Equatable {
        case off
        /// Every display frame: an event is showing or due soon.
        case frames
        /// Asleep until the next event is due.
        case idle
    }

    public static let frameInterval = 1.0 / 60
    /// Bitmap display sets kept around the clock.
    static let bitmapWindow = MediaTime.seconds(60)

    private let queue = DispatchQueue(label: "reel.subtitles", qos: .userInitiated)
    private let settings = Mutex(Settings())
    private let renderState = Mutex(RenderState())
    private let output = Mutex(Output())
    private let store = Mutex<SubtitleTrackStore?>(nil)
    private let timeline = Mutex(BitmapSubtitleTimeline())
    private let host = Mutex<SubtitleLayerHost?>(nil)
    private let renderPending = Atomic<Bool>(false)
    private let failure = Mutex<SendableCallback<(TrackID, String)>?>(nil)
    private let timer: any DispatchSourceTimer
    private let clock: @Sendable () -> MediaTime

    init(clock: @escaping @Sendable () -> MediaTime) {
        self.clock = clock
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.renderNow() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    func setFailureHandler(_ handler: @escaping @Sendable (TrackID, String) -> Void) {
        failure.withLock { $0 = SendableCallback(handler) }
    }

    /// The size factor with the mini player's floor: a layer shorter than `minimumHeightPoints`
    /// draws text as large as it would be at that height.
    static func fontScale(base: Double, minimumHeightPoints: Double?, viewport: Viewport?) -> Double {
        guard let minimum = minimumHeightPoints, let viewport, viewport.height > 0, viewport.scale > 0 else { return base }
        let points = Double(viewport.height) / viewport.scale
        return base * max(1, minimum / points)
    }

    /// The last published subtitle (tests).
    public var current: Output { output.withLock { $0 } }

    var settingsSnapshot: Settings { settings.withLock { $0 } }

    // MARK: Control (from the engine actor)

    func reset(store newStore: SubtitleTrackStore?, videoWidth: Int, videoHeight: Int) {
        store.withLock { $0 = newStore }
        timeline.withLock { $0 = BitmapSubtitleTimeline() }
        update { settings in
            let viewport = settings.viewport
            let minimumHeight = settings.minimumHeightPoints
            settings = Settings()
            settings.viewport = viewport
            settings.minimumHeightPoints = minimumHeight
            settings.videoWidth = videoWidth
            settings.videoHeight = videoHeight
            settings.holding = true
        }
    }

    func select(_ track: TrackID?, format: SubtitleFormat?) {
        update { settings in
            settings.track = track
            settings.format = format
        }
    }

    /// Changes the settings and renders once; the render also reschedules the timer.
    func update(_ body: (inout Settings) -> Void) {
        settings.withLock { body(&$0) }
        requestRender()
    }

    /// Renders once on the queue soon; requests while one is pending collapse into it.
    func requestRender() {
        guard !renderPending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            renderPending.store(false, ordering: .releasing)
            renderNow()
        }
    }

    func clearTimeline() {
        timeline.withLock { $0 = BitmapSubtitleTimeline() }
        // Render state belongs to the queue; the next render runs after this.
        queue.async { [weak self] in self?.renderState.withLock { $0.bitmapKey = nil } }
    }

    /// Adds decoded bitmap display sets and drops ones far from the clock.
    func insert(_ sets: [BitmapDisplaySet]) {
        guard !sets.isEmpty else { return }
        let now = clock()
        timeline.withLock { timeline in
            for set in sets { timeline.insert(set) }
            timeline.prune(before: now - SubtitlePresenter.bitmapWindow)
        }
        requestRender()
    }

    // MARK: Layer (main actor)

    @MainActor
    func attach(_ layer: CALayer) {
        let previous = host.withLock { $0 }
        previous?.detach()
        let attached = SubtitleLayerHost(container: layer)
        host.withLock { $0 = attached }
        let viewport = attached.viewport
        update { $0.viewport = viewport }
    }

    @MainActor
    func layerDidLayout() {
        guard let viewport = host.withLock({ $0 })?.viewport else { return }
        update { $0.viewport = viewport }
    }

    // MARK: Snapshots

    /// The subtitle at the clock drawn into a `width` x `height` frame (a screenshot at the video's
    /// native size). Nil when nothing shows.
    func snapshot(width: Int, height: Int) async -> SubtitleBitmap? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let current = settings.withLock { $0 }
                guard current.visible, let track = current.track, let format = current.format, width > 0, height > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let time = (current.scrubTime ?? clock()) - current.delay
                let drawn = draw(track: track, format: format, at: time, settings: current, width: width, height: height, inset: nil)
                // The live renderer's settings changed; its next render publishes again.
                renderState.withLock { state in
                    state.published = false
                    state.bitmapKey = nil
                }
                continuation.resume(returning: drawn.bitmap)
            }
        }
    }

    // MARK: Rendering (queue)

    private func frameSize(_ current: Settings) -> (width: Int, height: Int, scale: Double) {
        if let viewport = current.viewport, viewport.width > 0, viewport.height > 0 {
            return (viewport.width, viewport.height, viewport.scale)
        }
        return (current.videoWidth, current.videoHeight, 1)
    }

    private func renderNow() {
        let current = settings.withLock { $0 }
        defer { reschedule() }
        if current.holding || current.suspended { return }
        let size = frameSize(current)
        guard current.visible, let track = current.track, let format = current.format, size.width > 0, size.height > 0 else {
            publish(nil, current: current, width: size.width, height: size.height)
            return
        }
        let started = ContinuousClock.now
        let time = (current.scrubTime ?? clock()) - current.delay
        let inset = current.bottomInsetPoints.map { $0 * size.scale }
        let drawn = draw(track: track, format: format, at: time, settings: current, width: size.width, height: size.height, inset: inset)
        let elapsed = ContinuousClock.now - started
        output.withLock { output in
            output.renderCount += 1
            output.lastRenderMilliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
        }
        if drawn.unchanged, renderState.withLock({ $0.published }) { return }
        publish(drawn.bitmap, current: current, width: size.width, height: size.height)
    }

    // MARK: Timer (queue)

    /// Runs the timer at the display rate while an event shows or is due within the lookahead,
    /// sleeps until the next one otherwise, and stops when nothing plays (section 7.9).
    private func reschedule() {
        let current = settings.withLock { $0 }
        let mode: TimerMode
        var wait: Double?
        if !current.timerWanted {
            mode = .off
        } else if let idle = idleSeconds(current, at: (current.scrubTime ?? clock()) - current.delay) {
            mode = .idle
            wait = idle / max(current.rate, 0.01)
        } else {
            mode = .frames
        }
        let previous = renderState.withLock { state -> TimerMode in
            defer { state.timer = mode }
            return state.timer
        }
        switch mode {
        case .off:
            if previous != .off { timer.schedule(deadline: .distantFuture) }
        case .frames:
            if previous != .frames {
                let interval = SubtitlePresenter.frameInterval
                let leeway = Int((EnergyPolicy.leeway(forInterval: interval) * 1e9).rounded())
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(leeway))
            }
        case .idle:
            guard let wait, wait.isFinite else {
                // No later event is known: new events and seeks render, which reschedules.
                timer.schedule(deadline: .distantFuture)
                return
            }
            let interval = SubtitlePresenter.frameInterval
            let leeway = Int((EnergyPolicy.leeway(forInterval: wait) * 1e9).rounded())
            timer.schedule(deadline: .now() + wait, repeating: interval, leeway: .nanoseconds(leeway))
        }
    }

    /// Media seconds until an event comes within the lookahead of `time`; nil when one shows or
    /// is due within it, infinity when no later event is known.
    private func idleSeconds(_ current: Settings, at time: MediaTime) -> Double? {
        let lookahead = MediaTime.seconds(EnergyPolicy.subtitleLookahead)
        var next: MediaTime?
        if current.format?.isBitmap == true {
            let sets = timeline.withLock { $0 }
            if sets.active(at: time) != nil { return nil }
            next = sets.sets.first { $0.start > time && !$0.isClear }?.start
        } else if let id = current.track, let track = store.withLock({ $0 })?.track(id) {
            for stored in track.events {
                let span = stored.event.time
                if span.start <= time, time < span.end { return nil }
                if span.start > time, next.map({ span.start < $0 }) ?? true { next = span.start }
            }
        }
        guard let next else { return .infinity }
        let gap = next - time - lookahead
        return gap > .zero ? gap.seconds : nil
    }

    private func draw(
        track: TrackID,
        format: SubtitleFormat,
        at time: MediaTime,
        settings current: Settings,
        width: Int,
        height: Int,
        inset: Double?
    ) -> (bitmap: SubtitleBitmap?, unchanged: Bool) {
        if format.isBitmap {
            return drawBitmap(at: time, settings: current, width: width, height: height, inset: inset)
        }
        guard let store = store.withLock({ $0 }) else { return (nil, false) }
        var failed = false
        let result = renderState.withLock { state -> (bitmap: SubtitleBitmap?, unchanged: Bool) in
            if state.renderer == nil, !state.rendererUnavailable {
                do {
                    state.renderer = try SubtitleRenderer()
                } catch {
                    state.rendererUnavailable = true
                    failed = true
                }
            }
            guard let renderer = state.renderer else { return (nil, false) }
            renderer.sync(with: store, track: track)
            let rendered = renderer.render(at: time, settings: SubtitleRenderSettings(
                frameWidth: width,
                frameHeight: height,
                videoWidth: current.videoWidth,
                videoHeight: current.videoHeight,
                scale: SubtitlePresenter.fontScale(base: current.scale, minimumHeightPoints: current.minimumHeightPoints, viewport: current.viewport),
                position: current.position,
                bottomInset: inset
            ))
            return (rendered.bitmap, rendered.changed == 0)
        }
        if failed {
            // Section 8.7: subtitles are off for the session, with one message.
            failure.withLock { $0 }?.call((track, SubtitleRendererError.unavailable.localizedDescription))
        }
        return result
    }

    private func drawBitmap(at time: MediaTime, settings current: Settings, width: Int, height: Int, inset: Double?) -> (bitmap: SubtitleBitmap?, unchanged: Bool) {
        guard let set = timeline.withLock({ $0.active(at: time) }), !set.rects.isEmpty else {
            let unchanged = renderState.withLock { state -> Bool in
                defer {
                    state.bitmapKey = nil
                    state.bitmapImage = nil
                }
                return state.bitmapKey == nil
            }
            return (nil, unchanged)
        }
        let videoRect = PixelRect.aspectFit(width: current.videoWidth, height: current.videoHeight, inWidth: width, height: height)
        let placed = set.rects.map { rect in
            (rect.image, BitmapSubtitles.place(rect.rect, canvasWidth: set.canvasWidth, canvasHeight: set.canvasHeight, videoRect: videoRect))
        }
        guard var bounds = placed.first?.1 else { return (nil, false) }
        for (_, rect) in placed.dropFirst() { bounds = bounds.union(rect) }
        // sub-pos moves bitmaps as one image; the lift moves sets in the bottom third (8.4, 8.5).
        let raised = -Int(((SubtitleStyle.defaultPosition - current.position) / 100 * Double(videoRect.height)).rounded())
        let lift = BitmapSubtitles.liftOffset(bounds: bounds.offsetBy(dy: raised), frameHeight: height, bottomInset: inset)
        let key = BitmapKey(start: set.start, width: width, height: height, dy: raised + lift)
        if let cached = renderState.withLock({ $0.bitmapKey == key ? $0.bitmapImage : nil }) { return (cached, true) }
        guard let image = SubtitlePresenter.compose(placed, bounds: bounds) else { return (nil, false) }
        let bitmap = SubtitleBitmap(image: image, rect: bounds.offsetBy(dy: raised + lift))
        renderState.withLock { state in
            state.bitmapKey = key
            state.bitmapImage = bitmap
        }
        return (bitmap, false)
    }

    /// Draws placed rects into one premultiplied BGRA image covering `bounds`.
    static func compose(_ pieces: [(CGImage, PixelRect)], bounds: PixelRect) -> CGImage? {
        guard !bounds.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: bounds.width,
                  height: bounds.height,
                  bitsPerComponent: 8,
                  bytesPerRow: bounds.width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        for (image, rect) in pieces {
            // Core Graphics has a bottom-left origin.
            context.draw(image, in: CGRect(x: rect.x - bounds.x, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height))
        }
        return context.makeImage()
    }

    private func publish(_ bitmap: SubtitleBitmap?, current: Settings, width: Int, height: Int) {
        let skip = renderState.withLock { state -> Bool in
            if bitmap == nil, state.published, state.publishedEmpty { return true }
            state.published = true
            state.publishedEmpty = bitmap == nil
            return false
        }
        if skip { return }
        output.withLock { output in
            output.bitmap = bitmap
            output.frameWidth = width
            output.frameHeight = height
            output.publishCount += 1
        }
        guard let host = host.withLock({ $0 }) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                let viewport = host.show(bitmap, frameWidth: width, frameHeight: height)
                if let self, let viewport, viewport != current.viewport {
                    self.update { $0.viewport = viewport }
                }
            }
        }
    }
}

/// The app's subtitle layer and the sublayer the engine draws into.
@MainActor
final class SubtitleLayerHost {
    let container: CALayer
    let content = CALayer()

    init(container: CALayer) {
        self.container = container
        content.anchorPoint = .zero
        content.isHidden = true
        content.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        container.addSublayer(content)
    }

    var viewport: SubtitlePresenter.Viewport? {
        let scale = max(container.contentsScale, 1)
        let size = container.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        return SubtitlePresenter.Viewport(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()), scale: scale)
    }

    /// Shows `bitmap` (rendered for a `frameWidth` x `frameHeight` pixel frame) and returns the
    /// layer's current viewport, which differs from the rendered one after a resize.
    func show(_ bitmap: SubtitleBitmap?, frameWidth: Int, frameHeight: Int) -> SubtitlePresenter.Viewport? {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let bounds = container.bounds
        guard let bitmap, frameWidth > 0, frameHeight > 0, bounds.width > 0 else {
            content.contents = nil
            content.isHidden = true
            return viewport
        }
        let sx = bounds.width / CGFloat(frameWidth)
        let sy = bounds.height / CGFloat(frameHeight)
        let rect = bitmap.rect
        let top = CGFloat(rect.y) * sy
        let height = CGFloat(rect.height) * sy
        let y = container.isGeometryFlipped ? top : bounds.height - top - height
        content.contentsScale = max(container.contentsScale, 1)
        content.frame = CGRect(x: CGFloat(rect.x) * sx, y: y, width: CGFloat(rect.width) * sx, height: height)
        content.contents = bitmap.image
        content.isHidden = false
        return viewport
    }

    func detach() {
        content.removeFromSuperlayer()
    }
}

/// Feeds the selected embedded subtitle stream from the main demuxer's PacketStore (design
/// section 8.1): text events into the `SubtitleTrackStore` (deduplicated against the
/// prefetcher), PGS and DVD display sets into the presenter's timeline. Runs until cancelled.
struct SubtitlePacketFeeder: Sendable {
    let packets: PacketStore
    let streamIndex: Int
    let parameters: CodecParameters
    let fileName: String
    let title: String?
    let language: String?
    let tracks: SubtitleTrackStore
    let presenter: SubtitlePresenter

    /// Returns a reason when the decoder cannot open, else nil once cancelled.
    func run() async -> String? {
        let id = TrackID.embedded(streamIndex: streamIndex)
        let decoder: SubtitleDecoder
        do {
            decoder = try SubtitleDecoder(parameters: parameters, fileName: fileName, title: title, language: language, charset: tracks.charset(of: id))
        } catch {
            return "\(SubtitleFormat(codec: parameters.codecName).tag): decoder failed"
        }
        let text = decoder.isBitmap ? nil : SubtitleTextFeed(decoder: decoder, track: id, store: tracks)
        // The first stored packet: text duplicates are dropped by the store, bitmap sets replace.
        var cursor = packets.audioCursor(streamIndex: streamIndex, at: .zero)
        while !Task.isCancelled {
            let change = packets.changeCount
            switch packets.next(&cursor) {
            case .packet(let packet):
                if let text {
                    // A malformed event is skipped; the rest of the track plays (section 8.7).
                    try? text.feed(packet)
                    presenter.requestRender()
                } else if let set = try? decoder.decodeBitmap(packet) {
                    presenter.insert([set])
                }
            case .needMore, .endOfStream:
                await packets.waitForChange(since: change)
            case .invalidated:
                // A demuxer seek reset the store; continue at what it holds now.
                cursor = packets.audioCursor(streamIndex: streamIndex, at: .zero)
            }
        }
        return nil
    }

    /// Display sets of a bitmap stream between `from` and `through`, read on a private demuxer
    /// with every other stream discarded.
    static func readBitmapSets(url: URL, streamIndex: Int, from: MediaTime, through: MediaTime) -> [BitmapDisplaySet] {
        guard let source = try? MediaSource(url: url), let stream = source.stream(streamIndex) else { return [] }
        for index in 0..<source.streamCount where index != streamIndex {
            source.stream(index)?.pointee.discard = AVDISCARD_ALL
        }
        guard let decoder = try? SubtitleDecoder(
            parameters: stream.pointee.codecpar,
            streamIndex: streamIndex,
            timeBase: Rational(stream.pointee.time_base.num, stream.pointee.time_base.den)
        ), decoder.isBitmap else { return [] }
        if from > .zero { try? source.seek(toKeyframe: from) }
        var sets: [BitmapDisplaySet] = []
        while !Task.isCancelled, let packet = try? source.readPacket() {
            guard packet.streamIndex == streamIndex else { continue }
            if let time = packet.time, time > through { break }
            if let set = try? decoder.decodeBitmap(packet) { sets.append(set) }
        }
        return sets
    }
}
