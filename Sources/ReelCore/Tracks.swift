import Foundation

// Track identity, labels and the default choice (design section 8.2).

/// Identifies a subtitle source: an embedded stream or an external file.
public enum TrackID: Sendable, Hashable, Codable, CustomStringConvertible {
    case embedded(streamIndex: Int)
    case external(URL)

    public var description: String {
        switch self {
        case .embedded(let index): "embedded:\(index)"
        case .external(let url): "external:\(url.lastPathComponent)"
        }
    }
}

/// What the subtitle layer should show.
public enum SubtitleSelection: Sendable, Hashable, Codable {
    case off
    case embedded(streamIndex: Int)
    case external(URL)

    public init(_ id: TrackID?) {
        switch id {
        case nil: self = .off
        case .embedded(let index)?: self = .embedded(streamIndex: index)
        case .external(let url)?: self = .external(url)
        }
    }

    public var trackID: TrackID? {
        switch self {
        case .off: nil
        case .embedded(let index): .embedded(streamIndex: index)
        case .external(let url): .external(url)
        }
    }
}

/// Chinese script, from a language tag, a fansub tag or a title.
public enum ChineseScript: String, Sendable, Hashable, Codable {
    case simplified, traditional
}

/// A parsed language tag: ISO 639-1/2 codes, BCP 47 tags and fansub tags (`chs`, `cht`).
public struct LanguageTag: Sendable, Hashable, Codable, CustomStringConvertible {
    /// ISO 639-1 when one exists ("zh", "en", "ja"), else the lowercased 639-2/3 code.
    public var code: String
    /// Four-letter script subtag, title case ("Hans", "Hant").
    public var script: String?
    /// Region subtag, uppercase ("TW", "US").
    public var region: String?

    public init(code: String, script: String? = nil, region: String? = nil) {
        self.code = code
        self.script = script
        self.region = region
    }

    /// Parses `zho`, `chi`, `zh-Hans`, `zh_TW`, `en-US`, `chs`, `big5` and similar. Returns nil
    /// for text that is not a language (`1080p`, `forced`, `und`).
    public init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if let fansub = LanguageTag.fansubTags[lower] {
            self = fansub
            return
        }
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let first = parts.first?.lowercased(), let code = LanguageTag.normalizedCode(first) else { return nil }
        var script: String?
        var region: String?
        for part in parts.dropFirst() {
            if part.count == 4, part.allSatisfy(\.isLetter) {
                script = part.prefix(1).uppercased() + part.dropFirst().lowercased()
            } else if (part.count == 2 && part.allSatisfy(\.isLetter)) || (part.count == 3 && part.allSatisfy(\.isNumber)) {
                region = part.uppercased()
            } else {
                return nil
            }
        }
        self.init(code: code, script: script, region: region)
    }

    public var isChinese: Bool { code == "zh" }
    public var isEnglish: Bool { code == "en" }

    /// Simplified or Traditional for Chinese, from the script subtag or the region.
    public var chineseScript: ChineseScript? {
        guard isChinese else { return nil }
        switch script {
        case "Hans": return .simplified
        case "Hant": return .traditional
        default: break
        }
        switch region {
        case "TW", "HK", "MO": return .traditional
        case "CN", "SG": return .simplified
        default: return nil
        }
    }

    /// The English name: "Chinese (Simplified)", "English", "Portuguese (Brazil)".
    public func displayName(script override: ChineseScript? = nil) -> String {
        if let special = LanguageTag.specialNames[code] { return special }
        let locale = Locale(identifier: "en_US")
        let base = locale.localizedString(forLanguageCode: code) ?? code
        if isChinese {
            switch override ?? chineseScript {
            case .simplified?: return "\(base) (Simplified)"
            case .traditional?: return "\(base) (Traditional)"
            case nil: return base
            }
        }
        if let region, let regionName = locale.localizedString(forRegionCode: region) {
            return "\(base) (\(regionName))"
        }
        return base
    }

    public var description: String {
        [code, script, region].compactMap(\.self).joined(separator: "-")
    }

    // MARK: Tables

    private static let fansubTags: [String: LanguageTag] = [
        "chs": LanguageTag(code: "zh", script: "Hans"),
        "sc": LanguageTag(code: "zh", script: "Hans"),
        "gb": LanguageTag(code: "zh", script: "Hans"),
        "cht": LanguageTag(code: "zh", script: "Hant"),
        "tc": LanguageTag(code: "zh", script: "Hant"),
        "big5": LanguageTag(code: "zh", script: "Hant"),
        "简体": LanguageTag(code: "zh", script: "Hans"),
        "简中": LanguageTag(code: "zh", script: "Hans"),
        "簡體": LanguageTag(code: "zh", script: "Hans"),
        "繁体": LanguageTag(code: "zh", script: "Hant"),
        "繁體": LanguageTag(code: "zh", script: "Hant"),
        "繁中": LanguageTag(code: "zh", script: "Hant"),
    ]

    private static let specialNames: [String: String] = [
        "cmn": "Chinese (Mandarin)",
        "yue": "Chinese (Cantonese)",
    ]

    /// ISO 639-2 bibliographic codes that `Locale` does not map to 639-1.
    private static let bibliographic: [String: String] = [
        "chi": "zh", "fre": "fr", "ger": "de", "dut": "nl", "cze": "cs", "gre": "el", "per": "fa",
        "rum": "ro", "slo": "sk", "wel": "cy", "baq": "eu", "arm": "hy", "geo": "ka", "ice": "is",
        "mac": "mk", "mao": "mi", "may": "ms", "bur": "my", "tib": "bo", "alb": "sq",
    ]

    private static let notLanguages: Set<String> = ["und", "mul", "zxx", "mis", "unk", "non"]

    static func normalizedCode(_ lower: String) -> String? {
        guard (2...3).contains(lower.count), lower.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        if notLanguages.contains(lower) { return nil }
        if let mapped = bibliographic[lower] { return mapped }
        if specialNames[lower] != nil { return lower }
        if let alpha2 = Locale.LanguageCode(lower).identifier(.alpha2) {
            return alpha2
        }
        // A real code has an English name that differs from the code itself.
        guard let name = Locale(identifier: "en_US").localizedString(forLanguageCode: lower),
              name.lowercased() != lower else { return nil }
        return lower
    }
}

/// Subtitle formats and their tags (design section 8.2).
public enum SubtitleFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case ass, srt, vtt, tx3g, pgs, vobsub, dvb, sup, other

    /// From an FFmpeg codec name.
    public init(codec: String) {
        switch codec.lowercased() {
        case "ass", "ssa": self = .ass
        case "subrip", "srt": self = .srt
        case "webvtt", "vtt": self = .vtt
        case "mov_text", "tx3g": self = .tx3g
        case "hdmv_pgs_subtitle", "pgssub", "pgs": self = .pgs
        case "dvd_subtitle", "dvdsub", "vobsub": self = .vobsub
        case "dvb_subtitle", "dvbsub": self = .dvb
        default: self = .other
        }
    }

    /// From an external file extension.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "ass", "ssa": self = .ass
        case "srt": self = .srt
        case "vtt": self = .vtt
        case "idx", "sub": self = .vobsub
        case "sup": self = .sup
        default: return nil
        }
    }

    public var tag: String {
        switch self {
        case .ass: "ASS"
        case .srt: "SRT"
        case .vtt: "VTT"
        case .tx3g: "TX3G"
        case .pgs, .sup: "PGS"
        case .vobsub: "VobSub"
        case .dvb: "DVB"
        case .other: "Text"
        }
    }

    /// Bitmap formats are drawn as authored; the size factor does not apply (D35).
    public var isBitmap: Bool {
        switch self {
        case .pgs, .sup, .vobsub, .dvb: true
        case .ass, .srt, .vtt, .tx3g, .other: false
        }
    }

    /// Text formats without their own styling use Reel's default style (section 8.4).
    public var usesDefaultStyle: Bool {
        switch self {
        case .srt, .vtt, .tx3g, .other: true
        case .ass, .pgs, .sup, .vobsub, .dvb: false
        }
    }
}

/// Two lines and a tag for a panel row or menu item.
public struct TrackLabel: Sendable, Hashable {
    public var title: String
    public var detail: String?
    public var tag: String

    public init(title: String, detail: String? = nil, tag: String) {
        self.title = title
        self.detail = detail
        self.tag = tag
    }

    /// One line for a menu item: "Chinese (Simplified)  ASS, 简英双语".
    public var menuTitle: String { title }
    public var menuDetail: String {
        [tag, detail].compactMap(\.self).joined(separator: ", ")
    }
}

public struct SubtitleTrack: Sendable, Hashable, Identifiable {
    public var id: TrackID
    /// The raw language tag from the container or the file name.
    public var language: String?
    public var title: String?
    /// FFmpeg codec name for embedded tracks; nil for external files.
    public var codec: String?
    public var format: SubtitleFormat
    public var isDefault: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// Set when the track is listed but cannot be shown, e.g. VobSub files in M2.
    public var unsupportedReason: String?
    /// The charset the text was decoded with when it was not UTF-8 ("GB18030").
    public var charset: String?

    public init(
        id: TrackID,
        language: String? = nil,
        title: String? = nil,
        codec: String? = nil,
        format: SubtitleFormat,
        isDefault: Bool = false,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        unsupportedReason: String? = nil,
        charset: String? = nil
    ) {
        self.id = id
        self.language = language
        self.title = title
        self.codec = codec
        self.format = format
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.unsupportedReason = unsupportedReason
        self.charset = charset
    }

    /// From a container stream. Returns nil for non-subtitle streams.
    public init?(stream: StreamInfo) {
        guard stream.kind == .subtitle else { return nil }
        self.init(
            id: .embedded(streamIndex: stream.index),
            language: stream.language,
            title: stream.title,
            codec: stream.codec,
            format: SubtitleFormat(codec: stream.codec),
            isDefault: stream.isDefault,
            isForced: stream.isForced,
            isHearingImpaired: stream.isHearingImpaired
        )
    }

    public var isExternal: Bool {
        if case .external = id { return true }
        return false
    }

    public var isSupported: Bool { unsupportedReason == nil }

    public var languageTag: LanguageTag? { language.flatMap(LanguageTag.init) }

    /// Script from the language tag, else from the title ("简英双语", "CHS").
    public var chineseScript: ChineseScript? {
        if let script = languageTag?.chineseScript { return script }
        guard languageTag?.isChinese ?? true else { return nil }
        if let title, let script = TrackNaming.chineseScript(inTitle: title) { return script }
        if case .external(let url) = id { return TrackNaming.chineseScript(inTitle: url.lastPathComponent) }
        return nil
    }

    /// Hearing impaired from the flag or an `SDH` / `HI` token in the title.
    public var isSDH: Bool {
        isHearingImpaired || (title.map(TrackNaming.titleSaysSDH) ?? false)
    }

    public var identity: TrackIdentity {
        switch id {
        case .embedded(let index):
            TrackIdentity(streamIndex: index, language: language, title: title, codec: codec ?? format.rawValue)
        case .external(let url):
            TrackIdentity(externalFileName: url.lastPathComponent, language: language, title: title, codec: format.rawValue)
        }
    }

    /// The panel and menu label (design section 8.2, mockup png/02).
    public func label(ordinal: Int = 1) -> TrackLabel {
        let tag = languageTag
        var title: String
        var usedTitleAsLabel = false
        if let tag {
            title = tag.displayName(script: chineseScript)
        } else if let own = self.title, !own.isEmpty {
            title = own
            usedTitleAsLabel = true
        } else {
            title = "Track \(ordinal)"
        }
        if isSDH { title += " SDH" }
        var details: [String] = []
        if !usedTitleAsLabel, let extra = TrackNaming.informativeTitle(self.title, languageName: tag?.displayName(), formatTag: format.tag) {
            details.append(extra)
        }
        if isSDH { details.append("Hearing impaired") }
        if isDefault { details.append("Default") }
        if isForced { details.append("Forced") }
        if let charset { details.append(charset) }
        if case .external(let url) = id {
            details.append("External: " + TrackNaming.middleTruncated(url.lastPathComponent, maxLength: 44))
        }
        if let unsupportedReason { details.append(unsupportedReason) }
        return TrackLabel(title: title, detail: details.isEmpty ? nil : details.joined(separator: " · "), tag: format.tag)
    }
}

public struct AudioTrack: Sendable, Hashable, Identifiable {
    public var streamIndex: Int
    public var language: String?
    public var title: String?
    public var codec: String
    public var profile: String?
    public var channels: Int
    public var channelLayout: String?
    public var isDefault: Bool

    public var id: Int { streamIndex }

    public init(
        streamIndex: Int,
        language: String? = nil,
        title: String? = nil,
        codec: String,
        profile: String? = nil,
        channels: Int,
        channelLayout: String? = nil,
        isDefault: Bool = false
    ) {
        self.streamIndex = streamIndex
        self.language = language
        self.title = title
        self.codec = codec
        self.profile = profile
        self.channels = channels
        self.channelLayout = channelLayout
        self.isDefault = isDefault
    }

    public init?(stream: StreamInfo) {
        guard stream.kind == .audio else { return nil }
        self.init(
            streamIndex: stream.index,
            language: stream.language,
            title: stream.title,
            codec: stream.codec,
            profile: stream.profile,
            channels: stream.audio?.channels ?? 0,
            channelLayout: stream.audio?.channelLayout,
            isDefault: stream.isDefault
        )
    }

    public var languageTag: LanguageTag? { language.flatMap(LanguageTag.init) }

    public var identity: TrackIdentity {
        TrackIdentity(streamIndex: streamIndex, language: language, title: title, codec: codec)
    }

    /// "E-AC-3 5.1", "AAC 2.0", "TrueHD 7.1".
    public var formatTag: String {
        let name = TrackNaming.audioCodecName(codec, profile: profile)
        guard let channels = TrackNaming.channelText(channels: channels, layout: channelLayout) else { return name }
        return "\(name) \(channels)"
    }

    public func label(ordinal: Int = 1) -> TrackLabel {
        let tag = languageTag
        var title: String
        var usedTitleAsLabel = false
        if let tag {
            title = tag.displayName()
        } else if let own = self.title, !own.isEmpty {
            title = own
            usedTitleAsLabel = true
        } else {
            title = "Track \(ordinal)"
        }
        if title.isEmpty { title = "Track \(ordinal)" }
        var details: [String] = []
        if !usedTitleAsLabel, let extra = TrackNaming.informativeTitle(self.title, languageName: tag?.displayName(), formatTag: formatTag) {
            details.append(extra)
        }
        if isDefault { details.append("Default") }
        return TrackLabel(title: title, detail: details.isEmpty ? nil : details.joined(separator: " · "), tag: formatTag)
    }
}

public struct VideoTrack: Sendable, Hashable, Identifiable {
    public var streamIndex: Int
    public var codec: String
    public var width: Int
    public var height: Int
    public var title: String?
    public var isDefault: Bool

    public var id: Int { streamIndex }

    public init(streamIndex: Int, codec: String, width: Int, height: Int, title: String? = nil, isDefault: Bool = false) {
        self.streamIndex = streamIndex
        self.codec = codec
        self.width = width
        self.height = height
        self.title = title
        self.isDefault = isDefault
    }

    public init?(stream: StreamInfo) {
        guard stream.kind == .video, !stream.isAttachedPicture else { return nil }
        self.init(
            streamIndex: stream.index,
            codec: stream.codec,
            width: stream.video?.width ?? 0,
            height: stream.video?.height ?? 0,
            title: stream.title,
            isDefault: stream.isDefault
        )
    }
}

/// What a track was: enough to find "the same" track again in this file or the next episode.
public struct TrackIdentity: Sendable, Hashable, Codable {
    public var streamIndex: Int?
    public var externalFileName: String?
    public var language: String?
    public var title: String?
    public var codec: String?

    public init(
        streamIndex: Int? = nil,
        externalFileName: String? = nil,
        language: String? = nil,
        title: String? = nil,
        codec: String? = nil
    ) {
        self.streamIndex = streamIndex
        self.externalFileName = externalFileName
        self.language = language
        self.title = title
        self.codec = codec
    }

    /// Language normalised for matching: "zho", "chi" and "zh" are one language.
    var matchLanguage: String? {
        guard let language else { return nil }
        return LanguageTag(language)?.code ?? language.lowercased()
    }

    var matchTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The subtitle and audio tracks of the open file and the subtitle settings in force.
public struct TrackState: Sendable, Hashable {
    public var video: [VideoTrack]
    public var audio: [AudioTrack]
    /// Embedded tracks in container order, then external files.
    public var subtitles: [SubtitleTrack]
    public var selectedVideo: Int?
    public var selectedAudio: Int?
    public var selectedSubtitle: SubtitleSelection
    public var subtitlesVisible: Bool
    /// Seconds; positive shows subtitles later.
    public var subtitleDelay: Double
    /// Seconds; positive plays audio later.
    public var audioDelay: Double
    /// Font scale factor for text tracks (1 is size 45).
    public var subtitleScale: Double
    /// mpv `sub-pos`: 100 is the default bottom position, smaller moves up.
    public var subtitlePosition: Double

    public init(
        video: [VideoTrack] = [],
        audio: [AudioTrack] = [],
        subtitles: [SubtitleTrack] = [],
        selectedVideo: Int? = nil,
        selectedAudio: Int? = nil,
        selectedSubtitle: SubtitleSelection = .off,
        subtitlesVisible: Bool = true,
        subtitleDelay: Double = 0,
        audioDelay: Double = 0,
        subtitleScale: Double = 1,
        subtitlePosition: Double = SubtitleStyle.defaultPosition
    ) {
        self.video = video
        self.audio = audio
        self.subtitles = subtitles
        self.selectedVideo = selectedVideo
        self.selectedAudio = selectedAudio
        self.selectedSubtitle = selectedSubtitle
        self.subtitlesVisible = subtitlesVisible
        self.subtitleDelay = subtitleDelay
        self.audioDelay = audioDelay
        self.subtitleScale = subtitleScale
        self.subtitlePosition = subtitlePosition
    }

    /// Tracks of `info` plus external files, with the default subtitle chosen by `TrackPreference`.
    public init(info: MediaInfo, external: [SubtitleTrack] = []) {
        let subtitles = info.streams.compactMap(SubtitleTrack.init(stream:)) + external
        let audio = info.streams.compactMap(AudioTrack.init(stream:))
        let selectedAudio = info.audioStreamIndex
        let audioLanguage = audio.first { $0.streamIndex == selectedAudio }?.language
        self.init(
            video: info.streams.compactMap(VideoTrack.init(stream:)),
            audio: audio,
            subtitles: subtitles,
            selectedVideo: info.videoStreamIndex,
            selectedAudio: selectedAudio,
            selectedSubtitle: SubtitleSelection(TrackPreference.defaultSubtitle(subtitles, audioLanguage: audioLanguage))
        )
    }

    public var selectedSubtitleTrack: SubtitleTrack? {
        guard let id = selectedSubtitle.trackID else { return nil }
        return subtitles.first { $0.id == id }
    }

    public var selectedAudioTrack: AudioTrack? {
        guard let selectedAudio else { return nil }
        return audio.first { $0.streamIndex == selectedAudio }
    }

    /// The next subtitle choice for Ctrl+Cmd+S: Off, then each supported track, then Off.
    public func nextSubtitleSelection() -> SubtitleSelection {
        let choices: [SubtitleSelection] = [.off] + subtitles.filter(\.isSupported).map { SubtitleSelection($0.id) }
        guard let current = choices.firstIndex(of: selectedSubtitle) else { return choices.first ?? .off }
        return choices[(current + 1) % choices.count]
    }

    /// The next audio stream for Ctrl+Cmd+A, wrapping around.
    public func nextAudioStream() -> Int? {
        TrackState.cycle(audio.map(\.streamIndex), after: selectedAudio)
    }

    /// The next video stream for Ctrl+Cmd+V, wrapping around; nil with fewer than two.
    public func nextVideoStream() -> Int? {
        guard video.count > 1 else { return nil }
        return TrackState.cycle(video.map(\.streamIndex), after: selectedVideo)
    }

    private static func cycle(_ indices: [Int], after current: Int?) -> Int? {
        guard !indices.isEmpty else { return nil }
        guard let current, let position = indices.firstIndex(of: current) else { return indices.first }
        return indices[(position + 1) % indices.count]
    }
}

/// The default track choice and carry-over matching (design sections 8.2 and 9.8).
public enum TrackPreference {
    /// The user's IINA `subLang zho,eng`. Chinese first, then English; otherwise Off.
    public static func defaultSubtitle(_ tracks: [SubtitleTrack], audioLanguage: String? = nil) -> TrackID? {
        let candidates = tracks.enumerated().compactMap { offset, track -> (rank: [Int], track: SubtitleTrack)? in
            guard track.isSupported, let languageRank = languageRank(track.languageTag) else { return nil }
            let script: Int
            switch track.chineseScript {
            case .simplified?: script = 0
            case nil: script = 1
            case .traditional?: script = 2
            }
            let rank = [
                languageRank,
                track.isForced ? 1 : 0,
                track.languageTag?.isChinese == true ? script : 0,
                track.isExternal ? 0 : 1,
                track.isDefault ? 0 : 1,
                offset,
            ]
            return (rank, track)
        }
        let full = candidates.filter { !$0.track.isForced }
        if let best = full.min(by: { $0.rank.lexicographicallyPrecedes($1.rank) }) {
            return best.track.id
        }
        // Forced-only tracks qualify only when they match the audio and no full track exists.
        let audioCode = audioLanguage.flatMap(LanguageTag.init)?.code
        let forced = candidates.filter { $0.track.isForced && audioCode != nil && $0.track.languageTag?.code == audioCode }
        return forced.min(by: { $0.rank.lexicographicallyPrecedes($1.rank) })?.track.id
    }

    /// The default audio stream: the container default, then the first (section 7.2).
    public static func defaultAudio(_ tracks: [AudioTrack]) -> Int? {
        (tracks.first(where: \.isDefault) ?? tracks.first)?.streamIndex
    }

    /// Finds `identity` in `tracks` for the same file (resume): the same stream index or file
    /// name with the same language, else the carry-over match.
    public static func match(_ identity: TrackIdentity, in tracks: [SubtitleTrack], sameFile: Bool) -> TrackID? {
        let supported = tracks.filter(\.isSupported)
        if sameFile {
            if let index = identity.streamIndex,
               let track = supported.first(where: { $0.id == .embedded(streamIndex: index) }),
               track.identity.matchLanguage == identity.matchLanguage {
                return track.id
            }
            if let name = identity.externalFileName,
               let track = supported.first(where: { $0.identity.externalFileName == name }) {
                return track.id
            }
        }
        return carryOver(identity, candidates: supported.map { ($0.id, $0.identity) })
    }

    /// The audio stream matching `identity` (resume or carry-over).
    public static func match(_ identity: TrackIdentity, in tracks: [AudioTrack], sameFile: Bool) -> Int? {
        if sameFile, let index = identity.streamIndex,
           let track = tracks.first(where: { $0.streamIndex == index }),
           track.identity.matchLanguage == identity.matchLanguage {
            return index
        }
        return carryOver(identity, candidates: tracks.map { ($0.streamIndex, $0.identity) })
    }

    /// Language and title first, then language alone (section 9.8).
    static func carryOver<ID>(_ identity: TrackIdentity, candidates: [(ID, TrackIdentity)]) -> ID? {
        guard let language = identity.matchLanguage else {
            guard let title = identity.matchTitle else { return nil }
            return candidates.first { $0.1.matchTitle == title }?.0
        }
        let sameLanguage = candidates.filter { $0.1.matchLanguage == language }
        if let title = identity.matchTitle, let exact = sameLanguage.first(where: { $0.1.matchTitle == title }) {
            return exact.0
        }
        if let sameCodec = sameLanguage.first(where: { $0.1.codec == identity.codec && $0.1.matchTitle == identity.matchTitle }) {
            return sameCodec.0
        }
        return sameLanguage.first?.0
    }

    private static func languageRank(_ tag: LanguageTag?) -> Int? {
        guard let tag else { return nil }
        if tag.isChinese { return 0 }
        if tag.isEnglish { return 1 }
        return nil
    }
}

/// Start and end of one subtitle event, for next and previous line.
public struct SubtitleEventTime: Sendable, Hashable, Codable {
    public var start: MediaTime
    public var end: MediaTime

    public init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.end = end
    }
}

/// Next and previous line (Shift+Right / Shift+Left), like libass `ass_step_sub`.
public enum SubtitleLines {
    /// Events closer than this to `time` count as "at" it, so a repeat press moves on.
    static let tolerance = MediaTime.milliseconds(1)

    /// The start of the first event that starts after `time`.
    public static func next(after time: MediaTime, in events: [SubtitleEventTime]) -> MediaTime? {
        events.map(\.start).filter { $0 > time + tolerance }.min()
    }

    /// The start of the event before the one showing (or last shown) at `time`.
    public static func previous(before time: MediaTime, in events: [SubtitleEventTime]) -> MediaTime? {
        let starts = Set(events.map(\.start)).sorted()
        guard let current = starts.lastIndex(where: { $0 <= time + tolerance }) else { return nil }
        let showing = events.contains { $0.start == starts[current] && $0.end > time }
        if showing {
            return current > 0 ? starts[current - 1] : nil
        }
        return starts[current]
    }
}

/// Text helpers shared by the labels and the external file parser.
enum TrackNaming {
    static func titleTokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func chineseScript(inTitle title: String) -> ChineseScript? {
        if title.contains("繁") || title.contains("正體") { return .traditional }
        if title.contains("简") || title.contains("簡") { return .simplified }
        let tokens = Set(titleTokens(title))
        let traditional: Set<String> = ["cht", "tc", "big5", "hant", "traditional"]
        let simplified: Set<String> = ["chs", "sc", "gb", "hans", "simplified", "gbk"]
        if !tokens.isDisjoint(with: traditional) { return .traditional }
        if !tokens.isDisjoint(with: simplified) { return .simplified }
        let lower = title.lowercased()
        if lower.contains("zh-hant") || lower.contains("zh-tw") || lower.contains("zh-hk") { return .traditional }
        if lower.contains("zh-hans") || lower.contains("zh-cn") { return .simplified }
        return nil
    }

    static func titleSaysSDH(_ title: String) -> Bool {
        let tokens = titleTokens(title)
        return tokens.contains("sdh") || tokens.contains("hi") || title.lowercased().contains("hearing impaired")
    }

    /// The container title when it says something the language and tag do not.
    static func informativeTitle(_ title: String?, languageName: String?, formatTag: String) -> String? {
        guard let title else { return nil }
        var tokens = titleTokens(title)
        tokens.removeAll { ["sdh", "hi", "forced", "default"].contains($0) }
        let remainder = tokens.joined(separator: " ")
        if remainder.isEmpty { return nil }
        let ignored = [languageName, formatTag].compactMap { $0.map { titleTokens($0).joined(separator: " ") } }
        if ignored.contains(remainder) { return nil }
        if let languageName, remainder == titleTokens(languageName).first { return nil }
        if title.lowercased().contains("hearing impaired"), remainder == "hearing impaired" { return nil }
        return title.trimmingCharacters(in: .whitespaces)
    }

    static func audioCodecName(_ codec: String, profile: String?) -> String {
        if let profile {
            switch profile {
            case "DTS-HD MA": return "DTS-HD MA"
            case "DTS-HD HRA": return "DTS-HD HRA"
            case "DTS:X": return "DTS:X"
            default: break
            }
        }
        let names: [String: String] = [
            "aac": "AAC", "ac3": "AC-3", "eac3": "E-AC-3", "truehd": "TrueHD", "mlp": "MLP", "dts": "DTS",
            "opus": "Opus", "flac": "FLAC", "mp3": "MP3", "mp3float": "MP3", "mp2": "MP2", "vorbis": "Vorbis",
            "alac": "ALAC", "wmav2": "WMA",
        ]
        if let name = names[codec.lowercased()] { return name }
        if codec.lowercased().hasPrefix("pcm_") { return "PCM" }
        return codec.uppercased()
    }

    static func channelText(channels: Int, layout: String?) -> String? {
        if let layout {
            let base = layout.split(separator: "(").first.map(String.init) ?? layout
            switch base {
            case "mono": return "1.0"
            case "stereo", "downmix": return "2.0"
            default:
                if base.split(separator: ".").count == 2, base.allSatisfy({ $0.isNumber || $0 == "." }) { return base }
            }
        }
        switch channels {
        case ..<1: return nil
        case 1: return "1.0"
        case 2: return "2.0"
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    static func middleTruncated(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength, maxLength > 2 else { return text }
        let head = (maxLength - 1) / 2
        let tail = maxLength - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }
}
