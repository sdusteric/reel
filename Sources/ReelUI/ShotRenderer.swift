import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ReelCore
import SwiftUI
import UniformTypeIdentifiers

/// The background screenshot scenarios (design 14 and 15.2): the M1 four and the M2 surfaces.
nonisolated public enum ShotScenario: String, CaseIterable, Sendable {
    case empty
    /// Controller and title visible while playing.
    case playing
    /// Paused with the volume OSD.
    case pausedOSD = "paused-osd"
    /// Dragging the seek bar: hover pill and grown track.
    case scrubbing
    /// The subtitle panel open with seven tracks (mockup png/02).
    case subtitlePanel = "subtitle-panel"
    /// The audio panel open with four tracks (png/03).
    case audioPanel = "audio-panel"
    /// The speed panel open at 1.5x (png/04).
    case speedPanel = "speed-panel"
    /// The hover container with a thumbnail above the seek bar (png/05).
    case thumbnail
    /// Subtitles with the controller moved to the top, so they sit at the default position (png/07).
    case subtitles
    /// Subtitles lifted above a visible controller (png/09).
    case subtitlesLifted = "subtitles-lifted"
    /// The speed OSD with the changed speed label (png/10).
    case osdSpeed = "osd-speed"
    /// The A-B loop OSD with marks on the seek bar (png/12).
    case osdLoop = "osd-loop"
    /// The end of an episode: Replay, the lit next button and the countdown card (png/14).
    case nextEpisode = "next-episode"
    /// Fullscreen layout: controller 56 pt from the bottom, "Ends at" time (png/15).
    case fullscreen
    /// A file alone in its folder with no subtitles: no previous or next, empty subtitle panel (png/18).
    case edgeStates = "edge-states"
    // M3 (design 15.3, mockups png/19 to png/26)
    /// The HDR10 tag after the title (png/19).
    case hdrBadge = "hdr-badge"
    /// Video Info open on a Dolby Vision 8.1 file (png/20).
    case videoInfo = "video-info"
    /// HDR10 on a display without headroom: the tag gains "SDR" and its tooltip shows (png/21).
    case hdrSDR = "hdr-sdr"
    /// The Dolby Vision profile 5 note and the warning tag (png/22).
    case dvNote = "dv-note"
    /// The failure card on black (png/23).
    case openFailed = "open-failed"
    /// A file cut short: the faint tail, the tick and the pill over the tail (png/24).
    case truncated
    /// The damaged-data OSD (png/25).
    case damagedOSD = "damaged-osd"
    /// A disconnected drive: the dimmed last frame and the card (png/26).
    case driveGone = "drive-gone"

    /// Where the controller sits (centre x, bottom y as fractions); nil keeps the remembered default.
    var controllerPosition: (centerX: Double, bottomY: Double)? {
        switch self {
        case .subtitles: (0.5, 0.82)
        default: nil
        }
    }

    /// Scenarios that draw subtitles.
    var drawsSubtitles: Bool { self == .subtitles || self == .subtitlesLifted }

    var isFullscreen: Bool { self == .fullscreen }

    /// The scenario shows a decoded frame (the open failure sits on black).
    var showsFrame: Bool { self != .empty && self != .openFailed }

    /// The title the mockup uses for the scenario.
    @MainActor var defaultTitle: String {
        switch self {
        case .hdrBadge, .hdrSDR: "Northern.Line.S03E01.2160p.UHD.BluRay.HDR10.x265-RLS.mkv"
        case .videoInfo: "Northern.Line.S03E02.2160p.UHD.BluRay.DV.HDR10.x265-RLS.mkv"
        case .dvNote: "Harbour.Lights.2024.2160p.WEB-DL.DV.H265-GRP.mp4"
        case .openFailed: "Northern.Line.S02E07.1080p.BluRay.x265.10bit-RLS.mkv"
        default: ShotRenderer.demoTitle
        }
    }

    /// The content range the scenario shows when the caller gives none.
    @MainActor var defaultDynamicRange: DynamicRange? {
        switch self {
        case .hdrBadge, .hdrSDR: .hdr10
        case .videoInfo: .dolbyVision(ShotRenderer.dolbyVision81)
        case .dvNote: .dolbyVision(ShotRenderer.dolbyVision5)
        default: nil
        }
    }

    /// The display the scenario shows when the caller gives none.
    var defaultDisplay: DisplayCapabilities {
        self == .hdrSDR ? .sdr : .xdr
    }
}

nonisolated public enum ShotAppearance: String, CaseIterable, Sendable {
    case light, dark

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var appearanceName: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
}

nonisolated public struct ShotOptionsError: Error, Equatable, Sendable {
    public var message: String
}

/// `--shot <scenario> --appearance light|dark --size WxH --out path [--fixture file --at seconds]
/// [--duration seconds]`. Sizes are points; the PNG is twice as large.
nonisolated public struct ShotOptions: Equatable, Sendable {
    public var scenario: ShotScenario
    public var appearance: ShotAppearance
    public var size: CGSize
    public var output: URL
    public var fixture: URL?
    public var at: Double
    public var duration: Double

    public static let defaultSize = CGSize(width: 1280, height: 720)
    public static let defaultAt: Double = 12
    public static let defaultDuration: Double = 60

    public init(
        scenario: ShotScenario,
        appearance: ShotAppearance,
        size: CGSize = ShotOptions.defaultSize,
        output: URL,
        fixture: URL? = nil,
        at: Double = ShotOptions.defaultAt,
        duration: Double = ShotOptions.defaultDuration
    ) {
        self.scenario = scenario
        self.appearance = appearance
        self.size = size
        self.output = output
        self.fixture = fixture
        self.at = at
        self.duration = duration
    }

    public static func parse(_ arguments: [String], currentDirectory: URL) -> Result<ShotOptions, ShotOptionsError> {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else {
                return .failure(ShotOptionsError(message: "unexpected argument \(flag)"))
            }
            guard index + 1 < arguments.count else {
                return .failure(ShotOptionsError(message: "\(flag) needs a value"))
            }
            values[String(flag.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        let known: Set<String> = ["shot", "appearance", "size", "out", "fixture", "at", "duration"]
        if let unknown = values.keys.sorted().first(where: { !known.contains($0) }) {
            return .failure(ShotOptionsError(message: "unknown option --\(unknown)"))
        }
        guard let scenarioName = values["shot"], let scenario = ShotScenario(rawValue: scenarioName) else {
            let names = ShotScenario.allCases.map(\.rawValue).joined(separator: "|")
            return .failure(ShotOptionsError(message: "--shot must be one of \(names)"))
        }
        guard let appearance = ShotAppearance(rawValue: values["appearance"] ?? "light") else {
            return .failure(ShotOptionsError(message: "--appearance must be light or dark"))
        }
        var size = defaultSize
        if let text = values["size"] {
            let parts = text.lowercased().split(separator: "x")
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
                  width >= 64, height >= 64, width <= 8192, height <= 8192 else {
                return .failure(ShotOptionsError(message: "--size must look like 1280x720"))
            }
            size = CGSize(width: width, height: height)
        }
        guard let out = values["out"], !out.isEmpty else {
            return .failure(ShotOptionsError(message: "--out <png> is required"))
        }
        var at = defaultAt
        if let text = values["at"] {
            guard let value = Double(text), value.isFinite, value >= 0 else {
                return .failure(ShotOptionsError(message: "--at must be seconds"))
            }
            at = value
        }
        var duration = max(defaultDuration, at)
        if let text = values["duration"] {
            guard let value = Double(text), value.isFinite, value > 0 else {
                return .failure(ShotOptionsError(message: "--duration must be seconds"))
            }
            duration = value
        }
        return .success(ShotOptions(
            scenario: scenario,
            appearance: appearance,
            size: size,
            output: URL(filePath: out, relativeTo: currentDirectory).absoluteURL,
            fixture: values["fixture"].map { URL(filePath: $0, relativeTo: currentDirectory).absoluteURL },
            at: at,
            duration: duration
        ))
    }
}

/// Renders `PlayerSceneView` to an image with `ImageRenderer`: no window, no run loop
/// (design 14, D15, D16). The video surface is a SwiftUI `Image` of a decoded frame.
public enum ShotRenderer {
    public static let scale: CGFloat = 2
    public static let demoTitle = "Northern.Line.S02E05.1080p.BluRay.x265.10bit-RLS.mkv"

    /// A model in the state the scenario shows. It has no engine and never opens a file.
    /// `thumbnail` is the seek-bar and card picture.
    public static func makeModel(
        scenario: ShotScenario,
        title: String,
        position: MediaTime,
        duration: MediaTime,
        thumbnail: CGImage? = nil,
        dynamicRange: DynamicRange? = nil,
        display: DisplayCapabilities? = nil,
        problem: MediaProblem? = nil,
        problemDetail: String? = nil,
        dataEnd: MediaTime? = nil
    ) -> PlayerModel {
        let clock = ShotClock()
        let model = PlayerModel(dependencies: PlayerModel.Dependencies(
            makeEngine: { _ in StillEngine() },
            wallClock: { Date(timeIntervalSinceReferenceDate: 800_000_000) },
            now: { clock.now },
            sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) }
        ))
        guard scenario != .empty else { return model }
        let url = URL(filePath: "/Show/\(title)")
        if scenario == .openFailed {
            model.title = title
            model.problem = problem ?? .cutShort
            model.problemDetail = problemDetail ?? demoFailureDetail
            model.playbackState = .failed
            return model
        }
        let range = dynamicRange ?? scenario.defaultDynamicRange ?? .sdr
        model.media = demoMedia(url: url, duration: duration, range: range)
        model.dynamicRange = range
        model.videoDecoder = .hardware
        model.displayCapabilities = display ?? scenario.defaultDisplay
        model.title = title
        model.position = min(position, duration)
        model.storedRange = max(.zero, model.position - .seconds(8))...min(duration, model.position + .seconds(20))
        model.volume = 52
        model.tracks = scenario == .edgeStates ? demoTracks(subtitles: false) : demoTracks(subtitles: true)
        if scenario != .edgeStates {
            model.episodes = demoEpisodes(current: url)
        }
        if let position = scenario.controllerPosition {
            model.controllerCenterX = position.centerX
            model.controllerBottomY = position.bottomY
        }
        model.isFullscreen = scenario.isFullscreen
        model.playbackState = .playing
        model.isPlaying = true
        switch scenario {
        case .empty, .playing, .fullscreen, .subtitles, .subtitlesLifted:
            break
        case .edgeStates:
            model.activePanel = .subtitles
        case .pausedOSD:
            model.playbackState = .paused
            model.isPlaying = false
            model.osd = OSDMessage(kind: .volume, text: "Volume 52")
        case .scrubbing:
            model.playbackState = .seeking
            model.isScrubbing = true
            model.seekHoverFraction = model.fraction(of: model.position)
        case .subtitlePanel:
            model.activePanel = .subtitles
            model.panelHighlight = 4
        case .audioPanel:
            model.activePanel = .audio
            model.panelHighlight = 1
        case .speedPanel:
            model.rate = 1.5
            model.activePanel = .speed
        case .thumbnail:
            model.seekHoverFraction = 0.38
            model.hoverThumbnail = thumbnail ?? placeholderFrame(width: 384, height: 216)
        case .osdSpeed:
            model.rate = 1.5
            model.osd = OSDMessage(kind: .speed, text: PlaybackSpeed.osdText(1.5))
        case .osdLoop:
            var loop = LoopState()
            loop.start = MediaTime(microseconds: Int64(Double(duration.microseconds) * 0.715))
            loop.end = MediaTime(microseconds: Int64(Double(duration.microseconds) * 0.74))
            model.loop = loop
            if let start = loop.start, let end = loop.end {
                model.position = MediaTime(microseconds: (start.microseconds + end.microseconds) / 2)
            }
            model.osd = OSDMessage(kind: .loop, text: loop.abOSDText(duration: duration))
        case .nextEpisode:
            model.playbackState = .ended
            model.isPlaying = false
            model.position = duration
            model.storedRange = nil
            if let next = model.episodes?.next {
                model.autoAdvance.begin(next: next)
                clock.now = 2
                model.autoAdvance.tick()
                model.autoAdvance.thumbnail = thumbnail ?? placeholderFrame(width: 384, height: 216)
            }
        case .hdrBadge:
            break
        case .videoInfo:
            model.videoInfoVisible = true
        case .hdrSDR:
            model.showsTagTooltip = true
        case .dvNote:
            model.dolbyVisionNoteVisible = true
        case .openFailed:
            break
        case .truncated:
            let end = dataEnd ?? MediaTime(microseconds: Int64(Double(duration.microseconds) * 0.86))
            model.dataEnd = end
            model.position = min(model.position, end)
            model.storedRange = max(.zero, model.position - .seconds(8))...min(end, model.position + .seconds(20))
            model.seekHoverFraction = 0.93
        case .damagedOSD:
            model.osd = OSDMessage(
                kind: .damaged,
                text: "Skipped damaged video at \(TimeFormat.clock(model.position, duration: duration))",
                symbol: OSDMessage.warningSymbol
            )
        case .driveGone:
            model.playbackState = .paused
            model.isPlaying = false
            model.storedRange = nil
            model.problem = problem ?? .volumeGone("Eric X9 Pro")
        }
        model.chrome.setPlaying(model.isPlaying)
        if model.activePanel != nil { model.chrome.setPanelOpen(true) }
        return model
    }

    /// The bottom inset the lifted-subtitle shot uses for a window of `size`, from the default
    /// style and the controller's frame. Nil outside that scenario. The app's shot mode passes
    /// this to the libass renderer so the real subtitles sit where the sample ones do.
    public static func subtitleLift(scenario: ShotScenario, size: CGSize) -> Double? {
        guard scenario == .subtitlesLifted else { return nil }
        let frame = ControllerLayout.frame(
            in: size,
            centerX: RememberedState.defaultControllerCenterX,
            bottomY: RememberedState.defaultControllerBottomY
        )
        return SubtitleAvoidance.inset(style: SubtitleStyle(), windowSize: size, controllerFrame: frame)
    }

    public static func render(
        scenario: ShotScenario,
        appearance: ShotAppearance,
        size: CGSize,
        frame: CGImage?,
        title: String? = nil,
        position: MediaTime = .seconds(ShotOptions.defaultAt),
        duration: MediaTime = .seconds(ShotOptions.defaultDuration),
        subtitleImage: CGImage? = nil,
        subtitleRect: CGRect? = nil,
        thumbnail: CGImage? = nil,
        dynamicRange: DynamicRange? = nil,
        display: DisplayCapabilities? = nil,
        problem: MediaProblem? = nil,
        problemDetail: String? = nil,
        dataEnd: MediaTime? = nil
    ) -> CGImage? {
        let model = makeModel(
            scenario: scenario,
            title: title ?? scenario.defaultTitle,
            position: position,
            duration: duration,
            thumbnail: thumbnail,
            dynamicRange: dynamicRange,
            display: display,
            problem: problem,
            problemDetail: problemDetail,
            dataEnd: dataEnd
        )
        var subtitle: ShotSubtitle?
        if scenario.drawsSubtitles || subtitleImage != nil {
            subtitle = ShotSubtitle(
                image: subtitleImage,
                rect: subtitleRect,
                liftInset: subtitleLift(scenario: scenario, size: size)
            )
        }
        let scene = PlayerSceneView(model: model, subtitle: subtitle) {
            if scenario.showsFrame, let frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, appearance.colorScheme)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        var image: CGImage?
        // Materials resolve against the drawing appearance as well as the SwiftUI colour scheme.
        NSAppearance(named: appearance.appearanceName)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return image
    }

    // MARK: Demo content

    /// Subtitles, audio and video of the mockup's "Northern Line" file. `subtitles: false` gives
    /// a file with none (png/18).
    static func demoTracks(subtitles: Bool) -> TrackState {
        let base = Rational(1, 1_000)
        var streams = [
            StreamInfo(index: 0, kind: .video, codec: "hevc", timeBase: base, video: VideoParameters(width: 1920, height: 1080)),
            StreamInfo(
                index: 1, kind: .audio, codec: "eac3", timeBase: base, language: "eng", isDefault: true,
                audio: AudioParameters(sampleRate: 48_000, channels: 6, channelLayout: "5.1(side)")
            ),
            StreamInfo(
                index: 2, kind: .audio, codec: "aac", timeBase: base, language: "jpn",
                audio: AudioParameters(sampleRate: 48_000, channels: 6, channelLayout: "5.1")
            ),
            StreamInfo(
                index: 3, kind: .audio, codec: "aac", timeBase: base, language: "cmn",
                audio: AudioParameters(sampleRate: 48_000, channels: 2, channelLayout: "stereo")
            ),
            StreamInfo(
                index: 4, kind: .audio, codec: "aac", timeBase: base, language: "eng", title: "Commentary",
                audio: AudioParameters(sampleRate: 48_000, channels: 2, channelLayout: "stereo")
            ),
        ]
        var external: [SubtitleTrack] = []
        if subtitles {
            streams += [
                StreamInfo(index: 5, kind: .subtitle, codec: "ass", timeBase: base, language: "zho", title: "\u{7B80}\u{82F1}\u{53CC}\u{8BED}", isDefault: true),
                StreamInfo(index: 6, kind: .subtitle, codec: "ass", timeBase: base, language: "zh-Hant", title: "\u{7E41}\u{82F1}\u{96D9}\u{8A9E}"),
                StreamInfo(index: 7, kind: .subtitle, codec: "subrip", timeBase: base, language: "eng"),
                StreamInfo(index: 8, kind: .subtitle, codec: "subrip", timeBase: base, language: "eng", title: "SDH", isHearingImpaired: true),
                StreamInfo(index: 9, kind: .subtitle, codec: "hdmv_pgs_subtitle", timeBase: base, language: "jpn"),
            ]
            external = [SubtitleTrack(
                id: .external(URL(filePath: "/Show/Northern.Line.S02E05.zh-Hans.srt")),
                language: "zh-Hans",
                format: .srt
            )]
        }
        let info = MediaInfo(
            url: URL(filePath: "/Show/\(demoTitle)"),
            formatName: "matroska,webm",
            streams: streams,
            videoStreamIndex: 0,
            audioStreamIndex: 1
        )
        var tracks = TrackState(info: info, external: external)
        if subtitles { tracks.selectedSubtitle = .embedded(streamIndex: 5) }
        return tracks
    }

    static let demoFailureDetail = "Matroska header found, then the file ends after 4 KB (FFmpeg: End of file)."

    /// Dolby Vision profile 8.1 (HDR10 base) and profile 5 (no compatible base), as the fixtures have them.
    static let dolbyVision81 = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 1)
    static let dolbyVision5 = DolbyVisionConfig(profile: 5, level: 6, rpu: true, el: false, bl: true, compatibilityID: 0)

    /// The file Video Info describes: 4K HEVC Main 10 with the colour fields of `range` and E-AC-3 5.1.
    static func demoMedia(url: URL, duration: MediaTime, range: DynamicRange) -> MediaInfo {
        var color = ColorInfo(primaries: "bt709", transfer: "bt709", matrix: "bt709")
        if range.isHDR || range.dolbyVision != nil {
            color = ColorInfo(primaries: "bt2020", transfer: DynamicRange.pqTransfer, matrix: "bt2020nc", hasHDRMetadata: true)
            if range.dolbyVisionBase == .hlg || range == .hlg { color.transfer = DynamicRange.hlgTransfer }
            if range != .hlg {
                color.mastering = .p3D65()
                color.contentLight = ContentLightLevel(maxCLL: 1_000, maxFALL: 400)
            }
        }
        let base = Rational(1, 1_000)
        let streams = [
            StreamInfo(
                index: 0, kind: .video, codec: "hevc", profile: "Main 10", timeBase: base,
                video: VideoParameters(width: 3_840, height: 2_160, frameRate: Rational(24_000, 1_001), bitDepth: 10, color: color)
            ),
            StreamInfo(
                index: 1, kind: .audio, codec: "eac3", timeBase: base, language: "eng", isDefault: true,
                audio: AudioParameters(sampleRate: 48_000, channels: 6, channelLayout: "5.1(side)")
            ),
        ]
        return MediaInfo(
            url: url,
            formatName: "matroska,webm",
            duration: duration,
            streams: streams,
            videoStreamIndex: 0,
            audioStreamIndex: 1,
            videoDecoder: .hardware,
            dolbyVision: range.dolbyVision
        )
    }

    /// Where light and dark must differ for `scenario`, in image pixels: the controller, which every
    /// shot but the open failure shows, or the title text for the open failure.
    public static func appearanceRegion(size: CGSize, scenario: ShotScenario) -> CGRect {
        if scenario == .openFailed {
            return CGRect(x: size.width * scale * 0.3, y: 0, width: size.width * scale * 0.4, height: 28 * scale)
        }
        return controllerPixelRect(size: size, scenario: scenario).insetBy(dx: 40, dy: 20)
    }

    /// Three files in one folder, so previous and next show and the card has a next name.
    static func demoEpisodes(current: URL) -> EpisodeList {
        let folder = current.deletingLastPathComponent()
        let siblings = ["Northern.Line.S02E04.mkv", "Northern.Line.S02E06.mkv"].map {
            folder.appending(path: $0, directoryHint: .notDirectory)
        }
        return EpisodeList(current: current, folderContents: siblings)
    }

    /// A stand-in frame when no decoder is available: a diagonal colour gradient.
    public static func placeholderFrame(width: Int = 1920, height: Int = 1080) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let colors = [
            CGColor(srgbRed: 0.10, green: 0.18, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.42, green: 0.30, blue: 0.52, alpha: 1),
            CGColor(srgbRed: 0.93, green: 0.55, blue: 0.32, alpha: 1),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: context.colorSpace, colors: colors, locations: [0, 0.55, 1]) else {
            return nil
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: CGFloat(width), y: 0),
            options: []
        )
        return context.makeImage()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ShotOptionsError(message: "cannot write \(url.path(percentEncoded: false))")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ShotOptionsError(message: "PNG encoding failed for \(url.path(percentEncoded: false))")
        }
    }

    /// The controller's frame in image pixels (origin top-left) for a shot of `size` points.
    public static func controllerPixelRect(
        size: CGSize,
        centerX: Double = RememberedState.defaultControllerCenterX,
        bottomY: Double = RememberedState.defaultControllerBottomY,
        fullscreen: Bool = false
    ) -> CGRect {
        let frame = ControllerLayout.frame(in: size, centerX: centerX, bottomY: bottomY, fullscreen: fullscreen)
        return CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
    }

    /// The controller's frame in image pixels where `scenario` puts it.
    public static func controllerPixelRect(size: CGSize, scenario: ShotScenario) -> CGRect {
        let position = scenario.controllerPosition
        return controllerPixelRect(
            size: size,
            centerX: position?.centerX ?? RememberedState.defaultControllerCenterX,
            bottomY: position?.bottomY ?? RememberedState.defaultControllerBottomY,
            fullscreen: scenario.isFullscreen
        )
    }

    public struct LuminanceStats: Sendable, Equatable {
        public var mean: Double
        public var standardDeviation: Double
        public var minimum: Double
        public var maximum: Double

        /// A blank image is one flat colour: every pixel within a few levels of the others.
        public var isBlank: Bool { maximum - minimum < 16 }
    }

    /// Luminance statistics (Rec. 709 weights, 0 to 255) over `rect` in pixels, origin top-left.
    public static func luminance(of image: CGImage, in rect: CGRect? = nil) -> LuminanceStats? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let region = (rect ?? bounds).integral.intersection(bounds)
        guard !region.isEmpty, let cropped = image.cropping(to: region) else { return nil }
        let width = cropped.width
        let height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var sum = 0.0
        var squares = 0.0
        var minimum = 255.0
        var maximum = 0.0
        let count = Double(width * height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let luma = 0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])
            sum += luma
            squares += luma * luma
            minimum = min(minimum, luma)
            maximum = max(maximum, luma)
        }
        let mean = sum / count
        return LuminanceStats(
            mean: mean,
            standardDeviation: max(0, squares / count - mean * mean).squareRoot(),
            minimum: minimum,
            maximum: maximum
        )
    }
}

/// A clock the shot moves by hand, so the countdown card shows a fixed "in 3 s".
private final class ShotClock {
    var now: TimeInterval = 0
}

/// The engine behind a screenshot model: it never opens anything.
private final class StillEngine: PlayerEngine {
    let events: AsyncStream<EngineEvent> = AsyncStream { $0.finish() }

    func open(_ url: URL) async throws -> MediaInfo {
        throw EngineError.notOpen
    }

    func play() async {}
    func pause() async {}
    func seek(_ request: SeekRequest) async {}
    func setVolume(_ volume: Double) async {}
    func setMuted(_ muted: Bool) async {}
    func close() async {}
}
