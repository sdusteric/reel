import CoreMedia
import Foundation
import ReelCore
import Synchronization

/// `REEL_LOG=debug` traces opens, seek plans and landings to stderr.
let debugTrace = ReelEnvironment().debugLogging
func trace(_ message: @autoclosure () -> String) {
    guard debugTrace else { return }
    FileHandle.standardError.write(Data("[\(DispatchTime.now().uptimeNanoseconds / 1_000_000)] \(message())\n".utf8))
}

/// Monotonic clock in nanoseconds, the base of every latency in a `SeekReport`.
func monotonicNanos() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

extension MediaTime {
    var cmTime: CMTime { CMTime(value: microseconds, timescale: 1_000_000) }
}

/// A callback stored behind a lock. Closures go in a class instead of directly into a `Mutex`:
/// every `withLock { $0 }` read of a stored closure wraps it in two more reabstraction thunks,
/// and the chain overflows the stack after a few thousand reads.
final class SendableCallback<Value>: Sendable {
    let call: @Sendable (Value) -> Void

    init(_ call: @escaping @Sendable (Value) -> Void) {
        self.call = call
    }
}

/// Generation-scoped credits that bound decoded frames between the decoder and the video receiver
/// (design section 7.3: at most 8 decoded frames ahead). A new seek resets them, so credits held by
/// frames of an older generation never leak.
final class FrameCredits: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var available: Int
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter: UInt64 = 0
    }

    let limit: Int
    private let state: Mutex<State>

    init(limit: Int) {
        self.limit = limit
        state = Mutex(State(available: limit))
    }

    var available: Int { state.withLock { $0.available } }

    /// Starts `generation` with every credit free and wakes waiters of older generations.
    func reset(generation: UInt64) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.generation = generation
            state.available = limit
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    /// Takes one credit. Returns false when `generation` is no longer current or the task was cancelled.
    func acquire(generation: UInt64) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let id: UInt64? = state.withLock { state in
                guard state.generation == generation else { return nil }
                if state.available > 0 {
                    state.available -= 1
                    return UInt64.max
                }
                defer { state.nextWaiter += 1 }
                return state.nextWaiter
            }
            guard let id else { return false }
            if id == UInt64.max { return true }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow = state.withLock { state -> Bool in
                        if state.generation != generation || state.available > 0 || Task.isCancelled { return true }
                        state.waiters[id] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
            }
        }
    }

    /// Gives a credit back. Ignored for older generations, whose credits were reset.
    func release(generation: UInt64) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard state.generation == generation else { return [] }
            state.available = min(limit, state.available + 1)
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }
}

/// Bookkeeping of one seek (or open), shared by the engine actor, the feeder and the presenter.
struct SeekRun: Sendable {
    var generation: UInt64
    var request: SeekRequest
    /// The time the clock was set to (the request clamped to the file).
    var clockTime: MediaTime
    var requestedAtNanos: UInt64
    var start: SeekStart
    var startKeyframe: MediaTime?
    var storeHit: Bool
    var bytesAtStart: Int64
    /// The keyframe shown as a preview before the target, when the plan asked for one.
    var previewPTS: MediaTime?
    /// The frame decided to be the target (largest pts at or before the request).
    var targetPTS: MediaTime?
    var previewLandedNanos: UInt64?
    var targetLandedNanos: UInt64?
    var landedPTS: MediaTime?
    var framesDecoded = 0
    var framesSkipped = 0
    var targetSubmitted = false

    func report(bytesNow: Int64, cancelled: Bool) -> SeekReport {
        func milliseconds(_ nanos: UInt64?) -> Double? {
            nanos.map { Double($0 &- requestedAtNanos) / 1_000_000 }
        }
        return SeekReport(
            kind: request.kind,
            target: request.target,
            generation: generation,
            requestedAtNanos: requestedAtNanos,
            previewMilliseconds: milliseconds(previewLandedNanos),
            targetMilliseconds: milliseconds(targetLandedNanos),
            landedPTS: landedPTS,
            startKeyframePTS: startKeyframe,
            start: start,
            framesDecoded: framesDecoded,
            framesSkipped: framesSkipped,
            bytesRead: max(0, bytesNow - bytesAtStart),
            storeHit: storeHit,
            cancelled: cancelled
        )
    }
}

/// What a presented frame meant for the current seek.
enum Landing: Sendable, Equatable {
    case preview(generation: UInt64)
    case target(generation: UInt64)
}

/// State shared by the engine actor, the decode callbacks, the feeder and the presenter. Every
/// stage drops work whose generation is older than `generation` (design section 7.5).
final class PipelineShared: Sendable {
    let generation = Atomic<UInt64>(0)
    let run = Mutex<SeekRun?>(nil)
    let videoOutput = Mutex<VideoOutput?>(nil)
    let audioOutput = Mutex<AudioOutput?>(nil)
    /// Called from decoder callbacks with the generation and the consecutive failure count.
    let failureHandler = Mutex<SendableCallback<(generation: UInt64, consecutive: Int, status: Int32)>?>(nil)
    let frameObserver = Mutex<SendableCallback<DecodedFrame>?>(nil)
    let audioObserver = Mutex<SendableCallback<(buffer: DecodedAudioBuffer, generation: UInt64)>?>(nil)
    let lastLandedFrame = Mutex<DecodedFrame?>(nil)
    /// pts and end of the last video frame enqueued, for end-of-file detection.
    let lastVideoEnd = Mutex<MediaTime?>(nil)
    let lastAudioEnd = Mutex<MediaTime?>(nil)
    /// Generation whose first audio buffer has been consumed.
    let audioPrimedGeneration = Atomic<UInt64>(0)
    let videoEnded = Atomic<Bool>(false)
    let audioEnded = Atomic<Bool>(false)

    var currentGeneration: UInt64 { generation.load(ordering: .acquiring) }

    func isCurrent(_ value: UInt64) -> Bool { value == currentGeneration }

    /// Records an enqueued frame and returns what it meant for the seek in flight, if anything.
    func recordPresented(_ frame: DecodedFrame, at nanos: UInt64) -> Landing? {
        let pts = MediaTime(frame.presentationTime) ?? frame.time
        let end = pts + (MediaTime(frame.duration) ?? .zero)
        lastVideoEnd.withLock { $0 = max($0 ?? end, end) }
        let landing = run.withLock { run -> Landing? in
            guard var current = run, current.generation == frame.generation, current.targetLandedNanos == nil else { return nil }
            if let preview = current.previewPTS, preview == pts, current.targetPTS != preview, current.previewLandedNanos == nil {
                current.previewLandedNanos = nanos
                run = current
                return .preview(generation: frame.generation)
            }
            current.targetLandedNanos = nanos
            current.landedPTS = pts
            run = current
            return .target(generation: frame.generation)
        }
        if case .target = landing { lastLandedFrame.withLock { $0 = frame } }
        return landing
    }

    func updateRun(generation: UInt64, _ body: (inout SeekRun) -> Void) {
        run.withLock { run in
            guard var current = run, current.generation == generation else { return }
            body(&current)
            run = current
        }
    }
}

/// Where the video decoder stands between runs: the store cursor, packets read but not yet
/// submitted, and the last pts submitted. Owned by one feeder task at a time.
struct VideoFeedState: Sendable {
    var cursor: PacketStore.Cursor?
    /// Read from the store in decode order, not submitted yet.
    var lookahead: [Packet] = []
    var lastSubmittedPTS: MediaTime?
    /// Keyframe the current decode run started at. RASL pictures before it are never submitted.
    var startKeyframe: MediaTime?
    /// The decoder was drained at the end of the file; decoding needs a keyframe restart.
    var reachedEnd = false

    /// The live decoder position for the planner, when continuing is possible.
    func decoderPosition(storeEpoch: UInt64) -> DecoderPosition? {
        guard let cursor, cursor.epoch == storeEpoch, !reachedEnd, let lastSubmittedPTS else { return nil }
        return DecoderPosition(lastSubmittedPTS: lastSubmittedPTS)
    }
}

/// What one feeder run does.
struct FeedSpec: Sendable {
    var generation: UInt64
    /// Exact target time. Frames before it are decoded without output; nil outputs every frame.
    var target: MediaTime?
    /// Restart at this keyframe; nil continues from the state's cursor.
    var keyframe: MediaTime?
    /// Show the keyframe first (design section 7.5 step 3).
    var preview: Bool
    /// Decode the keyframe alone and stop (a scrub).
    var scrubOnly: Bool
    /// The store is being refilled by a demuxer seek of this generation; wait for it first.
    var awaitDemuxerSeek: Bool
}

/// Feeds packets from the PacketStore to the video decoder for one seek generation (design section
/// 7.5, steps 3 to 5): restart at a keyframe or continue, keyframe preview, non-reference and RASL
/// skipping before the target, then steady decode ahead bounded by `FrameCredits`.
///
/// Output flags are decided in decode order with a lookahead window: a packet whose pts is at or
/// before the target is the target only if no packet in the window has a pts between it and the
/// target. Any stream with a reorder depth below the window size is decided exactly.
struct VideoFeeder: Sendable {
    let demuxer: Demuxer
    let format: VideoFormat
    let decoder: any VideoDecoding
    let orderer: PresentationOrderer
    let credits: FrameCredits
    let shared: PipelineShared
    let frames: AsyncStream<DecodedFrame>.Continuation

    /// Packets read ahead of the one being decided. x265 with 8 B-frames reorders by up to 9.
    static func lookaheadWindow(for codec: VideoCodec) -> Int {
        switch codec {
        case .av1, .vp9: 4
        case .h264, .hevc, .other: 24
        }
    }

    private var store: PacketStore { demuxer.store }

    private func isStale(_ generation: UInt64) -> Bool {
        Task.isCancelled || !shared.isCurrent(generation)
    }

    /// Runs until the target is out and the file ends, the run is superseded, or (scrub) the
    /// keyframe is submitted. Returns the state for the next run.
    func run(_ initial: VideoFeedState, spec: FeedSpec) async -> VideoFeedState {
        var state = initial
        let generation = spec.generation
        if let keyframe = spec.keyframe {
            guard let resolved = await resolveStart(keyframe: keyframe, spec: spec) else { return state }
            state = VideoFeedState(cursor: resolved.cursor, startKeyframe: resolved.key)
            shared.updateRun(generation: generation) { run in
                run.startKeyframe = resolved.key
                if spec.preview { run.previewPTS = resolved.key }
            }
        }
        let window = VideoFeeder.lookaheadWindow(for: format.codec)
        var decision = Decision(target: spec.target, startKeyframe: state.startKeyframe, previewPTS: spec.preview ? spec.keyframe : nil)
        if spec.target == nil { decision.targetSubmitted = true }
        // A scrub submits the keyframe alone; the packets read behind it belong to a later run.
        decision.registersReadPackets = !spec.scrubOnly
        var firstPacket = spec.keyframe != nil
        var endOfStream = false
        // Packets read in an earlier run are registered again under this run's rules.
        for packet in state.lookahead { register(packet, decision: &decision) }

        while true {
            if isStale(generation) { return state }
            // Fill the lookahead window.
            var change = store.changeCount
            while state.lookahead.count < window, !endOfStream, var cursor = state.cursor {
                change = store.changeCount
                switch store.next(&cursor) {
                case .packet(let packet):
                    state.cursor = cursor
                    state.lookahead.append(packet)
                    register(packet, decision: &decision)
                    continue
                case .needMore:
                    break
                case .endOfStream:
                    endOfStream = true
                case .invalidated:
                    // The store was reset under this run (a newer seek); nothing more to do.
                    state.cursor = nil
                    return state
                }
                break
            }
            if state.cursor == nil { endOfStream = true }

            guard let head = state.lookahead.first else {
                if endOfStream {
                    await finishStream(&state, generation: generation)
                    return state
                }
                // Before the target is out, nothing else moves the store's playhead: ask for
                // packets past its read-ahead limit (a GOP longer than the limit).
                if !decision.targetSubmitted { store.requestMoreData() }
                await store.waitForChange(since: change)
                continue
            }
            let quick = firstPacket && (spec.preview || spec.scrubOnly)
            if !decision.targetSubmitted, !quick, state.lookahead.count < window, !endOfStream {
                store.requestMoreData()
                await store.waitForChange(since: change)
                continue
            }

            state.lookahead.removeFirst()
            let action = quick ? Action.submit(output: true) : decide(head, decision: &decision)
            firstPacket = false
            switch action {
            case .skip:
                shared.updateRun(generation: generation) { $0.framesSkipped += 1 }
                continue
            case .submit(let output):
                if output {
                    guard await credits.acquire(generation: generation) else {
                        state.lookahead.insert(head, at: 0)
                        return state
                    }
                }
                do {
                    try decoder.decode(head, generation: generation, output: output)
                } catch {
                    if output {
                        credits.release(generation: generation)
                        orderer.fail(head.cmPTS).forEach { frames.yield($0) }
                    }
                }
                if let pts = head.pts { state.lastSubmittedPTS = max(state.lastSubmittedPTS ?? pts, pts) }
                let isTarget = decision.justSubmittedTarget
                decision.justSubmittedTarget = false
                shared.updateRun(generation: generation) { run in
                    if !run.targetSubmitted { run.framesDecoded += 1 }
                    if isTarget {
                        run.targetSubmitted = true
                        run.targetPTS = head.pts
                    }
                }
                if spec.scrubOnly {
                    shared.updateRun(generation: generation) { $0.targetSubmitted = true }
                    return state
                }
            }
        }
    }

    // MARK: Start

    /// Waits for the store to hold the keyframe's GOP and returns a cursor at it. When the demuxer
    /// landed on a different keyframe (an index whose pts was estimated from dts), the stored
    /// keyframe closest at or before the target is used instead.
    private func resolveStart(keyframe: MediaTime, spec: FeedSpec) async -> (cursor: PacketStore.Cursor, key: MediaTime)? {
        let generation = spec.generation
        if spec.awaitDemuxerSeek {
            while demuxer.completedSeekGeneration < generation {
                if isStale(generation) { return nil }
                try? await Task.sleep(for: .microseconds(500))
            }
        }
        let limit = max(spec.target ?? keyframe, keyframe)
        while true {
            if isStale(generation) { return nil }
            let change = store.changeCount
            if let cursor = store.videoCursor(atKeyframe: keyframe) { return (cursor, keyframe) }
            let keys = store.storedKeyframes
            if let best = keys.last(where: { $0 <= limit }),
               keys.contains(where: { $0 > limit }) || store.isAtEndOfFile,
               let cursor = store.videoCursor(atKeyframe: best) {
                return (cursor, best)
            }
            if keys.isEmpty, store.isAtEndOfFile, let cursor = store.videoCursorAtStart() {
                return (cursor, keyframe)
            }
            // The keyframe to start at is only known once a later one (or the end) is stored.
            store.requestMoreData()
            await store.waitForChange(since: change)
        }
    }

    // MARK: Decisions

    private enum Action {
        case skip
        case submit(output: Bool)
    }

    /// Output decisions of one run.
    private struct Decision {
        var target: MediaTime?
        var startKeyframe: MediaTime?
        var previewPTS: MediaTime?
        /// The candidate registered with the orderer: the largest pts at or before the target so far.
        var best: MediaTime?
        var targetSubmitted = false
        var justSubmittedTarget = false
        var registersReadPackets = true
        /// The target frame once submitted. Packets that follow it in decode order but display
        /// before it (B-frames) are still pre-target: decoded without output, or skipped.
        var targetPTS: MediaTime?

        func isBeforeTarget(_ pts: MediaTime) -> Bool {
            targetPTS.map { pts < $0 } ?? false
        }
    }

    private func isUndecodableLeading(_ packet: Packet, pts: MediaTime, decision: Decision) -> Bool {
        guard let start = decision.startKeyframe, pts < start, format.codec == .hevc else { return false }
        return format.pictureFlags(packet).isRASL
    }

    /// Registers a packet's output with the orderer as soon as it is read, so a later frame that
    /// decodes first is held back until the target arrives.
    private func register(_ packet: Packet, decision: inout Decision) {
        guard let pts = packet.pts else { return }
        if isUndecodableLeading(packet, pts: pts, decision: decision) { return }
        guard decision.registersReadPackets || pts == decision.startKeyframe else { return }
        if decision.isBeforeTarget(pts) { return }
        if !decision.targetSubmitted, let target = decision.target, pts <= target {
            if pts == decision.previewPTS { orderer.expect(packet.cmPTS) }
            if decision.best.map({ pts > $0 }) ?? true {
                if let previous = decision.best, previous != decision.previewPTS {
                    orderer.fail(previous.cmTime).forEach { frames.yield($0) }
                }
                decision.best = pts
                orderer.expect(packet.cmPTS)
            }
            return
        }
        orderer.expect(packet.cmPTS)
    }

    private func decide(_ packet: Packet, decision: inout Decision) -> Action {
        guard let pts = packet.pts else { return .submit(output: true) }
        if isUndecodableLeading(packet, pts: pts, decision: decision) { return .skip }
        if decision.isBeforeTarget(pts) {
            return format.isDisposable(packet) ? .skip : .submit(output: false)
        }
        if !decision.targetSubmitted, let target = decision.target {
            if pts <= target {
                if pts == decision.best {
                    decision.targetSubmitted = true
                    decision.justSubmittedTarget = true
                    decision.targetPTS = pts
                    return .submit(output: true)
                }
                if pts == decision.previewPTS { return .submit(output: true) }
                return format.isDisposable(packet) ? .skip : .submit(output: false)
            }
            if decision.best == nil {
                // Nothing at or before the target (it lies before the first frame): this one lands.
                decision.targetSubmitted = true
                decision.justSubmittedTarget = true
                decision.targetPTS = pts
            }
        }
        return .submit(output: true)
    }

    // MARK: End of stream

    private func finishStream(_ state: inout VideoFeedState, generation: UInt64) async {
        await decoder.drain()
        state.reachedEnd = true
        guard shared.isCurrent(generation) else { return }
        orderer.flush().forEach { frames.yield($0) }
        shared.videoEnded.store(true, ordering: .releasing)
    }
}

/// Feeds audio packets from the store to the audio decode thread for one generation (design
/// section 7.5 step 6): from the target minus the codec preroll, paced to about one second ahead
/// of the clock so a headless engine does not decode the whole file at once.
struct AudioFeeder: Sendable {
    static let readAhead = MediaTime.seconds(1)
    static let pacingInterval: Duration = .milliseconds(20)

    let demuxer: Demuxer
    let streamIndex: Int
    let thread: AudioDecodeThread
    let shared: PipelineShared
    let clock: @Sendable () -> MediaTime

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
                if let time = packet.time {
                    while time > max(clock(), target) + AudioFeeder.readAhead {
                        try? await Task.sleep(for: AudioFeeder.pacingInterval)
                        if stale() { return }
                    }
                }
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
}
