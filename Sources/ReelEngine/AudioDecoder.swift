import AudioToolbox
import CoreMedia
import CReelDeps
import Dispatch
import Foundation
import ReelCore
import Synchronization

/// One block of decoded audio: interleaved float32 LPCM at the source rate, ready to enqueue.
public struct DecodedAudioBuffer: Sendable {
    public let sampleBuffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
    /// Index of the first sample, in units of 1 / `sampleRate` seconds.
    public let startSample: Int64
    public let frameCount: Int
    public let sampleRate: Int
    public let channelCount: Int
    /// The `AudioDecodeThread.restartCount` it was decoded under. A restart in the same
    /// generation (device change, track switch, audio delay) makes earlier buffers stale.
    public internal(set) var restart: UInt64 = 0
    /// The first buffer in a new sample rate or channel layout (section 7.10): a renderer
    /// holding audio in the old format flushes before taking it.
    public internal(set) var startsNewFormat = false

    public var presentationTime: CMTime { CMTime(value: startSample, timescale: CMTimeScale(sampleRate)) }
    public var endTime: CMTime { CMTime(value: startSample + Int64(frameCount), timescale: CMTimeScale(sampleRate)) }
    public var pts: MediaTime { MediaTime(value: startSample, timeBaseNum: 1, timeBaseDen: Int32(sampleRate)) }
    public var end: MediaTime { MediaTime(value: startSample + Int64(frameCount), timeBaseNum: 1, timeBaseDen: Int32(sampleRate)) }
    public var duration: MediaTime { end - pts }

    /// A copy of the interleaved samples (frameCount x channelCount floats).
    public func interleavedSamples() -> [Float] {
        let count = frameCount * channelCount
        return sampleBuffer.withUnsafeSampleBuffer { buffer -> [Float] in
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
            }
            return status == noErr ? samples : []
        }
    }
}

/// Audio presentation clock (design section 7.4). The first frame after open or a seek takes its
/// time from the packet; later frames continue from the running sample index, so container
/// timestamp rounding (1 ms in mkv) never accumulates. A packet more than 40 ms away from the
/// running time (a gap or a splice) re-anchors the clock.
public struct AudioClock: Sendable, Hashable {
    public static let reanchorThreshold = MediaTime.milliseconds(40)

    public struct Placement: Sendable, Hashable {
        /// First sample index of the placed frames.
        public var start: Int64
        /// The clock jumped to the packet time instead of continuing.
        public var isDiscontinuity: Bool
    }

    public let sampleRate: Int
    /// Sample index the next frame continues from, nil before the first frame.
    public private(set) var nextSample: Int64?

    public init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    /// Places `count` frames whose packet time, in samples, is `packetSample` (nil when unknown).
    public mutating func place(count: Int, packetSample: Int64?) -> Placement {
        let threshold = Int64(sampleRate) * AudioClock.reanchorThreshold.microseconds / 1_000_000
        let start: Int64
        var discontinuity = false
        switch (nextSample, packetSample) {
        case (nil, let packet?):
            start = packet
        case (nil, nil):
            start = 0
        case (let running?, let packet?) where abs(packet - running) > threshold:
            start = packet
            discontinuity = true
        case (let running?, _):
            start = running
        }
        nextSample = start + Int64(count)
        return Placement(start: start, isDiscontinuity: discontinuity)
    }

    /// Forgets the running position (after a seek).
    public mutating func reset() {
        nextSample = nil
    }

    /// Moves a packet time that a coarse container time base rounded (mkv: 1 ms) back onto the
    /// codec's frame grid, `origin + k * step` samples, when it is at most `maxCorrection` away.
    public static func snap(_ sample: Int64, step: Int64, origin: Int64, maxCorrection: Int64) -> Int64 {
        guard step > 0 else { return sample }
        let offset = sample - origin
        let lower = offset >= 0 ? offset / step : -((-offset + step - 1) / step)
        let below = origin + lower * step
        let nearest = sample - below <= below + step - sample ? below : below + step
        return abs(nearest - sample) <= maxCorrection ? nearest : sample
    }
}

/// Dropping audio before a seek target (design section 7.5 step 6).
public enum AudioTrim {
    /// How many leading frames of a buffer to drop so it starts at `target`; nil when the whole
    /// buffer ends at or before `target`.
    public static func leadingFramesToDrop(start: Int64, count: Int, target: Int64) -> Int? {
        if start + Int64(count) <= target { return nil }
        if start >= target { return 0 }
        return Int(target - start)
    }
}

/// libavcodec audio decode plus swresample to interleaved float32, with timestamps from
/// `AudioClock`, about 20 ms coalescing (TrueHD decodes 40-sample frames) and seek trimming.
/// Not thread-safe: one thread owns it (`AudioDecodeThread` in the engine).
public final class AudioDecoder {
    /// Coalesced buffers hold at least this much audio, unless a discontinuity or the end of the
    /// stream cuts them short.
    public static let coalescingTarget = MediaTime.milliseconds(20)
    public static let opusPreroll = MediaTime.milliseconds(80)

    public let codecName: String
    /// Audio to decode before a seek target so the decoder output has converged: 80 ms for Opus,
    /// one codec frame otherwise.
    public let preroll: MediaTime
    /// Rate and channels of the last decoded frame (codec parameters until the first frame).
    public private(set) var sampleRate: Int
    public private(set) var channelCount: Int
    public private(set) var channelLabels: [AudioChannelLabel] = []
    public private(set) var formatDescription: CMAudioFormatDescription?
    /// Packets the decoder rejected as corrupt (skipped, not fatal).
    public private(set) var corruptPackets = 0
    /// Presentation time of the last corrupt packet, when it had one.
    public private(set) var lastCorruptTime: MediaTime?
    /// Added to every output timestamp: the audio delay (positive plays later), applied against
    /// the synchronizer without re-decoding (design section 9.7). Trimming still uses media time.
    public var timestampOffset: MediaTime = .zero

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private let timeBase: AVRational
    private var resampler: AudioResampler?
    private var clock: AudioClock
    private var pending: [Float] = []
    private var pendingStart: Int64?
    private var scratch: [Float] = []
    private var dropBefore: MediaTime?
    private var carriedSkip = 0
    /// The next emitted buffer starts a new format (not set for the first format).
    private var formatChangePending = false
    /// Opus packets always start on a 2.5 ms grid counted from minus the pre-skip.
    private let opusGrid: (step: Int64, origin: Int64)?

    public convenience init(stream: UnsafePointer<AVStream>) throws {
        guard let parameters = stream.pointee.codecpar else { throw EngineError.noPlayableStream }
        try self.init(codecParameters: parameters, timeBase: stream.pointee.time_base)
    }

    /// `timeBase` is the stream time base the packets' pts are in.
    public init(codecParameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        let codecID = codecParameters.pointee.codec_id
        let name = String(cString: avcodec_get_name(codecID))
        guard codecParameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
            throw EngineError.unsupportedCodec("\(name) is not audio")
        }
        guard let codec = avcodec_find_decoder(codecID) else { throw EngineError.unsupportedCodec(name) }
        guard let context = avcodec_alloc_context3(codec) else {
            throw EngineError.decoderFailed("avcodec_alloc_context3 for \(name)")
        }
        var status = avcodec_parameters_to_context(context, codecParameters)
        if status >= 0 {
            context.pointee.pkt_timebase = timeBase
            // Pre-skip and priming are dropped here, not by libavcodec, which would shift pts by a
            // value rounded to the stream time base (0.5 ms off in mkv).
            context.pointee.flags2 |= AV_CODEC_FLAG2_SKIP_MANUAL
            context.pointee.thread_count = 1
            status = avcodec_open2(context, codec, nil)
        }
        guard status >= 0, let frame = av_frame_alloc() else {
            var owned: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&owned)
            throw EngineError.decoderFailed("opening \(name) decoder: \(FFmpegError.message(for: status))")
        }
        self.codecContext = context
        self.frame = frame
        self.codecName = name
        self.timeBase = timeBase
        let rate = Int(context.pointee.sample_rate > 0 ? context.pointee.sample_rate : codecParameters.pointee.sample_rate)
        self.sampleRate = rate
        self.channelCount = Int(context.pointee.ch_layout.nb_channels)
        self.clock = AudioClock(sampleRate: rate)
        let frameSize = codecParameters.pointee.frame_size > 0 ? codecParameters.pointee.frame_size : context.pointee.frame_size
        self.preroll = AudioDecoder.preroll(codecID: codecID, frameSize: Int(frameSize), sampleRate: rate)
        if codecID == AV_CODEC_ID_OPUS, rate > 0 {
            let padding = codecParameters.pointee.initial_padding > 0
                ? codecParameters.pointee.initial_padding : context.pointee.delay
            self.opusGrid = (step: Int64(rate) / 400, origin: -Int64(padding))
        } else {
            self.opusGrid = nil
        }
    }

    deinit {
        av_frame_free(&frame)
        avcodec_free_context(&codecContext)
    }

    /// Preroll before a seek target: 80 ms for Opus, one codec frame otherwise.
    public static func preroll(codecID: AVCodecID, frameSize: Int, sampleRate: Int) -> MediaTime {
        if codecID == AV_CODEC_ID_OPUS { return opusPreroll }
        let samples: Int
        if frameSize > 0 {
            samples = frameSize
        } else {
            switch codecID {
            case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: samples = 1536
            case AV_CODEC_ID_MP3, AV_CODEC_ID_MP2: samples = 1152
            case AV_CODEC_ID_VORBIS: samples = 2048
            case AV_CODEC_ID_DTS: samples = 512
            case AV_CODEC_ID_TRUEHD, AV_CODEC_ID_MLP: samples = 40
            default: samples = 1024
            }
        }
        guard sampleRate > 0 else { return .zero }
        return MediaTime(value: Int64(samples), timeBaseNum: 1, timeBaseDen: Int32(sampleRate))
    }

    /// Decodes one packet. A corrupt packet is counted and dropped, and the clock re-anchors on
    /// the next good one, so the gap it leaves does not shift later audio (section 7.10).
    public func decode(_ packet: UnsafePointer<AVPacket>) throws -> [DecodedAudioBuffer] {
        guard let codecContext else { throw EngineError.notOpen }
        var output: [DecodedAudioBuffer] = []
        var status = avcodec_send_packet(codecContext, packet)
        if status == reel_averror_eagain() {
            try receiveFrames(into: &output)
            status = avcodec_send_packet(codecContext, packet)
        }
        if status == reel_averror(ENOMEM) {
            throw EngineError.decoderFailed("\(codecName): out of memory")
        }
        if status < 0, status != reel_averror_eof() {
            try noteCorrupt(pts: packet.pointee.pts, into: &output)
        }
        try receiveFrames(into: &output)
        return output
    }

    private func noteCorrupt(pts: Int64, into output: inout [DecodedAudioBuffer]) throws {
        corruptPackets += 1
        if pts != reel_av_nopts(), timeBase.den != 0 {
            lastCorruptTime = MediaTime(value: pts, timeBaseNum: timeBase.num, timeBaseDen: timeBase.den)
        }
        try emitPending(into: &output)
        clock.reset()
    }

    /// Decodes one packet from the PacketStore.
    public func decode(_ packet: Packet) throws -> [DecodedAudioBuffer] {
        try withExtendedLifetime(packet) { try decode(packet.avPacket) }
    }

    /// End of stream: drains the decoder and emits the last partial buffer. The decoder accepts
    /// packets again afterwards (as after `reset`).
    public func finish() throws -> [DecodedAudioBuffer] {
        guard let codecContext else { throw EngineError.notOpen }
        var output: [DecodedAudioBuffer] = []
        if avcodec_send_packet(codecContext, nil) >= 0 {
            try receiveFrames(into: &output)
        }
        try emitPending(into: &output)
        avcodec_flush_buffers(codecContext)
        clock.reset()
        return output
    }

    /// Prepares for packets from a new position. Flushes the decoder and resampler and forgets
    /// the clock. When `target` is set, buffers ending before it are dropped and the buffer that
    /// straddles it is trimmed so the first output sample is at `target`.
    public func reset(dropBefore target: MediaTime?) {
        if let codecContext { avcodec_flush_buffers(codecContext) }
        resampler?.reset()
        clock.reset()
        carriedSkip = 0
        pending.removeAll(keepingCapacity: true)
        pendingStart = nil
        dropBefore = target
    }

    private func receiveFrames(into output: inout [DecodedAudioBuffer]) throws {
        guard let codecContext, let frame else { return }
        while true {
            let status = avcodec_receive_frame(codecContext, frame)
            if status == reel_averror_eagain() || status == reel_averror_eof() { return }
            if status < 0 {
                try noteCorrupt(pts: reel_av_nopts(), into: &output)
                return
            }
            defer { av_frame_unref(frame) }
            try handle(frame, into: &output)
        }
    }

    private func handle(_ frame: UnsafeMutablePointer<AVFrame>, into output: inout [DecodedAudioBuffer]) throws {
        if resampler?.accepts(frame) != true {
            try emitPending(into: &output)
            if resampler != nil { formatChangePending = true }
            let fresh = try AudioResampler(matching: frame)
            let labels = ChannelLayout.labels(for: fresh.channels)
            formatDescription = try ChannelLayout.formatDescription(sampleRate: fresh.sampleRate, labels: labels)
            if fresh.sampleRate != clock.sampleRate { clock = AudioClock(sampleRate: fresh.sampleRate) }
            resampler = fresh
            sampleRate = fresh.sampleRate
            channelCount = fresh.channelCount
            channelLabels = labels
        }
        guard let resampler else { return }
        // Decoder preroll frames that a container marks for discarding (mp4 edit lists).
        if frame.pointee.flags & AV_FRAME_FLAG_DISCARD != 0 { return }
        scratch.removeAll(keepingCapacity: true)
        let decoded = try resampler.convert(frame, appendingTo: &scratch)
        let (skip, padding) = skipAndPadding(of: frame, decoded: decoded)
        let count = decoded - skip - padding
        guard count > 0 else { return }
        if skip > 0 { scratch.removeFirst(skip * channelCount) }
        if padding > 0 { scratch.removeLast(padding * channelCount) }

        // Frame pts is still the packet pts (skipping is manual), so the kept samples start
        // `skip` samples after it, exactly, without the time base rounding libavcodec would add.
        let timestamp = frame.pointee.best_effort_timestamp != reel_av_nopts()
            ? frame.pointee.best_effort_timestamp : frame.pointee.pts
        var packetSample: Int64?
        if timestamp != reel_av_nopts(), timeBase.num > 0, timeBase.den > 0 {
            var sample = av_rescale_q(timestamp, timeBase, AVRational(num: 1, den: Int32(sampleRate)))
            let tickSamples = Int64(sampleRate) * Int64(timeBase.num) / Int64(timeBase.den)
            if let opusGrid, tickSamples > 1 {
                sample = AudioClock.snap(sample, step: opusGrid.step, origin: opusGrid.origin, maxCorrection: tickSamples)
            }
            packetSample = sample + Int64(skip)
        }
        let placement = clock.place(count: count, packetSample: packetSample)
        if placement.isDiscontinuity { try emitPending(into: &output) }
        if pending.isEmpty { pendingStart = placement.start }
        pending.append(contentsOf: scratch)

        let targetFrames = Int(Int64(sampleRate) * AudioDecoder.coalescingTarget.microseconds / 1_000_000)
        if pending.count / channelCount >= targetFrames {
            try emitPending(into: &output)
        }
    }

    /// Leading samples to drop (Opus pre-skip, AAC priming) and trailing padding, from the skip
    /// side data libavcodec exports with `AV_CODEC_FLAG2_SKIP_MANUAL`. A skip longer than the
    /// frame carries over to the next frame.
    private func skipAndPadding(of frame: UnsafeMutablePointer<AVFrame>, decoded: Int) -> (skip: Int, padding: Int) {
        var skip = carriedSkip
        var padding = 0
        if let side = av_frame_get_side_data(frame, AV_FRAME_DATA_SKIP_SAMPLES), side.pointee.size >= 8, let data = side.pointee.data {
            let bytes = UnsafeRawPointer(data)
            skip += Int(UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self)))
            padding = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
        }
        carriedSkip = max(0, skip - decoded)
        skip = min(skip, decoded)
        padding = min(padding, decoded - skip)
        return (skip, padding)
    }

    private func emitPending(into output: inout [DecodedAudioBuffer]) throws {
        defer {
            pending.removeAll(keepingCapacity: true)
            pendingStart = nil
        }
        guard let start = pendingStart, !pending.isEmpty, channelCount > 0, let formatDescription else { return }
        let count = pending.count / channelCount
        var drop = 0
        if let target = dropBefore {
            let targetSample = target.value(timeBaseNum: 1, timeBaseDen: Int32(sampleRate))
            guard let leading = AudioTrim.leadingFramesToDrop(start: start, count: count, target: targetSample) else { return }
            drop = leading
            dropBefore = nil
        }
        let frames = count - drop
        guard frames > 0 else { return }
        let first = start + Int64(drop) + timestampOffset.value(timeBaseNum: 1, timeBaseDen: Int32(sampleRate))
        let ready = try pending.withUnsafeBufferPointer { samples in
            try AudioSampleBufferFactory.make(
                samples: UnsafeBufferPointer(rebasing: samples[(drop * channelCount)...]),
                frames: frames,
                formatDescription: formatDescription,
                presentationTime: CMTime(value: first, timescale: CMTimeScale(sampleRate))
            )
        }
        var buffer = DecodedAudioBuffer(
            sampleBuffer: ready,
            startSample: first,
            frameCount: frames,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        buffer.startsNewFormat = formatChangePending
        formatChangePending = false
        output.append(buffer)
    }
}

/// Builds ready LPCM sample buffers with `CMAudioSampleBufferCreateReadyWithPacketDescriptions`.
enum AudioSampleBufferFactory {
    static func make(
        samples: UnsafeBufferPointer<Float>,
        frames: Int,
        formatDescription: CMAudioFormatDescription,
        presentationTime: CMTime
    ) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let length = samples.count * MemoryLayout<Float>.size
        guard let base = samples.baseAddress, length > 0 else {
            throw EngineError.decoderFailed("empty audio buffer")
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            throw EngineError.decoderFailed("CMBlockBufferCreateWithMemoryBlock failed (\(status))")
        }
        status = CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        guard status == noErr else {
            throw EngineError.decoderFailed("CMBlockBufferReplaceDataBytes failed (\(status))")
        }
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: frames,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw EngineError.decoderFailed("CMAudioSampleBufferCreateReadyWithPacketDescriptions failed (\(status))")
        }
        return CMReadySampleBuffer(fresh: sampleBuffer)
    }
}

/// The dedicated audio decode thread (design section 7.1). It owns an `AudioDecoder`, takes
/// packets and seek commands from a lock-protected queue and yields decoded buffers tagged with
/// the seek generation. Work from an older generation is discarded at submit time.
public final class AudioDecodeThread: Sendable {
    public enum Output: Sendable {
        case buffer(DecodedAudioBuffer, generation: UInt64)
        /// Everything submitted before `finish` has been decoded and emitted.
        case endOfStream(generation: UInt64)
        case failed(String, generation: UInt64)
    }

    /// Outputs in order. Finished after `stop()`.
    public let outputs: AsyncStream<Output>
    public let preroll: MediaTime

    private let continuation: AsyncStream<Output>.Continuation
    private let state: Mutex<State>
    private let wakeup = DispatchSemaphore(value: 0)
    private let restarts = Atomic<UInt64>(0)
    private let damageHandler = Mutex<SendableCallback<(time: MediaTime?, generation: UInt64)>?>(nil)

    /// Called on the decode thread for each packet the decoder rejected as corrupt, with its
    /// time and generation (section 7.10).
    public func setDamageHandler(_ handler: (@Sendable (MediaTime?, UInt64) -> Void)?) {
        damageHandler.withLock { $0 = handler.map { handler in SendableCallback { handler($0.time, $0.generation) } } }
    }

    /// Increments on every `seek`. Buffers tagged with an older value were decoded before it.
    public var restartCount: UInt64 { restarts.load(ordering: .acquiring) }

    private enum Command {
        case packet(Packet)
        case reset(MediaTime?, offset: MediaTime?)
        case finish
    }

    private struct State {
        var decoder: AudioDecoder
        var queue: [Command] = []
        var head = 0
        var generation: UInt64 = 0
        var restart: UInt64 = 0
        var stopped = false

        mutating func pop() -> Command? {
            guard head < queue.count else { return nil }
            let command = queue[head]
            head += 1
            if head == queue.count {
                queue.removeAll(keepingCapacity: true)
                head = 0
            }
            return command
        }

        mutating func clear() {
            queue.removeAll()
            head = 0
        }
    }

    public init(decoder: sending AudioDecoder, name: String = "Reel audio decode") {
        preroll = decoder.preroll
        state = Mutex(State(decoder: decoder))
        (outputs, continuation) = AsyncStream.makeStream(of: Output.self)
        let thread = Thread { [self] in run() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Queues a packet (from the PacketStore) for decoding. Ignored when `generation` is older
    /// than the last seek.
    public func submit(_ packet: Packet, generation: UInt64) {
        let queued = state.withLock { state -> Bool in
            guard !state.stopped, generation == state.generation else { return false }
            state.queue.append(.packet(packet))
            return true
        }
        if queued { wakeup.signal() }
    }

    /// Starts a new generation: queued work is dropped, the decoder is flushed, and output from
    /// the next packets is trimmed to start at `target` (none when nil). A `timestampOffset`
    /// replaces the decoder's (the audio delay); nil keeps it.
    public func seek(dropBefore target: MediaTime?, generation: UInt64, timestampOffset: MediaTime? = nil) {
        state.withLock { state in
            guard !state.stopped else { return }
            state.generation = generation
            state.restart = restarts.add(1, ordering: .acquiringAndReleasing).newValue
            state.clear()
            state.queue.append(.reset(target, offset: timestampOffset))
        }
        wakeup.signal()
    }

    /// Drains the decoder after the last packet of the current generation.
    public func finish(generation: UInt64) {
        let queued = state.withLock { state -> Bool in
            guard !state.stopped, generation == state.generation else { return false }
            state.queue.append(.finish)
            return true
        }
        if queued { wakeup.signal() }
    }

    /// Stops the thread and finishes `outputs`. Must be called; the thread keeps itself alive until then.
    public func stop() {
        state.withLock { state in
            state.stopped = true
            state.clear()
        }
        wakeup.signal()
    }

    private func run() {
        while true {
            wakeup.wait()
            let keepRunning = state.withLock { state -> Bool in
                if state.stopped { return false }
                guard let command = state.pop() else { return true }
                let generation = state.generation
                let restart = state.restart
                func tagged(_ buffer: DecodedAudioBuffer) -> DecodedAudioBuffer {
                    var buffer = buffer
                    buffer.restart = restart
                    return buffer
                }
                do {
                    switch command {
                    case .packet(let packet):
                        let corruptBefore = state.decoder.corruptPackets
                        for buffer in try state.decoder.decode(packet) {
                            continuation.yield(.buffer(tagged(buffer), generation: generation))
                        }
                        if state.decoder.corruptPackets != corruptBefore {
                            damageHandler.withLock { $0 }?.call((state.decoder.lastCorruptTime ?? packet.time, generation))
                        }
                    case .reset(let target, let offset):
                        state.decoder.reset(dropBefore: target)
                        if let offset { state.decoder.timestampOffset = offset }
                    case .finish:
                        for buffer in try state.decoder.finish() {
                            continuation.yield(.buffer(tagged(buffer), generation: generation))
                        }
                        continuation.yield(.endOfStream(generation: generation))
                    }
                } catch {
                    continuation.yield(.failed(error.localizedDescription, generation: generation))
                }
                return true
            }
            if !keepRunning { break }
        }
        continuation.finish()
    }
}
