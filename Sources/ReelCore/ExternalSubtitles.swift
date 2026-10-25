import Foundation

/// A subtitle file found next to a video (design section 8.1).
public struct ExternalSubtitle: Sendable, Hashable {
    public var url: URL
    public var format: SubtitleFormat
    /// The first language token, as written ("zh-Hans", "chs", "en").
    public var language: String?
    /// Further language tokens of a bilingual file ("cht&eng" gives "cht" then "eng").
    public var extraLanguages: [String]
    public var isForced: Bool
    public var isHearingImpaired: Bool
    public var isDefault: Bool
    /// Why the file is listed but cannot be shown in M2 (VobSub, .sup).
    public var unsupportedReason: String?

    public init(
        url: URL,
        format: SubtitleFormat,
        language: String? = nil,
        extraLanguages: [String] = [],
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        isDefault: Bool = false,
        unsupportedReason: String? = nil
    ) {
        self.url = url
        self.format = format
        self.language = language
        self.extraLanguages = extraLanguages
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isDefault = isDefault
        self.unsupportedReason = unsupportedReason
    }

    public var isSupported: Bool { unsupportedReason == nil }

    /// The menu track for this file. Language tokens like `chs` become `zh-Hans`.
    public var track: SubtitleTrack {
        SubtitleTrack(
            id: .external(url),
            language: language.flatMap(LanguageTag.init)?.description ?? language,
            format: format,
            isDefault: isDefault,
            isForced: isForced,
            isHearingImpaired: isHearingImpaired,
            unsupportedReason: unsupportedReason
        )
    }
}

/// Sidecar discovery: the video's folder plus `Subs/` and `Subtitles/` one level down, files
/// whose name starts with the video's stem (case-insensitive) followed by a dot.
public enum ExternalSubtitles {
    public static let supportedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]
    public static let subfolderNames: Set<String> = ["subs", "subtitles"]
    static let vobSubReason = "VobSub files are not supported yet"
    static let supReason = "PGS .sup files are not supported yet"

    /// Folders to list for `video`. Callers list each one (non-recursively) and pass every file
    /// to `discover`. Only folders inside the user's chosen file's folder are touched.
    public static func searchFolders(for video: URL) -> [URL] {
        let folder = video.deletingLastPathComponent()
        return [folder] + ["Subs", "Subtitles", "subs", "subtitles"].map {
            folder.appending(path: $0, directoryHint: .isDirectory)
        }
    }

    /// Lists the search folders with `fileManager` and runs `discover`. Missing folders are skipped.
    public static func scan(for video: URL, fileManager: FileManager = .default) -> [ExternalSubtitle] {
        var seen = Set<String>()
        var files: [URL] = []
        for folder in searchFolders(for: video) {
            let key = folder.standardizedFileURL.path(percentEncoded: false).lowercased()
            guard seen.insert(key).inserted else { continue }
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { continue }
            files += names.map { folder.appending(path: $0, directoryHint: .notDirectory) }
        }
        return discover(for: video, candidates: files)
    }

    /// The external subtitles for `video` among `candidates`, in a stable order: the video's
    /// folder first, then the subfolders, each sorted by name.
    public static func discover(for video: URL, candidates: [URL]) -> [ExternalSubtitle] {
        let folder = video.deletingLastPathComponent().standardizedFileURL
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        var byPath: [String: ExternalSubtitle] = [:]
        var order: [(depth: Int, name: String, key: String)] = []
        let names = Set(candidates.map { $0.lastPathComponent.lowercased() })
        for candidate in candidates {
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            let depth: Int
            if parent.path(percentEncoded: false) == folder.path(percentEncoded: false) {
                depth = 0
            } else if parent.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false) == folder.path(percentEncoded: false),
                      subfolderNames.contains(parent.lastPathComponent.lowercased()) {
                depth = 1
            } else {
                continue
            }
            let name = candidate.lastPathComponent
            guard !name.hasPrefix("."), let subtitle = parse(name: name, url: candidate, stem: stem, siblings: names) else { continue }
            let key = candidate.standardizedFileURL.path(percentEncoded: false)
            guard byPath[key] == nil else { continue }
            byPath[key] = subtitle
            order.append((depth, name, key))
        }
        return order
            .sorted { ($0.depth, $0.name.lowercased()) < ($1.depth, $1.name.lowercased()) }
            .compactMap { byPath[$0.key] }
    }

    /// Parses one file name, or nil when it does not belong to `stem`.
    static func parse(name: String, url: URL, stem: String, siblings: Set<String>) -> ExternalSubtitle? {
        let ext = (name as NSString).pathExtension.lowercased()
        let base = (name as NSString).deletingPathExtension
        let lowerBase = base.lowercased()
        guard lowerBase == stem || lowerBase.hasPrefix(stem + ".") else { return nil }
        let format: SubtitleFormat
        var reason: String?
        switch ext {
        case _ where supportedExtensions.contains(ext):
            guard let parsed = SubtitleFormat(fileExtension: ext) else { return nil }
            format = parsed
        case "idx":
            format = .vobsub
            reason = vobSubReason
        case "sub":
            // A .sub without a sibling .idx is MicroDVD text, which Reel does not read; skip it.
            // With an .idx, the .idx stands for the pair.
            return nil
        case "sup":
            format = .sup
            reason = supReason
        default:
            return nil
        }
        if ext == "idx", !siblings.contains((base + ".sub").lowercased()) { return nil }
        let rest = base.dropFirst(stem.count)
        let tokens = rest.split(separator: ".").map(String.init)
        var subtitle = ExternalSubtitle(url: url, format: format, unsupportedReason: reason)
        var languages: [String] = []
        var maybeHindi = false
        for token in tokens {
            switch token.lowercased() {
            case "forced": subtitle.isForced = true
            case "sdh", "cc": subtitle.isHearingImpaired = true
            case "hi":
                subtitle.isHearingImpaired = true
                maybeHindi = true
            case "default": subtitle.isDefault = true
            default:
                for part in token.split(whereSeparator: { $0 == "&" || $0 == "+" || $0 == "," }).map(String.init)
                where LanguageTag(part) != nil {
                    languages.append(part)
                }
            }
        }
        // "movie.hi.srt" with no other language is Hindi; "movie.en.hi.srt" is hearing impaired.
        if maybeHindi, languages.isEmpty {
            languages = ["hi"]
            subtitle.isHearingImpaired = false
        }
        subtitle.language = languages.first
        subtitle.extraLanguages = Array(languages.dropFirst())
        return subtitle
    }
}
