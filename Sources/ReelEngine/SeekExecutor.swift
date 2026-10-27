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
        var limit: Int
        var available: Int
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter: UInt64 = 0
    }

    /// The limit a reset without its own uses.
    let baseLimit: Int
    private let state: Mutex<State>

    init(limit: Int) {
        baseLimit = limit
        state = Mutex(State(limit: limit, available: limit))
    }

    var available: Int { state.withLock { $0.available } }
    /// The limit of the current generation.
    var limit: Int { state.withLock { $0.limit } }

    /// Starts `generation` with every credit free and wakes waiters of older generations. A
    /// software run of the VP9 hybrid passes a higher `limit`: its frame threads hold that many
    /// output frames before the first one comes out (`SoftwareVideoDecoder.outputDelay`).
    func reset(generation: UInt64, limit: Int? = nil) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.generation = generation
            state.limit = max(limit ?? baseLimit, baseLimit)
            state.available = state.limit
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
            state.available = min(state.limit, state.available + 1)
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
    /// The decoder the run started on (software for a long VP9 exact seek, D46).
    var decoder: VideoDecoderKind = .hardware

    func report(bytesNow: Int64, cancelled: Bool, handoffs: Int? = nil) -> SeekReport {
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
            cancelled: cancelled,
            decoder: decoder,
            decoderHandoffs: handoffs
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
    /// Tests: milliseconds the audio feeder holds the next packet before submitting it (one shot).
    let audioSubmitHoldForTesting = Atomic<Int>(0)
    /// Software to hardware hand-offs of the VP9 hybrid since open (D46).
    let decoderHandoffs = Atomic<Int>(0)
    /// The last frames enqueued, oldest first, for screenshots: the one on screen is the newest
    /// with a pts at or before the clock (up to `maxFramesAhead` are queued ahead of it).
    let recentFrames = Mutex<[DecodedFrame]>([])
    static let recentFrameLimit = VideoOutput.maxFramesAhead + 1

    // M3 robustness (section 7.10).
    /// Damaged frames and packets, and the rate-limited `.damaged` events.
    let damage = DamageTracker()
    /// Frames the video decoders returned since open. Failures before the first good frame are a
    /// decoder that cannot handle the stream (the software fallback's case), not damage.
    let goodFrames = Atomic<Int>(0)
    /// A frame failed during playback: the feeder skips to the next keyframe (section 7.10).
    let videoAwaitsKeyframe = Atomic<Bool>(false)
    /// The `.dataEnd` event of the open file has been sent.
    let dataEndReported = Atomic<Bool>(false)
    /// The open file's data end, once known. Frames that fail just before it reference frames
    /// the cut removed: that is the end of the data, not damage.
    let dataEnd = Mutex<MediaTime?>(nil)
    static let cutReferenceWindow = MediaTime.milliseconds(500)

    /// True when a frame at `time` failing is damage rather than the end of the data.
    func isDamage(at time: MediaTime?) -> Bool {
        guard let time, let end = dataEnd.withLock({ $0 }) else { return true }
        return time < end - PipelineShared.cutReferenceWindow
    }
    /// Decoders for GOPs in another format than the stream's at open (MPEG-TS resolution
    /// changes); nil when the stream needs none.
    let formatDecoders = Mutex<FormatDecoders?>(nil)
    /// Uptime when the feeder of the current generation reached the end of the video stream.
    let videoEndedNanos = Atomic<UInt64>(0)
    /// The VP9 tile check beside VideoToolbox (section 7.10); nil for other streams.
    let tileCheck = Mutex<VP9TileCheck?>(nil)

    var currentGeneration: UInt64 { generation.load(ordering: .acquiring) }

    func isCurrent(_ value: UInt64) -> Bool { value == currentGeneration }

    /// Records an enqueued frame and returns what it meant for the seek in flight, if anything.
    func recordPresented(_ frame: DecodedFrame, at nanos: UInt64) -> Landing? {
        let pts = MediaTime(frame.presentationTime) ?? frame.time
        let end = pts + (MediaTime(frame.duration) ?? .zero)
        lastVideoEnd.withLock { $0 = max($0 ?? end, end) }
        recentFrames.withLock { frames in
            frames.append(frame)
            if frames.count > PipelineShared.recentFrameLimit { frames.removeFirst(frames.count - PipelineShared.recentFrameLimit) }
        }
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

    /// The recent frame shown at `time`: the newest with a pts at or before it, else the oldest.
    func frameShown(at time: MediaTime) -> DecodedFrame? {
        recentFrames.withLock { frames in
            frames.last { (MediaTime($0.presentationTime) ?? $0.time) <= time + .milliseconds(1) } ?? frames.first
        }
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
    /// The decoder holding the reference state (the hybrid's software decoder until it hands over).
    var active: VideoDecoderKind?
    /// Packets were skipped after damage; the decoder holds no usable references until the next
    /// keyframe, so a seek must restart rather than continue.
    var skippedDamage = false
    /// The decoder for a GOP in another format than the stream's at open, and that format's
    /// configuration record; nil while the open format plays.
    var formatDecoder: (any VideoDecoding)?
    var formatRecord: Data?

    /// The live decoder position for the planner, when continuing is possible.
    func decoderPosition(storeEpoch: UInt64) -> DecoderPosition? {
        guard let cursor, cursor.epoch == storeEpoch, !reachedEnd, !skippedDamage, let lastSubmittedPTS else { return nil }
        return DecoderPosition(lastSubmittedPTS: lastSubmittedPTS, decoder: active)
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
    /// The decoder a restart begins on; a continued run keeps the state's.
    var decoder: VideoDecoderKind
}

/// Feeds packets from the PacketStore to the video decoder for one seek generation (design section
/// 7.5, steps 3 to 5): restart at a keyframe or continue, keyframe preview, non-reference and RASL
/// skipping before the target, then steady decode ahead bounded by `FrameCredits`.
///
/// Output flags are decided in decode order with a lookahead window: a packet whose pts is at or
/// before the target is the target only if no packet in the window has a pts between it and the
/// target. Any stream with a reorder depth below the window size is decided exactly.
///
/// VP9 hybrid (D46): a run may start on `software`; once its target is out, the next keyframe
/// goes to `decoder` (VideoToolbox) after the software decoder has drained, so the frames before
/// it are presented and nothing on screen is flushed.
struct VideoFeeder: Sendable {
    let demuxer: Demuxer
    let format: VideoFormat
    let decoder: any VideoDecoding
    /// The hybrid's software decoder, when the stream has one.
    let software: (any VideoDecoding)?
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
        if spec.keyframe != nil { state.active = spec.decoder }
        if software == nil || state.active == nil { state.active = decoder.kind }
        let tileCheck = shared.tileCheck.withLock { $0 }
        if let keyframe = spec.keyframe {
            tileCheck?.pause()
            guard let resolved = await resolveStart(keyframe: keyframe, spec: spec) else { return state }
            state = VideoFeedState(cursor: resolved.cursor, startKeyframe: resolved.key, active: state.active)
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
            // A preview keyframe that is also the frame shown at the target goes through decide(),
            // which marks the target submitted; the quick path would show it as a mere preview.
            let isTargetFrame = spec.target != nil && head.pts != nil && head.pts == decision.best
            let quick = firstPacket && (spec.preview || spec.scrubOnly) && !isTargetFrame
            if !decision.targetSubmitted, !quick, state.lookahead.count < window, !endOfStream {
                store.requestMoreData()
                await store.waitForChange(since: change)
                continue
            }

            state.lookahead.removeFirst()
            if head.isKeyframe, let pts = head.pts, store.videoFormat(atKeyframe: pts)?.convertedConfigurationRecord != state.formatRecord {
                guard await switchFormat(&state, at: pts, generation: generation) else {
                    state.lookahead.insert(head, at: 0)
                    return state
                }
            }
            if decision.targetSubmitted, !spec.scrubOnly, head.isKeyframe, head.pts != state.startKeyframe,
               let software, state.active == .software, decoder.kind == .hardware {
                // Hand-off: the frames before this keyframe come out of software first. Counted
                // before the drain, which pushes out a software landing whose report must include it.
                shared.decoderHandoffs.add(1, ordering: .releasing)
                await software.drain()
                if !shared.isCurrent(generation) {
                    // Superseded during the drain: the hand-off did not happen.
                    shared.decoderHandoffs.subtract(1, ordering: .releasing)
                    state.lookahead.insert(head, at: 0)
                    state.reachedEnd = true
                    return state
                }
                state.active = .hardware
                trace("hybrid hand-off to VideoToolbox at \(head.pts?.description ?? "-")")
                if Task.isCancelled {
                    // Parked while paused (section 7.9), same generation: the drain already put
                    // out the landing, so the hand-off stands; the keyframe waits for play.
                    state.lookahead.insert(head, at: 0)
                    return state
                }
            }
            if decision.targetSubmitted, !spec.scrubOnly, shared.videoAwaitsKeyframe.load(ordering: .acquiring) {
                if !head.isKeyframe {
                    // Damaged video: nothing decodes cleanly until the next keyframe (section 7.10).
                    tileCheck?.pause()
                    orderer.fail(head.cmPTS).forEach { frames.yield($0) }
                    shared.damage.record(.video, at: head.pts)
                    state.skippedDamage = true
                    continue
                }
                // The keyframe after the damage: flush the decoder's error state, then go on.
                await current(state).drain()
                if isStale(generation) {
                    state.lookahead.insert(head, at: 0)
                    return state
                }
                shared.videoAwaitsKeyframe.store(false, ordering: .releasing)
                state.skippedDamage = false
                // The resume keyframe starts a new decode run, as a seek restart does: the RASL
                // pictures of an HEVC CRA reference the GOP that was skipped, would fail with
                // "reference missing" and send the feeder back to waiting, GOP after GOP.
                if let pts = head.pts {
                    state.startKeyframe = pts
                    decision.startKeyframe = pts
                    state.lookahead.removeAll { packet in
                        guard let leading = packet.pts, isUndecodableLeading(packet, pts: leading, decision: decision) else { return false }
                        orderer.fail(packet.cmPTS).forEach { frames.yield($0) }
                        return true
                    }
                }
                trace("video resumes after damage at \(head.pts?.description ?? "-")")
            }
            let action = quick ? Action.submit(output: true) : decide(head, decision: &decision)
            firstPacket = false
            switch action {
            case .skip:
                tileCheck?.pause()
                shared.updateRun(generation: generation) { $0.framesSkipped += 1 }
                continue
            case .submit(let output):
                if output {
                    guard await credits.acquire(generation: generation) else {
                        state.lookahead.insert(head, at: 0)
                        return state
                    }
                }
                if let tileCheck, checkTiles(head, with: tileCheck, output: output, state: state, decision: decision, generation: generation) == .damaged {
                    // Damage VideoToolbox would decode without an error: skip to the next
                    // keyframe as for a failed frame (section 7.10).
                    shared.damage.record(.video, at: head.pts)
                    shared.videoAwaitsKeyframe.store(true, ordering: .releasing)
                    state.skippedDamage = true
                    if output {
                        credits.release(generation: generation)
                        orderer.fail(head.cmPTS).forEach { frames.yield($0) }
                    }
                    continue
                }
                // Before the decode: the presenter tells a preview from the target by this pts.
                if decision.justSubmittedTarget { shared.updateRun(generation: generation) { $0.targetPTS = head.pts } }
                do {
                    try current(state).decode(head, generation: generation, output: output)
                } catch {
                    if output {
                        credits.release(generation: generation)
                        orderer.fail(head.cmPTS).forEach { frames.yield($0) }
                    }
                    // A packet the decoder refuses outright (empty, malformed) is damage too.
                    if shared.goodFrames.load(ordering: .relaxed) > 0, shared.isDamage(at: head.pts) { shared.damage.record(.video, at: head.pts) }
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
                    if let threaded = current(state) as? SoftwareVideoDecoder, threaded.outputDelay > 0 {
                        // Frame threads hold the keyframe until more packets come; the drain lets
                        // it out now. The decoder keeps no references, so the next run restarts.
                        await threaded.drain()
                        state.reachedEnd = true
                    }
                    return state
                }
            }
        }
    }

    /// Runs the VP9 tile check on a packet about to go to VideoToolbox. Returns `.damaged` only
    /// when the packet should be skipped: the seek target itself, and damage at the end of a cut
    /// file, still go to the decoder (`.unchecked`).
    private func checkTiles(_ packet: Packet, with check: VP9TileCheck, output: Bool, state: VideoFeedState, decision: Decision, generation: UInt64) -> VP9TileCheck.Verdict {
        guard current(state).kind == .hardware, state.formatDecoder == nil else {
            check.pause()
            return .unchecked
        }
        let verdict = check.inspect(packet, mayStart: output && decision.targetSubmitted)
        guard verdict == .damaged else { return verdict }
        if decision.justSubmittedTarget || !shared.isDamage(at: packet.pts) || !shared.isCurrent(generation) {
            return .unchecked
        }
        return .damaged
    }

    /// The decoder the state's reference frames live in.
    private func current(_ state: VideoFeedState) -> any VideoDecoding {
        if let formatDecoder = state.formatDecoder { return formatDecoder }
        if state.active == .software, decoder.kind == .hardware, let software { return software }
        return decoder
    }

    /// A keyframe in another format than the one decoding (section 7.10): the frames before it
    /// come out of the old decoder, then a decoder for its format takes over. Returns false
    /// when the run went stale meanwhile.
    private func switchFormat(_ state: inout VideoFeedState, at pts: MediaTime, generation: UInt64) async -> Bool {
        let wanted = store.videoFormat(atKeyframe: pts)
        let next: (any VideoDecoding)? = wanted.flatMap { format in shared.formatDecoders.withLock { $0 }?.decoder(for: format) }
        if wanted != nil, next == nil { return true } // No decoder for it: the open one tries.
        await current(state).drain()
        if isStale(generation) { return false }
        next?.reset(generation: generation)
        state.formatDecoder = next
        state.formatRecord = wanted?.convertedConfigurationRecord
        trace("video format \(wanted.map { "\($0.width)x\($0.height)" } ?? "of the stream") from \(pts)")
        return true
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
        await current(state).drain()
        state.reachedEnd = true
        guard shared.isCurrent(generation) else { return }
        orderer.flush().forEach { frames.yield($0) }
        shared.videoEndedNanos.store(monotonicNanos(), ordering: .releasing)
        shared.videoEnded.store(true, ordering: .releasing)
    }
}

/// Damaged data counts and the `.damaged` events (section 7.10, D62): every damaged frame or
/// packet is counted, and an event goes out at most once per `eventInterval` per kind, so one
/// damaged region gives one OSD.
final class DamageTracker: Sendable {
    static let eventInterval: UInt64 = 10_000_000_000

    private struct State {
        var videoFrames = 0
        var audioPackets = 0
        var lastEvent: [DamageKind: UInt64] = [:]
    }

    private let state = Mutex(State())
    private let sink = Mutex<SendableCallback<(time: MediaTime?, kind: DamageKind)>?>(nil)

    /// Receives the rate-limited events; a nil time means "now on the clock".
    func setEventSink(_ handler: (@Sendable (MediaTime?, DamageKind) -> Void)?) {
        sink.withLock { $0 = handler.map { handler in SendableCallback { handler($0.time, $0.kind) } } }
    }

    func reset() {
        state.withLock { $0 = State() }
    }

    var videoFrames: Int { state.withLock { $0.videoFrames } }
    var audioPackets: Int { state.withLock { $0.audioPackets } }

    /// Counts `count` damaged frames (video) or packets (audio) at `time`. Damage found while
    /// probing at open has no place in time and is counted without an event.
    func record(_ kind: DamageKind, at time: MediaTime?, count: Int = 1, emitsEvent: Bool = true, now: UInt64 = monotonicNanos()) {
        let emit = state.withLock { state -> Bool in
            switch kind {
            case .video: state.videoFrames += count
            case .audio: state.audioPackets += count
            }
            guard emitsEvent else { return false }
            if let last = state.lastEvent[kind], now &- last < DamageTracker.eventInterval { return false }
            state.lastEvent[kind] = now
            return true
        }
        if emit {
            trace("damaged \(kind.rawValue) at \(time?.description ?? "-")")
            sink.withLock { $0 }?.call((time, kind))
        }
    }
}

/// Hardware decoders for GOPs whose in-band parameter sets differ from the stream's at open (an
/// SPS change in MPEG-TS, section 7.10), one per format, made on first use with the same frame
/// handler as the main decoder.
final class FormatDecoders: Sendable {
    private let handler: DecodeHandler
    private let parameters: CodecParameters
    private let decoders = Mutex<[Data: any VideoDecoding]>([:])

    init(handler: @escaping DecodeHandler, parameters: CodecParameters) {
        self.handler = handler
        self.parameters = parameters
    }

    /// A decoder for `format`: VideoToolbox, or libavcodec when VideoToolbox refuses it.
    func decoder(for format: VideoFormat) -> (any VideoDecoding)? {
        guard let record = format.convertedConfigurationRecord else { return nil }
        return decoders.withLock { decoders -> (any VideoDecoding)? in
            if let known = decoders[record] { return known }
            let made: (any VideoDecoding)? = (try? VTVideoDecoder(format: format, handler: handler))
                ?? (try? SoftwareVideoDecoder(parameters: parameters, format: format, handler: handler))
            decoders[record] = made
            return made
        }
    }

    /// Frames of older generations are dropped, as for the main decoder.
    func cancel(olderThan generation: UInt64) {
        for decoder in decoders.withLock({ Array($0.values) }) { decoder.cancel(olderThan: generation) }
    }

    func invalidateAll() {
        let all = decoders.withLock { decoders -> [any VideoDecoding] in
            defer { decoders.removeAll() }
            return Array(decoders.values)
        }
        for decoder in all { decoder.invalidate() }
    }
}
