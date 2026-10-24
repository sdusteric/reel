import AVFoundation
import CoreMedia
import Foundation
import ReelCore

/// The audio renderer and its macOS 27 receiver on the shared synchronizer (design section 7.4).
///
/// Safety: an output is only created by `attach(to:mode:environment:)`, which refuses in headless
/// mode and in test processes unless `REEL_ALLOW_AUDIO=1`, and then keeps volume 0 and muted.
public actor AudioOutput {
    /// Who is asking for audio.
    public enum Mode: Sendable, Hashable {
        /// The app: attaches a renderer at the user's volume.
        case playback
        /// reelctl, benches and tests: no renderer unless `REEL_ALLOW_AUDIO=1`.
        case headless
    }

    /// What `attach` does for a mode and environment.
    public enum AttachDecision: Sendable, Hashable {
        case none
        case audible
        /// Attached (so the clock follows the audio device), but muted at volume 0.
        case silent
    }

    public enum FlushReason: Sendable, Hashable {
        case outputConfigurationChanged
        /// The renderer flushed itself, e.g. after a device change, from this media time on.
        case flushedAutomatically(at: MediaTime?)
        /// A reason added after macOS 27.
        case other(String)
    }

    /// Reported to the engine, which flushes audio and re-enqueues from the current time.
    public enum Event: Sendable, Hashable {
        case flushSuggested(FlushReason)
        case failed(String)
        /// A rendering event added after macOS 27; logged only.
        case unrecognized(String)
    }

    public enum EnqueueOutcome: Sendable, Hashable {
        case enqueued
        case cancelledDueToFlush
        case failed(String)
    }

    /// Renderer events in order. Finished by `stop()`.
    public nonisolated let events: AsyncStream<Event>
    public let decision: AttachDecision

    private let continuation: AsyncStream<Event>.Continuation
    private let renderer: AVSampleBufferAudioRenderer
    private let receiver: AVSampleBufferAudioRenderer.Receiver
    private let eventTask: Task<Void, Never>
    private var volume: Double = VolumeCurve.firstRunVolume
    private var muted = false

    /// Attaches an audio renderer to `synchronizer`, or returns nil when this process must stay
    /// silent. Call before the first video enqueue so the clock follows the audio device.
    public static func attach(
        to synchronizer: AVSampleBufferRenderSynchronizer,
        mode: Mode,
        environment: ReelEnvironment = ReelEnvironment()
    ) -> AudioOutput? {
        let decision = attachDecision(
            mode: mode,
            allowsAudio: environment.allowsAudioOutput,
            isTestProcess: isTestProcess(environment: environment.values)
        )
        guard decision != .none else { return nil }
        return AudioOutput(synchronizer: synchronizer, decision: decision)
    }

    /// Headless callers and test processes never get a renderer unless `REEL_ALLOW_AUDIO=1`, and
    /// then a silent one.
    public static func attachDecision(mode: Mode, allowsAudio: Bool, isTestProcess: Bool) -> AttachDecision {
        if mode == .playback, !isTestProcess { return .audible }
        return allowsAudio ? .silent : .none
    }

    /// True inside `swift test` (XCTest or Swift Testing runners).
    public static func isTestProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processName: String = ProcessInfo.processInfo.processName
    ) -> Bool {
        let name = processName.lowercased()
        if name.contains("xctest") || name.contains("swiftpm-testing-helper") || name.hasSuffix("packagetests") {
            return true
        }
        return environment.keys.contains { $0.hasPrefix("XCTest") || $0 == "SWIFT_TESTING_ENABLED" }
    }

    /// Linear gain and mute state applied to the renderer: `(v / 100)^3`, or 0 and muted when silent.
    public static func rendererSettings(volume: Double, muted: Bool, decision: AttachDecision) -> (gain: Float, muted: Bool) {
        if decision != .audible { return (0, true) }
        return (VolumeCurve.gain(forVolume: volume), muted)
    }

    public static func event(for reason: AVSampleBufferAudioRenderer.Receiver.SuggestedFlushReason) -> Event {
        switch reason {
        case .outputConfigurationChanged:
            .flushSuggested(.outputConfigurationChanged)
        case .wasFlushedAutomatically(let time):
            .flushSuggested(.flushedAutomatically(at: mediaTime(time)))
        @unknown default:
            .flushSuggested(.other(String(describing: reason)))
        }
    }

    public static func event(for renderingEvent: AVSampleBufferAudioRenderer.Receiver.RenderingEvent) -> Event {
        switch renderingEvent {
        case .outputConfigurationChanged:
            .flushSuggested(.outputConfigurationChanged)
        case .wasFlushedAutomatically(let time):
            .flushSuggested(.flushedAutomatically(at: mediaTime(time)))
        case .failed(let error):
            .failed(String(describing: error))
        @unknown default:
            .unrecognized(String(describing: renderingEvent))
        }
    }

    private init(synchronizer: AVSampleBufferRenderSynchronizer, decision: AttachDecision) {
        let renderer = AVSampleBufferAudioRenderer()
        renderer.audioTimePitchAlgorithm = .timeDomain
        let settings = AudioOutput.rendererSettings(volume: VolumeCurve.firstRunVolume, muted: false, decision: decision)
        renderer.volume = settings.gain
        renderer.isMuted = settings.muted
        let receiver = synchronizer.sampleBufferReceiver(adding: renderer)
        let renderingEvents = receiver.renderingEventsAfterFinishedEnqueuing
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.events = events
        self.continuation = continuation
        self.decision = decision
        self.eventTask = Task {
            for await event in renderingEvents {
                continuation.yield(AudioOutput.event(for: event))
            }
        }
        self.renderer = renderer
        self.receiver = receiver
    }

    deinit {
        eventTask.cancel()
        continuation.finish()
    }

    /// Enqueues one buffer, suspending under back-pressure. A suggested flush is reported on `events`.
    public func enqueue(_ buffer: DecodedAudioBuffer) async -> EnqueueOutcome {
        do {
            let result = try await receiver.enqueue(buffer.sampleBuffer)
            return outcome(of: result)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Enqueues without waiting for room (for priming after a seek).
    public func enqueueImmediately(_ buffer: DecodedAudioBuffer) -> EnqueueOutcome {
        outcome(of: receiver.enqueueImmediately(buffer.sampleBuffer))
    }

    /// Drops everything enqueued (seek, device change).
    public func flush() {
        receiver.flush()
    }

    /// Drops enqueued audio from `time` on, keeping what plays before it.
    public func flush(from time: MediaTime) async -> Bool {
        await receiver.flush(fromSourceTime: CMTime(value: time.microseconds, timescale: 1_000_000))
    }

    /// Volume 0 to 100 on the mpv scale.
    public func setVolume(_ volume: Double) {
        self.volume = min(max(volume, 0), 100)
        apply()
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
        apply()
    }

    /// Flushes and finishes `events`.
    public func stop() {
        receiver.flush()
        eventTask.cancel()
        continuation.finish()
    }

    private func apply() {
        let settings = AudioOutput.rendererSettings(volume: volume, muted: muted, decision: decision)
        renderer.volume = settings.gain
        renderer.isMuted = settings.muted
    }

    private func outcome(of result: AVSampleBufferAudioRenderer.Receiver.EnqueueResult) -> EnqueueOutcome {
        switch result {
        case .enqueued:
            return .enqueued
        case .enqueuedWithSuggestedFlush(let reasons):
            for reason in reasons { continuation.yield(AudioOutput.event(for: reason)) }
            return .enqueued
        case .cancelledDueToFlush:
            return .cancelledDueToFlush
        case .cancelledDueToError(let error):
            return .failed(String(describing: error))
        @unknown default:
            return .failed("unrecognized enqueue result \(result)")
        }
    }

    private static func mediaTime(_ time: CMTime) -> MediaTime? {
        guard time.isValid, time.isNumeric else { return nil }
        return MediaTime(seconds: time.seconds)
    }
}
