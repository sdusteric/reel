import Foundation

/// Why a file could not be opened or stopped being readable, with the failure card copy
/// (sections 7.10 and 9.14, D63).
public enum MediaProblem: Sendable, Hashable {
    /// No demuxer recognised the file.
    case notMedia
    /// A known container header, then end of file before the first video or audio packet.
    case cutShort
    case noPlayableStream
    /// A codec the LGPL build cannot decode; the name as shown ("ProRes").
    case unsupportedCodec(String)
    /// An I/O error, a permission problem or a timed-out open.
    case unreadable(String)
    /// The file's volume (`/Volumes/<name>`) is no longer mounted.
    case volumeGone(String)

    /// The class name used in reports: "notMedia", "cutShort", "noPlayableStream",
    /// "unsupportedCodec", "unreadable", "volumeGone".
    public var kind: String {
        switch self {
        case .notMedia: "notMedia"
        case .cutShort: "cutShort"
        case .noPlayableStream: "noPlayableStream"
        case .unsupportedCodec: "unsupportedCodec"
        case .unreadable: "unreadable"
        case .volumeGone: "volumeGone"
        }
    }

    public var title: String {
        switch self {
        case .notMedia, .cutShort, .noPlayableStream, .unsupportedCodec: "This file can't be played"
        case .unreadable: "This file couldn't be read"
        case .volumeGone(let name): "\u{201C}\(name)\u{201D} was disconnected"
        }
    }

    /// The one-sentence explanation. For `.volumeGone`, `savedPosition` is the resume time
    /// as the controller shows it ("31:04").
    public func explanation(savedPosition: String?) -> String {
        switch self {
        case .cutShort:
            "The file ends before its first video frame. It may still be downloading, or the copy was cut short."
        case .notMedia:
            "Reel doesn't recognise this as a video or audio file."
        case .noPlayableStream:
            "The file has no video or audio that Reel can play."
        case .unsupportedCodec(let name):
            "The video uses \(name), which Reel can't decode."
        case .unreadable:
            "macOS reported a read error. The disk may have a problem, or Reel may not have access to this folder."
        case .volumeGone:
            if let savedPosition {
                "Reel saved your place at \(savedPosition) and will continue when the drive is connected again."
            } else {
                "Reel saved your place and will continue when the drive is connected again."
            }
        }
    }

    public var explanation: String { explanation(savedPosition: nil) }

    /// The card's buttons, secondary first, primary last (as drawn).
    public var buttons: [MediaProblemButton] {
        switch self {
        case .notMedia, .cutShort, .noPlayableStream, .unsupportedCodec:
            [.showInFinder, .openAnotherFile]
        case .unreadable:
            [.tryAgain, .openAnotherFile]
        case .volumeGone:
            [.closeFile, .tryAgain]
        }
    }

    public var primaryButton: MediaProblemButton { buttons[buttons.count - 1] }

    /// The card's glyph: a drive for `.volumeGone`, a document otherwise. The document carries an
    /// exclamation mark drawn over it (`showsExclamation`): no SF Symbol on macOS 27 combines the
    /// two (`doc.badge.exclamationmark` and its variants are missing).
    public var symbolName: String {
        if case .volumeGone = self { return "externaldrive" }
        return "doc"
    }

    /// True when the card draws an exclamation mark over `symbolName`.
    public var showsExclamation: Bool {
        if case .volumeGone = self { return false }
        return true
    }

    /// Classifies an engine error for `path`. A path under `/Volumes/<name>/` whose volume is not
    /// in `mountedVolumes` is `.volumeGone` whatever the error says.
    public static func classify(from error: EngineError, path: String, mountedVolumes: Set<String>) -> MediaProblem {
        if let volume = volumeName(of: path), !mountedVolumes.contains(volume) {
            return .volumeGone(volume)
        }
        switch error {
        case .notMedia: return .notMedia
        case .cutShort: return .cutShort
        case .noPlayableStream: return .noPlayableStream
        case .unsupportedCodec(let name): return .unsupportedCodec(displayCodecName(name))
        case .io(let reason): return .unreadable(reason)
        case .openFailed(let reason): return classifyOpenFailure(reason)
        case .decoderFailed(let reason), .notImplemented(let reason): return .unreadable(reason)
        case .notOpen: return .unreadable(error.errorDescription ?? "not open")
        }
    }

    /// FFmpeg's open errors by their message (`av_strerror` text).
    static func classifyOpenFailure(_ reason: String) -> MediaProblem {
        let lowered = reason.lowercased()
        let readErrors = [
            "permission denied", "operation not permitted", "no such file", "input/output error",
            "device not configured", "timed out", "resource busy", "stale nfs",
        ]
        if readErrors.contains(where: lowered.contains) { return .unreadable(reason) }
        if lowered.contains("end of file") { return .cutShort }
        return .notMedia
    }

    /// `/Volumes/<name>/...` gives `<name>`; nil for any other path.
    public static func volumeName(of path: String) -> String? {
        let parts = URL(filePath: path).standardizedFileURL.pathComponents
        guard parts.count >= 4, parts[0] == "/", parts[1] == "Volumes", !parts[2].isEmpty else { return nil }
        return parts[2]
    }

    /// A codec name as people know it: "prores" becomes "ProRes". The first word of an engine
    /// message ("hevc without parameter sets") is the codec.
    public static func displayCodecName(_ name: String) -> String {
        let codec = name.split(separator: " ").first.map(String.init) ?? name
        let known: [String: String] = [
            "prores": "ProRes", "hevc": "HEVC", "h264": "H.264", "av1": "AV1", "vp9": "VP9", "vp8": "VP8",
            "mpeg2video": "MPEG-2", "mpeg4": "MPEG-4 Part 2", "vc1": "VC-1", "dnxhd": "DNxHD",
            "cfhd": "CineForm", "theora": "Theora", "mjpeg": "Motion JPEG", "rawvideo": "uncompressed video",
            "truehd": "TrueHD", "dts": "DTS",
        ]
        return known[codec.lowercased()] ?? codec
    }
}

extension MediaProblem: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        switch try container.decode(String.self, forKey: .kind) {
        case "notMedia": self = .notMedia
        case "cutShort": self = .cutShort
        case "noPlayableStream": self = .noPlayableStream
        case "unsupportedCodec": self = .unsupportedCodec(detail)
        case "unreadable": self = .unreadable(detail)
        case "volumeGone": self = .volumeGone(detail)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown problem \(other)")
        }
    }

    /// `{"kind": "unsupportedCodec", "detail": "ProRes"}`; `detail` only for cases that carry one.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .unsupportedCodec(let value), .unreadable(let value), .volumeGone(let value):
            try container.encode(value, forKey: .detail)
        case .notMedia, .cutShort, .noPlayableStream:
            break
        }
    }
}

/// A failure card button (section 9.14).
public enum MediaProblemButton: String, Sendable, Codable, Hashable, CaseIterable {
    case showInFinder, openAnotherFile, tryAgain, closeFile

    public var title: String {
        switch self {
        case .showInFinder: "Show in Finder"
        case .openAnotherFile: "Open Another File\u{2026}"
        case .tryAgain: "Try Again"
        case .closeFile: "Close File"
        }
    }
}
