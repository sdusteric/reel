import ReelCore
import SwiftUI

/// Shared chrome styling (design 9.3 and 15).
enum ChromeStyle {
    /// The 0.5 pt inner stroke: white 12% in dark, black 8% in light.
    static func stroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    static let timeFont = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let iconSize: CGFloat = 17
    static let playIconSize: CGFloat = 22
    static let hitSize: CGFloat = 28
    static let playHitSize: CGFloat = 32
}

/// Controller geometry (design 9.3). Positions are SwiftUI coordinates (origin top-left).
nonisolated public enum ControllerLayout {
    public static let height: CGFloat = 76
    public static let cornerRadius: CGFloat = 22
    public static let horizontalPadding: CGFloat = 14
    public static let verticalPadding: CGFloat = 10
    public static let edgeMargin: CGFloat = 16
    public static let minimumWidth: CGFloat = 360
    public static let maximumWidth: CGFloat = 560
    public static let maximumWindowFraction: CGFloat = 0.7

    /// 480 pt in a 1280 pt window, scaling with the window between 360 and 560, and never more
    /// than 70% of the window width.
    public static func width(windowWidth: CGFloat) -> CGFloat {
        let scaled = min(max(windowWidth * 0.375, minimumWidth), maximumWidth)
        return max(0, min(scaled, windowWidth * maximumWindowFraction))
    }

    /// The controller frame for stored fractions (centre x, bottom edge from the window bottom),
    /// clamped to keep 16 pt from every edge.
    public static func frame(in size: CGSize, centerX: Double, bottomY: Double) -> CGRect {
        let width = width(windowWidth: size.width)
        let centre = size.width * centerX
        var minX = centre - width / 2
        minX = min(max(minX, edgeMargin), max(edgeMargin, size.width - edgeMargin - width))
        let bottom = size.height * bottomY
        var maxY = size.height - bottom
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
}

/// What the controller's buttons do beyond the model (window-level actions).
public struct SceneActions {
    public var toggleFullscreen: () -> Void

    public init(toggleFullscreen: @escaping () -> Void = {}) {
        self.toggleFullscreen = toggleFullscreen
    }
}

/// The floating frosted controller (design 9.3).
struct ControllerView: View {
    let model: PlayerModel
    let actions: SceneActions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text(model.elapsedLabel)
                    .font(ChromeStyle.timeFont)
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .fixedSize()
                SeekBar(model: model)
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
            ZStack {
                HStack(spacing: 4) {
                    VolumeControl(model: model)
                    Spacer(minLength: 0)
                    ChromeButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full Screen") {
                        actions.toggleFullscreen()
                    }
                }
                HStack(spacing: 18) {
                    ChromeButton(symbol: "gobackward.10", help: "Back 10 Seconds", enabled: model.hasMedia) {
                        model.seek(by: -PlayerModel.buttonSeekStep, source: .pointer)
                    }
                    ChromeButton(
                        symbol: model.isPlaying ? "pause.fill" : "play.fill",
                        size: ChromeStyle.playIconSize,
                        hitSize: ChromeStyle.playHitSize,
                        help: model.isPlaying ? "Pause" : "Play",
                        enabled: model.hasMedia
                    ) {
                        model.togglePause()
                    }
                    ChromeButton(symbol: "goforward.10", help: "Forward 10 Seconds", enabled: model.hasMedia) {
                        model.seek(by: PlayerModel.buttonSeekStep, source: .pointer)
                    }
                }
            }
            .frame(height: ChromeStyle.playHitSize)
        }
        .padding(.horizontal, ControllerLayout.horizontalPadding)
        .padding(.vertical, ControllerLayout.verticalPadding)
        .frame(height: ControllerLayout.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ControllerLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ControllerLayout.cornerRadius, style: .continuous)
                .strokeBorder(ChromeStyle.stroke(colorScheme), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onHover { model.chrome.setPointerOverController($0) }
    }
}

/// An SF Symbol button with a hover circle (design 9.3).
struct ChromeButton: View {
    let symbol: String
    var size: CGFloat = ChromeStyle.iconSize
    var hitSize: CGFloat = ChromeStyle.hitSize
    let help: String
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(Color.primary.opacity(enabled ? 0.9 : 0.55))
                .frame(width: hitSize, height: hitSize)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .opacity(hovering && enabled ? 1 : 0)
                        .animation(.easeInOut(duration: 0.12), value: hovering)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Mute button plus a 72 pt slider that widens to 120 pt on hover (design 9.3).
struct VolumeControl: View {
    static let narrowWidth: CGFloat = 72
    static let wideWidth: CGFloat = 120

    let model: PlayerModel
    @State private var hovering = false

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
            withAnimation(.easeInOut(duration: 0.12)) { hovering = over }
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
