import ReelCore
import SwiftUI

/// Shared chrome styling (design 9.3 and 15).
enum ChromeStyle {
    /// The 0.5 pt inner stroke: white 12% in dark, black 8% in light.
    static func stroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    /// Second lines, counts and "in 3 s": primary 68% in light, 55% in dark (D47).
    static func secondaryText(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.55 : 0.68)
    }

    /// Format tags: primary 62% in light, 50% in dark.
    static func tagText(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.5 : 0.62)
    }

    static func accentTint(_ scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.16)
    }

    static let timeFont = Font.system(size: 12, weight: .medium).monospacedDigit()
    /// SF Symbol point sizes. At 14 and 18 the glyphs fill about the 17 and 22 pt boxes the
    /// mockup draws; at 17 and 22 they came out about 1.5 times larger than the mockup.
    static let iconSize: CGFloat = 14
    static let playIconSize: CGFloat = 18
    static let hitSize: CGFloat = 28
    static let playHitSize: CGFloat = 32
    static let controllerSpace = "reel.controller"
    static let sceneSpace = "reel.scene"
}

/// How much shadow a material surface carries (design 15.2 tokens).
enum SurfaceShadow {
    case large, small
}

/// The material, hairline and shadows shared by the controller, panels, pill, OSD and card.
/// With Reduce Transparency the material becomes the window background at 96%.
struct ChromeSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let shadow: SurfaceShadow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background { fill }
            .overlay(shape.strokeBorder(ChromeStyle.stroke(colorScheme), lineWidth: 0.5))
            .shadow(color: .black.opacity(shadow == .large ? 0.22 : 0.16), radius: shadow == .large ? 1.5 : 1, y: 1)
            .shadow(color: .black.opacity(shadow == .large ? 0.28 : 0.22), radius: shadow == .large ? 28 : 9, y: shadow == .large ? 10 : 4)
    }

    @ViewBuilder
    private var fill: some View {
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

extension View {
    func chromeSurface<S: InsettableShape>(_ shape: S, shadow: SurfaceShadow = .large) -> some View {
        modifier(ChromeSurface(shape: shape, shadow: shadow))
    }

    func continuousSurface(radius: CGFloat, shadow: SurfaceShadow = .large) -> some View {
        chromeSurface(RoundedRectangle(cornerRadius: radius, style: .continuous), shadow: shadow)
    }
}

/// Controller geometry (design 9.3 and 15.2). Positions are SwiftUI coordinates (origin top-left).
nonisolated public enum ControllerLayout {
    public static let height: CGFloat = 80
    public static let cornerRadius: CGFloat = 24
    public static let horizontalPadding: CGFloat = 14
    public static let verticalPadding: CGFloat = 12
    public static let edgeMargin: CGFloat = 16
    public static let minimumWidth: CGFloat = 440
    public static let maximumWidth: CGFloat = 600
    public static let windowFraction: CGFloat = 0.45
    public static let maximumWindowFraction: CGFloat = 0.7
    /// In fullscreen the bottom edge sits this far from the screen bottom (D41).
    public static let fullscreenBottomInset: CGFloat = 56
    /// Below this width previous, next and Picture in Picture are dropped.
    public static let compactWidth: CGFloat = 568
    /// Below this width the audio button and the speed label go too.
    public static let narrowWidth: CGFloat = 480

    /// `clamp(0.45 x window, 440, 600)`, and never more than 70% of the window.
    public static func width(windowWidth: CGFloat) -> CGFloat {
        let scaled = min(max(windowWidth * windowFraction, minimumWidth), maximumWidth)
        return max(0, min(scaled, windowWidth * maximumWindowFraction))
    }

    /// The controller frame for stored fractions (centre x, bottom edge from the window bottom),
    /// clamped to keep 16 pt from every edge. In fullscreen the bottom edge is fixed.
    public static func frame(in size: CGSize, centerX: Double, bottomY: Double, fullscreen: Bool = false) -> CGRect {
        let width = width(windowWidth: size.width)
        let centre = size.width * centerX
        var minX = centre - width / 2
        minX = min(max(minX, edgeMargin), max(edgeMargin, size.width - edgeMargin - width))
        var maxY = fullscreen ? size.height - fullscreenBottomInset : size.height - size.height * bottomY
        maxY = min(max(maxY, edgeMargin + height), max(edgeMargin + height, size.height - edgeMargin))
        return CGRect(x: minX, y: maxY - height, width: width, height: height)
    }

    /// The fractions that put the controller's frame at `frame` in a window of `size`.
    public static func fractions(for frame: CGRect, in size: CGSize) -> (centerX: Double, bottomY: Double) {
        guard size.width > 0, size.height > 0 else {
            return (RememberedState.defaultControllerCenterX, RememberedState.defaultControllerBottomY)
        }
        return (Double(frame.midX / size.width), Double((size.height - frame.maxY) / size.height))
    }

    /// Which optional buttons fit (design 9.3). Priority from first kept to first dropped: play,
    /// back and forward 10, fullscreen, volume, subtitles, audio, speed, next, previous, PiP.
    public struct Buttons: Equatable, Sendable {
        public var previous: Bool
        public var next: Bool
        public var pictureInPicture: Bool
        public var audio: Bool
        public var speed: Bool

        public var count: Int {
            [previous, next, pictureInPicture, audio, speed].filter(\.self).count
        }
    }

    /// `hasEpisodes` is false when the file is alone in its folder: previous and next are hidden.
    public static func buttons(controllerWidth: CGFloat, hasEpisodes: Bool) -> Buttons {
        let roomy = controllerWidth >= compactWidth
        let wide = controllerWidth >= narrowWidth
        return Buttons(
            previous: roomy && hasEpisodes,
            next: roomy && hasEpisodes,
            pictureInPicture: roomy,
            audio: wide,
            speed: wide
        )
    }
}

/// What the controller needs to know about where it sits.
struct ControllerContext: Equatable {
    var windowSize: CGSize
    var frame: CGRect
}

/// What the controller's buttons do beyond the model (window-level actions).
public struct SceneActions {
    public var toggleFullscreen: () -> Void
    /// Whether a file drag is over the window; the empty state reacts to it.
    public var dropTarget: DropTargetState

    public init(toggleFullscreen: @escaping () -> Void = {}, dropTarget: DropTargetState = DropTargetState()) {
        self.toggleFullscreen = toggleFullscreen
        self.dropTarget = dropTarget
    }
}

/// Places its one child above the container's top edge: its bottom `gap` pt above the top, its
/// leading edge at `x` (or its centre, clamped into `range`). Explicit placement, because
/// alignment guides on overlays did not take effect in `ImageRenderer`.
nonisolated struct AboveLayout: Layout {
    var x: CGFloat
    var centered = false
    var range: ClosedRange<CGFloat>?
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.unspecified)
        var originX = centered ? x - size.width / 2 : x
        if let range {
            originX = min(max(originX, range.lowerBound), max(range.lowerBound, range.upperBound - size.width))
        }
        subview.place(
            at: CGPoint(x: bounds.minX + originX, y: bounds.minY - gap - size.height),
            anchor: .topLeading,
            proposal: .unspecified
        )
    }
}

/// Button bounds, collected so panels can centre on the button that opened them.
nonisolated struct PanelAnchorKey: PreferenceKey {
    static var defaultValue: [ControllerPanel: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [ControllerPanel: Anchor<CGRect>], nextValue: () -> [ControllerPanel: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The floating frosted controller (design 9.3 and 15.2).
struct ControllerView: View {
    let model: PlayerModel
    let actions: SceneActions
    let context: ControllerContext
    var onDragChanged: (DragGesture.Value) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onReset: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var buttons: ControllerLayout.Buttons {
        ControllerLayout.buttons(controllerWidth: context.frame.width, hasEpisodes: model.showsEpisodeButtons)
    }

    var body: some View {
        VStack(spacing: 6) {
            topRow
            bottomRow
        }
        .padding(.horizontal, ControllerLayout.horizontalPadding)
        .padding(.vertical, ControllerLayout.verticalPadding)
        .frame(height: ControllerLayout.height)
        .coordinateSpace(name: ChromeStyle.controllerSpace)
        .background { dragSurface }
        .continuousSurface(radius: ControllerLayout.cornerRadius)
        .onHover { model.chrome.setPointerOverController($0) }
        .overlayPreferenceValue(PanelAnchorKey.self) { anchors in
            ControllerOverlays(model: model, context: context, anchors: anchors)
        }
    }

    /// Empty areas drag the controller; a double click resets its position.
    private var dragSurface: some View {
        Color.clear
            .contentShape(RoundedRectangle(cornerRadius: ControllerLayout.cornerRadius, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged(onDragChanged)
                    .onEnded { _ in onDragEnded() }
            )
            .onTapGesture(count: 2, perform: onReset)
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            Text(model.elapsedLabel)
                .font(ChromeStyle.timeFont)
                .foregroundStyle(Color.primary.opacity(0.85))
                .fixedSize()
            SeekBar(model: model, context: context)
            Button {
                model.toggleRemainingTime()
            } label: {
                Text(model.trailingLabel)
                    .font(ChromeStyle.timeFont)
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help(model.showRemainingTime ? "Show total time" : "Show remaining time")
        }
        .frame(height: SeekBar.hitHeight)
    }

    private var bottomRow: some View {
        ZStack {
            HStack(spacing: 0) {
                VolumeControl(model: model)
                Spacer(minLength: 8)
                rightCluster
            }
            centreCluster
        }
        .frame(height: ChromeStyle.playHitSize)
    }

    private var centreCluster: some View {
        HStack(spacing: 20) {
            if buttons.previous {
                ChromeButton(
                    symbol: "backward.end.fill",
                    help: "Previous Episode, \u{2318}\u{2190}",
                    enabled: model.hasPreviousEpisode
                ) {
                    Task { await model.playPreviousEpisode() }
                }
                .padding(.trailing, -4)
            }
            ChromeButton(symbol: "gobackward.10", help: "Back 10 Seconds", enabled: model.hasMedia) {
                model.seek(by: -PlayerModel.buttonSeekStep, source: .pointer)
            }
            ChromeButton(
                symbol: playSymbol,
                size: ChromeStyle.playIconSize,
                hitSize: ChromeStyle.playHitSize,
                help: playHelp,
                enabled: model.hasMedia
            ) {
                model.togglePause()
            }
            ChromeButton(symbol: "goforward.10", help: "Forward 10 Seconds", enabled: model.hasMedia) {
                model.seek(by: PlayerModel.buttonSeekStep, source: .pointer)
            }
            if buttons.next {
                ChromeButton(
                    symbol: "forward.end.fill",
                    help: "Next Episode, \u{2318}\u{2192}",
                    enabled: model.hasNextEpisode,
                    tint: model.autoAdvance.isActive ? Color.accentColor : nil
                ) {
                    Task { await model.playNextEpisode() }
                }
                .padding(.leading, -4)
            }
        }
    }

    private var playSymbol: String {
        if model.playbackState == .ended { return "arrow.counterclockwise" }
        return model.isPlaying ? "pause.fill" : "play.fill"
    }

    private var playHelp: String {
        if model.playbackState == .ended { return "Replay" }
        return model.isPlaying ? "Pause" : "Play"
    }

    private var rightCluster: some View {
        HStack(spacing: 0) {
            if buttons.speed {
                SpeedButton(model: model)
                    .padding(.trailing, 6)
            }
            ChromeButton(
                symbol: model.subtitlesAreOn ? "captions.bubble.fill" : "captions.bubble",
                help: "Subtitles, \u{2303}\u{2318}S",
                enabled: model.hasMedia,
                isOn: model.activePanel == .subtitles,
                panel: .subtitles,
                value: model.subtitleAccessibilityValue
            ) {
                model.togglePanel(.subtitles)
            }
            if buttons.audio {
                ChromeButton(
                    symbol: "waveform",
                    help: "Audio, \u{2303}\u{2318}A",
                    enabled: model.hasMedia,
                    isOn: model.activePanel == .audio,
                    panel: .audio,
                    value: model.audioAccessibilityValue
                ) {
                    model.togglePanel(.audio)
                }
            }
            if buttons.pictureInPicture {
                ChromeButton(
                    symbol: model.isPictureInPictureActive ? "pip.exit" : "pip.enter",
                    help: "Picture in Picture, \u{2303}\u{2318}P",
                    enabled: model.hasMedia,
                    tint: model.isPictureInPictureActive ? Color.accentColor : nil
                ) {
                    model.togglePictureInPicture()
                }
            }
            ChromeButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full Screen, \u{2303}\u{2318}F") {
                actions.toggleFullscreen()
            }
        }
    }
}

/// The panel and the next-episode card, positioned against the controller (design 9.7, 9.8).
private struct ControllerOverlays: View {
    static let panelGap: CGFloat = 10
    static let cardGap: CGFloat = 12

    let model: PlayerModel
    let context: ControllerContext
    let anchors: [ControllerPanel: Anchor<CGRect>]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                AboveLayout(x: panelOriginX(proxy), gap: ControllerOverlays.panelGap) {
                    if let panel = model.activePanel {
                        PanelHost(model: model, panel: panel, windowHeight: context.windowSize.height)
                            .id(panel)
                            .frame(width: PanelMetrics.width(for: panel))
                            .transition(Motion.panelTransition(reduceMotion: reduceMotion, anchor: panelAnchor(panel, proxy)))
                    }
                }
                AboveLayout(x: cardOriginX(controllerWidth: proxy.size.width), gap: ControllerOverlays.cardGap) {
                    if model.autoAdvance.isActive {
                        NextEpisodeCard(model: model, autoAdvance: model.autoAdvance)
                            .transition(Motion.cardTransition(reduceMotion: reduceMotion))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        // Keyed on open or closed: switching straight between panels swaps with no morph.
        .animation(reduceMotion ? Motion.reduced : Motion.easeOut(0.16), value: model.activePanel != nil)
        .animation(reduceMotion ? Motion.reduced : Motion.easeOut(0.32), value: model.autoAdvance.isActive)
    }

    private func panelOriginX(_ proxy: GeometryProxy) -> CGFloat {
        guard let panel = model.activePanel, let anchor = anchors[panel] else { return 0 }
        return originX(centre: proxy[anchor].midX, width: PanelMetrics.width(for: panel))
    }

    /// The scale starts over the button, even when the panel was clamped away from it.
    private func panelAnchor(_ panel: ControllerPanel, _ proxy: GeometryProxy) -> UnitPoint {
        guard let anchor = anchors[panel] else { return .bottom }
        return PanelAnchor.track(
            buttonMidX: proxy[anchor].midX,
            panelOriginX: panelOriginX(proxy),
            panelWidth: PanelMetrics.width(for: panel)
        )
    }

    /// Centred on the button, kept 16 pt inside the window, in controller coordinates.
    private func originX(centre: CGFloat, width: CGFloat) -> CGFloat {
        let lowest = ControllerLayout.edgeMargin - context.frame.minX
        let highest = context.windowSize.width - ControllerLayout.edgeMargin - width - context.frame.minX
        return min(max(centre - width / 2, lowest), max(lowest, highest))
    }

    /// Right edge on the controller's right edge, or 16 pt inside the window when that would overflow.
    private func cardOriginX(controllerWidth: CGFloat) -> CGFloat {
        let rightLimit = context.windowSize.width - ControllerLayout.edgeMargin - context.frame.minX
        let right = min(controllerWidth, rightLimit)
        let left = right - NextEpisodeCard.width
        return max(left, ControllerLayout.edgeMargin - context.frame.minX)
    }
}

/// Press feedback on the pointer-down: a 0.94 scale in 0.1 s, released with the same curve.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Press feedback for the stepper cells, which are pressed in bursts: a fill that follows the
/// pointer-down at once and fades back in 0.1 s. A scale would pull half a cell off its divider.
struct PressFillStyle: ButtonStyle {
    static let hoverOpacity = 0.08
    static let pressedOpacity = 0.16

    var hovering: Bool

    static func fillOpacity(pressed: Bool, hovering: Bool) -> Double {
        if pressed { return pressedOpacity }
        return hovering ? hoverOpacity : 0
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(PressFillStyle.fillOpacity(pressed: configuration.isPressed, hovering: hovering)))
            .animation(configuration.isPressed ? nil : Motion.pressRelease, value: configuration.isPressed)
    }
}

/// An SF Symbol button with a hover circle (design 9.3). `isOn` keeps the circle while the
/// button's panel is open; `tint` colours the glyph (accent for a lit button).
struct ChromeButton: View {
    let symbol: String
    var size: CGFloat = ChromeStyle.iconSize
    var hitSize: CGFloat = ChromeStyle.hitSize
    let help: String
    var enabled = true
    var tint: Color?
    var isOn = false
    var panel: ControllerPanel?
    var value: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(glyphColor)
                .frame(width: hitSize, height: hitSize)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.1))
                        .opacity((hovering && enabled) || isOn ? 1 : 0)
                        .animation(.easeInOut(duration: 0.12), value: hovering)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(ChromeButton.accessibilityName(help))
        .accessibilityValue(value ?? "")
        .anchorPreference(key: PanelAnchorKey.self, value: .bounds) { anchor in
            panel.map { [$0: anchor] } ?? [:]
        }
    }

    private var glyphColor: Color {
        if let tint, enabled { return tint }
        return Color.primary.opacity(enabled ? 0.9 : 0.55)
    }

    /// "Subtitles, Ctrl+Cmd+S" reads as "Subtitles" to VoiceOver.
    static func accessibilityName(_ help: String) -> String {
        help.split(separator: ",").first.map(String.init) ?? help
    }
}

/// The playback rate as text ("1x", "1.5x"); accent on an accent tint when it is not 1 (design 9.3).
struct SpeedButton: View {
    let model: PlayerModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var isChanged: Bool { !PlaybackSpeed.isNormal(model.rate) }

    var body: some View {
        Button {
            model.togglePanel(.speed)
        } label: {
            Text(PlaybackSpeed.label(model.rate))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(isChanged ? Color.accentColor : Color.primary.opacity(model.hasMedia ? 0.9 : 0.55))
                .padding(.horizontal, 6)
                .frame(minWidth: 36, minHeight: ChromeStyle.hitSize)
                .background {
                    ZStack {
                        Capsule().fill(Color.primary.opacity(0.1))
                            .opacity((hovering && model.hasMedia) || model.activePanel == .speed ? 1 : 0)
                            .animation(.easeInOut(duration: 0.12), value: hovering)
                        Capsule().fill(ChromeStyle.accentTint(colorScheme))
                            .opacity(isChanged ? 1 : 0)
                    }
                }
                .contentShape(Capsule())
                .animation(Motion.easeInOut(0.15), value: isChanged)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!model.hasMedia)
        .onHover { hovering = $0 }
        .help("Speed, \u{2318}] \u{2318}[")
        .accessibilityLabel("Speed")
        .accessibilityValue(model.speedAccessibilityValue)
        .anchorPreference(key: PanelAnchorKey.self, value: .bounds) { [.speed: $0] }
    }
}

/// Mute button plus a 72 pt slider that widens to 104 pt on hover (design 9.3, D27).
struct VolumeControl: View {
    static let narrowWidth: CGFloat = 72
    static let wideWidth: CGFloat = 104

    let model: PlayerModel
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 34 { return "speaker.wave.1.fill" }
        if model.volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 6) {
            ChromeButton(symbol: symbol, help: model.isMuted ? "Unmute" : "Mute") {
                model.toggleMute()
            }
            VolumeSlider(model: model)
                .frame(width: hovering ? VolumeControl.wideWidth : VolumeControl.narrowWidth, height: ChromeStyle.hitSize)
        }
        .onHover { over in
            withAnimation(Motion.volumeWiden(reduceMotion: reduceMotion)) { hovering = over }
        }
    }
}

/// A drawn slider (AppKit's `NSSlider` would not render in the background screenshots).
struct VolumeSlider: View {
    let model: PlayerModel

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = model.isMuted ? 0 : model.volume / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.2)).frame(height: 4)
                Capsule().fill(Color.primary.opacity(0.75)).frame(width: max(4, width * fraction), height: 4)
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.chrome.setDragging(true)
                        model.setVolume(SeekBarInteraction.fraction(x: value.location.x, width: width) * 100, showOSD: false)
                    }
                    .onEnded { _ in model.chrome.setDragging(false) }
            )
        }
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(model.volume.rounded()))")
    }
}
