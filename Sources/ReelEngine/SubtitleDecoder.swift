import CoreGraphics
import CReelDeps
import Foundation
import ReelCore

/// One text subtitle event as libass takes it from Matroska: the event fields after ReadOrder
/// (`Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`) and its display interval.
public struct SubtitleTextEvent: Sendable, Hashable {
    public var start: MediaTime
    public var end: MediaTime
    public var fields: String

    public init(start: MediaTime, end: MediaTime, fields: String) {
        self.start = start
        self.end = end
        self.fields = fields
    }

    public var time: SubtitleEventTime { SubtitleEventTime(start: start, end: end) }

    public func isActive(at time: MediaTime) -> Bool { start <= time && time < end }

    /// The Text field (the eighth and last field), with its commas kept.
    public var assText: String {
        var remainder = Substring(fields)
        for _ in 0..<7 {
            guard let comma = remainder.firstIndex(of: ",") else { return String(remainder) }
            remainder = remainder[remainder.index(after: comma)...]
        }
        return String(remainder)
    }

    /// The text without override blocks: `{\an8}Hi\NThere` gives "Hi\nThere".
    public var plainText: String {
        var output = ""
        var inBlock = false
        var escape = false
        for character in assText {
            if inBlock {
                if character == "}" { inBlock = false }
                continue
            }
            if escape {
                escape = false
                switch character {
                case "N", "n": output.append("\n")
                case "h": output.append(" ")
                default: output.append("\\"); output.append(character)
                }
                continue
            }
            switch character {
            case "{": inBlock = true
            case "\\": escape = true
            default: output.append(character)
            }
        }
        if escape { output.append("\\") }
        return output
    }
}

/// A compressed subtitle packet kept by the decoder so a charset change can decode it again.
/// Text packets are small; bitmap packets are not kept.
public struct SubtitleSourcePacket: Sendable, Hashable {
    public var data: Data
    /// Timestamps in the stream time base; nil pts is skipped.
    public var pts: Int64?
    public var duration: Int64

    public init(data: Data, pts: Int64?, duration: Int64) {
        self.data = data
        self.pts = pts
        self.duration = duration
    }

    public init(_ packet: Packet) {
        self.init(data: packet.data, pts: packet.rawPTS, duration: packet.rawDuration)
    }
}

/// What one text packet produced.
public enum SubtitleTextUpdate: Sendable, Hashable {
    /// New events under the charset already in use.
    case added([SubtitleTextEvent])
    /// The charset changed: these are all events decoded so far, replacing the earlier ones.
    case replaced([SubtitleTextEvent], charset: SubtitleCharset)
}

/// libavcodec subtitle decoding for one stream (design sections 8.1 and 8.3): ass, ssa, subrip,
/// webvtt and mov_text to ASS events, pgssub and dvdsub to bitmaps. Text tracks start as UTF-8;
/// on invalid UTF-8 the decoder reopens with `sub_charenc` and `sub_charenc_mode=pre_decoder`
/// using the `SubtitleCharsetDetector` fallbacks and decodes its history again.
///
/// Not thread-safe: one owner at a time.
public final class SubtitleDecoder {
    /// Events without a duration in the packet or the decoder last this long.
    static let defaultEventDuration = MediaTime.seconds(5)

    public let codecName: String
    public let format: SubtitleFormat
    public let isBitmap: Bool
    public let streamIndex: Int
    public let timeBase: Rational
    /// The charset the text is decoded with now.
    public private(set) var charset: SubtitleCharset
    /// The ASS header (`[Script Info]` and styles) for `ass_process_codec_private`.
    public private(set) var header: String = ""
    /// The family for Reel's default style on this track (`SubtitleStyle.fontName(language:...)`).
    public let fontFamily: String

    private let parameters: UnsafeMutablePointer<AVCodecParameters>
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private let chain: [SubtitleCharset]
    private var history: [SubtitleSourcePacket] = []

    /// - Parameters:
    ///   - fileName: the file name, used with `title` to choose Big5 over GB18030.
    ///   - charset: the charset to open with; UTF-8 when nil.
    public init(
        parameters source: UnsafePointer<AVCodecParameters>,
        streamIndex: Int,
        timeBase: Rational,
        fileName: String? = nil,
        title: String? = nil,
        language: String? = nil,
        charset: SubtitleCharset? = nil
    ) throws {
        guard let copy = avcodec_parameters_alloc() else { throw FFmpegError(code: reel_averror(ENOMEM), operation: "avcodec_parameters_alloc") }
        parameters = copy
        do {
            try FFmpegError.check(avcodec_parameters_copy(copy, source), "avcodec_parameters_copy")
        } catch {
            var pointer: UnsafeMutablePointer<AVCodecParameters>? = copy
            avcodec_parameters_free(&pointer)
            throw error
        }
        self.streamIndex = streamIndex
        self.timeBase = timeBase
        codecName = String(cString: avcodec_get_name(copy.pointee.codec_id))
        format = SubtitleFormat(codec: codecName)
        let descriptor = avcodec_descriptor_get(copy.pointee.codec_id)
        isBitmap = ((descriptor?.pointee.props ?? 0) & AV_CODEC_PROP_BITMAP_SUB) != 0 || format.isBitmap
        chain = [.utf8] + SubtitleCharsetDetector.fallbacks(fileName: fileName, title: title)
        fontFamily = SubtitleStyle.fontName(language: language, title: title, fileName: fileName)
        self.charset = isBitmap ? .utf8 : (charset ?? .utf8)
        try open(charset: self.charset)
    }

    /// Opens a decoder for an embedded stream from its copied parameters.
    public convenience init(
        parameters: CodecParameters,
        fileName: String? = nil,
        title: String? = nil,
        language: String? = nil,
        charset: SubtitleCharset? = nil
    ) throws {
        try self.init(
            parameters: parameters.pointer,
            streamIndex: parameters.streamIndex,
            timeBase: parameters.timeBase,
            fileName: fileName,
            title: title,
            language: language,
            charset: charset
        )
    }

    deinit {
        avcodec_free_context(&context)
        var pointer: UnsafeMutablePointer<AVCodecParameters>? = parameters
        avcodec_parameters_free(&pointer)
    }

    /// True when the text fell through to Latin-1, so the OSD should say
    /// "Subtitle encoding not recognised".
    public var charsetRecognised: Bool { isBitmap || charset != .latin1 }

    /// The canvas bitmap positions refer to: the decoder's size (PGS sets it from the
    /// presentation segment), else the stream's.
    public var canvasSize: (width: Int, height: Int)? {
        if let context, context.pointee.width > 0, context.pointee.height > 0 {
            return (Int(context.pointee.width), Int(context.pointee.height))
        }
        if parameters.pointee.width > 0, parameters.pointee.height > 0 {
            return (Int(parameters.pointee.width), Int(parameters.pointee.height))
        }
        return nil
    }

    // MARK: Text

    /// Decodes one text packet. Falls back to the next charset on invalid text and then returns
    /// every event decoded so far. A packet that fails in every charset is skipped.
    public func decodeText(_ packet: SubtitleSourcePacket) throws -> SubtitleTextUpdate {
        guard !isBitmap else { return .added([]) }
        guard packet.pts != nil, !packet.data.isEmpty else { return .added([]) }
        history.append(packet)
        do {
            return .added(try decodeEvents(packet))
        } catch let error as FFmpegError where SubtitleDecoder.isCharsetFailure(error) {
            let original = charset
            let start = (chain.firstIndex(of: charset) ?? 0) + 1
            for candidate in chain.dropFirst(start) {
                if let events = try? redecode(as: candidate) {
                    return .replaced(events, charset: candidate)
                }
            }
            // Even the last charset failed: the event is malformed, so skip it (section 8.7).
            history.removeLast()
            return .replaced(try redecode(as: original), charset: original)
        }
    }

    /// Switches to `charset` (chosen by another decoder of the same track) and returns every event
    /// decoded so far under it.
    public func adopt(_ charset: SubtitleCharset) throws -> [SubtitleTextEvent] {
        guard !isBitmap, charset != self.charset else { return [] }
        return try redecode(as: charset)
    }

    /// Whether `charset` comes after `other` in this decoder's fallback order.
    public func charset(_ charset: SubtitleCharset, isLaterThan other: SubtitleCharset) -> Bool {
        guard let first = chain.firstIndex(of: charset), let second = chain.firstIndex(of: other) else { return false }
        return first > second
    }

    private func redecode(as candidate: SubtitleCharset) throws -> [SubtitleTextEvent] {
        try open(charset: candidate)
        var events: [SubtitleTextEvent] = []
        for packet in history {
            events += try decodeEvents(packet)
        }
        return events
    }

    private func decodeEvents(_ source: SubtitleSourcePacket) throws -> [SubtitleTextEvent] {
        guard let pts = source.pts else { return [] }
        let decoded = try withDecodedSubtitle(source) { subtitle in
            let start = time(pts) + .milliseconds(Int64(subtitle.start_display_time))
            let end: MediaTime
            if source.duration > 0 {
                end = time(pts + source.duration)
            } else if subtitle.end_display_time > subtitle.start_display_time, subtitle.end_display_time != UInt32.max {
                end = time(pts) + .milliseconds(Int64(subtitle.end_display_time))
            } else {
                end = start + SubtitleDecoder.defaultEventDuration
            }
            var events: [SubtitleTextEvent] = []
            for index in 0..<Int(subtitle.num_rects) {
                guard let rect = subtitle.rects[index], let ass = rect.pointee.ass else { continue }
                let line = String(cString: ass)
                // Drop the decoder's ReadOrder; the track store numbers events itself.
                guard let comma = line.firstIndex(of: ",") else { continue }
                events.append(SubtitleTextEvent(start: start, end: max(end, start), fields: String(line[line.index(after: comma)...])))
            }
            return events
        }
        return decoded ?? []
    }

    // MARK: Bitmaps

    /// Decodes one PGS or DVD packet. Returns a display set when the packet completed one (a PGS
    /// display set with no objects clears the screen and has no rects).
    public func decodeBitmap(_ packet: Packet) throws -> BitmapDisplaySet? {
        guard isBitmap else { return nil }
        let source = SubtitleSourcePacket(packet)
        return try withDecodedSubtitle(source) { subtitle -> BitmapDisplaySet? in
            let start: MediaTime
            if subtitle.pts != reel_av_nopts() {
                start = MediaTime(microseconds: subtitle.pts) + .milliseconds(Int64(subtitle.start_display_time))
            } else if let pts = source.pts {
                start = time(pts) + .milliseconds(Int64(subtitle.start_display_time))
            } else {
                return nil
            }
            var end: MediaTime?
            // 0 and UINT32_MAX mean "until the next display set" (section 8.1).
            if subtitle.end_display_time != 0, subtitle.end_display_time != UInt32.max,
               subtitle.end_display_time > subtitle.start_display_time {
                end = start + .milliseconds(Int64(subtitle.end_display_time - subtitle.start_display_time))
            }
            var rects: [BitmapSubtitleRect] = []
            for index in 0..<Int(subtitle.num_rects) {
                guard let rect = subtitle.rects[index], rect.pointee.type == SUBTITLE_BITMAP,
                      let converted = BitmapSubtitles.rect(from: rect) else { continue }
                rects.append(converted)
            }
            let canvas = canvasSize
            return BitmapDisplaySet(
                start: start,
                end: end,
                rects: rects,
                canvasWidth: canvas?.width ?? 0,
                canvasHeight: canvas?.height ?? 0
            )
        } ?? nil
    }

    // MARK: libavcodec

    private func open(charset: SubtitleCharset) throws {
        avcodec_free_context(&context)
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw EngineError.unsupportedCodec(codecName)
        }
        guard let context = avcodec_alloc_context3(codec) else {
            throw FFmpegError(code: reel_averror(ENOMEM), operation: "avcodec_alloc_context3")
        }
        self.context = context
        try FFmpegError.check(avcodec_parameters_to_context(context, parameters), "avcodec_parameters_to_context")
        context.pointee.pkt_timebase = AVRational(num: timeBase.num, den: timeBase.den)
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        if !isBitmap, charset != .utf8 {
            av_dict_set(&options, "sub_charenc", charset.rawValue, 0)
            av_dict_set(&options, "sub_charenc_mode", "pre_decoder", 0)
        }
        try FFmpegError.check(avcodec_open2(context, codec, &options), "avcodec_open2 \(codecName)")
        self.charset = charset
        header = SubtitleDecoder.headerText(context, charset: charset)
    }

    private static func headerText(_ context: UnsafeMutablePointer<AVCodecContext>, charset: SubtitleCharset) -> String {
        guard let bytes = context.pointee.subtitle_header, context.pointee.subtitle_header_size > 0 else { return "" }
        let data = Data(bytes: bytes, count: Int(context.pointee.subtitle_header_size))
        // The header is not recoded by libavcodec; style names in a GBK file need the charset too.
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: charset.stringEncoding) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private func withDecodedSubtitle<Result>(_ source: SubtitleSourcePacket, _ body: (AVSubtitle) throws -> Result) throws -> Result? {
        guard let context else { throw EngineError.notOpen }
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { throw FFmpegError(code: reel_averror(ENOMEM), operation: "av_packet_alloc") }
        try FFmpegError.check(av_new_packet(packet, Int32(source.data.count)), "av_new_packet")
        source.data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress, !bytes.isEmpty {
                packet.pointee.data.update(from: base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
            }
        }
        packet.pointee.pts = source.pts ?? reel_av_nopts()
        packet.pointee.dts = packet.pointee.pts
        packet.pointee.duration = source.duration
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        try FFmpegError.check(avcodec_decode_subtitle2(context, &subtitle, &got, packet), "decode \(codecName) subtitle")
        defer { avsubtitle_free(&subtitle) }
        guard got != 0 else { return nil }
        return try body(subtitle)
    }

    private func time(_ value: Int64) -> MediaTime {
        MediaTime(value: value, timeBaseNum: timeBase.num, timeBaseDen: timeBase.den)
    }

    /// Invalid UTF-8 after decoding, or an iconv failure while recoding.
    static func isCharsetFailure(_ error: FFmpegError) -> Bool {
        error.code == reel_averror_invaliddata() || error.code == reel_averror(EILSEQ)
            || error.code == reel_averror(EINVAL) || error.code == -1
    }
}

extension SubtitleFormat {
    /// Formats whose events are text, decoded to ASS and drawn by libass.
    var isText: Bool {
        switch self {
        case .ass, .srt, .vtt, .tx3g: true
        case .other, .pgs, .sup, .vobsub, .dvb: false
        }
    }
}
