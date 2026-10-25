import ReelCore
import SwiftUI

/// Top-left on-screen display (design 9.5): 20 pt semibold rounded text on the controller
/// material, corner radius 14, with Start Over for resume, Show for screenshots and a progress
/// ring for slow seeks.
struct OSDView: View {
    static let edgeInset: CGFloat = 20
    static let cornerRadius: CGFloat = 14

    let model: PlayerModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let message = model.osd {
            HStack(spacing: 10) {
                if let symbol = OSDView.symbol(for: message) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: 24)
                }
                text(for: message)
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .fixedSize()
                if model.showsSeekProgress, message.kind == .seek || message.kind == .frameStep {
                    ProgressRing()
                        .frame(width: 16, height: 16)
                }
                if message.showsStartOver {
                    OSDButton(title: "Start Over") { model.startOver() }
                }
                if message.showsReveal {
                    OSDButton(title: "Show") { model.revealScreenshot() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .continuousSurface(radius: OSDView.cornerRadius, shadow: .small)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))
                    .animation(.easeOut(duration: 0.12)),
                removal: .opacity.animation(.easeIn(duration: 0.25))
            ))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message.text)
        }
    }

    /// "Loop 31:04 to 32:10" sets "to" at regular weight and secondary colour.
    private func text(for message: OSDMessage) -> Text {
        guard message.kind == .loop, let range = message.text.range(of: " to ") else {
            return Text(message.text)
        }
        let connector = Text(" to ").fontWeight(.regular).foregroundStyle(ChromeStyle.secondaryText(colorScheme))
        return Text("\(String(message.text[..<range.lowerBound]))\(connector)\(String(message.text[range.upperBound...]))")
    }
}

extension OSDView {
    static func symbol(for message: OSDMessage) -> String? {
        if let symbol = message.symbol { return symbol }
        switch message.kind {
        case .volume:
            let level = Int(message.text.filter(\.isNumber)) ?? 0
            if level == 0 { return "speaker.slash.fill" }
            return level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .mute: return "speaker.slash.fill"
        case .resume: return "arrow.counterclockwise"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .subtitleDelay, .subtitleSize, .subtitlePosition: return "captions.bubble.fill"
        case .audioDelay: return "waveform"
        case .loop: return "repeat"
        case .fileLoop: return "repeat.1"
        case .screenshot: return "camera"
        case .seek, .frameStep, .track, .episode: return nil
        }
    }
}

/// The small capsule button inside an OSD (Start Over, Show).
private struct OSDButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// A small spinning arc, drawn so it renders without AppKit.
struct ProgressRing: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
