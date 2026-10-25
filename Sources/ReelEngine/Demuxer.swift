import CoreMedia
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
    /// Interrupts blocking reads (an open past its deadline, a demuxer being stopped). The
    /// format context's callback points at it, so it lives as long as the context.
    private let interrupt: ReadInterrupt?
    /// The format context's key in `FFmpegLogTap`, and errors logged by a context closed to
    /// retry the open with default probing.
    public private(set) var logKey: Int?
    public private(set) var reopenErrors = 0

    /// - Parameter preferredVideoStream: the video stream to select (Ctrl+Cmd+V), when it exists.
    /// - Parameter interrupt: makes blocking FFmpeg calls give up (section 7.10).
    public init(url: URL, preferredVideoStream: Int? = nil, interrupt: ReadInterrupt? = nil) throws {
        self.url = url
        self.interrupt = interrupt
        var context = try MediaSource.openContext(url: url, limited: true, interrupt: interrupt)
        if !MediaSource.hasParameters(context) {
            // A stream still lacks parameters: retry once with FFmpeg's default probing.
            var limitedContext: UnsafeMutablePointer<AVFormatContext>? = context
            reopenErrors = FFmpegLogTap.untrack(Int(bitPattern: context))
            avformat_close_input(&limitedContext)
            context = try MediaSource.openContext(url: url, limited: false, interrupt: interrupt)
        }
        self.context = context
        logKey = Int(bitPattern: context)
        let streams = MediaSource.streams(context)
        let videos = streams.filter { stream in
            stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                && (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) == 0
        }
        videoStreamIndex = (videos.first { Int($0.pointee.index) == preferredVideoStream } ?? videos.first)
            .map { Int($0.pointee.index) }
        let audio = streams.filter { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO }
        audioStreamIndex = (audio.first { ($0.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0 } ?? audio.first)
            .map { Int($0.pointee.index) }
    }

    deinit {
        if let logKey { FFmpegLogTap.untrack(logKey) }
        avformat_close_input(&context)
    }

    private static func openContext(url: URL, limited: Bool, interrupt: ReadInterrupt?) throws -> UnsafeMutablePointer<AVFormatContext> {
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        if limited {
            av_dict_set(&options, "probesize", String(probeSize), 0)
            av_dict_set(&options, "analyzeduration", String(analyzeDurationMicroseconds), 0)
        }
        guard let allocated = avformat_alloc_context() else {
            throw EngineError.io(FFmpegError(code: reel_averror(ENOMEM), operation: "avformat_alloc_context").description)
        }
        if let interrupt { allocated.pointee.interrupt_callback = interrupt.callback }
        // Counted from the start: probing may read past damage the playback reads never log.
        let key = Int(bitPattern: allocated)
        FFmpegLogTap.track(key)
        // avformat_open_input frees a caller-allocated context when it fails.
        var context: UnsafeMutablePointer<AVFormatContext>? = allocated
        let path = url.path(percentEncoded: false)
        let status = avformat_open_input(&context, path, nil, &options)
        guard status >= 0, let context else {
            FFmpegLogTap.untrack(key)
            throw MediaSource.openError(code: status, operation: "avformat_open_input", url: url, interrupt: interrupt)
        }
        let infoStatus = avformat_find_stream_info(context, nil)
        if infoStatus < 0 {
            FFmpegLogTap.untrack(key)
            let format = MediaSource.formatName(context)
            var failed: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&failed)
            throw MediaSource.openError(code: infoStatus, operation: "avformat_find_stream_info", url: url, interrupt: interrupt, format: format)
        }
        if let name = context.pointee.iformat?.pointee.name, String(cString: name).contains("matroska"), context.pointee.pb != nil {
            // Matroska parses Cues on the first seek; a seek to the start fills the index at open.
            let start = context.pointee.start_time == reel_av_nopts() ? 0 : context.pointee.start_time
            _ = avformat_seek_file(context, -1, Int64.min, start, Int64.max, 0)
        }
        return context
    }

    // MARK: Open failures (design section 7.10)

    /// FFmpeg's `AVPROBE_SCORE_RETRY`: a format detected at or below it is a guess (an extension
    /// match on bytes that look like nothing in particular).
    public static let confidentProbeScore: Int32 = 25

    /// Classifies a failed open: a read error is `.io`, an interrupted deadline is `.io("timed
    /// out")`, bytes no demuxer recognises are `.notMedia`, and a recognised container that fails
    /// (no index, end of file in the header) is `.cutShort`.
    static func openError(code: Int32, operation: String, url: URL, interrupt: ReadInterrupt?, format: String? = nil) -> EngineError {
        let error = FFmpegError(code: code, operation: operation)
        if interrupt?.timedOut == true { return .io("timed out (\(operation))") }
        if error.isInterrupted { return .io("stopped (\(operation))") }
        if error.isReadError { return .io(error.description) }
        let probe = contentProbe(url)
        let size = fileSizeDescription(url)
        guard probe.score > confidentProbeScore, let name = format ?? probe.name else {
            return .notMedia("no demuxer recognised this \(size) file (FFmpeg: \(error.message))")
        }
        if error.isEndOfFile || error.isInvalidData {
            return .cutShort("\(displayFormatName(name)) header found, then the file ends after \(size) (FFmpeg: \(error.message)).")
        }
        return .openFailed(error.description)
    }

    /// The demuxer FFmpeg picks from the file's first 64 KB alone (no file name), and its score
    /// (0 to 100). A file that cannot be read probes as nothing.
    static func contentProbe(_ url: URL) -> (name: String?, score: Int32) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, 0) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 16), !data.isEmpty else { return (nil, 0) }
        var buffer = [UInt8](data) + [UInt8](repeating: 0, count: Int(AVPROBE_PADDING_SIZE))
        var score: Int32 = 0
        let format = buffer.withUnsafeMutableBufferPointer { pointer in
            "".withCString { name in
                var probe = AVProbeData(filename: name, buf: pointer.baseAddress, buf_size: Int32(data.count), mime_type: nil)
                return av_probe_input_format3(&probe, 1, &score)
            }
        }
        guard let format, let name = format.pointee.name else { return (nil, 0) }
        return (String(cString: name), score)
    }

    static func fileSizeDescription(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
        if size < 1_024 { return "\(size) bytes" }
        if size < 1 << 20 { return "\(size / 1_024) KB" }
        return String(format: "%.1f MB", Double(size) / Double(1 << 20))
    }

    /// "Matroska", "MP4", "MPEG-TS" for FFmpeg's demuxer names.
    public static func displayFormatName(_ name: String) -> String {
        if name.contains("matroska") || name == "webm" { return "Matroska" }
        if name.contains("mp4") || name.contains("mov") { return "MP4" }
        let known = ["mpegts": "MPEG-TS", "avi": "AVI", "flv": "FLV", "mp3": "MP3", "ogg": "Ogg", "wav": "WAV", "asf": "ASF", "mpeg": "MPEG-PS"]
        return known[name] ?? name.uppercased()
    }

    private static func formatName(_ context: UnsafeMutablePointer<AVFormatContext>) -> String? {
        context.pointee.iformat?.pointee.name.map { String(cString: $0) }
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

    /// How sure FFmpeg was of the format (100 for a signature, 50 for an extension match).
    public var probeScore: Int32 { context?.pointee.probe_score ?? 0 }

    /// The header duration was guessed from the bit rate (mpegts without timestamps at the end);
    /// it says nothing about where the data should end.
    public var durationIsEstimate: Bool {
        context?.pointee.duration_estimation_method == AVFMT_DURATION_FROM_BITRATE
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
                let error = FFmpegError(code: status, operation: "av_read_frame")
                // A truncated or damaged tail ends the file instead of failing playback. Read
                // errors and interrupts are reported: a drive may have gone (section 7.10).
                if !error.isReadError, !error.isInterrupted, context.pointee.pb != nil, avio_feof(context.pointee.pb) != 0 { return nil }
                throw error
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

    /// The byte position the next read starts at, to tell a demuxer that resyncs after damage
    /// from one stuck on the same bytes.
    public var readPosition: Int64? {
        guard let pb = context?.pointee.pb else { return nil }
        return avio_tell(pb)
    }

    /// The last presentation time the container index promises data for, and the last one whose
    /// bytes lie inside the file (section 7.10). MP4 indexes every sample with its offset, so a
    /// file cut short shows at open; other containers return nil.
    public func indexedDataEnd(ptsOffset: MediaTime) -> (promised: MediaTime, readable: MediaTime?)? {
        guard formatName.contains("mp4") || formatName.contains("mov"), let fileSize, fileSize > 0 else { return nil }
        var promised: MediaTime?
        var readable: MediaTime?
        for index in [videoStreamIndex, audioStreamIndex].compactMap({ $0 }) {
            guard let stream = stream(index) else { continue }
            let timeBase = stream.pointee.time_base
            let offset = index == videoStreamIndex ? ptsOffset : .zero
            let count = Int(avformat_index_get_entries_count(stream))
            for position in 0..<count {
                guard let entry = avformat_index_get_entry(stream, Int32(position)),
                      let stamp = MediaTime(ffmpeg: entry.pointee.timestamp, timeBase: timeBase) else { continue }
                let time = stamp + offset
                promised = max(promised ?? time, time)
                if entry.pointee.pos >= 0, entry.pointee.pos + Int64(entry.pointee.size) <= fileSize {
                    readable = max(readable ?? time, time)
                }
            }
        }
        guard let promised else { return nil }
        return (promised, readable)
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

    /// The size the container index gives the packet at `position`, looking among the last 64
    /// entries (the end of the file is where a sample can be cut short).
    public func indexedSize(streamIndex: Int, position: Int64) -> Int? {
        guard let stream = stream(streamIndex) else { return nil }
        let count = Int(avformat_index_get_entries_count(stream))
        for entryIndex in stride(from: count - 1, through: max(0, count - 64), by: -1) {
            if let entry = avformat_index_get_entry(stream, Int32(entryIndex)), entry.pointee.pos == position {
                return Int(entry.pointee.size)
            }
        }
        return nil
    }

    /// Byte positions of every packet the container index lists for `streamIndex`, sorted.
    public func indexedPositions(streamIndex: Int) -> [Int64] {
        guard let stream = stream(streamIndex) else { return [] }
        let count = Int(avformat_index_get_entries_count(stream))
        var positions: [Int64] = []
        positions.reserveCapacity(count)
        for position in 0..<count {
            if let entry = avformat_index_get_entry(stream, Int32(position)), entry.pointee.pos >= 0 { positions.append(entry.pointee.pos) }
        }
        return positions.sorted()
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
            isHearingImpaired: (stream.pointee.disposition & AV_DISPOSITION_HEARING_IMPAIRED) != 0,
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
    /// Parameters of every audio and subtitle stream, for track switches and subtitle decoders.
    public let streamParameters: [Int: CodecParameters]
    /// Every audio and subtitle stream is kept in the store, so a track switch finds the packets
    /// around the playhead without I/O (design section 9.7).
    public let activeStreams: Set<Int>
    public let store: PacketStore

    private let source: Mutex<MediaSource>
    private let index: Mutex<KeyframeIndex>
    private let commands = Mutex<[Command]>([])
    private let signal = DemuxerWake()
    private let packetsReadCounter = Atomic<Int>(0)
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

    // M3 robustness (section 7.10).
    /// Interrupts a blocked read when the demuxer stops.
    private let interrupt: ReadInterrupt
    /// The name of the file's volume when it is no longer mounted; nil while it is (or the file
    /// is on no removable volume).
    private let volumeCheck: @Sendable (URL) -> String?
    private let reading = Mutex(ReadTracking())
    private let dataEndHandler = Mutex<SendableCallback<MediaTime>?>(nil)
    /// The damage handler, and damage found before one was set (a short file is read to its
    /// end before the engine installs it).
    private let damageSink = Mutex<(handler: SendableCallback<DemuxDamage>?, undelivered: [DemuxDamage])>((nil, []))
    private let volumeLostHandler = Mutex<SendableCallback<String>?>(nil)
    /// Tests: the next read fails with this FFmpeg code (one shot), like a drive that went away.
    let readFaultForTesting = Atomic<Int32>(0)
    /// The header duration, when it says where the data should end (not a bit-rate estimate).
    private let promisedEnd: MediaTime?
    /// Formats of Annex B GOPs by their parameter sets; nil for the open format.
    private let formats: Mutex<[[Data]: VideoFormat?]>
    /// AVI indexes every video chunk; a chunk the demuxer skips over damaged bytes shows as an
    /// index entry between two packets read (section 7.10). Empty for other containers.
    private let chunkIndex: [Int64]
    /// Matroska and WebM: the cluster CRC-32 check (damage that decodes without an error).
    private let clusterCheck: MatroskaClusterCheck?

    /// Opens `url`, selects streams, reads the first video packets (for Annex B parameter sets and
    /// the colour probe) into the store and builds the video format. The read thread starts with
    /// `start()`.
    ///
    /// Failures are classified (section 7.10): `.notMedia` when no demuxer recognises the bytes,
    /// `.cutShort` when a container header is followed by the end of the file before any video
    /// keyframe, `.io` for read errors and a deadline passed on `interrupt`.
    public init(
        url: URL,
        limits: PacketStore.Limits = .standard,
        preferredVideoStream: Int? = nil,
        interrupt: ReadInterrupt? = nil,
        volumeCheck: (@Sendable (URL) -> String?)? = nil
    ) throws {
        let interrupt = interrupt ?? ReadInterrupt()
        let source = try MediaSource(url: url, preferredVideoStream: preferredVideoStream, interrupt: interrupt)
        self.url = url
        self.interrupt = interrupt
        self.volumeCheck = volumeCheck ?? { MountedVolumes.missingVolume(of: $0) }
        if source.probeScore <= MediaSource.confidentProbeScore {
            // An extension match on bytes no demuxer recognises (text, random data, zeros).
            throw EngineError.notMedia("\(source.formatName) was only a guess (probe score \(source.probeScore) of 100)")
        }
        if source.videoStreamIndex == nil, source.audioStreamIndex == nil { throw EngineError.noPlayableStream }

        var videoFormat: VideoFormat?
        var videoParameters: CodecParameters?
        var initialPackets: [Packet] = []
        if let videoIndex = source.videoStreamIndex, let stream = source.stream(videoIndex) {
            videoParameters = try CodecParameters(copying: stream)
            let first = try Demuxer.readUntilFirstVideoFrame(source, videoIndex: videoIndex)
            initialPackets = first.packets
            let videoPackets = initialPackets.filter { $0.streamIndex == videoIndex }
            if first.reachedEnd, !videoPackets.contains(where: \.isKeyframe) {
                let name = MediaSource.displayFormatName(source.formatName)
                let size = MediaSource.fileSizeDescription(url)
                throw EngineError.cutShort("\(name) header found, then the file ends after \(size) before the first video frame (FFmpeg: End of file).")
            }
            videoFormat = try FormatDescriptionBuilder.make(stream: stream, firstPackets: videoPackets)
        }
        audioParameters = try source.audioStreamIndex.flatMap(source.stream).map { try CodecParameters(copying: $0) }
        var parameters: [Int: CodecParameters] = [:]
        for index in 0..<source.streamCount {
            guard let stream = source.stream(index) else { continue }
            let type = stream.pointee.codecpar.pointee.codec_type
            guard type == AVMEDIA_TYPE_AUDIO || type == AVMEDIA_TYPE_SUBTITLE else { continue }
            parameters[index] = try CodecParameters(copying: stream)
        }
        streamParameters = parameters
        self.videoFormat = videoFormat
        self.videoParameters = videoParameters

        let store = PacketStore(videoStreamIndex: source.videoStreamIndex, limits: limits)
        self.store = store

        // mp4 and the generic index store dts; the first keyframe's pts minus dts estimates the
        // reorder delay that turns them into presentation times.
        let firstKey = initialPackets.first { $0.streamIndex == source.videoStreamIndex && $0.isKeyframe }
        var offset = MediaTime.zero
        if let pts = firstKey?.pts, let dts = firstKey?.dts { offset = pts - dts }
        var indexed = source.indexedKeyframes(ptsOffset: offset)
        // An MP4 cut short indexes samples past the end of the file (section 7.10): its data
        // ends at the last sample that is inside, and keyframes after that cannot be read.
        var tracking = ReadTracking()
        if let indexedEnd = source.indexedDataEnd(ptsOffset: offset), let fileSize = source.fileSize {
            let promised = indexedEnd.promised
            if let readable = indexedEnd.readable, readable < promised {
                tracking.dataEnd = readable
                indexed.removeAll { ($0.pos ?? 0) >= fileSize }
            }
        }
        hasCompleteIndex = Demuxer.isComplete(index: indexed, source: source)
        var keyframes = KeyframeIndex(indexed)

        let active = Set([source.videoStreamIndex, source.audioStreamIndex].compactMap { $0 }).union(parameters.keys)
        activeStreams = active
        var formatCache: [[Data]: VideoFormat?] = [:]
        for packet in initialPackets where active.contains(packet.streamIndex) {
            let isVideo = packet.streamIndex == source.videoStreamIndex
            let prepared = isVideo ? (videoFormat?.prepare(packet) ?? packet) : packet
            var tag: VideoFormat?
            if isVideo, prepared.isKeyframe {
                Demuxer.record(prepared, format: videoFormat, in: &keyframes)
                tag = Demuxer.formatTag(of: packet, base: videoFormat, cache: &formatCache)
            }
            store.append(prepared, format: tag)
        }
        formats = Mutex(formatCache)

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
            keyframeCount: keyframes.count,
            dolbyVision: source.videoStreamIndex.flatMap(source.stream).flatMap { DolbyVisionProbe.config(of: $0) }
        )
        bytesReadCounter.store(source.bytesRead, ordering: .relaxed)
        // Reading starts at the beginning of the file, so everything up to the first packets is known.
        var readCoverage = ReadCoverage()
        readCoverage.start(at: nil)
        for packet in initialPackets where packet.streamIndex == source.videoStreamIndex {
            if let time = packet.time { readCoverage.extend(to: time) }
        }
        coverage = Mutex(readCoverage)
        for packet in initialPackets where active.contains(packet.streamIndex) {
            tracking.note(packet, isVideo: packet.streamIndex == source.videoStreamIndex)
        }
        reading.withLock { $0 = tracking }
        if let duration = source.duration, !source.durationIsEstimate {
            promisedEnd = (source.startTime ?? .zero) + duration
        } else {
            promisedEnd = nil
        }
        let logKey = source.logKey
        let reopenErrors = source.reopenErrors
        chunkIndex = source.formatName == "avi" ? source.videoStreamIndex.map { source.indexedPositions(streamIndex: $0) } ?? [] : []
        clusterCheck = source.formatName.contains("matroska") ? MatroskaClusterCheck(url: url) : nil
        self.source = Mutex(source)
        self.index = Mutex(keyframes)
        commands.withLock { $0 = [.setActiveStreams(active)] }
        if let logKey {
            // Damage the demuxer resyncs over silently, apart from an error in the log.
            let early = FFmpegLogTap.attach(logKey) { [weak self] in self?.loggedDamage() } + reopenErrors
            // Logged while probing: damage, or the end of a file cut short. Settled once reading
            // passes the probed bytes or reaches the end (`settleProbeErrors`).
            reading.withLock { $0.probeErrors = early }
        }
    }

    deinit {
        stop()
    }

    /// The demuxer logged an error while reading (a resync over damaged bytes, a packet whose
    /// size does not match its header). Called on the demuxer thread, inside the read; it counts
    /// once the read returns a packet, since an error in the read that ends the file is a file
    /// cut short, which `dataEnd` reports.
    private func loggedDamage() {
        reading.withLock { $0.loggedErrors += 1 }
    }

    /// Errors logged while probing at open are damage, unless the file turned out to be cut
    /// short: probing reads to the end of a short file and logs the cut. Their place in time is
    /// not known, so they are counted without an event.
    private func settleProbeErrors(cutShort: Bool) {
        let count = reading.withLock { tracking -> Int in
            defer { tracking.probeErrors = 0 }
            guard !cutShort else { return 0 }
            tracking.damagedReads += tracking.probeErrors
            return tracking.probeErrors
        }
        if count > 0 { report(DemuxDamage(at: nil, video: info.videoStreamIndex != nil, count: count, located: false)) }
    }

    /// Reports the errors logged since the last read as damage, or drops them at the end of
    /// the file.
    private func settleLoggedErrors(endOfFile: Bool) {
        let damage = reading.withLock { tracking -> DemuxDamage? in
            defer { tracking.loggedErrors = 0 }
            guard tracking.loggedErrors > 0, !endOfFile else { return nil }
            tracking.damagedReads += tracking.loggedErrors
            return DemuxDamage(at: tracking.lastTime, video: info.videoStreamIndex != nil, count: tracking.loggedErrors)
        }
        if let damage { report(damage) }
    }

    private func report(_ damage: DemuxDamage) {
        let handler = damageSink.withLock { sink -> SendableCallback<DemuxDamage>? in
            if sink.handler == nil, sink.undelivered.count < 1_024 { sink.undelivered.append(damage) }
            return sink.handler
        }
        handler?.call(damage)
    }

    private static func readUntilFirstVideoFrame(_ source: MediaSource, videoIndex: Int) throws -> (packets: [Packet], reachedEnd: Bool) {
        var packets: [Packet] = []
        var videoCount = 0
        var sawKeyframe = false
        var bytes = 0
        var damaged = 0
        // Enough video packets for one decoded frame even with frame reordering; capped by size.
        while videoCount < 12, bytes < 16 << 20 {
            let packet: Packet?
            do {
                packet = try source.readPacket()
            } catch let error as FFmpegError where error.isInvalidData && damaged < 64 {
                // Damaged bytes near the start: the demuxer resyncs on the next read.
                damaged += 1
                continue
            }
            guard let packet else { return (packets, true) }
            packets.append(packet)
            bytes += packet.size
            if packet.streamIndex == videoIndex {
                if packet.isKeyframe { sawKeyframe = true }
                if sawKeyframe { videoCount += 1 }
            }
        }
        return (packets, false)
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
        let signal = self.signal
        store.setDemuxerWake { signal.wake() }
        // The thread holds the demuxer only during one step and waits without it, so dropping
        // the last reference ends the thread too (deinit sends `.stop`, which wakes it).
        let thread = Thread { [weak self] in
            var loop = LoopState()
            while true {
                let outcome: StepOutcome
                do {
                    guard let demuxer = self else { break }
                    outcome = demuxer.step(&loop)
                }
                if outcome == .exit { break }
                if outcome == .idle { signal.wait() }
            }
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
        clusterCheck?.close()
        guard running.load(ordering: .acquiring), !finished.load(ordering: .acquiring) else { return }
        // A read blocked on a dead drive returns at once instead of holding the thread.
        interrupt.abort()
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

    /// Packets the read thread has read since `start()` (the energy counters, section 7.9).
    public var packetsRead: Int { packetsReadCounter.load(ordering: .relaxed) }

    /// The generation of the most recent seek the thread has carried out.
    public var completedSeekGeneration: UInt64 { lastSeekGeneration.load(ordering: .acquiring) }

    // MARK: Robustness (design section 7.10)

    /// The last presentation time the file has data for, when that is earlier than the header
    /// promises (a file cut short). Known at open for MP4, else once reading hits the end.
    public var dataEnd: MediaTime? { reading.withLock { $0.dataEnd } }

    /// Called once, on the demuxer thread, when `dataEnd` becomes known after open.
    public func setDataEndHandler(_ handler: (@Sendable (MediaTime) -> Void)?) {
        dataEndHandler.withLock { $0 = handler.map { SendableCallback($0) } }
    }

    /// Called on the demuxer thread for damaged data the demuxer skipped.
    public func setDamageHandler(_ handler: (@Sendable (DemuxDamage) -> Void)?) {
        let callback = handler.map { SendableCallback($0) }
        let pending = damageSink.withLock { sink -> [DemuxDamage] in
            sink.handler = callback
            defer { sink.undelivered.removeAll() }
            return callback == nil ? [] : sink.undelivered
        }
        pending.forEach { callback?.call($0) }
    }

    /// Called on the demuxer thread when a read fails because the file's volume went away. The
    /// thread then waits for a command instead of ending the file.
    public func setVolumeLostHandler(_ handler: (@Sendable (String) -> Void)?) {
        volumeLostHandler.withLock { $0 = handler.map { SendableCallback($0) } }
    }

    /// AVI index entries whose chunk lies between two video packets read at `after` and `before`:
    /// a packet's position is its chunk's plus the 8-byte chunk header.
    static func skippedChunks(_ index: [Int64], after: Int64, before: Int64) -> Int {
        guard before > after else { return 0 }
        func firstIndex(above value: Int64) -> Int {
            var low = 0
            var high = index.count
            while low < high {
                let middle = (low + high) / 2
                if index[middle] <= value { low = middle + 1 } else { high = middle }
            }
            return low
        }
        // Chunks starting after the previous packet's own chunk and before this packet's chunk.
        return max(0, firstIndex(above: before - 9) - firstIndex(above: after - 8))
    }

    /// Damaged stretches the demuxer skipped since open.
    public var damagedReads: Int { reading.withLock { $0.damagedReads } }

    private func wake() {
        signal.wake()
    }

    // MARK: Thread

    private struct LoopState {
        var active = Set<Int>()
        var reachedEnd = false
        /// Read errors in a row without a packet in between.
        var consecutiveErrors = 0
        var lastErrorPosition: Int64?
    }

    private enum StepOutcome {
        case proceed
        /// Nothing to read: wait for a command or a wake from the store.
        case idle
        case exit
    }

    /// One iteration of the read loop.
    private func step(_ loop: inout LoopState) -> StepOutcome {
        for command in commands.withLock({ queue -> [Command] in defer { queue.removeAll() }; return queue }) {
            switch command {
            case .stop:
                return .exit
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
            // A command queued after the drain above has already marked the signal pending.
            return .idle
        }
        do {
            let fault = readFaultForTesting.exchange(0, ordering: .relaxed)
            if fault != 0 { throw FFmpegError(code: fault, operation: "av_read_frame") }
            let packet = try source.withLock { source -> Packet? in
                let packet = try source.readPacket()
                bytesReadCounter.store(source.bytesRead, ordering: .relaxed)
                return packet
            }
            guard let packet else {
                settleLoggedErrors(endOfFile: true)
                reachEnd(&loop)
                return .proceed
            }
            settleLoggedErrors(endOfFile: false)
            if bytesRead > Int64(MediaSource.probeSize) { settleProbeErrors(cutShort: false) }
            loop.consecutiveErrors = 0
            packetsReadCounter.add(1, ordering: .relaxed)
            if loop.active.contains(packet.streamIndex), !isCutOff(packet) { accept(packet) }
        } catch {
            return readFailed(error, loop: &loop)
        }
        return .proceed
    }

    /// The last sample of an MP4 cut short: FFmpeg returns the bytes that are there, fewer than
    /// the index says, so it is part of a frame and is left out rather than decoded as damage.
    private func isCutOff(_ packet: Packet) -> Bool {
        guard let position = packet.position, let size = info.fileSize, position + Int64(packet.size) >= size,
              let indexed = source.withLock({ $0.indexedSize(streamIndex: packet.streamIndex, position: position) }),
              packet.size < indexed else { return false }
        trace("left out a packet cut off by the end of the file at \(packet.time?.description ?? "-")")
        return true
    }

    /// End of file: everything after the last packet read is missing when the header promised
    /// more (section 7.10).
    private func reachEnd(_ loop: inout LoopState) {
        loop.reachedEnd = true
        coverage.withLock { $0.reachEnd() }
        let found = reading.withLock { tracking -> MediaTime? in
            guard tracking.dataEnd == nil, let promisedEnd, let last = tracking.lastTime,
                  last + Demuxer.dataEndTolerance(tracking.frameDuration) < promisedEnd else { return nil }
            tracking.dataEnd = last
            return last
        }
        store.markEndOfFile()
        settleProbeErrors(cutShort: reading.withLock { $0.dataEnd != nil })
        if let found {
            trace("data ends at \(found), the header promises \(promisedEnd?.description ?? "-")")
            dataEndHandler.withLock { $0 }?.call(found)
        }
    }

    /// How far before the promised end the last packet may end in a complete file: the header
    /// duration is the end of the last packet of any stream, so rounding and one frame of slack.
    static func dataEndTolerance(_ frameDuration: MediaTime?) -> MediaTime {
        max(.milliseconds(100), MediaTime(microseconds: (frameDuration?.microseconds ?? 0) * 2))
    }

    /// A failed read. A vanished volume stalls the thread and reports it; damaged bytes are
    /// skipped (the demuxer resyncs); a read error that repeats, or a demuxer stuck on the same
    /// bytes, ends the file where the data ends.
    private func readFailed(_ error: any Error, loop: inout LoopState) -> StepOutcome {
        if interrupt.isAborted { return .exit }
        let ffmpeg = error as? FFmpegError
        settleLoggedErrors(endOfFile: ffmpeg?.isInvalidData != true)
        if ffmpeg?.isDriveLossError == true || ffmpeg?.isReadError == true, let volume = volumeCheck(url) {
            failure.withLock { $0 = "\(String(describing: error)); volume \(volume) is gone" }
            trace("read failed and volume \(volume) is gone: \(error)")
            loop.reachedEnd = true
            volumeLostHandler.withLock { $0 }?.call(volume)
            return .idle
        }
        let position = source.withLock { $0.readPosition }
        loop.consecutiveErrors += 1
        let stuck = position != nil && position == loop.lastErrorPosition
        loop.lastErrorPosition = position
        if ffmpeg?.isInvalidData == true, loop.consecutiveErrors < 64, !(stuck && loop.consecutiveErrors >= 8) {
            let damage = reading.withLock { tracking -> DemuxDamage in
                tracking.damagedReads += 1
                return DemuxDamage(at: tracking.lastTime, video: info.videoStreamIndex != nil)
            }
            report(damage)
            return .proceed
        }
        if ffmpeg?.isReadError == true, loop.consecutiveErrors < 3 { return .proceed }
        failure.withLock { $0 = String(describing: error) }
        trace("reading stopped: \(error)")
        reachEnd(&loop)
        return .proceed
    }

    private func accept(_ packet: Packet) {
        // Every kept stream counts for where the data ends: subtitles may run past the picture.
        let isVideo = packet.streamIndex == info.videoStreamIndex
        let selected = isVideo || packet.streamIndex == info.audioStreamIndex
        // The first packet of each cluster queues a checksum of the whole cluster in the background.
        if selected, let position = packet.position, let clusterCheck {
            let damage = DemuxDamage(at: packet.time, video: info.videoStreamIndex != nil)
            clusterCheck.check(position: position) { [weak self] in
                guard let self else { return }
                trace("cluster CRC-32 mismatch at byte \(position)")
                reading.withLock { $0.damagedReads += 1 }
                report(damage)
            }
        }
        let found = reading.withLock { tracking -> [DemuxDamage] in
            tracking.note(packet, isVideo: isVideo)
            var found: [DemuxDamage] = []
            if isVideo, !chunkIndex.isEmpty, let position = packet.position {
                if let last = tracking.lastVideoPosition {
                    let skipped = Demuxer.skippedChunks(chunkIndex, after: last, before: position)
                    if skipped > 0 { found.append(DemuxDamage(at: packet.time, video: true, count: skipped)) }
                }
                tracking.lastVideoPosition = position
            }
            if selected, packet.isCorrupt { found.append(DemuxDamage(at: packet.time, video: isVideo)) }
            tracking.damagedReads += found.reduce(0) { $0 + $1.count }
            return found
        }
        found.forEach(report)
        guard packet.streamIndex == info.videoStreamIndex else {
            store.append(packet)
            return
        }
        let prepared = videoFormat?.prepare(packet) ?? packet
        var tag: VideoFormat?
        if prepared.isKeyframe {
            index.withLock { Demuxer.record(prepared, format: videoFormat, in: &$0) }
            tag = formats.withLock { Demuxer.formatTag(of: packet, base: videoFormat, cache: &$0) }
        }
        if let time = prepared.time { coverage.withLock { $0.extend(to: time) } }
        store.append(prepared, format: tag)
    }

    /// The format of an Annex B keyframe whose in-band parameter sets differ from the stream's
    /// at open (a resolution change in MPEG-TS, section 7.10), else nil. `packet` is the
    /// keyframe as read, before its start codes are rewritten.
    static func formatTag(of packet: Packet, base: VideoFormat?, cache: inout [[Data]: VideoFormat?]) -> VideoFormat? {
        guard let base, base.convertsAnnexB, let codec = base.codec.nalCodec,
              let sets = NALUnits.parameterSets(inAnnexB: packet.data, codec: codec) else { return nil }
        if let known = cache[sets] { return known }
        let format = try? alternateFormat(base, parameterSets: sets)
        cache[sets] = format
        if let format { trace("format change at \(packet.time?.description ?? "-"): \(format.width)x\(format.height)") }
        return format
    }

    /// `base` with other parameter sets: new size, configuration record and description, the
    /// same colour and aspect extensions. Nil when the sets describe `base` itself.
    static func alternateFormat(_ base: VideoFormat, parameterSets sets: [Data]) throws -> VideoFormat? {
        guard let codec = base.codec.nalCodec, let type = base.codec.cmCodecType, let baseDescription = base.formatDescription else { return nil }
        let record = try FormatDescriptionBuilder.configurationRecord(parameterSets: sets, codec: codec)
        if record == base.convertedConfigurationRecord { return nil }
        let probe = try describe(parameterSets: sets, codec: codec)
        let size = CMVideoFormatDescriptionGetDimensions(probe)
        guard size.width > 0, size.height > 0 else { return nil }
        var extensions = (CMFormatDescriptionGetExtensions(baseDescription) as? [CFString: Any]) ?? [:]
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [codec == .h264 ? "avcC" : "hvcC": record]
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: type,
            width: size.width,
            height: size.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw MediaStatusError(status: status, operation: "CMVideoFormatDescriptionCreate") }
        var format = base
        format.width = Int(size.width)
        format.height = Int(size.height)
        format.convertedConfigurationRecord = record
        format.formatDescription = description
        if codec == .hevc { format.hevcTemporalLayers = NALUnits.hevcTemporalLayerCount(hvcC: record) ?? 0 }
        return format
    }

    private static func describe(parameterSets sets: [Data], codec: NALUnits.Codec) throws -> CMFormatDescription {
        let buffers = sets.map { [UInt8]($0) }
        var description: CMFormatDescription?
        let status = withPointers(buffers, at: 0, []) { pointers in
            switch codec {
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                    parameterSetSizes: buffers.map(\.count), nalUnitHeaderLength: 4, formatDescriptionOut: &description
                )
            case .hevc:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                    parameterSetSizes: buffers.map(\.count), nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { throw MediaStatusError(status: status, operation: "format description from parameter sets") }
        return description
    }

    /// Calls `body` with stable pointers to every buffer's bytes.
    private static func withPointers<R>(_ buffers: [[UInt8]], at index: Int, _ collected: [UnsafePointer<UInt8>], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        guard index < buffers.count else { return body(collected) }
        return buffers[index].withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return body(collected) }
            return withPointers(buffers, at: index + 1, collected + [base], body)
        }
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
        // The last time read belongs to the old stretch; the end of this one is found anew.
        reading.withLock { tracking in
            tracking.lastTime = nil
            tracking.lastVideoPosition = nil
        }
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

}

/// Wakes the demuxer thread: a command was queued or the store wants more data (`setPlayhead`,
/// `requestMoreData`). The flag keeps a wake that arrives before the wait, so the thread can
/// wait without a timeout and an idle demuxer causes no wakeups (section 7.9).
final class DemuxerWake: Sendable {
    private let condition = NSCondition()
    private let pending = Atomic<Bool>(false)

    func wake() {
        condition.lock()
        pending.store(true, ordering: .releasing)
        condition.signal()
        condition.unlock()
    }

    /// Blocks until `wake()` was called since the last return.
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        while !pending.load(ordering: .acquiring) {
            condition.wait()
        }
        pending.store(false, ordering: .releasing)
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

/// Damaged data the demuxer skipped: an unreadable stretch, or a packet the container marked
/// corrupt (section 7.10).
public struct DemuxDamage: Sendable, Hashable {
    /// The last presentation time read before it, when known.
    public var at: MediaTime?
    /// The stretch is attributed to video when the file has video.
    public var video: Bool
    /// Damaged reads it stands for.
    public var count = 1
    /// False for damage logged while probing at open, whose time is unknown.
    public var located = true

    public init(at: MediaTime?, video: Bool, count: Int = 1, located: Bool = true) {
        self.at = at
        self.video = video
        self.count = count
        self.located = located
    }
}

/// What the read thread has seen, for `dataEnd` and damage counts.
struct ReadTracking: Sendable {
    /// End of the last packet read in the current stretch (pts plus duration).
    var lastTime: MediaTime?
    var dataEnd: MediaTime?
    /// Byte position of the last video packet read in the current stretch.
    var lastVideoPosition: Int64?
    /// Errors FFmpeg logged during the read in progress, and while probing at open.
    var loggedErrors = 0
    var probeErrors = 0
    var frameDuration: MediaTime?
    var damagedReads = 0

    mutating func note(_ packet: Packet, isVideo: Bool) {
        guard let time = packet.time else { return }
        let end = time + max(packet.duration, .zero)
        lastTime = max(lastTime ?? end, end)
        if isVideo, packet.duration > .zero, frameDuration == nil { frameDuration = packet.duration }
    }
}

/// Removable volumes (section 7.10). `getmntinfo` lists mounts without touching them, so no
/// folder is read and no permission is asked.
public enum MountedVolumes {
    /// Names of the volumes mounted under /Volumes.
    public static func names() -> Set<String> {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        var names: Set<String> = []
        for index in 0..<Int(count) {
            let path = withUnsafeBytes(of: mounts[index].f_mntonname) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if let name = MediaProblem.volumeName(of: path + "/x") { names.insert(name) }
        }
        return names
    }

    /// The volume name of a file under /Volumes/<name>/ when that volume is not mounted; nil
    /// otherwise (including every file outside /Volumes).
    public static func missingVolume(of url: URL, mounted: () -> Set<String> = names) -> String? {
        guard let name = MediaProblem.volumeName(of: url.path(percentEncoded: false)) else { return nil }
        return mounted().contains(name) ? nil : name
    }
}

/// Error messages FFmpeg logs for a tracked format context (section 7.10). Demuxers resync
/// over damaged bytes and only say so in the log (Matroska "invalid as first byte of an EBML
/// number", FLV "Packet mismatch"), so the log is where damage shows. A context is tracked from
/// allocation, so errors while probing the file count too; a handler attached later gets the
/// count so far. Every message still goes to FFmpeg's default callback, which prints it at the
/// level set with `av_log_set_level`.
enum FFmpegLogTap {
    private struct Entry {
        var handler: SendableCallback<Void>?
        var count = 0
    }

    private static let entries = Mutex<[Int: Entry]>([:])
    private static let installed: Bool = {
        av_log_set_callback { context, level, format, arguments in
            if level <= AV_LOG_ERROR, let context {
                let handler = FFmpegLogTap.entries.withLock { entries -> SendableCallback<Void>? in
                    let key = Int(bitPattern: context)
                    guard entries[key] != nil else { return nil }
                    entries[key]?.count += 1
                    return entries[key]?.handler
                }
                handler?.call(())
            }
            if let arguments { av_log_default_callback(context, level, format, arguments) }
        }
        return true
    }()

    /// Starts counting errors logged for `key` (a format context's address).
    static func track(_ key: Int) {
        _ = installed
        entries.withLock { $0[key] = Entry() }
    }

    /// Calls `handler` for every later error of `key`; returns the errors counted so far.
    @discardableResult
    static func attach(_ key: Int, _ handler: @escaping @Sendable () -> Void) -> Int {
        entries.withLock { entries in
            let counted = entries[key]?.count ?? 0
            entries[key] = Entry(handler: SendableCallback { _ in handler() }, count: counted)
            return counted
        }
    }

    /// Stops tracking `key` (its context is closed); returns the errors counted.
    @discardableResult
    static func untrack(_ key: Int) -> Int {
        entries.withLock { $0.removeValue(forKey: key)?.count ?? 0 }
    }
}
