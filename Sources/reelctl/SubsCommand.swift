import CoreGraphics
import CReelDeps
import Foundation
import ImageIO
import ReelCore
import ReelEngine
import UniformTypeIdentifiers

/// `reelctl subs <file> [--track <streamIndex|lang|external>] [--external <path>] [--no-external]
/// [--at <s>] [--size WxH] [--frames N] [--out png] [--dump-text] [--json]` (design section 16).
///
/// Lists the subtitle tracks (embedded plus sidecars), selects one the way the player does (or as
/// `--track` says) and reports why, the charset, and with `--at` the ink, bounding box, missing
/// glyphs, fonts and render time of the subtitle at that time. `<file>` may also be a subtitle
/// file. Headless: no window, no audio.
enum SubsCommand {
    struct TrackRow: Encodable {
        var id: String
        var language: String?
        var title: String?
        var format: String
        var label: String
        var detail: String?
        var isDefault: Bool
        var isForced: Bool
        var isExternal: Bool
        var supported: Bool

        enum CodingKeys: String, CodingKey {
            case id, language, title, format, label, detail
            case isDefault = "default"
            case isForced = "forced"
            case isExternal = "external"
            case supported
        }
    }

    struct Box: Encodable {
        var x: Int
        var y: Int
        var w: Int
        var h: Int
    }

    struct Size: Encodable {
        var width: Int
        var height: Int
    }

    struct Timing: Encodable {
        var frames: Int
        var first: Double?
        var p50: Double?
        var p95: Double?
        var max: Double?

        init(first: Double?, samples: [Double]) {
            frames = samples.count
            self.first = first
            let sorted = samples.sorted()
            func rank(_ fraction: Double) -> Double? {
                guard !sorted.isEmpty else { return nil }
                let index = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
                return sorted[Swift.min(Swift.max(index, 0), sorted.count - 1)]
            }
            p50 = rank(0.5)
            p95 = rank(0.95)
            max = sorted.last
        }
    }

    struct EventRow: Encodable {
        var start: Double
        var end: Double
        var text: String
    }

    struct Report: Encodable {
        var file: String
        var tracks: [TrackRow]
        var selected: TrackRow?
        var reason: String
        var charset: String?
        var charsetRecognised: Bool?
        var eventCount: Int
        var at: Double?
        var size: Size?
        var eventsAtTime: Int?
        var inkPixels: Int?
        var bbox: Box?
        var missingGlyphs: Int?
        var fonts: [String]?
        var fontFallbacks: [String]?
        var fontSubstitutions: [String: String]?
        var libassLog: [String]?
        var renderMs: Timing?
        var out: String?
        var text: String?
        var events: [EventRow]?

        enum CodingKeys: String, CodingKey {
            case file, tracks, selected, reason, charset
            case charsetRecognised = "charset_recognised"
            case eventCount = "event_count"
            case at, size
            case eventsAtTime = "events_at_time"
            case inkPixels = "ink_pixels"
            case bbox
            case missingGlyphs = "missing_glyphs"
            case fonts
            case fontFallbacks = "font_fallbacks"
            case fontSubstitutions = "font_substitutions"
            case libassLog = "libass_log"
            case renderMs = "render_ms"
            case out, text, events
        }
    }

    static func run(_ arguments: CommandArguments) async throws -> Int32 {
        let file = try arguments.file()
        var report = try await makeReport(file, arguments: arguments)
        if !arguments.flags.contains("--dump-text") {
            report.text = nil
            report.events = nil
        }
        if arguments.json {
            try printJSON(report)
        } else {
            printText(report)
        }
        return report.selected == nil && !report.tracks.isEmpty ? 1 : 0
    }

    // MARK: Selection

    private struct Media {
        var tracks: [SubtitleTrack]
        var videoWidth: Int
        var videoHeight: Int
        var audioLanguage: String?
    }

    private static func makeReport(_ file: URL, arguments: CommandArguments) async throws -> Report {
        let media = try describe(file, arguments: arguments)
        let (choice, reason) = try select(media, arguments: arguments, file: file)
        var report = Report(file: file.lastPathComponent, tracks: media.tracks.enumerated().map { row($1, ordinal: $0 + 1) }, reason: reason, eventCount: 0)
        guard let choice else { return report }
        report.selected = row(choice, ordinal: (media.tracks.firstIndex(of: choice) ?? 0) + 1)
        let size = try outputSize(arguments, media: media)
        let at = try arguments.options["--at"].map { text -> Double in
            guard let value = Double(text), value >= 0 else { throw UsageError("--at must be a time in seconds") }
            return value
        }
        let frames = try arguments.int("--frames", default: 1)
        if choice.format.isBitmap {
            try reportBitmap(choice, file: file, media: media, at: at, size: size, frames: frames, arguments: arguments, into: &report)
        } else {
            try await reportText(choice, file: file, media: media, at: at, size: size, frames: frames, arguments: arguments, into: &report)
        }
        return report
    }

    private static func describe(_ file: URL, arguments: CommandArguments) throws -> Media {
        if ExternalSubtitleLoader.demuxerName(for: file.pathExtension) != nil {
            // The file is itself a subtitle file: it is the only track. Its name up to the first dot
            // stands for the video, so the remaining tokens parse as language and flags.
            let stem = file.lastPathComponent.split(separator: ".").first.map(String.init) ?? file.lastPathComponent
            let video = file.deletingLastPathComponent().appending(path: stem + ".mkv", directoryHint: .notDirectory)
            let parsed = ExternalSubtitles.discover(for: video, candidates: [file]).first
            let track = parsed?.track ?? SubtitleTrack(id: .external(file), format: SubtitleFormat(fileExtension: file.pathExtension) ?? .srt)
            return Media(tracks: [track], videoWidth: 1920, videoHeight: 1080, audioLanguage: nil)
        }
        let source = try MediaSource(url: file)
        var tracks: [SubtitleTrack] = []
        for index in 0..<source.streamCount {
            guard var info = source.streamInfo(index, video: nil) else { continue }
            if let stream = source.stream(index) {
                info.isHearingImpaired = (stream.pointee.disposition & AV_DISPOSITION_HEARING_IMPAIRED) != 0
            }
            if let track = SubtitleTrack(stream: info) { tracks.append(track) }
        }
        var external: [SubtitleTrack] = []
        if !arguments.flags.contains("--no-external") {
            external = ExternalSubtitles.scan(for: file).map(\.track)
        }
        if let path = arguments.options["--external"] {
            let url = URL(filePath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { throw UsageError("no such file: \(path)") }
            let parsed = ExternalSubtitles.discover(for: file, candidates: [url]).first?.track
                ?? SubtitleTrack(id: .external(url), format: SubtitleFormat(fileExtension: url.pathExtension) ?? .other)
            if !external.contains(where: { $0.id == parsed.id }) { external.append(parsed) }
        }
        let video = source.videoStreamIndex.flatMap { source.streamInfo($0, video: nil)?.video }
        let audio = source.audioStreamIndex.flatMap { source.streamInfo($0, video: nil)?.language }
        return Media(tracks: tracks + external, videoWidth: video?.width ?? 1920, videoHeight: video?.height ?? 1080, audioLanguage: audio)
    }

    private static func select(_ media: Media, arguments: CommandArguments, file: URL) throws -> (SubtitleTrack?, String) {
        let tracks = media.tracks
        if tracks.count == 1, case .external(let url) = tracks[0].id, url == file {
            return (tracks[0], "the file is a subtitle file")
        }
        if let wanted = arguments.options["--track"] {
            if let index = Int(wanted) {
                guard let track = tracks.first(where: { $0.id == .embedded(streamIndex: index) }) else {
                    throw UsageError("no subtitle stream \(index)")
                }
                return (track, "--track \(index)")
            }
            if wanted.lowercased() == "external" {
                let explicit = arguments.options["--external"].map { URL(filePath: $0).standardizedFileURL }
                let track = tracks.first { $0.id == explicit.map(TrackID.external) } ?? tracks.first { $0.isExternal && $0.isSupported }
                guard let track else { throw UsageError("no external subtitle file") }
                return (track, "--track external")
            }
            guard let tag = LanguageTag(wanted) else { throw UsageError("--track takes a stream index, a language or external") }
            let matching = tracks.filter { $0.isSupported && $0.languageTag?.code == tag.code }
            guard let track = matching.first(where: { !$0.isForced }) ?? matching.first else {
                throw UsageError("no subtitle track in \(tag.displayName())")
            }
            return (track, "--track \(wanted)")
        }
        guard let id = TrackPreference.defaultSubtitle(tracks, audioLanguage: media.audioLanguage),
              let track = tracks.first(where: { $0.id == id }) else {
            // The player starts with subtitles off here; the tool still inspects the first track.
            guard let first = tracks.first(where: \.isSupported) else {
                return (nil, tracks.isEmpty ? "no subtitle tracks" : "no supported subtitle track")
            }
            return (first, "no Chinese or English track, so the player starts with subtitles off; showing the first track")
        }
        return (track, preferenceReason(track, among: tracks))
    }

    /// Why `TrackPreference` chose `track` (design section 8.2).
    private static func preferenceReason(_ track: SubtitleTrack, among tracks: [SubtitleTrack]) -> String {
        var parts: [String] = []
        let language = track.languageTag
        parts.append(language?.isChinese == true ? "Chinese is preferred first (subLang zho,eng)" : "English is the first preferred language present")
        if language?.isChinese == true, let script = track.chineseScript {
            parts.append(script == .simplified ? "Simplified before Traditional" : "Traditional, no Simplified track")
        }
        let rivals = tracks.filter { $0.id != track.id && $0.languageTag?.code == language?.code && $0.isSupported && !$0.isForced }
        if track.isExternal, rivals.contains(where: { !$0.isExternal }) {
            parts.append("an external file beats an embedded track of the same language (D29)")
        }
        if track.isDefault { parts.append("container default") }
        if track.isForced { parts.append("forced track matching the audio language") }
        return parts.joined(separator: "; ")
    }

    private static func row(_ track: SubtitleTrack, ordinal: Int) -> TrackRow {
        let label = track.label(ordinal: ordinal)
        return TrackRow(
            id: track.id.description,
            language: track.language,
            title: track.title,
            format: label.tag,
            label: label.title,
            detail: label.detail,
            isDefault: track.isDefault,
            isForced: track.isForced,
            isExternal: track.isExternal,
            supported: track.isSupported
        )
    }

    private static func outputSize(_ arguments: CommandArguments, media: Media) throws -> (width: Int, height: Int) {
        guard let text = arguments.options["--size"] else { return (media.videoWidth, media.videoHeight) }
        let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0, parts[0] <= 16_384, parts[1] <= 16_384 else {
            throw UsageError("--size must be WIDTHxHEIGHT")
        }
        return (parts[0], parts[1])
    }

    // MARK: Text tracks

    private static func reportText(
        _ track: SubtitleTrack,
        file: URL,
        media: Media,
        at: Double?,
        size: (width: Int, height: Int),
        frames: Int,
        arguments: CommandArguments,
        into report: inout Report
    ) async throws {
        let store = SubtitleTrackStore()
        switch track.id {
        case .external(let url):
            try ExternalSubtitleLoader.load(url, title: track.title, into: store)
        case .embedded(let index):
            let prefetcher = SubtitlePrefetcher(url: file, store: store, streams: [index])
            prefetcher.start()
            let outcome = await prefetcher.wait()
            if let error = outcome.error { throw EngineError.decoderFailed(error) }
        }
        guard let stored = store.track(track.id) else { throw EngineError.decoderFailed("no events decoded for \(track.id)") }
        report.charset = stored.charset.rawValue
        report.charsetRecognised = stored.charsetRecognised
        report.eventCount = stored.events.count
        let events = stored.events.map(\.event)
        report.events = events.map { EventRow(start: $0.start.seconds, end: $0.end.seconds, text: $0.plainText) }
        report.text = events.map(\.plainText).joined(separator: "\n")
        guard let at else { return }

        let renderer = try SubtitleRenderer()
        renderer.sync(with: store, track: track.id)
        let settings = SubtitleRenderSettings(frameWidth: size.width, frameHeight: size.height, videoWidth: media.videoWidth, videoHeight: media.videoHeight)
        let time = MediaTime.seconds(at)
        let firstStart = ContinuousClock.now
        let first = renderer.render(at: time, settings: settings)
        let firstMs = milliseconds(ContinuousClock.now - firstStart)
        var samples: [Double] = []
        for frame in 0..<frames {
            let started = ContinuousClock.now
            _ = renderer.render(at: time + .seconds(Double(frame) / 24), settings: settings)
            samples.append(milliseconds(ContinuousClock.now - started))
        }
        let pieces = first.bitmap.map { [($0.image, $0.rect)] } ?? []
        fill(&report, at: at, size: size, eventsAtTime: stored.events(at: time).count, pieces: pieces)
        let diagnostics = renderer.diagnostics
        report.missingGlyphs = diagnostics.missingGlyphs
        report.fonts = diagnostics.fonts
        report.fontFallbacks = diagnostics.fallbacks
        report.fontSubstitutions = diagnostics.substitutions
        if ReelEnvironment().debugLogging { report.libassLog = diagnostics.log }
        report.renderMs = Timing(first: firstMs, samples: samples)
        try writeOutput(arguments, size: size, pieces: pieces, into: &report)
    }

    // MARK: Bitmap tracks

    private static func reportBitmap(
        _ track: SubtitleTrack,
        file: URL,
        media: Media,
        at: Double?,
        size: (width: Int, height: Int),
        frames: Int,
        arguments: CommandArguments,
        into report: inout Report
    ) throws {
        guard case .embedded(let index) = track.id, track.isSupported else {
            throw EngineError.unsupportedCodec(track.unsupportedReason ?? "external bitmap subtitles")
        }
        let decoded = try BitmapSubtitles.decodeAll(url: file, streamIndex: index)
        report.eventCount = decoded.timeline.sets.filter { !$0.isClear }.count
        report.events = decoded.timeline.sets.map { set in
            EventRow(start: set.start.seconds, end: (set.end ?? set.start).seconds, text: set.isClear ? "(clear)" : "\(set.rects.count) bitmap(s)")
        }
        guard let at else { return }
        let videoRect = PixelRect.aspectFit(width: media.videoWidth, height: media.videoHeight, inWidth: size.width, height: size.height)
        func place(at time: MediaTime) -> [(CGImage, PixelRect)] {
            guard let set = decoded.timeline.active(at: time) else { return [] }
            let width = set.canvasWidth > 0 ? set.canvasWidth : decoded.canvasWidth
            let height = set.canvasHeight > 0 ? set.canvasHeight : decoded.canvasHeight
            return set.rects.map { rect in
                (rect.image, BitmapSubtitles.place(rect.rect, canvasWidth: width, canvasHeight: height, videoRect: videoRect))
            }
        }
        let time = MediaTime.seconds(at)
        let firstStart = ContinuousClock.now
        let pieces = place(at: time)
        let firstMs = milliseconds(ContinuousClock.now - firstStart)
        var samples: [Double] = []
        for frame in 0..<frames {
            let started = ContinuousClock.now
            _ = place(at: time + .seconds(Double(frame) / 24))
            samples.append(milliseconds(ContinuousClock.now - started))
        }
        fill(&report, at: at, size: size, eventsAtTime: pieces.count, pieces: pieces)
        report.missingGlyphs = 0
        report.fonts = []
        report.renderMs = Timing(first: firstMs, samples: samples)
        try writeOutput(arguments, size: size, pieces: pieces, into: &report)
    }

    // MARK: Output

    private static func fill(_ report: inout Report, at: Double, size: (width: Int, height: Int), eventsAtTime: Int, pieces: [(CGImage, PixelRect)]) {
        report.at = at
        report.size = Size(width: size.width, height: size.height)
        report.eventsAtTime = eventsAtTime
        let ink = SubtitleInk.measure(pieces, frameWidth: size.width, frameHeight: size.height)
        report.inkPixels = ink.pixels
        report.bbox = ink.bounds.map { Box(x: $0.x, y: $0.y, w: $0.width, h: $0.height) }
    }

    /// `--out`: the subtitle drawn over a mid-grey frame, as a PNG.
    private static func writeOutput(_ arguments: CommandArguments, size: (width: Int, height: Int), pieces: [(CGImage, PixelRect)], into report: inout Report) throws {
        guard let path = arguments.options["--out"] else { return }
        let url = URL(filePath: path).standardizedFileURL
        guard let image = SubtitleInk.composite(pieces, frameWidth: size.width, frameHeight: size.height, grey: 0.5),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EngineError.io("cannot write \(path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EngineError.io("cannot write \(path)") }
        report.out = url.path(percentEncoded: false)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func printText(_ report: Report) {
        print("file: \(report.file)")
        for track in report.tracks {
            let mark = track.id == report.selected?.id ? "*" : " "
            print("\(mark) \(track.id)  \(track.label)  \(track.format)\(track.detail.map { "  \($0)" } ?? "")")
        }
        print("selected: \(report.selected?.id ?? "off") (\(report.reason))")
        if let charset = report.charset { print("charset: \(charset)") }
        print("events: \(report.eventCount)")
        if let at = report.at {
            print("at \(at) s: \(report.eventsAtTime ?? 0) event(s), ink \(report.inkPixels ?? 0) px, bbox \(report.bbox.map { "\($0.x),\($0.y) \($0.w)x\($0.h)" } ?? "none")")
            print("missing glyphs: \(report.missingGlyphs ?? 0), fonts: \((report.fonts ?? []).joined(separator: ", "))")
            if let timing = report.renderMs {
                print("render ms over \(timing.frames) frame(s): p50 \(timing.p50 ?? 0), p95 \(timing.p95 ?? 0), first \(timing.first ?? 0)")
            }
        }
        if let text = report.text { print(text) }
    }
}
