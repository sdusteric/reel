import ReelCore
import SwiftUI

/// Values of the mini player overlay (mini player design section 5). Everything sits on the
/// picture, so the colours are fixed in both appearances.
nonisolated public enum MiniPlayerLayout {
    public static let dim: Double = 0.4
    public static let endDim: Double = 0.6
    public static let cornerButton: CGFloat = 28
    public static let cornerGlyph: CGFloat = 15
    public static let cornerInset: CGFloat = 8
    public static let skipButton: CGFloat = 36
    public static let skipGlyph: CGFloat = 22
    public static let playButton: CGFloat = 48
    public static let playGlyph: CGFloat = 30
    public static let transportGap: CGFloat = 24
    public static let barSide: CGFloat = 12
    public static let barBottom: CGFloat = 10
    public static let barHeight: CGFloat = 16
    public static let track: CGFloat = 4
    public static let activeTrack: CGFloat = 6
    public static let thumb: CGFloat = 10
    /// Bottom subtitle lines sit this far above the panel bottom while the chrome shows.
    public static let subtitleLift: Double = 34
    public static let pauseMark: CGFloat = 24
    public static let pauseGlyph: CGFloat = 12
    public static let pauseMarkInset: CGFloat = 10
    public static let ring: CGFloat = 48
    public static let glyphOpacity: Double = 0.94
    public static let hoverFill: Double = 0.18
    /// SF Symbols fill their box at about this fraction of the font size.
    static let symbolFill: CGFloat = 0.82
}

/// What the overlay shows for the model's state at a panel width. Pure, so tests read it.
public struct MiniPlayerContent: Equatable {
    public var showsChrome: Bool
    public var showsSkipButtons: Bool
    public var showsPauseMark: Bool
    public var showsNextEpisode: Bool
    public var nextName: String?
    public var nextLine: String?

    @MainActor
    public init(model: PlayerModel, width: CGFloat) {
        showsNextEpisode = model.autoAdvance.isActive
        // The end-of-episode countdown keeps the chrome up without hover.
        showsChrome = model.miniChrome.isVisible || showsNextEpisode
        showsSkipButtons = MiniPlayerGeometry.showsSkipButtons(width: width)
        showsPauseMark = model.hasMedia && !model.isPlaying && !showsChrome
        nextName = showsNextEpisode ? model.autoAdvance.nextName : nil
        nextLine = showsNextEpisode ? "Next episode \(model.autoAdvance.remainingLabel)" : nil
    }
}

/// The two corner buttons: Close pauses and returns the picture to the hidden window; Back to
/// Window brings the window back and activates Reel.
public struct MiniPlayerActions {
    public var close: () -> Void
    public var backToWindow: () -> Void

    public init(close: @escaping () -> Void = {}, backToWindow: @escaping () -> Void = {}) {
        self.close = close
        self.backToWindow = backToWindow
    }
}

/// The overlay inside the mini player panel (mockups png/29 to png/33): a flat dim, white
/// controls on the picture, the seek bar, the pause mark, the end-of-episode row and the OSD.
/// The app passes the video surface; shots pass an image of a frame.
public struct MiniPlayerView<Surface: View>: View {
    let model: PlayerModel
    let actions: MiniPlayerActions
    let subtitle: ShotSubtitle?
    let surface: Surface

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: PlayerModel,
        actions: MiniPlayerActions = MiniPlayerActions(),
        subtitle: ShotSubtitle? = nil,
        @ViewBuilder surface: () -> Surface
    ) {
        self.model = model
        self.actions = actions
        self.subtitle = subtitle
        self.surface = surface()
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let content = MiniPlayerContent(model: model, width: size.width)
            ZStack(alignment: .topLeading) {
                Color.black
                surface
                    .frame(width: size.width, height: size.height)
                if subtitle != nil {
                    SampleSubtitles(
                        windowHeight: max(size.height, MiniPlayerGeometry.subtitleFloorHeight),
                        liftInset: content.showsChrome ? MiniPlayerLayout.subtitleLift : nil
                    )
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                }
                chrome(content, size: size)
                    .opacity(content.showsChrome ? 1 : 0)
                    .allowsHitTesting(content.showsChrome)
                pauseMark
                    .opacity(content.showsPauseMark ? 1 : 0)
                    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                OSDView(model: model, style: .mini)
                    .padding(.leading, OSDView.Style.mini.inset)
                    .padding(.top, OSDView.Style.mini.inset + (content.showsChrome ? MiniPlayerLayout.cornerButton + MiniPlayerLayout.cornerInset : 0))
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .animation(ChromeVisibility.animation(visible: content.showsChrome, reduceMotion: reduceMotion), value: content.showsChrome)
            .onChange(of: content.showsChrome) { _, shown in
                model.updateMiniSubtitleAvoidance(chromeShown: shown)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini Player")
    }

    // MARK: Chrome

    private func chrome(_ content: MiniPlayerContent, size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(content.showsNextEpisode ? MiniPlayerLayout.endDim : MiniPlayerLayout.dim)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack {
                    MiniButton(symbol: "xmark", box: MiniPlayerLayout.cornerGlyph, hit: MiniPlayerLayout.cornerButton, help: "Close Mini Player") {
                        actions.close()
                    }
                    Spacer()
                    MiniButton(symbol: "pip.exit", box: MiniPlayerLayout.cornerGlyph, hit: MiniPlayerLayout.cornerButton, help: "Back to Window") {
                        actions.backToWindow()
                    }
                }
                .padding(MiniPlayerLayout.cornerInset)
                Spacer(minLength: 0)
                if content.showsNextEpisode {
                    nextRow(content)
                } else {
                    MiniSeekBar(model: model)
                        .padding(.horizontal, MiniPlayerLayout.barSide)
                        .padding(.bottom, MiniPlayerLayout.barBottom)
                }
            }
            if content.showsNextEpisode {
                countdownRing
            } else {
                transport(content)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func transport(_ content: MiniPlayerContent) -> some View {
        HStack(spacing: MiniPlayerLayout.transportGap) {
            if content.showsSkipButtons {
                MiniButton(symbol: "gobackward.10", box: MiniPlayerLayout.skipGlyph, hit: MiniPlayerLayout.skipButton, help: "Back 10 Seconds") {
                    model.seek(by: -PlayerModel.buttonSeekStep, source: .pointer)
                }
            }
            MiniButton(
                symbol: model.isPlaying ? "pause.fill" : "play.fill",
                box: MiniPlayerLayout.playGlyph,
                hit: MiniPlayerLayout.playButton,
                help: model.isPlaying ? "Pause" : "Play"
            ) {
                model.togglePause()
            }
            if content.showsSkipButtons {
                MiniButton(symbol: "goforward.10", box: MiniPlayerLayout.skipGlyph, hit: MiniPlayerLayout.skipButton, help: "Forward 10 Seconds") {
                    model.seek(by: PlayerModel.buttonSeekStep, source: .pointer)
                }
            }
        }
    }

    private var countdownRing: some View {
        let progress = model.autoAdvance.progress
        return Button {
            model.autoAdvance.playNow()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: AutoAdvance.tickInterval), value: progress)
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: MiniPlayerLayout.ring, height: MiniPlayerLayout.ring)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .help("Play Now")
        .accessibilityLabel("Play Now")
    }

    private func nextRow(_ content: MiniPlayerContent) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(content.nextName ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(content.nextLine ?? "")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.66))
            }
            .shadow(color: .black.opacity(0.45), radius: 1, y: 0.5)
            Spacer(minLength: 0)
            Button("Cancel") { model.autoAdvance.cancel() }
                .buttonStyle(MiniCapsuleStyle())
        }
        .padding(.horizontal, MiniPlayerLayout.barSide)
        .padding(.bottom, MiniPlayerLayout.barBottom)
    }

    private var pauseMark: some View {
        Image(systemName: "pause.fill")
            .font(.system(size: MiniPlayerLayout.pauseGlyph * MiniPlayerLayout.symbolFill, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: MiniPlayerLayout.pauseMark, height: MiniPlayerLayout.pauseMark)
            .background(Circle().fill(Color.black.opacity(0.5)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .padding(MiniPlayerLayout.pauseMarkInset)
            .accessibilityLabel("Paused")
    }
}

/// A white glyph on the picture with a soft shadow, a white hover circle and the shared press scale.
struct MiniButton: View {
    let symbol: String
    /// The glyph's box in points; the symbol is drawn to fill it.
    let box: CGFloat
    let hit: CGFloat
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: box * MiniPlayerLayout.symbolFill, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(Color.white.opacity(MiniPlayerLayout.glyphOpacity))
                .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                .frame(width: hit, height: hit)
                .background(
                    Circle()
                        .fill(Color.white.opacity(MiniPlayerLayout.hoverFill))
                        .opacity(hovering ? 1 : 0)
                        .animation(.easeInOut(duration: 0.12), value: hovering)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Cancel on the end-of-episode row: a white 18% capsule with the shared press scale.
private struct MiniCapsuleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(MiniPlayerLayout.hoverFill)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Elapsed time, the bar and remaining time along the panel's bottom edge. A drag scrubs, with
/// a small time label over the pointer; there is no thumbnail, the picture is the preview.
struct MiniSeekBar: View {
    let model: PlayerModel
    @State private var interaction: SeekBarInteraction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { model.seekHoverFraction != nil || model.isScrubbing }

    var body: some View {
        HStack(spacing: 10) {
            label(model.elapsedLabel)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: isActive ? MiniPlayerLayout.activeTrack : MiniPlayerLayout.track)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, width * model.playedFraction), height: isActive ? MiniPlayerLayout.activeTrack : MiniPlayerLayout.track)
                    if isActive {
                        Circle()
                            .fill(Color.white)
                            .frame(width: MiniPlayerLayout.thumb, height: MiniPlayerLayout.thumb)
                            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                            .offset(x: width * model.playedFraction - MiniPlayerLayout.thumb / 2)
                    }
                }
                .frame(width: width, height: MiniPlayerLayout.barHeight)
                .overlay(alignment: .topLeading) {
                    if model.isScrubbing, let hover = model.seekHoverFraction {
                        scrubLabel(hover: hover, width: width)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        model.setSeekHover(SeekBarInteraction.fraction(x: location.x, width: width))
                    case .ended:
                        if !model.isScrubbing { model.setSeekHover(nil) }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            currentInteraction().dragChanged(startX: value.startLocation.x, x: value.location.x, width: width)
                        }
                        .onEnded { value in
                            currentInteraction().dragEnded(x: value.location.x, width: width)
                        }
                )
            }
            .frame(height: MiniPlayerLayout.barHeight)
            .animation(Motion.seekTrack(reduceMotion: reduceMotion), value: isActive)
            .accessibilityElement()
            .accessibilityLabel("Seek")
            .accessibilityValue(model.elapsedLabel)
            label(model.trailingLabel)
        }
        .frame(height: MiniPlayerLayout.barHeight)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.88))
            .shadow(color: .black.opacity(0.45), radius: 1, y: 0.5)
            .fixedSize()
    }

    private func scrubLabel(hover: Double, width: CGFloat) -> some View {
        let text = TimeFormat.hover(model.time(atFraction: hover), duration: model.duration)
        let estimated = CGFloat(text.count) * 7 + 14
        let x = min(max(width * hover - estimated / 2, -MiniPlayerLayout.barSide + 8), width - estimated + MiniPlayerLayout.barSide - 8)
        return Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.white)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.74)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            .fixedSize()
            .offset(x: x, y: -26)
            .allowsHitTesting(false)
    }

    private func currentInteraction() -> SeekBarInteraction {
        if let interaction, interaction.model === model { return interaction }
        let created = SeekBarInteraction(model: model)
        interaction = created
        return created
    }
}
