import CoreMedia
import CoreVideo
import CReelDeps
import Foundation
import ReelCore
import Synchronization

/// libavcodec video decode (dav1d for AV1) on a dedicated thread (design section 7.3, software path).
///
/// Frames are converted with swscale into an IOSurface-backed `CVPixelBufferPool` (NV12 for 8-bit,
/// P010 above), with colour attachments that propagate. The pool has an allocation threshold of
/// 12 buffers; when it is reached the thread waits for the consumer instead of failing.
public final class SoftwareVideoDecoder: VideoDecoding {
    public let kind: VideoDecoderKind = .software
    public static let poolAllocationThreshold = 12
    /// How long the decode thread waits for a free pool buffer before allocating past the threshold.
    public static let poolWaitLimit: Duration = .seconds(5)

    fileprivate enum Job: Sendable {
        case packet(Packet, generation: UInt64, output: Bool)
        case reset(generation: UInt64)
        case drain(@Sendable () -> Void)
        case stop
    }

    /// State shared between the decoder object and its thread.
    fileprivate final class Channel: Sendable {
        let jobs = Mutex<[Job]>([])
        let condition = NSCondition()
        let generation = Atomic<UInt64>(0)
        let stopped = Atomic<Bool>(false)

        func takeJobs() -> [Job] {
            jobs.withLock { queue -> [Job] in
                defer { queue.removeAll() }
                return queue
            }
        }
    }

    private let channel = Channel()
    private let handler: DecodeHandler
    public let codecName: String

    public init(parameters: CodecParameters, format: VideoFormat?, threads: Int? = nil, handler: @escaping DecodeHandler) throws {
        self.handler = handler
        // Open once here so an unsupported codec fails at creation, not on the thread.
        let threadCount = threads ?? SoftwareVideoDecoder.performanceCoreCount
        let extradata = format?.convertedConfigurationRecord
        var context: UnsafeMutablePointer<AVCodecContext>? = try SoftwareVideoDecoder.openCodecContext(parameters: parameters.pointer, threads: threadCount, extradata: extradata)
        codecName = context.flatMap { $0.pointee.codec }.map { String(cString: $0.pointee.name) } ?? parameters.codecName
        avcodec_free_context(&context)

        let thread = Thread { [channel, handler] in
            let worker: Worker
            do {
                worker = try Worker(parameters: parameters, format: format, threads: threadCount, channel: channel, handler: handler)
            } catch {
                channel.stopped.store(true, ordering: .releasing)
                return
            }
            while true {
                channel.condition.lock()
                var batch = channel.takeJobs()
                while batch.isEmpty {
                    _ = channel.condition.wait(until: Date(timeIntervalSinceNow: 1))
                    batch = channel.takeJobs()
                }
                channel.condition.unlock()
                for job in batch {
                    switch job {
                    case .stop:
                        return
                    case .packet(let packet, let packetGeneration, let output):
                        guard packetGeneration >= channel.generation.load(ordering: .acquiring) else { continue }
                        worker.decode(packet, generation: packetGeneration, output: output)
                    case .reset:
                        worker.flushDecoder()
                    case .drain(let done):
                        worker.drain()
                        done()
                    }
                }
            }
        }
        thread.name = "reel.video.software"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        invalidate()
    }

    /// Performance cores, used as libavcodec's frame-thread count.
    public static var performanceCoreCount: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// Opens a libavcodec decoder for `parameters`, preferring libdav1d for AV1.
    /// - Parameter extradata: replaces codecpar's extradata (the avcC/hvcC for converted Annex B streams).
    static func openCodecContext(parameters: UnsafePointer<AVCodecParameters>, threads: Int, extradata: Data? = nil) throws -> UnsafeMutablePointer<AVCodecContext> {
        let codecID = parameters.pointee.codec_id
        var codec: UnsafePointer<AVCodec>?
        if codecID == AV_CODEC_ID_AV1 { codec = avcodec_find_decoder_by_name("libdav1d") }
        if codec == nil { codec = avcodec_find_decoder(codecID) }
        guard let codec else { throw EngineError.unsupportedCodec(String(cString: avcodec_get_name(codecID))) }
        guard let context = avcodec_alloc_context3(codec) else {
            throw FFmpegError(code: reel_averror(ENOMEM), operation: "avcodec_alloc_context3")
        }
        var owned: UnsafeMutablePointer<AVCodecContext>? = context
        do {
            try FFmpegError.check(avcodec_parameters_to_context(context, parameters), "avcodec_parameters_to_context")
            if let extradata {
                av_freep(&context.pointee.extradata)
                let padding = Int(AV_INPUT_BUFFER_PADDING_SIZE)
                guard let buffer = av_mallocz(extradata.count + padding)?.assumingMemoryBound(to: UInt8.self) else {
                    throw FFmpegError(code: reel_averror(ENOMEM), operation: "av_mallocz")
                }
                extradata.copyBytes(to: buffer, count: extradata.count)
                context.pointee.extradata = buffer
                context.pointee.extradata_size = Int32(extradata.count)
            }
            context.pointee.thread_count = Int32(max(1, threads))
            context.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
            try FFmpegError.check(avcodec_open2(context, codec, nil), "avcodec_open2(\(String(cString: codec.pointee.name)))")
        } catch {
            avcodec_free_context(&owned)
            throw error
        }
        return context
    }

    private func enqueue(_ job: Job) {
        channel.condition.lock()
        channel.jobs.withLock { $0.append(job) }
        channel.condition.signal()
        channel.condition.unlock()
    }

    /// Jobs not yet taken by the decode thread.
    public var pendingJobs: Int { channel.jobs.withLock { $0.count } }

    public var currentGeneration: UInt64 { channel.generation.load(ordering: .acquiring) }

    public func decode(_ packet: Packet, generation: UInt64, output: Bool) throws {
        guard !channel.stopped.load(ordering: .acquiring) else { throw EngineError.decoderFailed("software decoder stopped") }
        enqueue(.packet(packet, generation: generation, output: output))
    }

    public func cancel(olderThan generation: UInt64) {
        var current = channel.generation.load(ordering: .relaxed)
        while current < generation {
            let (exchanged, original) = channel.generation.compareExchange(expected: current, desired: generation, ordering: .acquiringAndReleasing)
            if exchanged { break }
            current = original
        }
    }

    public func reset(generation: UInt64) {
        cancel(olderThan: generation)
        channel.condition.lock()
        channel.jobs.withLock { queue in
            queue.removeAll { job in
                if case .packet = job { return true }
                return false
            }
            queue.append(.reset(generation: generation))
        }
        channel.condition.signal()
        channel.condition.unlock()
    }

    public func drain() async {
        guard !channel.stopped.load(ordering: .acquiring) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue(.drain { continuation.resume() })
        }
    }

    public func drainSynchronously() {
        guard !channel.stopped.load(ordering: .acquiring) else { return }
        let done = DispatchSemaphore(value: 0)
        enqueue(.drain { done.signal() })
        done.wait()
    }

    public func invalidate() {
        guard !channel.stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
        channel.condition.lock()
        channel.jobs.withLock { queue in
            for job in queue {
                if case .drain(let done) = job { done() }
            }
            queue = [.stop]
        }
        channel.condition.signal()
        channel.condition.unlock()
    }
}

/// The decode thread's state. Lives on that thread only.
private final class Worker {
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType)?
    private let timeBase: AVRational
    private let streamColor: VideoColor
    private let channel: SoftwareVideoDecoder.Channel
    private let handler: DecodeHandler
    /// Generation and output flag of submitted packets, by pts. libavcodec frames carry the pts of
    /// the packet that produced them.
    private var pending: [Int64: (generation: UInt64, output: Bool)] = [:]
    private var lastGeneration: UInt64 = 0
    private var consecutiveFailures = 0

    init(parameters: CodecParameters, format: VideoFormat?, threads: Int, channel: SoftwareVideoDecoder.Channel, handler: @escaping DecodeHandler) throws {
        context = try SoftwareVideoDecoder.openCodecContext(parameters: parameters.pointer, threads: threads, extradata: format?.convertedConfigurationRecord)
        frame = av_frame_alloc()
        timeBase = AVRational(num: parameters.timeBase.num, den: parameters.timeBase.den)
        streamColor = format?.color ?? VideoColor(codecParameters: parameters.pointer)
        self.channel = channel
        self.handler = handler
    }

    deinit {
        avcodec_free_context(&context)
        av_frame_free(&frame)
        sws_freeContext(scaler)
    }

    func decode(_ packet: Packet, generation packetGeneration: UInt64, output: Bool) {
        guard let context else { return }
        lastGeneration = packetGeneration
        if let pts = packet.rawPTS { pending[pts] = (packetGeneration, output) }
        if pending.count > 512 { pending.removeAll() }
        var status = avcodec_send_packet(context, packet.avPacket)
        if status == reel_averror_eagain() {
            receiveFrames()
            status = avcodec_send_packet(context, packet.avPacket)
        }
        if status < 0, status != reel_averror_eagain() {
            consecutiveFailures += 1
            handler(.failed(presentationTime: packet.cmPTS, generation: packetGeneration, status: status, consecutiveFailures: consecutiveFailures))
        }
        receiveFrames()
    }

    func drain() {
        guard let context else { return }
        avcodec_send_packet(context, nil)
        receiveFrames()
        avcodec_flush_buffers(context)
        pending.removeAll()
    }

    func flushDecoder() {
        guard let context else { return }
        avcodec_flush_buffers(context)
        pending.removeAll()
    }

    private func receiveFrames() {
        guard let context, let frame else { return }
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            let pts = frame.pointee.best_effort_timestamp != reel_av_nopts() ? frame.pointee.best_effort_timestamp : frame.pointee.pts
            let tag = pending.removeValue(forKey: pts) ?? (lastGeneration, true)
            guard tag.output, tag.generation >= channel.generation.load(ordering: .acquiring) else { continue }
            let presentationTime = pts == reel_av_nopts() ? CMTime.invalid : CMTime(value: pts * Int64(timeBase.num), timescale: timeBase.den)
            guard let buffer = convert(frame, generation: tag.generation) else {
                // No pixel buffer for it: the frame is lost, and whoever waits for it must know.
                handler(.dropped(presentationTime: presentationTime, generation: tag.generation))
                continue
            }
            consecutiveFailures = 0
            let duration = frame.pointee.duration > 0
                ? CMTime(value: frame.pointee.duration * Int64(timeBase.num), timescale: timeBase.den) : CMTime.invalid
            handler(.frame(DecodedFrame(
                pixelBuffer: CVReadOnlyPixelBuffer(fresh: buffer),
                presentationTime: presentationTime,
                duration: duration,
                generation: tag.generation,
                decoder: .software
            )))
        }
    }

    private func makePool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        if let pool, let poolKey, poolKey.width == width, poolKey.height == height, poolKey.format == format { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &created) == kCVReturnSuccess else {
            return nil
        }
        pool = created
        poolKey = (width, height, format)
        return created
    }

    /// Takes a buffer from the pool, waiting while the allocation threshold is reached.
    private func takeBuffer(_ pool: CVPixelBufferPool, generation frameGeneration: UInt64) -> CVPixelBuffer? {
        let auxiliary: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: SoftwareVideoDecoder.poolAllocationThreshold]
        let deadline = ContinuousClock.now + SoftwareVideoDecoder.poolWaitLimit
        while true {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxiliary as CFDictionary, &buffer)
            if status == kCVReturnSuccess { return buffer }
            guard status == kCVReturnWouldExceedAllocationThreshold,
                  !channel.stopped.load(ordering: .acquiring),
                  frameGeneration >= channel.generation.load(ordering: .acquiring) else { return nil }
            if ContinuousClock.now > deadline {
                // A consumer that never releases frames must not stall decoding forever.
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                return buffer
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>, generation frameGeneration: UInt64) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        let sourceFormat = AVPixelFormat(rawValue: frame.pointee.format)
        let depth = av_pix_fmt_desc_get(sourceFormat).map { Int($0.pointee.comp.0.depth) } ?? 8
        let color = VideoColor(frame: frame).filling(from: streamColor)
        let fullRange = color.isFullRange || sourceFormat == AV_PIX_FMT_YUVJ420P
        let targetFormat = depth > 8 ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12
        let cvFormat = VTVideoDecoder.outputPixelFormat(bitDepth: depth, fullRange: fullRange)
        guard width > 0, height > 0, let pool = makePool(width: width, height: height, format: cvFormat),
              let buffer = takeBuffer(pool, generation: frameGeneration) else { return nil }
        scaler = sws_getCachedContext(
            scaler,
            Int32(width), Int32(height), sourceFormat,
            Int32(width), Int32(height), targetFormat,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
        guard let scaler else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var destination: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self),
            nil, nil,
        ]
        var destinationStride: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)),
            0, 0,
        ]
        let source: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3),
        ]
        let sourceStride: [Int32] = [frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2, frame.pointee.linesize.3]
        let rows = sws_scale(scaler, source, sourceStride, 0, Int32(height), &destination, &destinationStride)
        guard rows > 0 else { return nil }
        color.attach(to: buffer, height: height)
        return buffer
    }
}
