import Foundation

/// Text subtitle charsets (design section 8.3). Raw values are iconv names, so they can be
/// passed to libavcodec's `sub_charenc` as they are.
public enum SubtitleCharset: String, Sendable, Hashable, Codable, CaseIterable {
    case utf8 = "UTF-8"
    case utf16LE = "UTF-16LE"
    case utf16BE = "UTF-16BE"
    case gb18030 = "GB18030"
    case big5 = "BIG5"
    case latin1 = "LATIN1"

    /// Foundation's encoding for decoding in Swift.
    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .gb18030: SubtitleCharset.cfEncoding(CFStringEncodings.GB_18030_2000)
        case .big5: SubtitleCharset.cfEncoding(CFStringEncodings.big5_HKSCS_1999)
        case .latin1: .isoLatin1
        }
    }

    private static func cfEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}

/// The result of decoding a text subtitle file.
public struct DecodedSubtitleText: Sendable, Hashable {
    public var text: String
    public var charset: SubtitleCharset
    /// False when every candidate failed and the text was read as Latin-1, so the OSD should say
    /// "Subtitle encoding not recognized".
    public var recognised: Bool

    public init(text: String, charset: SubtitleCharset, recognised: Bool) {
        self.text = text
        self.charset = charset
        self.recognised = recognised
    }
}

/// The charset fallback: UTF-8 (UTF-16 by BOM), then Big5 when the name or title says
/// Traditional, else GB18030, then Latin-1 (D30).
public enum SubtitleCharsetDetector {
    public static let unrecognisedMessage = "Subtitle encoding not recognized"

    /// True when the file name or track title marks Traditional Chinese
    /// (`cht`, `tc`, `big5`, `zh-Hant`, `zh-TW`, `zh-HK`, or 繁 in a title).
    public static func saysTraditional(fileName: String?, title: String?) -> Bool {
        for text in [fileName, title].compactMap(\.self) {
            if text.contains("繁") { return true }
            let lower = text.lowercased()
            if lower.contains("zh-hant") || lower.contains("zh_hant") || lower.contains("zh-tw")
                || lower.contains("zh_tw") || lower.contains("zh-hk") || lower.contains("zh_hk") {
                return true
            }
            let tokens = Set(TrackNaming.titleTokens(text))
            if !tokens.isDisjoint(with: ["cht", "tc", "big5", "hant"]) { return true }
        }
        return false
    }

    /// The charsets to try after UTF-8 failed, in order.
    public static func fallbacks(fileName: String?, title: String?) -> [SubtitleCharset] {
        saysTraditional(fileName: fileName, title: title) ? [.big5, .latin1] : [.gb18030, .latin1]
    }

    /// The charset given by a byte order mark, and the mark's length.
    public static func byteOrderMark(_ data: Data) -> (charset: SubtitleCharset, length: Int)? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return (.utf8, 3) }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return (.utf16LE, 2) }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return (.utf16BE, 2) }
        return nil
    }

    /// Decodes a whole text subtitle file. The BOM, if any, is removed from the text.
    public static func decode(_ data: Data, fileName: String? = nil, title: String? = nil) -> DecodedSubtitleText {
        if let (charset, length) = byteOrderMark(data),
           let text = String(data: data.dropFirst(length), encoding: charset.stringEncoding) {
            return DecodedSubtitleText(text: text, charset: charset, recognised: true)
        }
        if let text = String(data: data, encoding: .utf8) {
            return DecodedSubtitleText(text: text, charset: .utf8, recognised: true)
        }
        for charset in fallbacks(fileName: fileName, title: title) {
            if let text = String(data: data, encoding: charset.stringEncoding) {
                return DecodedSubtitleText(text: text, charset: charset, recognised: charset != .latin1)
            }
        }
        // Latin-1 maps every byte, so this is only reached for an encoding Foundation lacks.
        return DecodedSubtitleText(text: String(decoding: data, as: UTF8.self), charset: .latin1, recognised: false)
    }
}
