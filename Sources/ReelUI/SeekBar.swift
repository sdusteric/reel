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

/// The controller's seek bar: track, stored range, played part, thumb, resume tick and the
/// hover pill (design 9.4 and 15).
struct SeekBar: View {
    static let trackHeight: CGFloat = 4
    static let hoverTrackHeight: CGFloat = 8
    static let thumbSize: CGFloat = 12
    static let hitHeight: CGFloat = 20

    let model: PlayerModel
    @State private var interaction: SeekBarInteraction?

    private var isActive: Bool { model.seekHoverFraction != nil || model.isScrubbing }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                track(width: width)
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
                    HoverPill(text: TimeFormat.hover(model.time(atFraction: hover), duration: model.duration))
                        .fixedSize()
                        .alignmentGuide(.leading) { dimensions in dimensions.width / 2 - width * hover }
                        .offset(y: -34)
                        .transition(.opacity.animation(.easeOut(duration: 0.1)))
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
    }

    private func currentInteraction() -> SeekBarInteraction {
        if let interaction, interaction.model === model { return interaction }
        let created = SeekBarInteraction(model: model)
        interaction = created
        return created
    }

    private func track(width: CGFloat) -> some View {
        let height = isActive ? SeekBar.hoverTrackHeight : SeekBar.trackHeight
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.2))
            if let range = model.storedRange {
                let start = model.fraction(of: range.lowerBound)
                let end = model.fraction(of: range.upperBound)
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: max(0, width * (end - start)))
                    .offset(x: width * start)
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
    }
}

/// Time under the pointer, on the controller material (design 9.4).
struct HoverPill: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.primary.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(ChromeStyle.stroke(colorScheme), lineWidth: 0.5))
    }
}
