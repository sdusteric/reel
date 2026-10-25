import CReelDeps
import Foundation
import ReelCore

/// A sidecar subtitle file read whole and decoded (design section 8.1).
public struct LoadedExternalSubtitle: Sendable {
    public var url: URL
    public var format: SubtitleFormat
    /// The ASS header from the decoder.
    public var header: String
    /// The charset the file was read as: UTF-16 by its byte order mark, else the decoder's.
    public var charset: SubtitleCharset
    /// False when the text fell through to Latin-1 ("Subtitle encoding not recognised").
    public var charsetRecognised: Bool
    /// Time-ordered events.
    public var events: [SubtitleTextEvent]
    /// The family Reel's default style uses: PingFang TC or HK when the name or title says so.
    public var fontFamily: String {
        SubtitleStyle.fontName(language: nil, title: title, fileName: url.lastPathComponent)
    }
    /// The title the file was loaded with.
    public var title: String?

    public var trackID: TrackID { .external(url) }
}

/// Reads `.srt`, `.ass`, `.ssa` and `.vtt` files into memory and decodes them through the same
/// libavcodec decoders as embedded tracks, with the same charset fallback (section 8.3).
public enum ExternalSubtitleLoader {
    /// Subtitle files are small; anything larger is not a subtitle file.
    public static let maximumSize = 64 << 20

    public enum LoadError: Error, Sendable, Hashable, LocalizedError {
        case unsupportedFormat(String)
        case tooLarge(Int)
        case noSubtitleStream

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let name): "\(name) is not a supported subtitle file"
            case .tooLarge(let size): "The subtitle file is too large (\(size) bytes)"
            case .noSubtitleStream: "The file has no subtitle events"
            }
        }
    }

    /// Reads and decodes `url`. `title` helps choose Big5 when the name does not say Traditional.
    public static func load(_ url: URL, title: String? = nil) throws -> LoadedExternalSubtitle {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maximumSize else { throw LoadError.tooLarge(size) }
        let data = try Data(contentsOf: url)
        return try load(data: data, url: url, title: title)
    }

    /// Loads `url` and puts its events in `store` under `.external(url)`, replacing earlier ones.
    @discardableResult
    public static func load(_ url: URL, title: String? = nil, into store: SubtitleTrackStore) throws -> LoadedExternalSubtitle {
        let loaded = try load(url, title: title)
        store.begin(
            loaded.trackID,
            header: loaded.header,
            format: loaded.format,
            charset: loaded.charset,
            recognised: loaded.charsetRecognised,
            fontFamily: loaded.fontFamily
        )
        store.reset(loaded.trackID, charset: loaded.charset, recognised: loaded.charsetRecognised, header: loaded.header)
        store.add(loaded.events, to: loaded.trackID)
        store.markComplete(loaded.trackID)
        return loaded
    }

    /// Decodes file contents already in memory; `url` names the file (extension and language hints).
    public static func load(data: Data, url: URL, title: String? = nil) throws -> LoadedExternalSubtitle {
        let fileName = url.lastPathComponent
        guard let format = SubtitleFormat(fileExtension: url.pathExtension), format.isText,
              let demuxer = demuxerName(for: url.pathExtension) else {
            throw LoadError.unsupportedFormat(fileName)
        }
        let byteOrderMark = SubtitleCharsetDetector.byteOrderMark(data)
        var input = data
        if let mark = byteOrderMark, mark.charset != .utf8 {
            // FFmpeg's own UTF-16 reading garbles the first character; convert to UTF-8 here.
            guard let text = String(data: data.dropFirst(mark.length), encoding: mark.charset.stringEncoding) else {
                throw LoadError.unsupportedFormat(fileName)
            }
            input = Data(text.utf8)
        }
        let decoded = try withInput(data: input, demuxer: demuxer, fileName: fileName) { context in
            try decode(context, fileName: fileName, title: title)
        }
        return LoadedExternalSubtitle(
            url: url,
            format: format,
            header: decoded.header,
            charset: byteOrderMark?.charset ?? decoded.charset,
            charsetRecognised: byteOrderMark != nil || decoded.recognised,
            events: decoded.events.sorted { $0.start < $1.start },
            title: title
        )
    }

    /// The FFmpeg demuxer for a sidecar extension, or nil when Reel cannot read it.
    public static func demuxerName(for fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "srt": "srt"
        case "ass", "ssa": "ass"
        case "vtt": "webvtt"
        default: nil
        }
    }

    private struct Decoded {
        var header: String
        var charset: SubtitleCharset
        var recognised: Bool
        var events: [SubtitleTextEvent]
    }

    private static func decode(_ context: UnsafeMutablePointer<AVFormatContext>, fileName: String, title: String?) throws -> Decoded {
        guard context.pointee.nb_streams > 0, let stream = context.pointee.streams[0],
              stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else {
            throw LoadError.noSubtitleStream
        }
        let decoder = try SubtitleDecoder(
            parameters: stream.pointee.codecpar,
            streamIndex: 0,
            timeBase: Rational(stream.pointee.time_base.num, stream.pointee.time_base.den),
            fileName: fileName,
            title: title
        )
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { throw FFmpegError(code: reel_averror(ENOMEM), operation: "av_packet_alloc") }
        var events: [SubtitleTextEvent] = []
        while true {
            let status = av_read_frame(context, packet)
            if status == reel_averror_eof() { break }
            if status == reel_averror_eagain() { continue }
            try FFmpegError.check(status, "read \(fileName)")
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == 0 else { continue }
            let noValue = reel_av_nopts()
            let source = SubtitleSourcePacket(
                data: packet.pointee.data.map { Data(bytes: $0, count: Int(packet.pointee.size)) } ?? Data(),
                pts: packet.pointee.pts == noValue ? nil : packet.pointee.pts,
                duration: packet.pointee.duration
            )
            switch try decoder.decodeText(source) {
            case .added(let new): events += new
            case .replaced(let all, _): events = all
            }
        }
        return Decoded(header: decoder.header, charset: decoder.charset, recognised: decoder.charsetRecognised, events: events)
    }

    /// Opens `data` with the named demuxer through an in-memory AVIOContext.
    private static func withInput<Result>(
        data: Data,
        demuxer: String,
        fileName: String,
        _ body: (UnsafeMutablePointer<AVFormatContext>) throws -> Result
    ) throws -> Result {
        var io: UnsafeMutablePointer<AVIOContext>? = data.withUnsafeBytes { bytes in
            reel_avio_open_memory(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
        }
        defer { reel_avio_close_memory(&io) }
        guard let io, var context = avformat_alloc_context() else {
            throw FFmpegError(code: reel_averror(ENOMEM), operation: "open \(fileName) in memory")
        }
        context.pointee.pb = io
        context.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        var optional: UnsafeMutablePointer<AVFormatContext>? = context
        let status = avformat_open_input(&optional, fileName, av_find_input_format(demuxer), nil)
        guard status >= 0, let opened = optional else {
            // avformat_open_input frees the context on failure, but never a custom pb.
            throw FFmpegError(code: status, operation: "avformat_open_input \(fileName)")
        }
        context = opened
        defer {
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
        }
        return try body(context)
    }
}
