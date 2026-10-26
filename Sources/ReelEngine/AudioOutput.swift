import AVFoundation
import CoreMedia
import Foundation
import ReelCore
import ReelObjCSupport
import Synchronization

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
    private var deviceSlot: RendererDeviceSlot

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
        let (output, result) = AudioOutput.make(synchronizer: synchronizer, decision: decision, deviceUID: preferredOutputDevice)
        report(result)
        routing.withLock { state in
            state.outputs.removeAll { $0.output == nil }
            state.outputs.append(WeakOutput(output: output))
        }
        return output
    }

    // MARK: Output device (section 7.11, D67)

    private struct WeakOutput: Sendable {
        weak var output: AudioOutput?
    }

    private struct Routing: Sendable {
        var uid: String?
        var outputs: [WeakOutput] = []
    }

    private static let routing = Mutex(Routing())

    /// The `AudioDeviceUID` every renderer plays on; nil follows the system default. The app sets
    /// it from the Output Device choice after resolving it against the device list, so a missing
    /// device is never passed here.
    public static var preferredOutputDevice: String? {
        routing.withLock { $0.uid }
    }

    /// Changes the device for renderers attached later and for every live one.
    public static func setPreferredOutputDevice(_ uid: String?) {
        let live = routing.withLock { state -> [AudioOutput] in
            state.uid = uid
            state.outputs.removeAll { $0.output == nil }
            return state.outputs.compactMap(\.output)
        }
        for output in live {
            Task { await output.setOutputDevice(uid) }
        }
    }

    /// `audioOutputDeviceUniqueID`; nil plays on the system default. The renderer flushes itself
    /// after a change, which reaches the engine as a suggested flush.
    /// A device the renderer refuses (an Objective-C exception, e.g. a Bluetooth device that is
    /// reconnecting) leaves the system default playing and is reported to the refusal handler; the
    /// next call with the same UID tries it again.
    public func setOutputDevice(_ uid: String?) {
        let renderer = renderer
        let result = deviceSlot.request(uid, defaultUID: AudioOutputDevices.defaultOutputUID) {
            try ReelObjCSupport.setOutputDevice(on: renderer, uid: $0)
        }
        AudioOutput.report(result)
    }

    /// Called (from any thread) when a renderer refuses a chosen device and plays on the system
    /// default instead, or when the default output cannot be read. The app logs and shows the OSD.
    public static func setOutputRouteHandler(_ handler: (@Sendable (OutputRouteEvent) -> Void)?) {
        routeHandler.withLock { $0 = handler }
    }

    private static let routeHandler = Mutex<(@Sendable (OutputRouteEvent) -> Void)?>(nil)

    fileprivate static func report(_ result: DeviceRouteResult) {
        let handler = routeHandler.withLock { $0 }
        if let refusal = result.refusal { handler?(.refused(refusal)) }
        if result.defaultUnreadable { handler?(.defaultUnreadable) }
    }

    /// The device this renderer plays on; nil is the system default.
    public var outputDevice: String? { renderer.audioOutputDeviceUniqueID }

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

    private static func make(
        synchronizer: AVSampleBufferRenderSynchronizer, decision: AttachDecision, deviceUID: String?
    ) -> (AudioOutput, DeviceRouteResult) {
        let renderer = AVSampleBufferAudioRenderer()
        var slot = RendererDeviceSlot()
        let result = slot.request(deviceUID, defaultUID: AudioOutputDevices.defaultOutputUID) {
            try ReelObjCSupport.setOutputDevice(on: renderer, uid: $0)
        }
        return (AudioOutput(synchronizer: synchronizer, decision: decision, renderer: renderer, deviceSlot: slot), result)
    }

    private init(
        synchronizer: AVSampleBufferRenderSynchronizer, decision: AttachDecision,
        renderer: AVSampleBufferAudioRenderer, deviceSlot: RendererDeviceSlot
    ) {
        self.deviceSlot = deviceSlot
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

/// Reported by the audio routing to the app.
public enum OutputRouteEvent: Sendable, Hashable {
    case refused(OutputRefusal)
    /// The system default output could not be read, so the renderer was left as it is.
    case defaultUnreadable
}

/// A chosen output device the renderer refused.
public struct OutputRefusal: Sendable, Hashable {
    public var uid: String
    public var reason: String

    public init(uid: String, reason: String) {
        self.uid = uid
        self.reason = reason
    }

    /// The log line; it names the device and the exception, never a path.
    public func logLine(deviceName: String) -> String {
        "audio output: \(deviceName) refused, using system output (\(reason))"
    }
}

/// What a request to the slot changed or could not do.
struct DeviceRouteResult: Equatable {
    var refusal: OutputRefusal?
    /// The default output could not be read and a pin was needed; true once per streak.
    var defaultUnreadable = false
}

/// Which device a renderer plays on, and the fallback when it refuses one. AVFoundation raises
/// when the device is set to nil, so the system default is followed by pinning the current default
/// output's UID, re-pinned when the default changes. `setter` is the exception-guarded property
/// set and `defaultUID` the Core Audio read; tests pass fakes. Nil or "" never reaches `setter`.
struct RendererDeviceSlot {
    /// The device last set; nil while the renderer is untouched (it follows the default itself).
    private(set) var applied: String?
    private var reportedUnreadable = false

    /// Routes to `wanted` (nil: the system default). A refused device falls back to the default
    /// output and is returned as a refusal; the next request with the same `wanted` tries it again.
    mutating func request(
        _ wanted: String?,
        defaultUID: () -> String?,
        _ setter: (String?) throws -> Void
    ) -> DeviceRouteResult {
        var result = DeviceRouteResult()
        if let wanted, !wanted.isEmpty {
            if applied == wanted { return result }
            do {
                try setter(wanted)
                applied = wanted
                return result
            } catch {
                let nsError = error as NSError
                let reason = nsError.domain == ReelObjCSupportErrorDomain ? nsError.localizedDescription : String(describing: error)
                result.refusal = OutputRefusal(uid: wanted, reason: reason)
            }
        }
        // The system default: an untouched renderer already follows it.
        guard applied != nil || result.refusal != nil else { return result }
        guard let target = defaultUID(), !target.isEmpty else {
            result.defaultUnreadable = !reportedUnreadable
            reportedUnreadable = true
            return result
        }
        reportedUnreadable = false
        if applied != target {
            do {
                try setter(target)
                applied = target
            } catch {
                // The default device refuses too: leave the renderer as it is.
            }
        }
        return result
    }
}
