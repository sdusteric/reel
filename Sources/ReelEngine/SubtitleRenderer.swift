import CoreGraphics
import CoreText
import CReelDeps
import Foundation
import ReelCore
import Synchronization

/// What libass said while one renderer worked: glyphs it could not find and the faces it chose.
public struct SubtitleRenderDiagnostics: Sendable, Hashable {
    /// "Glyph ... not found" messages (section 8.7); zero for the Chinese fixtures.
    public var missingGlyphs = 0
    /// Font faces selected, by PostScript name ("PingFangSC-Regular"), in first-use order.
    public var fonts: [String] = []
    /// Families that fell back to another face, logged once per family (section 8.4).
    public var fallbacks: [String] = []
    /// Families replaced because FreeType cannot draw them (PingFang on macOS 27), with the
    /// family used instead.
    public var substitutions: [String: String] = [:]
    /// The first messages libass sent, for debugging (`REEL_LOG=debug` in reelctl).
    public var log: [String] = []
    static let logLimit = 200
}

/// Collects libass messages for one renderer. The C shim passes it as the thread's sink while the
/// renderer calls into libass, so messages land on the renderer that caused them.
final class SubtitleMessageSink: Sendable {
    private let state = Mutex(SubtitleRenderDiagnostics())

    var diagnostics: SubtitleRenderDiagnostics { state.withLock { $0 } }

    func record(level: Int32, message: String) {
        state.withLock { diagnostics in
            if diagnostics.log.count < SubtitleRenderDiagnostics.logLimit { diagnostics.log.append("[\(level)] \(message)") }
        }
        if message.hasPrefix("Glyph "), message.contains("not found") {
            state.withLock { $0.missingGlyphs += 1 }
        }
        guard message.hasPrefix("fontselect:"), let arrow = message.range(of: "-> ") else { return }
        let parts = message[arrow.upperBound...].components(separatedBy: ", ")
        var face = parts.last ?? ""
        if face.isEmpty || face == "(none)" {
            face = URL(filePath: parts.first ?? "").lastPathComponent
        }
        let requested = message.range(of: "(").map { start -> String in
            let rest = message[start.upperBound...]
            return String(rest.prefix { $0 != "," })
        }
        state.withLock { diagnostics in
            if !face.isEmpty, !diagnostics.fonts.contains(face) { diagnostics.fonts.append(face) }
            if let requested, !face.lowercased().replacingOccurrences(of: " ", with: "")
                .hasPrefix(requested.lowercased().replacingOccurrences(of: " ", with: "")),
               !diagnostics.fallbacks.contains(requested) {
                diagnostics.fallbacks.append(requested)
            }
        }
    }

    func reset() {
        state.withLock { $0 = SubtitleRenderDiagnostics() }
    }

    func recordSubstitution(_ family: String, _ replacement: String) {
        state.withLock { $0.substitutions[family] = replacement }
    }
}

/// Font families libass can draw. libass draws through FreeType, and on macOS 27 PingFang ships
/// only with `hvgl` outlines (PingFangUI.ttc), which FreeType cannot read: CoreText still lists
/// the family, so libass would pick it, fail to open it and show boxes. `PingFangFaces` rebuilds
/// PingFang SC, TC, HK and MO Medium from CoreText's outlines and registers them with libass; only if
/// that fails are the families replaced with the closest installed CJK sans.
enum SubtitleFonts {
    static let preferredFamily = SubtitleStyle.fontName

    /// PingFang rebuilt for FreeType, or nil when it could not be built.
    static let pingFang: PingFangFaces.Collection? = PingFangFaces.load(cacheDirectory: cacheDirectory)

    /// `REEL_HOME/Caches/fonts`, only when `REEL_HOME` is set or this is the app itself, so a
    /// test or tool run without `REEL_HOME` never writes into the user's folders.
    static var cacheDirectory: URL? {
        let environment = ReelEnvironment()
        let explicitHome = !(environment.values["REEL_HOME"] ?? "").isEmpty
        guard explicitHome || Bundle.main.bundleIdentifier == "dev.sdusteric.reel" else { return nil }
        return environment.paths.cachesDirectory.appending(path: "fonts", directoryHint: .isDirectory)
    }

    private static let registered = Mutex(false)

    /// Loads or builds `pingFang` on a utility thread so the first render does not wait for it.
    static func prepareInBackground() {
        DispatchQueue.global(qos: .utility).async { _ = pingFang }
    }

    /// Adds the rebuilt PingFang faces to the shared library once, before renderers pick fonts.
    static func register(in library: OpaquePointer) {
        guard let pingFang else { return }
        reel_ass_library_lock()
        defer { reel_ass_library_unlock() }
        registered.withLock { done in
            guard !done else { return }
            done = true
            pingFang.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                ass_add_font(library, "PingFang (Reel)", base.assumingMemoryBound(to: CChar.self), Int32(raw.count))
            }
        }
    }

    private static let candidates: [String: [String]] = [
        "pingfang sc": ["Hiragino Sans GB", "Heiti SC", "Songti SC"],
        "pingfang tc": ["Heiti TC", "Hiragino Sans GB", "Songti TC"],
        "pingfang hk": ["Heiti TC", "Hiragino Sans GB", "Songti TC"],
        "pingfang mo": ["Heiti TC", "Hiragino Sans GB", "Songti TC"],
    ]

    /// Lowercased family to replacement, for the PingFang families that cannot be drawn here.
    static let substitutions: [String: String] = {
        var table: [String: String] = [:]
        for (family, options) in candidates where !(pingFang?.families.contains(family) ?? false) && !isDrawable(family) {
            if let replacement = options.first(where: isDrawable) { table[family] = replacement }
        }
        return table
    }()

    /// The family for Reel's default style and libass's default family.
    static var defaultFamily: String { substitute(preferredFamily) ?? preferredFamily }

    /// The replacement for `family` (a leading `@` for vertical text is kept), or nil to keep it.
    static func substitute(_ family: String) -> String? {
        let vertical = family.hasPrefix("@")
        let bare = (vertical ? String(family.dropFirst()) : family).trimmingCharacters(in: .whitespaces)
        guard let replacement = substitutions[bare.lowercased()] else { return nil }
        return vertical ? "@" + replacement : replacement
    }

    /// Replaces `\fn<family>` overrides that name a substituted family.
    static func rewriteOverrides(_ fields: String) -> String {
        guard !substitutions.isEmpty, fields.range(of: "\\fn", options: .caseInsensitive) != nil else { return fields }
        var result = fields
        for (family, replacement) in substitutions {
            result = result.replacingOccurrences(of: "\\fn" + family, with: "\\fn" + replacement, options: .caseInsensitive)
            result = result.replacingOccurrences(of: "\\fn@" + family, with: "\\fn@" + replacement, options: .caseInsensitive)
        }
        return result
    }

    /// True when CoreText resolves `family` to itself and the face has outlines FreeType reads.
    /// Only called for the known families above, never for arbitrary names from a file.
    static func isDrawable(_ family: String) -> Bool {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        let resolved = CTFontCopyFamilyName(font) as String
        guard resolved.caseInsensitiveCompare(family) == .orderedSame,
              let tables = CTFontCopyAvailableTables(font, []) else { return false }
        let drawable: Set<UInt32> = [fourCC("glyf"), fourCC("CFF "), fourCC("CFF2")]
        for index in 0..<CFArrayGetCount(tables) {
            // The array holds the tags themselves, not CFNumbers.
            let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tables, index)))
            if drawable.contains(tag) { return true }
        }
        return false
    }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// The libass message handler: formatting happens in C, attribution through the thread's sink.
private let assMessageHandler: reel_ass_message_handler = { level, message, sink in
    guard let message, let sink else { return }
    Unmanaged<SubtitleMessageSink>.fromOpaque(sink).takeUnretainedValue().record(level: level, message: String(cString: message))
}

/// Where and how big one render is.
public struct SubtitleRenderSettings: Sendable, Hashable {
    /// The output in pixels: the window's backing size, or the video's for a screenshot.
    public var frameWidth: Int
    public var frameHeight: Int
    /// The video picture inside the frame (output pixels, top-left origin).
    public var videoRect: PixelRect
    /// The video's own size (`ass_set_storage_size`).
    public var videoWidth: Int
    public var videoHeight: Int
    /// `SubtitleStyle.scale`: 1 at size 45.
    public var scale: Double
    /// mpv `sub-pos`: 100 is the default bottom position.
    public var position: Double
    /// Lift: bottom-aligned, unpositioned lines keep their bottom edge at least this many output
    /// pixels above the frame bottom (section 8.5). Nil leaves them where they are.
    public var bottomInset: Double?

    public init(
        frameWidth: Int,
        frameHeight: Int,
        videoRect: PixelRect? = nil,
        videoWidth: Int,
        videoHeight: Int,
        scale: Double = 1,
        position: Double = SubtitleStyle.defaultPosition,
        bottomInset: Double? = nil
    ) {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoRect = videoRect ?? PixelRect.aspectFit(width: videoWidth, height: videoHeight, inWidth: frameWidth, height: frameHeight)
        self.scale = scale
        self.position = position
        self.bottomInset = bottomInset
    }
}

/// One render's output.
public struct SubtitleRenderResult: Sendable {
    /// The blended subtitle, or nil when nothing shows.
    public var bitmap: SubtitleBitmap?
    /// libass's change detection: 0 same image, 1 moved, 2 new content.
    public var changed: Int
}

public enum SubtitleRendererError: Error, Sendable, Hashable, LocalizedError {
    /// libass failed to initialise; subtitles are off for the session (section 8.7).
    case unavailable

    public var errorDescription: String? { "Subtitles unavailable" }
}

/// libass for text subtitles (design sections 8.1, 8.4 to 8.6): one `ASS_Renderer` with the
/// CoreText font provider over the shared `ASS_Library`, one `ASS_Track` for the selected track.
/// Unstyled text (SRT, WebVTT, mov_text) gets Reel's default style through the selective style
/// override and may use the black bars; ASS keeps its own styles inside the video rect.
///
/// Not thread-safe: the player renders on one serial queue.
public final class SubtitleRenderer {
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private var track: UnsafeMutablePointer<ASS_Track>?
    private let sink = SubtitleMessageSink()
    private let compositor = SubtitleCompositor()
    private var styleName: UnsafeMutablePointer<CChar>?
    private var styleFont: UnsafeMutablePointer<CChar>?

    public private(set) var format: SubtitleFormat?
    /// The family Reel's default style uses for the loaded track.
    public private(set) var defaultStyleFamily = SubtitleStyle.fontName
    private var loadedEpoch: Int?
    private var lastEventID = 0
    private var ownEventID = 0
    private var applied: SubtitleRenderSettings?

    public init() throws {
        guard let library = reel_ass_shared_library(assMessageHandler) else { throw SubtitleRendererError.unavailable }
        self.library = library
        SubtitleFonts.register(in: library)
        reel_ass_library_lock()
        let renderer = ass_renderer_init(library)
        reel_ass_library_unlock()
        guard let renderer else { throw SubtitleRendererError.unavailable }
        self.renderer = renderer
        withSink {
            ass_set_fonts(renderer, nil, SubtitleFonts.defaultFamily, Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
        }
        ass_set_hinting(renderer, ASS_HINTING_NONE)
    }

    deinit {
        if let track { ass_free_track(track) }
        ass_renderer_done(renderer)
        free(styleName)
        free(styleFont)
    }

    public var diagnostics: SubtitleRenderDiagnostics { sink.diagnostics }

    public func resetDiagnostics() { sink.reset() }

    /// Images blended so far (renders with `changed == 0` or a uniform move reuse the last one).
    public var blendCount: Int { compositor.blendCount }

    // MARK: Track

    /// Starts a new track from a decoder header (`ass_process_codec_private`). `fontFamily` is
    /// the default style's family for unstyled text (PingFang SC, TC or HK).
    public func load(header: String, format: SubtitleFormat, fontFamily: String = SubtitleStyle.fontName) {
        unload()
        reel_ass_library_lock()
        let track = ass_new_track(library)
        reel_ass_library_unlock()
        guard let track else { return }
        let text = header.isEmpty ? SubtitleRenderer.fallbackHeader : header
        withSink {
            var bytes = Array(text.utf8)
            bytes.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
                    ass_process_codec_private(track, pointer, Int32(buffer.count))
                }
            }
        }
        substituteStyleFonts(track)
        self.track = track
        self.format = format
        defaultStyleFamily = fontFamily
        applied = nil
        configureStyle(for: format)
    }

    /// Points styles that name an undrawable family at its replacement (`SubtitleFonts`).
    private func substituteStyleFonts(_ track: UnsafeMutablePointer<ASS_Track>) {
        guard !SubtitleFonts.substitutions.isEmpty, let styles = track.pointee.styles else { return }
        for index in 0..<Int(track.pointee.n_styles) {
            guard let name = styles[index].FontName else { continue }
            let family = String(cString: name)
            guard let replacement = SubtitleFonts.substitute(family) else { continue }
            // libass frees style strings with free().
            free(name)
            styles[index].FontName = strdup(replacement)
            sink.recordSubstitution(family, replacement)
        }
    }

    /// Drops the track; renders return nothing until the next `load`.
    public func unload() {
        if let track { ass_free_track(track) }
        track = nil
        format = nil
        loadedEpoch = nil
        lastEventID = 0
        compositor.reset()
    }

    /// Adds events with their own numbering (an external file or a test).
    public func add(_ events: [SubtitleTextEvent]) {
        for event in events {
            ownEventID += 1
            process(event, readOrder: ownEventID)
        }
    }

    /// Brings the track up to date with `store`: rebuilt when its epoch changed (a charset
    /// change), otherwise only events newer than the last sync are added.
    public func sync(with store: SubtitleTrackStore, track id: TrackID) {
        guard let snapshot = store.track(id) else {
            unload()
            return
        }
        if loadedEpoch != snapshot.epoch || track == nil {
            load(header: snapshot.header, format: snapshot.format, fontFamily: snapshot.fontFamily)
            loadedEpoch = snapshot.epoch
        }
        for stored in snapshot.events(after: lastEventID) {
            process(stored.event, readOrder: stored.id)
            lastEventID = max(lastEventID, stored.id)
        }
    }

    /// Number of events libass holds.
    public var eventCount: Int { Int(track?.pointee.n_events ?? 0) }

    private func process(_ event: SubtitleTextEvent, readOrder: Int) {
        guard let track else { return }
        let chunk = Array("\(readOrder),\(SubtitleFonts.rewriteOverrides(event.fields))".utf8)
        let start = Int64(event.start.milliseconds.rounded())
        let duration = max(0, Int64(event.end.milliseconds.rounded()) - start)
        withSink {
            chunk.withUnsafeBufferPointer { buffer in
                buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
                    ass_process_chunk(track, pointer, Int32(buffer.count), start, duration)
                }
            }
        }
    }

    // MARK: Render

    /// Renders the track at `time` (the subtitle clock: playback time minus the delay).
    public func render(at time: MediaTime, settings: SubtitleRenderSettings) -> SubtitleRenderResult {
        guard let track, settings.frameWidth > 0, settings.frameHeight > 0 else {
            compositor.reset()
            return SubtitleRenderResult(bitmap: nil, changed: 0)
        }
        apply(settings)
        var changed: Int32 = 0
        let milliseconds = Int64(time.milliseconds.rounded(.down))
        let bitmap = withSink {
            let images = ass_render_frame(renderer, track, milliseconds, &changed)
            return compositor.composite(images, changed: changed)
        }
        return SubtitleRenderResult(bitmap: bitmap, changed: Int(changed))
    }

    private func apply(_ settings: SubtitleRenderSettings) {
        guard settings != applied, let track else { return }
        applied = settings
        let unstyled = format?.usesDefaultStyle ?? true
        let video = settings.videoRect
        ass_set_frame_size(renderer, Int32(settings.frameWidth), Int32(settings.frameHeight))
        ass_set_storage_size(renderer, Int32(max(settings.videoWidth, 1)), Int32(max(settings.videoHeight, 1)))
        ass_set_margins(
            renderer,
            Int32(video.y),
            Int32(settings.frameHeight - video.maxY),
            Int32(video.x),
            Int32(settings.frameWidth - video.maxX)
        )
        // Unstyled text may use the black bars; ASS positions are authored against the video (D33).
        ass_set_use_margins(renderer, unstyled ? 1 : 0)
        ass_set_font_scale(renderer, settings.scale)
        ass_set_line_position(renderer, SubtitleRenderer.linePosition(settings: settings, track: track.pointee, unstyled: unstyled))
    }

    /// The `ass_set_line_position` value: the user's `sub-pos` (100 - position), raised further when
    /// the lift needs the bottom line higher. libass ignores it for `\pos` and `\move` events.
    static func linePosition(settings: SubtitleRenderSettings, track: ASS_Track, unstyled: Bool) -> Double {
        let user = SubtitleStyle.defaultPosition - settings.position
        guard let inset = settings.bottomInset, inset > 0 else { return user }
        let playResY = Double(track.PlayResY > 0 ? track.PlayResY : 288)
        let frameHeight = Double(settings.frameHeight)
        let video = settings.videoRect
        let bottom: Double
        let top: Double
        if unstyled {
            let marginV = SubtitleStyle.bottomMargin * playResY / SubtitleStyle.referenceHeight
            // libass's fit height with margins in use (ass_render_api.c).
            let contentWidth = Double(max(video.width, 1))
            let contentHeight = Double(max(video.height, 1))
            let frameWidth = Double(settings.frameWidth)
            let fitHeight = contentWidth * frameHeight <= contentHeight * frameWidth ? frameHeight : contentHeight * frameWidth / contentWidth
            bottom = frameHeight - marginV / playResY * fitHeight
            top = 0
        } else {
            var marginV = 0.0
            if track.n_styles > 0, let styles = track.styles {
                let index = Int(track.default_style) < Int(track.n_styles) ? Int(max(track.default_style, 0)) : 0
                marginV = Double(styles[index].MarginV)
            }
            bottom = Double(video.y) + (playResY - marginV) / playResY * Double(video.height)
            top = Double(video.y)
        }
        let target = frameHeight - inset
        guard bottom - top > 1, target < bottom else { return user }
        let lift = 100 * (bottom - target) / (bottom - top)
        return max(user, lift)
    }

    /// Reel's default style for unstyled text, on libass's 288-line user-style scale (the values
    /// in `SubtitleStyle` are on the 720-line reference).
    private func configureStyle(for format: SubtitleFormat) {
        guard let track else { return }
        guard format.usesDefaultStyle else {
            // ASS: only the size factor applies, and only to dialogue-like events.
            ass_set_selective_style_override_enabled(renderer, Int32(ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue))
            return
        }
        let userScale = 288 / SubtitleStyle.referenceHeight
        let playResX = Double(track.pointee.PlayResX > 0 ? track.pointee.PlayResX : 384)
        let playResY = Double(track.pointee.PlayResY > 0 ? track.pointee.PlayResY : 288)
        free(styleName)
        free(styleFont)
        styleName = strdup("Default")
        let family = SubtitleFonts.substitute(defaultStyleFamily) ?? defaultStyleFamily
        styleFont = strdup(family)
        if family != defaultStyleFamily {
            sink.recordSubstitution(defaultStyleFamily, family)
        }
        var style = ASS_Style()
        style.Name = styleName
        style.FontName = styleFont
        style.FontSize = SubtitleStyle.baseSize * userScale
        style.PrimaryColour = 0xFFFF_FF00
        style.SecondaryColour = 0xFFFF_FF00
        style.OutlineColour = 0x0000_0000
        style.BackColour = UInt32(((1 - SubtitleStyle.shadowOpacity) * 255).rounded())
        style.Bold = Int32(SubtitleStyle.fontWeight)
        style.ScaleX = 1
        style.ScaleY = 1
        style.BorderStyle = 1
        style.Outline = SubtitleStyle.outline * userScale
        style.Shadow = SubtitleStyle.shadowOffset * userScale
        style.Blur = SubtitleStyle.blur * userScale
        style.Alignment = 2
        // Margins are not rescaled by libass: they are in the track's own PlayRes units.
        style.MarginV = Int32((SubtitleStyle.bottomMargin * playResY / SubtitleStyle.referenceHeight).rounded())
        let side = Int32((playResX * (1 - SubtitleStyle.maximumLineWidthFraction) / 2).rounded())
        style.MarginL = side
        style.MarginR = side
        style.Encoding = 1
        ass_set_selective_style_override(renderer, &style)
        let bits = ASS_OVERRIDE_BIT_STYLE.rawValue | ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue
            | ASS_OVERRIDE_BIT_MARGINS.rawValue | ASS_OVERRIDE_BIT_BLUR.rawValue | ASS_OVERRIDE_BIT_ALIGNMENT.rawValue
        ass_set_selective_style_override_enabled(renderer, Int32(bits))
    }

    private func withSink<Result>(_ body: () -> Result) -> Result {
        reel_ass_set_thread_sink(Unmanaged.passUnretained(sink).toOpaque())
        defer { reel_ass_set_thread_sink(nil) }
        return body()
    }

    /// A minimal header for a text track whose decoder gave none.
    static let fallbackHeader = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 384
        PlayResY: 288
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,PingFang SC,18,&H00FFFFFF,&H00FFFFFF,&H00000000,&H99000000,0,0,0,0,100,100,0,0,1,1,0.56,2,19,19,16,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
}

extension PixelRect {
    /// `width` x `height` scaled to fit inside the frame, centred (the video rect).
    public static func aspectFit(width: Int, height: Int, inWidth frameWidth: Int, height frameHeight: Int) -> PixelRect {
        guard width > 0, height > 0, frameWidth > 0, frameHeight > 0 else {
            return PixelRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        }
        let scale = min(Double(frameWidth) / Double(width), Double(frameHeight) / Double(height))
        let fittedWidth = Int((Double(width) * scale).rounded())
        let fittedHeight = Int((Double(height) * scale).rounded())
        return PixelRect(x: (frameWidth - fittedWidth) / 2, y: (frameHeight - fittedHeight) / 2, width: fittedWidth, height: fittedHeight)
    }
}
