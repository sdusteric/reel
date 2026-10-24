import CReelDeps
import Foundation
import ReelCore
import Synchronization

/// A private copy of a stream's `AVCodecParameters` and time base, for opening decoders on
/// other threads.
///
/// Unchecked Sendable: the copy is written once in init and only read afterwards.
public final class CodecParameters: @unchecked Sendable {
    private let raw: UnsafeMutablePointer<AVCodecParameters>
    public let streamIndex: Int
    public let timeBase: Rational

    init(copying stream: UnsafePointer<AVStream>) throws {
        guard let raw = avcodec_parameters_alloc() else { throw FFmpegError(code: reel_averror(ENOMEM), operation: "avcodec_parameters_alloc") }
        self.raw = raw
        streamIndex = Int(stream.pointee.index)
        timeBase = Rational(stream.pointee.time_base.num, stream.pointee.time_base.den)
        try FFmpegError.check(avcodec_parameters_copy(raw, stream.pointee.codecpar), "avcodec_parameters_copy")
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVCodecParameters>? = raw
        avcodec_parameters_free(&pointer)
    }

    /// Read-only access to the parameters.
    public var pointer: UnsafePointer<AVCodecParameters> { UnsafePointer(raw) }
    public var codecID: AVCodecID { raw.pointee.codec_id }
    public var codecName: String { String(cString: avcodec_get_name(raw.pointee.codec_id)) }
}

extension MediaTime {
    /// An FFmpeg timestamp in `timeBase`, or nil for AV_NOPTS_VALUE.
    init?(ffmpeg value: Int64, timeBase: AVRational) {
        guard value != reel_av_nopts(), timeBase.den != 0 else { return nil }
        self.init(value: value, timeBaseNum: timeBase.num, timeBaseDen: timeBase.den)
    }

    func ffmpegValue(timeBase: AVRational) -> Int64 {
        value(timeBaseNum: timeBase.num, timeBaseDen: timeBase.den)
    }
}

/// Synchronous access to one opened file: `AVFormatContext`, stream selection, packet reads and
/// seeks. Not thread-safe: one owner at a time (the opener, then the demuxer thread).
public final class MediaSource {
    /// `probesize` 5 MB and `analyzeduration` 2 s (design section 7.2).
    public static let probeSize = 5_000_000
    public static let analyzeDurationMicroseconds = 2_000_000

    public let url: URL
    private var context: UnsafeMutablePointer<AVFormatContext>?
    public let videoStreamIndex: Int?
    public let audioStreamIndex: Int?
    private(set) public var bytesRead: Int64 = 0

    public init(url: URL) throws {
        self.url = url
        var context = try MediaSource.openContext(url: url, limited: true)
        if !MediaSource.hasParameters(context) {
            // A stream still lacks parameters: retry once with FFmpeg's default probing.
            var limitedContext: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&limitedContext)
            context = try MediaSource.openContext(url: url, limited: false)
        }
        self.context = context
        let streams = MediaSource.streams(context)
        videoStreamIndex = streams.first { stream in
            stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                && (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) == 0
        }.map { Int($0.pointee.index) }
        let audio = streams.filter { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO }
        audioStreamIndex = (audio.first { ($0.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0 } ?? audio.first)
            .map { Int($0.pointee.index) }
    }

    deinit {
        avformat_close_input(&context)
    }

    private static func openContext(url: URL, limited: Bool) throws -> UnsafeMutablePointer<AVFormatContext> {
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        if limited {
            av_dict_set(&options, "probesize", String(probeSize), 0)
            av_dict_set(&options, "analyzeduration", String(analyzeDurationMicroseconds), 0)
        }
        var context: UnsafeMutablePointer<AVFormatContext>?
        let path = url.path(percentEncoded: false)
        let status = avformat_open_input(&context, path, nil, &options)
        guard status >= 0, let context else {
            throw EngineError.openFailed(FFmpegError(code: status, operation: "avformat_open_input").description)
        }
        let infoStatus = avformat_find_stream_info(context, nil)
        if infoStatus < 0 {
            var failed: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&failed)
            throw EngineError.openFailed(FFmpegError(code: infoStatus, operation: "avformat_find_stream_info").description)
        }
        if let name = context.pointee.iformat?.pointee.name, String(cString: name).contains("matroska"), context.pointee.pb != nil {
            // Matroska parses Cues on the first seek; a seek to the start fills the index at open.
            let start = context.pointee.start_time == reel_av_nopts() ? 0 : context.pointee.start_time
            _ = avformat_seek_file(context, -1, Int64.min, start, Int64.max, 0)
        }
        return context
    }

    private static func streams(_ context: UnsafeMutablePointer<AVFormatContext>) -> [UnsafeMutablePointer<AVStream>] {
        (0..<Int(context.pointee.nb_streams)).compactMap { context.pointee.streams[$0] }
    }

    private static func hasParameters(_ context: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        streams(context).allSatisfy { stream in
            let par = stream.pointee.codecpar.pointee
            switch par.codec_type {
            case AVMEDIA_TYPE_VIDEO: return par.width > 0 && par.height > 0
            case AVMEDIA_TYPE_AUDIO: return par.sample_rate > 0
            default: return true
            }
        }
    }

    var formatContext: UnsafeMutablePointer<AVFormatContext>? { context }

    public var streamCount: Int { Int(context?.pointee.nb_streams ?? 0) }

    public func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>? {
        guard let context, index >= 0, index < Int(context.pointee.nb_streams) else { return nil }
        return context.pointee.streams[index]
    }

    public var formatName: String {
        guard let name = context?.pointee.iformat?.pointee.name else { return "" }
        return String(cString: name)
    }

    /// True when the container index stores presentation timestamps (mkv Cues). mp4 and the
    /// generic index store decode timestamps.
    public var indexUsesPTS: Bool { formatName.contains("matroska") }

    public var duration: MediaTime? {
        guard let value = context?.pointee.duration, value > 0 else { return nil }
        return MediaTime(ffmpeg: value, timeBase: AVRational(num: 1, den: reel_av_time_base()))
    }

    public var startTime: MediaTime? {
        guard let value = context?.pointee.start_time else { return nil }
        return MediaTime(ffmpeg: value, timeBase: AVRational(num: 1, den: reel_av_time_base()))
    }

    /// Reads the next packet of any stream. Returns nil at end of file.
    public func readPacket() throws -> Packet? {
        guard let context else { throw EngineError.notOpen }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { throw FFmpegError(code: reel_averror(ENOMEM), operation: "av_packet_alloc") }
        while true {
            let status = av_read_frame(context, packet)
            if status == reel_averror_eof() { return nil }
            if status == reel_averror_eagain() { continue }
            if status < 0 {
                // A truncated or damaged tail ends the file instead of failing playback.
                if context.pointee.pb != nil, avio_feof(context.pointee.pb) != 0 { return nil }
                throw FFmpegError(code: status, operation: "av_read_frame")
            }
            let index = Int(packet.pointee.stream_index)
            guard let stream = stream(index) else {
                av_packet_unref(packet)
                continue
            }
            bytesRead += Int64(packet.pointee.size)
            return Packet(moving: packet, timeBase: stream.pointee.time_base)
        }
    }

    /// Seeks so the next video packet read is the keyframe at or before `keyframe`
    /// (`avformat_seek_file` with `max_ts` = the keyframe and `AVSEEK_FLAG_BACKWARD`).
    public func seek(toKeyframe keyframe: MediaTime) throws {
        guard let context else { throw EngineError.notOpen }
        let index = videoStreamIndex ?? audioStreamIndex ?? 0
        guard let stream = stream(index) else { throw EngineError.noPlayableStream }
        let timestamp = keyframe.ffmpegValue(timeBase: stream.pointee.time_base)
        if avformat_seek_file(context, Int32(index), Int64.min, timestamp, timestamp, AVSEEK_FLAG_BACKWARD) >= 0 { return }
        // Some demuxers reject the bounded form; fall back to the plain backward seek.
        if av_seek_frame(context, Int32(index), timestamp, AVSEEK_FLAG_BACKWARD) >= 0 { return }
        // No index and no generic seeking (flv without keyframe metadata): read again from the
        // first byte. Correct, only slower.
        try FFmpegError.check(avformat_seek_file(context, -1, Int64.min, 0, 0, AVSEEK_FLAG_BYTE), "seek to the start of \(url.lastPathComponent)")
    }

    /// Seeks so that reading continues at a video keyframe with pts at or before `keyframe`, and
    /// returns the packets read to verify that (the last one is the keyframe). Some demuxers (mpegts,
    /// files without an index) land after the wanted keyframe or mid-GOP; then it seeks again
    /// further back, and as a last resort rewinds to the start (the result is then empty).
    public func seekVerified(toKeyframe keyframe: MediaTime) throws -> [Packet] {
        guard let videoStreamIndex else {
            try seek(toKeyframe: keyframe)
            return []
        }
        var target = keyframe
        var backoff = MediaTime.seconds(1)
        for _ in 0..<6 {
            try seek(toKeyframe: target)
            var buffered: [Packet] = []
            var landed: MediaTime?
            while buffered.count < 20_000, let packet = try readPacket() {
                buffered.append(packet)
                if packet.streamIndex == videoStreamIndex, packet.isKeyframe {
                    landed = packet.pts ?? packet.dts
                    break
                }
            }
            if let landed, landed <= keyframe { return buffered }
            target = min(target, landed ?? target) - backoff
            backoff = backoff + backoff
            if target < (startTime ?? .zero) { break }
        }
        try rewind()
        return []
    }

    /// Returns to the first packet of the file.
    public func rewind() throws {
        guard let context else { throw EngineError.notOpen }
        let start = context.pointee.start_time == reel_av_nopts() ? 0 : context.pointee.start_time
        if avformat_seek_file(context, -1, Int64.min, start, start, AVSEEK_FLAG_BACKWARD) >= 0 { return }
        try FFmpegError.check(avformat_seek_file(context, -1, Int64.min, 0, 0, AVSEEK_FLAG_BYTE), "rewind \(url.lastPathComponent)")
    }

    /// Keyframes from the container index (mkv Cues, mp4 stss, avi idx1, flv metadata).
    /// - Parameter ptsOffset: added to dts-based index timestamps to estimate presentation time.
    public func indexedKeyframes(ptsOffset: MediaTime) -> [KeyframeIndex.Entry] {
        guard let videoStreamIndex, let stream = stream(videoStreamIndex) else { return [] }
        let timeBase = stream.pointee.time_base
        let count = Int(avformat_index_get_entries_count(stream))
        var entries: [KeyframeIndex.Entry] = []
        let usesPTS = indexUsesPTS
        for position in 0..<count {
            guard let entry = avformat_index_get_entry(stream, Int32(position)),
                  (entry.pointee.flags & Int32(AVINDEX_KEYFRAME)) != 0,
                  let stamp = MediaTime(ffmpeg: entry.pointee.timestamp, timeBase: timeBase) else { continue }
            let pos = entry.pointee.pos >= 0 ? entry.pointee.pos : nil
            if usesPTS {
                entries.append(KeyframeIndex.Entry(pts: stamp, pos: pos))
            } else {
                entries.append(KeyframeIndex.Entry(pts: stamp + ptsOffset, dts: stamp, pos: pos))
            }
        }
        return entries
    }

    // MARK: Stream description

    public func streamInfo(_ index: Int, video: VideoFormat?) -> StreamInfo? {
        guard let stream = stream(index) else { return nil }
        let par = stream.pointee.codecpar.pointee
        let timeBase = stream.pointee.time_base
        let kind: StreamKind
        switch par.codec_type {
        case AVMEDIA_TYPE_VIDEO: kind = .video
        case AVMEDIA_TYPE_AUDIO: kind = .audio
        case AVMEDIA_TYPE_SUBTITLE: kind = .subtitle
        case AVMEDIA_TYPE_DATA: kind = .data
        case AVMEDIA_TYPE_ATTACHMENT: kind = .attachment
        default: kind = .unknown
        }
        func metadata(_ key: String) -> String? {
            guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0), let value = entry.pointee.value else { return nil }
            return String(cString: value)
        }
        var info = StreamInfo(
            index: index,
            kind: kind,
            codec: String(cString: avcodec_get_name(par.codec_id)),
            profile: avcodec_profile_name(par.codec_id, par.profile).map { String(cString: $0) },
            timeBase: Rational(timeBase.num, timeBase.den),
            startTime: MediaTime(ffmpeg: stream.pointee.start_time, timeBase: timeBase),
            duration: stream.pointee.duration > 0 ? MediaTime(ffmpeg: stream.pointee.duration, timeBase: timeBase) : nil,
            bitRate: par.bit_rate > 0 ? Int(par.bit_rate) : nil,
            language: metadata("language"),
            title: metadata("title"),
            isDefault: (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0,
            isForced: (stream.pointee.disposition & AV_DISPOSITION_FORCED) != 0,
            isAttachedPicture: (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
        )
        if kind == .video {
            if let video, index == videoStreamIndex {
                info.video = video.parameters
            } else {
                info.video = VideoParameters(
                    width: Int(par.width),
                    height: Int(par.height),
                    pixelAspect: FormatDescriptionBuilder.pixelAspect(stream),
                    frameRate: FormatDescriptionBuilder.frameRate(stream),
                    bitDepth: FormatDescriptionBuilder.bitDepth(par),
                    rotation: FormatDescriptionBuilder.rotation(par),
                    color: VideoColor(codecParameters: stream.pointee.codecpar).info
                )
            }
        } else if kind == .audio {
            var layout = par.ch_layout
            let described = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 128) { pointer -> String? in
                guard let base = pointer.baseAddress, av_channel_layout_describe(&layout, base, pointer.count) > 0 else { return nil }
                return String(cString: base)
            }
            info.audio = AudioParameters(
                sampleRate: Int(par.sample_rate),
                channels: Int(par.ch_layout.nb_channels),
                channelLayout: described
            )
        }
        return info
    }

    public var fileSize: Int64? {
        guard let pb = context?.pointee.pb else { return nil }
        let size = avio_size(pb)
        return size >= 0 ? size : nil
    }

    public var bitRate: Int? {
        guard let rate = context?.pointee.bit_rate, rate > 0 else { return nil }
        return Int(rate)
    }
}

/// Opens a file and reads it on one dedicated thread into a `PacketStore` (design section 7.2).
///
/// `av_read_frame` blocks on I/O, so it runs on a `Thread`, not the cooperative pool. The thread
/// takes commands from a lock-protected queue that it checks between packets, so a seek preempts
/// read-ahead within one packet.
public final class Demuxer: Sendable {
    public enum Command: Sendable, Hashable {
        /// Make the GOP starting at `keyframe` available. A store hit costs no I/O; otherwise the
        /// demuxer seeks, resets the store and refills from the keyframe.
        case seek(keyframe: MediaTime, generation: UInt64)
        /// Streams to keep. Packets of other streams are dropped.
        case setActiveStreams(Set<Int>)
        case stop
    }

    public let url: URL
    public let info: MediaInfo
    public let videoFormat: VideoFormat?
    public let videoParameters: CodecParameters?
    public let audioParameters: CodecParameters?
    public let store: PacketStore

    private let source: Mutex<MediaSource>
    private let index: Mutex<KeyframeIndex>
    private let commands = Mutex<[Command]>([])
    private let condition = NSCondition()
    private let running = Atomic<Bool>(false)
    private let finished = Atomic<Bool>(false)
    private let bytesReadCounter = Atomic<Int64>(0)
    private let lastSeekGeneration = Atomic<UInt64>(0)
    /// The newest generation sent as a `.seek` command. While it is ahead of
    /// `lastSeekGeneration` a seek is queued or running and may still reset the store.
    private let requestedSeekGeneration = Mutex<UInt64>(0)
    /// Tests: milliseconds each seek that needs I/O waits first, like a slow disk or a demuxer
    /// that retries (mpegts, mkv without Cues).
    let seekDelayForTesting = Atomic<Int>(0)
    private let failure = Mutex<String?>(nil)
    private let coverage: Mutex<ReadCoverage>
    /// The container index lists every keyframe of the file (mp4 stss, mkv Cues that reach the end).
    public let hasCompleteIndex: Bool

    /// Opens `url`, selects streams, reads the first video packets (for Annex B parameter sets and
    /// the colour probe) into the store and builds the video format. The read thread starts with
    /// `start()`.
    public init(url: URL, limits: PacketStore.Limits = .standard) throws {
        let source = try MediaSource(url: url)
        self.url = url

        var videoFormat: VideoFormat?
        var videoParameters: CodecParameters?
        var initialPackets: [Packet] = []
        if let videoIndex = source.videoStreamIndex, let stream = source.stream(videoIndex) {
            videoParameters = try CodecParameters(copying: stream)
            initialPackets = try Demuxer.readUntilFirstVideoFrame(source, videoIndex: videoIndex)
            let videoPackets = initialPackets.filter { $0.streamIndex == videoIndex }
            videoFormat = try FormatDescriptionBuilder.make(stream: stream, firstPackets: videoPackets)
        }
        if source.videoStreamIndex == nil, source.audioStreamIndex == nil { throw EngineError.noPlayableStream }
        audioParameters = try source.audioStreamIndex.flatMap(source.stream).map { try CodecParameters(copying: $0) }
        self.videoFormat = videoFormat
        self.videoParameters = videoParameters

        let store = PacketStore(videoStreamIndex: source.videoStreamIndex, limits: limits)
        self.store = store

        // mp4 and the generic index store dts; the first keyframe's pts minus dts estimates the
        // reorder delay that turns them into presentation times.
        let firstKey = initialPackets.first { $0.streamIndex == source.videoStreamIndex && $0.isKeyframe }
        var offset = MediaTime.zero
        if let pts = firstKey?.pts, let dts = firstKey?.dts { offset = pts - dts }
        let indexed = source.indexedKeyframes(ptsOffset: offset)
        hasCompleteIndex = Demuxer.isComplete(index: indexed, source: source)
        var keyframes = KeyframeIndex(indexed)

        let active = Set([source.videoStreamIndex, source.audioStreamIndex].compactMap { $0 })
        for packet in initialPackets where active.contains(packet.streamIndex) {
            let prepared = packet.streamIndex == source.videoStreamIndex ? (videoFormat?.prepare(packet) ?? packet) : packet
            if prepared.streamIndex == source.videoStreamIndex, prepared.isKeyframe {
                Demuxer.record(prepared, format: videoFormat, in: &keyframes)
            }
            store.append(prepared)
        }

        var streams: [StreamInfo] = []
        for streamIndex in 0..<source.streamCount {
            if let stream = source.streamInfo(streamIndex, video: videoFormat) { streams.append(stream) }
        }
        info = MediaInfo(
            url: url,
            formatName: source.formatName,
            duration: source.duration,
            startTime: source.startTime,
            bitRate: source.bitRate,
            fileSize: source.fileSize,
            streams: streams,
            videoStreamIndex: source.videoStreamIndex,
            audioStreamIndex: source.audioStreamIndex,
            videoDecoder: nil,
            keyframeCount: keyframes.count
        )
        bytesReadCounter.store(source.bytesRead, ordering: .relaxed)
        // Reading starts at the beginning of the file, so everything up to the first packets is known.
        var readCoverage = ReadCoverage()
        readCoverage.start(at: nil)
        for packet in initialPackets where packet.streamIndex == source.videoStreamIndex {
            if let time = packet.time { readCoverage.extend(to: time) }
        }
        coverage = Mutex(readCoverage)
        self.source = Mutex(source)
        self.index = Mutex(keyframes)
        commands.withLock { $0 = [.setActiveStreams(active)] }
    }

    deinit {
        stop()
    }

    private static func readUntilFirstVideoFrame(_ source: MediaSource, videoIndex: Int) throws -> [Packet] {
        var packets: [Packet] = []
        var videoCount = 0
        var sawKeyframe = false
        var bytes = 0
        // Enough video packets for one decoded frame even with frame reordering; capped by size.
        while videoCount < 12, bytes < 16 << 20, let packet = try source.readPacket() {
            packets.append(packet)
            bytes += packet.size
            if packet.streamIndex == videoIndex {
                if packet.isKeyframe { sawKeyframe = true }
                if sawKeyframe { videoCount += 1 }
            }
        }
        return packets
    }

    /// mp4 and mov always index every sync sample. Other containers count as complete when the
    /// index reaches the end of the file: FFmpeg also lists keyframes it read while probing, so an
    /// mkv without Cues has a few entries at the start that say nothing about the rest.
    private static func isComplete(index: [KeyframeIndex.Entry], source: MediaSource) -> Bool {
        if source.formatName.contains("mp4") || source.formatName.contains("mov") { return !index.isEmpty }
        guard index.count >= 2, let duration = source.duration, let last = index.last?.pts else { return false }
        let sorted = index.map(\.pts).sorted()
        let largestGap = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.max() ?? .zero
        let end = (source.startTime ?? .zero) + duration
        return last + max(largestGap, .seconds(1)) + .seconds(1) >= end
    }

    private static func record(_ packet: Packet, format: VideoFormat?, in index: inout KeyframeIndex) {
        guard let pts = packet.pts ?? packet.dts else { return }
        let kind: KeyframeIndex.Kind
        if let format, format.codec == .h264 || format.codec == .hevc {
            kind = NALUnits.keyframeKind(format.pictureFlags(packet))
        } else if let format, format.codec == .av1 || format.codec == .vp9 {
            kind = .idr
        } else {
            kind = .other
        }
        let entry = KeyframeIndex.Entry(pts: pts, dts: packet.dts, pos: packet.position, kind: kind)
        // An index entry whose estimated pts differs from the packet's real pts is replaced.
        if let position = packet.position,
           let stale = index.entries.first(where: { $0.pos == position && $0.pts != pts }) {
            index = KeyframeIndex(index.entries.filter { $0 != stale } + [entry])
        } else {
            index.insert(entry)
        }
    }

    // MARK: Control

    /// Starts the read thread. Safe to call once; later calls do nothing.
    public func start() {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        store.setDemuxerWake { [weak self] in self?.wake() }
        // The thread holds the demuxer only during one step, so dropping the last reference
        // ends the thread too.
        let thread = Thread { [weak self] in
            var loop = LoopState()
            while let demuxer = self, demuxer.step(&loop) {}
            self?.store.setDemuxerWake(nil)
            self?.finished.store(true, ordering: .releasing)
        }
        thread.name = "reel.demuxer"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func send(_ command: Command) {
        commands.withLock { $0.append(command) }
        wake()
    }

    /// Asks for the GOP starting at `keyframe`. Returns true when it is already stored (no I/O).
    /// An exact seek passes its target as `readThrough`: the store then reads at least that far,
    /// however long the GOP. A scrub passes nil.
    ///
    /// `keyframe` may also be a time that is not a keyframe (a target past what the index knows):
    /// the demuxer then seeks to the keyframe at or before it.
    ///
    /// Generations must increase from call to call. While an older seek is queued or running it
    /// may still reset the store, so the store is not trusted: the command is always sent, the
    /// thread drops the older one if it has not started and checks the store again (no I/O
    /// when it still covers the keyframe), and the caller waits for `completedSeekGeneration`.
    @discardableResult
    public func seek(toKeyframe keyframe: MediaTime, readThrough: MediaTime? = nil, generation: UInt64) -> Bool {
        requestedSeekGeneration.withLock { requested in
            let idle = requested <= lastSeekGeneration.load(ordering: .acquiring)
            let hit = idle && store.covers(keyframe: keyframe, through: keyframe)
            store.setPlayhead(keyframe, readThrough: readThrough)
            if !hit {
                requested = max(requested, generation)
                send(.seek(keyframe: keyframe, generation: generation))
            }
            return hit
        }
    }

    /// True while a seek command is queued or running: the store may still be reset under a reader.
    public var hasPendingSeek: Bool {
        requestedSeekGeneration.withLock { $0 > lastSeekGeneration.load(ordering: .acquiring) }
    }

    /// The keyframe an exact seek or scrub to `time` starts at, and whether the index is known to
    /// hold every keyframe up to `time`. Without a complete container index (mkv without Cues,
    /// mpegts) only the stretches the demuxer has read are known; a later keyframe may exist
    /// that nobody has seen yet, and the caller must let the demuxer find it.
    public func keyframe(atOrBefore time: MediaTime) -> (entry: KeyframeIndex.Entry?, known: Bool) {
        let entry = index.withLock { $0.entry(atOrBefore: time) }
        guard !hasCompleteIndex, let entry else { return (entry, true) }
        return (entry, coverage.withLock { $0.contains(entry.pts...max(entry.pts, time)) })
    }

    /// Stops the thread. Returns once the command is queued; the thread exits after its current read.
    public func stop() {
        guard running.load(ordering: .acquiring), !finished.load(ordering: .acquiring) else { return }
        send(.stop)
    }

    /// True once the thread has exited.
    public var isFinished: Bool { finished.load(ordering: .acquiring) }

    /// A copy of the keyframe index (presentation pts).
    public var keyframeIndex: KeyframeIndex { index.withLock { $0 } }

    /// Compressed bytes read from the file since open.
    public var bytesRead: Int64 { bytesReadCounter.load(ordering: .relaxed) }

    /// The last read error, if reading stopped early.
    public var readError: String? { failure.withLock { $0 } }

    /// The generation of the most recent seek the thread has carried out.
    public var completedSeekGeneration: UInt64 { lastSeekGeneration.load(ordering: .acquiring) }

    private func wake() {
        condition.lock()
        condition.signal()
        condition.unlock()
    }

    // MARK: Thread

    private struct LoopState {
        var active = Set<Int>()
        var reachedEnd = false
    }

    /// One iteration of the read loop. Returns false when the thread should exit.
    private func step(_ loop: inout LoopState) -> Bool {
        for command in commands.withLock({ queue -> [Command] in defer { queue.removeAll() }; return queue }) {
            switch command {
            case .stop:
                return false
            case .setActiveStreams(let streams):
                loop.active = streams
            case .seek(let keyframe, let generation):
                // A newer seek is queued behind this one: its caller saw this one pending and
                // waits for the newer generation, so this one would only reset the store for nothing.
                if generation < requestedSeekGeneration.withLock({ $0 }) { continue }
                performSeek(to: keyframe, activeStreams: loop.active)
                loop.reachedEnd = false
                let completed = max(lastSeekGeneration.load(ordering: .acquiring), generation)
                lastSeekGeneration.store(completed, ordering: .releasing)
            }
        }
        if loop.reachedEnd || !store.wantsMoreData {
            waitForWork()
            return true
        }
        do {
            let packet = try source.withLock { source -> Packet? in
                let packet = try source.readPacket()
                bytesReadCounter.store(source.bytesRead, ordering: .relaxed)
                return packet
            }
            guard let packet else {
                loop.reachedEnd = true
                coverage.withLock { $0.reachEnd() }
                store.markEndOfFile()
                return true
            }
            if loop.active.contains(packet.streamIndex) { accept(packet) }
        } catch {
            failure.withLock { $0 = String(describing: error) }
            loop.reachedEnd = true
            store.markEndOfFile()
        }
        return true
    }

    private func accept(_ packet: Packet) {
        guard packet.streamIndex == info.videoStreamIndex else {
            store.append(packet)
            return
        }
        let prepared = videoFormat?.prepare(packet) ?? packet
        if prepared.isKeyframe {
            index.withLock { Demuxer.record(prepared, format: videoFormat, in: &$0) }
        }
        if let time = prepared.time { coverage.withLock { $0.extend(to: time) } }
        store.append(prepared)
    }

    private func performSeek(to keyframe: MediaTime, activeStreams: Set<Int>) {
        // The store may have filled up to the keyframe while the command waited, or still holds
        // it because an older queued seek was dropped. An older seek that ran first moved the
        // playhead to its own keyframe, so it moves back here.
        if store.covers(keyframe: keyframe, through: keyframe) {
            store.setPlayhead(keyframe)
            return
        }
        let delay = seekDelayForTesting.load(ordering: .relaxed)
        if delay > 0 { Thread.sleep(forTimeInterval: Double(delay) / 1_000) }
        var landing: [Packet] = []
        var failed = false
        do {
            landing = try source.withLock { source in
                let packets = try source.seekVerified(toKeyframe: keyframe)
                bytesReadCounter.store(source.bytesRead, ordering: .relaxed)
                return packets
            }
        } catch {
            failed = true
            failure.withLock { $0 = String(describing: error) }
        }
        store.reset(playhead: keyframe)
        // A new contiguous stretch starts at the keyframe the seek landed on (the last packet
        // read), or at the start of the file after a rewind.
        let landedKey = landing.last { $0.streamIndex == info.videoStreamIndex && $0.isKeyframe }
        coverage.withLock { coverage in
            if failed {
                coverage.stop()
            } else {
                coverage.start(at: landing.isEmpty ? nil : landedKey?.time)
            }
        }
        for packet in landing where activeStreams.contains(packet.streamIndex) {
            accept(packet)
        }
    }

    private func waitForWork() {
        condition.lock()
        defer { condition.unlock() }
        let hasCommands = commands.withLock { !$0.isEmpty }
        if !hasCommands {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
    }
}

/// Stretches of the file the demuxer has read without a gap, in presentation time. Every
/// keyframe inside one of them is in the keyframe index.
struct ReadCoverage: Sendable {
    private var finished: [ClosedRange<MediaTime>] = []
    private var currentStart: MediaTime?
    private var currentEnd: MediaTime?

    private static let farPast = MediaTime(microseconds: Int64.min / 4)
    private static let farFuture = MediaTime(microseconds: Int64.max / 4)

    /// Closes the current stretch and opens one at `time` (nil: the start of the file).
    mutating func start(at time: MediaTime?) {
        close()
        currentStart = time ?? ReadCoverage.farPast
        currentEnd = currentStart
    }

    /// Closes the current stretch without opening another: the read position is unknown.
    mutating func stop() {
        close()
    }

    mutating func extend(to time: MediaTime) {
        guard let end = currentEnd else { return }
        currentEnd = max(end, time)
    }

    /// The current stretch reached the end of the file.
    mutating func reachEnd() {
        guard currentStart != nil else { return }
        currentEnd = ReadCoverage.farFuture
    }

    func contains(_ range: ClosedRange<MediaTime>) -> Bool {
        if let start = currentStart, let end = currentEnd, start <= range.lowerBound, end >= range.upperBound { return true }
        return finished.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    private mutating func close() {
        guard let start = currentStart, let end = currentEnd else { return }
        var merged = start...max(start, end)
        var kept: [ClosedRange<MediaTime>] = []
        for range in finished {
            if range.upperBound >= merged.lowerBound, range.lowerBound <= merged.upperBound {
                merged = min(range.lowerBound, merged.lowerBound)...max(range.upperBound, merged.upperBound)
            } else {
                kept.append(range)
            }
        }
        kept.append(merged)
        finished = kept.sorted { $0.lowerBound < $1.lowerBound }
        currentStart = nil
        currentEnd = nil
    }
}
