import ReelCore
import SwiftUI

/// What the title bar tag says, from the presentation plan (design 9.13): "HDR10", "HLG",
/// "Dolby Vision" or "Dolby Vision 5", with "SDR" after it when the picture is tone-mapped and a
/// warning glyph for profile 5. SDR files have no tag.
struct DynamicRangeTagContent: Equatable {
    var text: String
    var detail: String?
    var warning: Bool
    var tooltip: String
    var accessibilityLabel: String

    init?(plan: DynamicRangePlan) {
        guard let text = plan.tag else { return nil }
        self.text = text
        detail = plan.tagDetail
        warning = plan.warning
        tooltip = plan.tagTooltip ?? DynamicRangePlan.hdrTooltip
        accessibilityLabel = plan.accessibilityLabel ?? "Dynamic range, \(text)"
    }
}

/// The warning colours of 15.3: system yellow on the dark scrim and in dark appearance,
/// `#b25000` on the light material.
enum WarningColor {
    static let lightMaterial = Color(red: 0xB2 / 255, green: 0x50 / 255, blue: 0)

    static func onMaterial(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.yellow : lightMaterial
    }
}

/// The tag after the title (design 9.13, mockups png/19, 21 and 22). It always sits on the black
/// title scrim, so its colours are fixed. A button: click toggles Video Info.
struct DynamicRangeTag: View {
    static let height: CGFloat = 18
    static let cornerRadius: CGFloat = 5
    static let horizontalPadding: CGFloat = 7
    static let textSize: CGFloat = 10.5
    static let warningSize: CGFloat = 11
    /// 3% of the 10.5 pt text.
    static let tracking: CGFloat = 0.315
    static let gap: CGFloat = 8

    let content: DynamicRangeTagContent
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if content.warning {
                    Image(systemName: OSDMessage.warningSymbol)
                        .font(.system(size: DynamicRangeTag.warningSize))
                        .foregroundStyle(Color.yellow)
                }
                Text(content.text)
                    .font(.system(size: DynamicRangeTag.textSize, weight: .semibold))
                    .tracking(DynamicRangeTag.tracking)
                    .foregroundStyle(Color.white.opacity(0.88))
                if let detail = content.detail {
                    Text(detail)
                        .font(.system(size: DynamicRangeTag.textSize, weight: .medium))
                        .tracking(DynamicRangeTag.tracking)
                        .foregroundStyle(Color.white.opacity(0.62))
                        .transition(.opacity)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, DynamicRangeTag.horizontalPadding)
            .frame(height: DynamicRangeTag.height)
            .background(
                RoundedRectangle(cornerRadius: DynamicRangeTag.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.2 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DynamicRangeTag.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: DynamicRangeTag.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? Motion.reduced : Motion.easeInOut(0.15), value: content.detail)
        .help(content.tooltip)
        .accessibilityLabel(content.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .environment(\.colorScheme, .dark)
    }
}

/// The tag's tooltip drawn by hand, for shots (a system tooltip needs a window).
struct TagTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Color.primary.opacity(0.9))
            .multilineTextAlignment(.leading)
            .frame(width: 280, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .continuousSurface(radius: 10, shadow: .small)
    }
}

extension Motion {
    /// The failure card: opacity only, 0.2 s ease-out. A failure gets no shake or slide.
    static func failureTransition(reduceMotion: Bool) -> AnyTransition {
        .opacity.animation(reduceMotion ? reduced : easeOut(0.2))
    }

    /// Drive gone: the frame dims over 0.3 s, then the card fades in 0.2 s after 0.1 s.
    static func driveGoneDimAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : easeOut(0.3)
    }

    static func driveGoneCardTransition(reduceMotion: Bool) -> AnyTransition {
        .opacity.animation(reduceMotion ? reduced : easeOut(0.2).delay(0.1))
    }
}
