import ReelCore
import SwiftUI

/// Turns pointer input on the seek bar into seeks (design 9.4): a drag sends `.scrub(t)` on
/// every move and one `.exact(t)` on release; a click without a drag sends `.exact(t)`.
/// Kept apart from the view so tests can drive it without a window.
public final class SeekBarInteraction {
    /// Movement below this many points is a click, not a drag.
    public static let dragThreshold: CGFloat = 2

    public let model: PlayerModel
    public private(set) var isDragging = false

    public init(model: PlayerModel) {
        self.model = model
    }

    public static func fraction(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// The pointer moved with the button down, from `startX` to `x`.
    public func dragChanged(startX: CGFloat, x: CGFloat, width: CGFloat) {
        if !isDragging {
            guard abs(x - startX) >= SeekBarInteraction.dragThreshold else { return }
            isDragging = true
        }
        let fraction = SeekBarInteraction.fraction(x: x, width: width)
        model.setSeekHover(fraction)
        model.scrub(to: model.time(atFraction: fraction))
    }

    /// The button went up at `x`.
    public func dragEnded(x: CGFloat, width: CGFloat) {
        let target = model.time(atFraction: SeekBarInteraction.fraction(x: x, width: width))
        if isDragging {
            isDragging = false
            model.endScrub(at: target)
        } else {
            model.seek(to: target, source: .pointer)
        }
    }
}

/// The controller's seek bar: track, stored range, loop marks, played part, thumb, resume tick and
/// the hover pill with its thumbnail (design 9.4 and 15.2).
struct SeekBar: View {
    static let trackHeight: CGFloat = 4
    static let hoverTrackHeight: CGFloat = 8
    static let thumbSize: CGFloat = 12
    static let hitHeight: CGFloat = 20
    static let loopMarkSize = CGSize(width: 3, height: 14)

    let model: PlayerModel
    let context: ControllerContext
    @State private var interaction: SeekBarInteraction?
    @Environment(\.colorScheme) private var colorScheme

    private var isActive: Bool { model.seekHoverFraction != nil || model.isScrubbing }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let barFrame = proxy.frame(in: .named(ChromeStyle.controllerSpace))
            ZStack(alignment: .leading) {
                track(width: width)
                loopMarks(width: width)
                if isActive {
                    Circle()
                        .fill(Color.white)
                        .frame(width: SeekBar.thumbSize, height: SeekBar.thumbSize)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .offset(x: width * model.playedFraction - SeekBar.thumbSize / 2)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: SeekBar.hitHeight)
            .overlay(alignment: .topLeading) {
                if let hover = model.seekHoverFraction {
                    hoverOverlay(hover: hover, width: width, barFrame: barFrame)
                        .allowsHitTesting(false)
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
                        let interaction = currentInteraction()
                        interaction.dragChanged(startX: value.startLocation.x, x: value.location.x, width: width)
                    }
                    .onEnded { value in
                        currentInteraction().dragEnded(x: value.location.x, width: width)
                    }
            )
        }
        .frame(height: SeekBar.hitHeight)
        .animation(.spring(duration: 0.18), value: isActive)
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue(model.elapsedLabel)
    }

    private func currentInteraction() -> SeekBarInteraction {
        if let interaction, interaction.model === model { return interaction }
        let created = SeekBarInteraction(model: model)
        interaction = created
        return created
    }

    /// With a thumbnail: a 12 pt container 8 pt above the controller, centred on the pointer and
    /// kept 16 pt inside the window. Without one: the time capsule above the track, kept inside
    /// the bar's ends.
    private func hoverOverlay(hover: Double, width: CGFloat, barFrame: CGRect) -> some View {
        let time = TimeFormat.hover(model.time(atFraction: hover), duration: model.duration)
        let hasThumbnail = model.hoverThumbnail != nil
        let windowRange = (ControllerLayout.edgeMargin - context.frame.minX - barFrame.minX)...(
            context.windowSize.width - ControllerLayout.edgeMargin - context.frame.minX - barFrame.minX
        )
        return AboveLayout(
            x: width * hover,
            centered: true,
            range: hasThumbnail ? windowRange : 0...width,
            gap: hasThumbnail ? barFrame.minY + ThumbnailPill.gap : 12
        ) {
            if let image = model.hoverThumbnail {
                ThumbnailPill(image: image, time: time)
                    .fixedSize()
                    .transition(.opacity)
            } else {
                HoverPill(text: time)
                    .fixedSize()
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
        .animation(Motion.easeOut(0.12), value: hasThumbnail)
    }

    private func track(width: CGFloat) -> some View {
        let height = isActive ? SeekBar.hoverTrackHeight : SeekBar.trackHeight
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.18))
            if let range = model.storedRange {
                let start = model.fraction(of: range.lowerBound)
                let end = model.fraction(of: range.upperBound)
                Capsule()
                    .fill(Color.primary.opacity(0.4))
                    .frame(width: max(0, width * (end - start)))
                    .offset(x: width * start)
            }
            if let range = model.loop.range {
                let start = model.fraction(of: range.lowerBound)
                let end = model.fraction(of: range.upperBound)
                Rectangle()
                    .fill(ChromeStyle.accentTint(colorScheme))
                    .frame(width: max(0, width * (end - start)), height: height)
                    .offset(x: width * start)
                    .transition(.opacity)
            }
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(height, width * model.playedFraction))
                .opacity(model.playedFraction > 0 ? 1 : 0)
            if let marker = model.resumeMarker {
                Rectangle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 2, height: height)
                    .offset(x: width * model.fraction(of: marker) - 1)
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
        .animation(Motion.easeOut(0.12), value: model.loop)
    }

    /// A and B as 3 x 14 pt accent capsules, taller than the track (design 9.4).
    private func loopMarks(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            if let start = model.loop.start {
                loopMark(width: width, at: start)
            }
            if let end = model.loop.end {
                loopMark(width: width, at: end)
            }
        }
        .frame(width: width, height: SeekBar.hitHeight, alignment: .leading)
        .animation(Motion.easeOut(0.12), value: model.loop)
    }

    private func loopMark(width: CGFloat, at time: MediaTime) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: SeekBar.loopMarkSize.width, height: SeekBar.loopMarkSize.height)
            .offset(x: width * model.fraction(of: time) - SeekBar.loopMarkSize.width / 2)
            .transition(.opacity)
    }
}

/// Time under the pointer, on the controller material (design 9.4).
struct HoverPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.primary.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .chromeSurface(Capsule(), shadow: .small)
    }
}
