import ReelCore
import SwiftUI

/// The speed panel (design 9.7, mockup png/04): preset segments and a Fine stepper. It stays open
/// while the stepper is pressed repeatedly.
struct SpeedPanelView: View {
    static let segmentTrackHeight: CGFloat = 26
    static let trackInset: CGFloat = 3
    static let trackRadius: CGFloat = 9
    static let segmentRadius: CGFloat = 7
    static let segmentGap: CGFloat = 2
    static let trackFill = 0.07
    static let presetText = 0.75

    let model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Speed")
            presets
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .padding(.bottom, 6)
            PanelStepperRow(
                label: "Fine",
                value: PlaybackSpeed.fineLabel(model.rate),
                altScale: 1,
                minus: { _ in model.stepSpeed(by: -1) },
                plus: { _ in model.stepSpeed(by: 1) }
            )
        }
        .padding(PanelMetrics.padding)
        .frame(width: PanelMetrics.speedWidth)
        .continuousSurface(radius: PanelMetrics.cornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speed")
        .accessibilityValue(model.speedAccessibilityValue)
    }

    private var presets: some View {
        HStack(spacing: SpeedPanelView.segmentGap) {
            ForEach(PlaybackSpeed.presets, id: \.self) { preset in
                let selected = PlaybackSpeed.preset(matching: model.rate) == preset
                Button {
                    model.setRate(preset)
                } label: {
                    Text(PlaybackSpeed.label(preset))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(SpeedPanelView.presetText))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: SpeedPanelView.segmentRadius, style: .continuous)
                                .fill(Color.accentColor)
                                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                                .opacity(selected ? 1 : 0)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PlaybackSpeed.label(preset))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: SpeedPanelView.segmentTrackHeight)
        .padding(SpeedPanelView.trackInset)
        .background(
            RoundedRectangle(cornerRadius: SpeedPanelView.trackRadius, style: .continuous)
                .fill(Color.primary.opacity(SpeedPanelView.trackFill))
        )
    }
}
