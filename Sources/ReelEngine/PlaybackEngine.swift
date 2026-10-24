import AVFoundation
import CoreMedia
import CReelDeps
import Foundation
import ReelCore
import Synchronization

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

    public init(url: URL, position: MediaTime, duration: MediaTime?, audioStreamIndex: Int?, reason: Reason) {
        self.url = url
        self.position = position
        self.duration = duration
        self.audioStreamIndex = audioStreamIndex
        self.reason = reason
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

        public init(
            audioMode: AudioOutput.Mode,
            environment: ReelEnvironment = ReelEnvironment(),
            hardwareDecoding: Bool = true,
            keyframePreview: Bool = true,
            preventsDisplaySleep: Bool,
            backgroundExactDelay: Duration = PlaybackEngine.backgroundExactDelay,
            storeLimits: PacketStore.Limits = .standard
        ) {
            self.audioMode = audioMode
            self.environment = environment
            self.hardwareDecoding = hardwareDecoding
            self.keyframePreview = keyframePreview
            self.preventsDisplaySleep = preventsDisplaySleep
            self.backgroundExactDelay = backgroundExactDelay
            self.storeLimits = storeLimits
        }

        /// The app.
        public static var playback: Configuration { Configuration(audioMode: .playback, preventsDisplaySleep: true) }
        /// Tests, benches and reelctl: silent, no display sleep assertion.
        public static var headless: Configuration { Configuration(audioMode: .headless, preventsDisplaySleep: false) }
    }

    public static let positionSaveInterval = MediaTime.seconds(5)
    /// A drag that rests this long starts the exact seek in the background (design section 7.5).
    public static let backgroundExactDelay: Duration = .milliseconds(150)
    /// Playback resumes after a seek once audio is primed, or after this long without it.
    public static let audioPrimeTimeout: Duration = .milliseconds(250)
    /// A scrub that has not landed by then no longer blocks the next one.
    public static let scrubWatchdog: Duration = .seconds(1)
    /// End of file, the store playhead and periodic saves are checked this often, whatever the
    /// time event interval.
    static let housekeepingInterval = 0.1

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
    }

    private struct Session {
        let url: URL
        var info: MediaInfo
        let demuxer: Demuxer
        var video: VideoSession?
        let audio: AudioSession?
        /// Presentation time of the first frame (mpegts files start later than zero).
        let start: MediaTime
    }

    private var session: Session?
    private var state: PlaybackState = .idle
    private var generation: UInt64 = 0
    private var planner: SeekPlanner
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
    private let timeEvents: TimeEventTimer
    private var closed = false

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
    private var headlessLayer: HeadlessLayer?

    private var positionHandler: (@Sendable (PositionUpdate) -> Void)?
    private var reportWaiters: [UInt64: [CheckedContinuation<SeekReport?, Never>]] = [:]
    private var completedReports: [UInt64: SeekReport] = [:]
    public private(set) var lastReport: SeekReport?

    public init(configuration: Configuration = .playback) {
        self.configuration = configuration
        synchronizer = AVSampleBufferRenderSynchronizer()
        (events, eventSink) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(4_096))
        displaySleep = DisplaySleep(enabled: configuration.preventsDisplaySleep)
        planner = SeekPlanner(keyframePreviewEnabled: configuration.keyframePreview)
        timeEvents = TimeEventTimer(interval: 0.1, synchronizer: synchronizer, sink: eventSink)
    }

    deinit {
        timeEvents.cancel()
    }

    // MARK: Attaching outputs

    /// Adds the app's display layer to the synchronizer. Call before `open`; without it the engine
    /// renders into a standalone layer that is in no window.
    @MainActor
    public func attach(displayLayer layer: AVSampleBufferDisplayLayer) async {
        let receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        await installVideoReceiver(receiver, keeping: nil)
    }

    @MainActor
    private func attachHeadlessLayer() async {
        let holder = HeadlessLayer()
        let receiver = synchronizer.sampleBufferReceiver(adding: holder.layer.sampleBufferRenderer)
        await installVideoReceiver(receiver, keeping: holder)
    }

    private func installVideoReceiver(_ receiver: sending AVSampleBufferVideoRenderer.Receiver, keeping holder: HeadlessLayer?) async {
        let output = VideoOutput(receiver: receiver)
        await output.setGeneration(generation)
        shared.videoOutput.withLock { $0 = output }
        headlessLayer = holder
    }

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
        guard !closed else { throw EngineError.notOpen }
        if session != nil { await closeSession() }
        setState(.opening)
        trace("open \(url.lastPathComponent)")
        let demuxer: Demuxer
        do {
            let limits = configuration.storeLimits
            demuxer = try await Task.detached(priority: .userInitiated) { try Demuxer(url: url, limits: limits) }.value
        } catch {
            try fail(error)
        }
        trace("open: demuxer ready")
        var info = demuxer.info
        var video: VideoSession?
        if let format = demuxer.videoFormat, let parameters = demuxer.videoParameters {
            do {
                video = try makeVideoSession(format: format, parameters: parameters)
            } catch {
                demuxer.stop()
                try fail(error)
            }
            info.videoDecoder = video?.decoder.kind
        }
        let audio = makeAudioSession(demuxer)
        if video == nil, audio == nil {
            demuxer.stop()
            try fail(EngineError.noPlayableStream)
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
            await attachHeadlessLayer()
        }
        trace("open: decoders and outputs ready")
        let start = demuxer.keyframeIndex.first?.pts ?? demuxer.store.storedKeyframes.first ?? info.startTime ?? .zero
        session = Session(url: url, info: info, demuxer: demuxer, video: video, audio: audio, start: start)
        demuxer.start()
        startWorkers()
        eventSink.yield(.opened(info))
        setState(.ready)
        resumeAfterSeek = false
        if let generation = await beginExact(.exact(start), requestedAt: monotonicNanos(), resume: false) {
            _ = await waitForReport(generation: generation, timeout: .seconds(5))
        }
        return info
    }

    public func play() async {
        guard session != nil else { return }
        switch state {
        case .playing:
            return
        case .seeking:
            resumeAfterSeek = true
            if backgroundExactLanded {
                settleBackgroundExact()
            } else if !exactInFlight {
                let target = lastScrubTarget ?? currentTime
                _ = await beginExact(.exact(target), requestedAt: monotonicNanos(), resume: true)
            }
        case .ended:
            _ = await beginExact(.exact(session?.start ?? .zero), requestedAt: monotonicNanos(), resume: true)
        case .ready, .paused:
            startPlaying(at: nil)
        case .idle, .opening, .failed:
            return
        }
    }

    public func pause() async {
        switch state {
        case .seeking:
            resumeAfterSeek = false
        case .playing:
            synchronizer.rate = 0
            setRealTime(false)
            displaySleep.allowSleep()
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
        timeEvents.setInterval(timeInterval)
    }

    /// Playback speed. M1 uses it only in benches (av-sync runs faster than real time).
    public func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0.1, min(rate, 16))
        if state == .playing { synchronizer.rate = playbackRate }
    }

    public func close() async {
        guard !closed else { return }
        await closeSession()
        closed = true
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

    // MARK: Setup

    private func makeVideoSession(format: VideoFormat, parameters: CodecParameters) throws -> VideoSession {
        let orderer = PresentationOrderer()
        let credits = FrameCredits(limit: VideoOutput.maxFramesAhead)
        let (frames, sink) = AsyncStream.makeStream(of: DecodedFrame.self)
        let handler = PlaybackEngine.decodeHandler(shared: shared, orderer: orderer, credits: credits, sink: sink)

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
        let frameDuration = format.frameDuration ?? MediaTime(microseconds: 33_333)
        let profile = DecodeProfile(
            codec: format.codecName,
            decoder: decoder.kind,
            width: format.width,
            height: format.height,
            frameDuration: frameDuration
        )
        presenterTask?.cancel()
        presenterTask = Task.detached(priority: .userInitiated) { [shared, weak self] in
            await PlaybackEngine.present(frames: frames, credits: credits, shared: shared, engine: self)
        }
        return VideoSession(
            format: format,
            decoder: decoder,
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
        sink: AsyncStream<DecodedFrame>.Continuation
    ) -> DecodeHandler {
        { event in
            switch event {
            case .frame(let frame):
                // Older frames would confuse the orderer's expectations of the current run.
                guard frame.generation >= shared.currentGeneration else { return }
                orderer.receive(frame).forEach { sink.yield($0) }
            case .failed(let pts, let generation, let status, let count):
                orderer.fail(pts).forEach { sink.yield($0) }
                credits.release(generation: generation)
                shared.failureHandler.withLock { $0 }?.call((generation, count, status))
            case .dropped(let pts, let generation):
                guard generation >= shared.currentGeneration else { return }
                trace("decoder dropped the frame at \(MediaTime(pts)?.description ?? "-")")
                orderer.fail(pts).forEach { sink.yield($0) }
                credits.release(generation: generation)
            }
        }
    }

    private func makeAudioSession(_ demuxer: Demuxer) -> AudioSession? {
        guard let parameters = demuxer.audioParameters, let index = demuxer.info.audioStreamIndex else { return nil }
        let decoder: AudioDecoder
        do {
            decoder = try AudioDecoder(
                codecParameters: parameters.pointer,
                timeBase: AVRational(num: parameters.timeBase.num, den: parameters.timeBase.den)
            )
        } catch {
            return nil
        }
        let thread = AudioDecodeThread(decoder: decoder)
        audioConsumerTask?.cancel()
        audioConsumerTask = Task.detached(priority: .userInitiated) { [shared, weak self] in
            await PlaybackEngine.consumeAudio(thread: thread, shared: shared, engine: self)
        }
        return AudioSession(thread: thread, streamIndex: index)
    }

    private func startWorkers() {
        shared.failureHandler.withLock { handler in
            handler = SendableCallback { [weak self] failure in
                Task { await self?.handleDecodeFailure(generation: failure.generation, consecutive: failure.consecutive, status: failure.status) }
            }
        }
        if tickerTask == nil {
            tickerTask = Task { [weak self] in
                while !Task.isCancelled {
                    let interval = await self?.timeInterval ?? 1
                    try? await Task.sleep(for: .seconds(min(interval, PlaybackEngine.housekeepingInterval)))
                    guard let self else { return }
                    await self.tick()
                }
            }
        }
    }

    private func fail(_ error: any Error) throws -> Never {
        let engineError = (error as? EngineError) ?? .openFailed(String(describing: error))
        setState(.failed)
        eventSink.yield(.failed(engineError))
        throw engineError
    }

    private func closeSession() async {
        guard let current = session else { return }
        sendPosition(.closed)
        _ = nextGeneration()
        coalescer.cancel()
        for task in [audioFeedTask, backgroundExactTask, audioResumeTask, scrubWatchdogTask] { task?.cancel() }
        _ = await stopFeeder()
        parkedFeed = nil
        current.video?.decoder.invalidate()
        current.video?.sink.finish()
        current.audio?.thread.stop()
        current.demuxer.stop()
        presenterTask = nil
        audioConsumerTask = nil
        synchronizer.rate = 0
        if let output = shared.videoOutput.withLock({ $0 }) {
            await output.flush(removingDisplayedImage: true)
        }
        if let audio = shared.audioOutput.withLock({ $0 }) { await audio.flush() }
        displaySleep.allowSleep()
        displayedKeyframe = nil
        lastScrubTarget = nil
        lastPeriodicSave = nil
        session = nil
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
        backgroundExactGeneration = nil
        backgroundExactLanded = false
        let superseded = shared.run.withLock { run -> SeekRun? in
            guard let current = run, current.targetLandedNanos == nil else { return nil }
            run = nil
            return current
        }
        if let superseded {
            let report = superseded.report(bytesNow: session?.demuxer.bytesRead ?? 0, cancelled: true)
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
        current.audio?.thread.seek(dropBefore: target, generation: generation)
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
        if let video = current.video {
            let previous = await stopFeeder()
            guard generation == self.generation else {
                parkedFeed = previous
                return generation
            }
            estimateSkippable()
            let profile = session?.video?.profile ?? video.profile
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
            if plan.start == .continueDecoder, let previous {
                run.start = .continueDecoder
                feedState = previous
                // The store reads ahead from its playhead; the decode continues from here to the target.
                demuxer.store.setPlayhead(target, readThrough: target)
                spec = FeedSpec(generation: generation, target: target, keyframe: nil, preview: false, scrubOnly: false, awaitDemuxerSeek: false)
            } else {
                video.decoder.reset(generation: generation)
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
                    preview: plan.showsKeyframePreview,
                    scrubOnly: false,
                    awaitDemuxerSeek: !hit
                )
            }
            video.orderer.reset()
            video.credits.reset(generation: generation)
            shared.run.withLock { $0 = run }
            await prepareOutputs(generation: generation)
            guard generation == self.generation else { return generation }
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
            complete(run.report(bytesNow: demuxer.bytesRead, cancelled: false))
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
            complete(run.report(bytesNow: demuxer.bytesRead, cancelled: false))
            finishScrub(generation: generation)
            return generation
        case .noKeyframe:
            keyframe = current.start
        case .showKeyframe(let entry):
            keyframe = entry.pts
        }
        synchronizer.setRate(0, time: keyframe.cmTime)
        setRealTime(false)
        _ = await stopFeeder()
        guard generation == self.generation else { return generation }
        video.decoder.reset(generation: generation)
        video.orderer.reset()
        video.credits.reset(generation: generation)
        let hit = demuxer.seek(toKeyframe: keyframe, generation: generation)
        run.storeHit = hit
        run.startKeyframe = keyframe
        shared.run.withLock { $0 = run }
        await prepareOutputs(generation: generation)
        guard generation == self.generation else { return generation }
        let spec = FeedSpec(generation: generation, target: nil, keyframe: keyframe, preview: false, scrubOnly: true, awaitDemuxerSeek: !hit)
        startFeeder(VideoFeedState(), spec: spec, video: video, demuxer: demuxer)
        scrubWatchdogTask?.cancel()
        scrubWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: PlaybackEngine.scrubWatchdog)
            guard !Task.isCancelled else { return }
            await self?.scrubTimedOut(generation: generation)
        }
        return generation
    }

    /// Step 1: the old picture stays (no image removal), queued frames and audio go.
    private func prepareOutputs(generation: UInt64) async {
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
            orderer: video.orderer,
            credits: video.credits,
            shared: shared,
            frames: video.sink
        )
        feederTask = Task.detached(priority: .userInitiated) {
            await feeder.run(state, spec: spec)
        }
    }

    private func startAudioFeed(generation: UInt64, target: MediaTime, awaitDemuxerSeek: Bool) {
        guard let current = session, let audio = current.audio else { return }
        let synchronizer = self.synchronizer
        let feeder = AudioFeeder(
            demuxer: current.demuxer,
            streamIndex: audio.streamIndex,
            thread: audio.thread,
            shared: shared,
            clock: { MediaTime(synchronizer.currentTime()) ?? .zero }
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
        let report = run.report(bytesNow: current.demuxer.bytesRead, cancelled: false)
        trace("landed g\(landed) \(run.request) at \(run.landedPTS?.description ?? "-") in \(report.targetMilliseconds ?? -1) ms")
        complete(report)
        if run.start == .keyframe, run.framesDecoded > 30, let milliseconds = report.targetMilliseconds, let video = current.video {
            planner.rates.record(
                codec: video.profile.codec,
                decoder: video.decoder.kind,
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
        if let time {
            synchronizer.setRate(playbackRate, time: time.cmTime)
        } else {
            synchronizer.rate = playbackRate
        }
        setRealTime(true)
        displaySleep.preventSleep()
        lastPeriodicSave = currentTime
        setState(.playing)
    }

    // MARK: Audio device events

    /// Design section 7.4: after a device or configuration change the renderer suggests a flush;
    /// audio restarts from the current time in the same generation, so video is not disturbed.
    /// Unverified on hardware (tests stay silent), so it is traced.
    private func handleAudioEvent(_ event: AudioOutput.Event) async {
        trace("audio renderer event \(event)")
        guard case .flushSuggested = event, let current = session, let audio = current.audio,
              state == .playing || state == .paused else { return }
        let now = currentTime
        audio.thread.seek(dropBefore: now, generation: generation)
        audioFeedTask?.cancel()
        if let output = shared.audioOutput.withLock({ $0 }) { await output.flush() }
        startAudioFeed(generation: generation, target: now, awaitDemuxerSeek: false)
    }

    // MARK: Decoder failures

    private func handleDecodeFailure(generation failed: UInt64, consecutive: Int, status: Int32) async {
        guard failed == generation, consecutive >= DecoderFailureTracker.failureLimit,
              var current = session, var video = current.video, video.decoder.kind == .hardware, !video.forced,
              let parameters = current.demuxer.videoParameters else { return }
        let handler = PlaybackEngine.decodeHandler(shared: shared, orderer: video.orderer, credits: video.credits, sink: video.sink)
        guard let software = try? SoftwareVideoDecoder(parameters: parameters, format: video.format, handler: handler) else { return }
        _ = await stopFeeder()
        parkedFeed = nil
        video.decoder.invalidate()
        video.decoder = software
        video.profile.decoder = .software
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
            current.demuxer.store.setPlayhead(now)
            if let last = lastPeriodicSave, now - last >= PlaybackEngine.positionSaveInterval || now < last {
                lastPeriodicSave = now
                sendPosition(.periodic, at: now)
            }
            checkEnd(now: now, session: current)
            releaseStalledFrames(now: now, session: current)
        }
        if nanos &- lastStoredRangeNanos > 1_000_000_000 {
            lastStoredRangeNanos = nanos
            let range = current.demuxer.store.storedRange
            if range != lastStoredRange {
                lastStoredRange = range
                eventSink.yield(.storedRange(range))
            }
        }
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

    private func checkEnd(now: MediaTime, session current: Session) {
        let videoDone = current.video.map { video in
            shared.videoEnded.load(ordering: .acquiring) && video.credits.available == video.credits.limit
        } ?? true
        let audioDone = current.audio == nil || shared.audioEnded.load(ordering: .acquiring)
        guard videoDone, audioDone else { return }
        let ends = [shared.lastVideoEnd.withLock { $0 }, shared.lastAudioEnd.withLock { $0 }].compactMap { $0 }
        let end = ends.max() ?? current.info.duration ?? .zero
        guard now + .milliseconds(20) >= end else { return }
        synchronizer.rate = 0
        setRealTime(false)
        displaySleep.allowSleep()
        setState(.ended)
        eventSink.yield(.ended)
        sendPosition(.ended, at: end)
    }

    private func setState(_ newState: PlaybackState) {
        guard newState != state else { return }
        state = newState
        eventSink.yield(.stateChanged(newState))
        timeEvents.setActive(newState.hasMedia)
    }

    private func sendPosition(_ reason: PositionUpdate.Reason, at time: MediaTime? = nil) {
        guard let handler = positionHandler, let current = session else { return }
        let update = PositionUpdate(
            url: current.url,
            position: time ?? currentTime,
            duration: current.info.duration,
            audioStreamIndex: current.info.audioStreamIndex,
            reason: reason
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
            guard outcome == .enqueued || outcome == .enqueuedWithDecodeFailures else { continue }
            let landing = shared.recordPresented(frame, at: now)
            shared.frameObserver.withLock { $0 }?.call(frame)
            if let landing, let engine { await engine.handleLanding(landing) }
        }
    }

    /// Enqueues decoded audio on the renderer, when one is attached, and reports priming.
    private static func consumeAudio(thread: AudioDecodeThread, shared: PipelineShared, engine: PlaybackEngine?) async {
        for await output in thread.outputs {
            switch output {
            case .buffer(let buffer, let generation):
                guard shared.isCurrent(generation) else { continue }
                if let audio = shared.audioOutput.withLock({ $0 }) {
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

    init(interval: Double, synchronizer: AVSampleBufferRenderSynchronizer, sink: AsyncStream<EngineEvent>.Continuation) {
        state = Mutex(State(interval: interval))
        source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "reel.time-events", qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self, state.withLock({ $0.active && !$0.cancelled }) else { return }
            sink.yield(.time(MediaTime(synchronizer.currentTime()) ?? .zero))
        }
        schedule(interval)
        source.resume()
    }

    func setInterval(_ interval: Double) {
        let changed = state.withLock { state -> Bool in
            guard !state.cancelled, state.interval != interval else { return false }
            state.interval = interval
            return true
        }
        if changed { schedule(interval) }
    }

    func setActive(_ active: Bool) {
        state.withLock { $0.active = active }
    }

    func cancel() {
        let first = state.withLock { state -> Bool in
            defer { state.cancelled = true }
            return !state.cancelled
        }
        if first { source.cancel() }
    }

    private func schedule(_ interval: Double) {
        let nanos = Int((interval * 1e9).rounded())
        source.schedule(deadline: .now() + .nanoseconds(nanos), repeating: .nanoseconds(nanos), leeway: .milliseconds(2))
    }
}

/// A display layer in no window, for engines without the app's layer. A bare
/// `AVSampleBufferVideoRenderer` rejects enqueues, so the layer is needed even when nothing shows.
@MainActor
final class HeadlessLayer {
    let layer: AVSampleBufferDisplayLayer

    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
    }
}
