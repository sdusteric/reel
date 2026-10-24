import ReelCore
import SwiftUI

/// Top-left on-screen display (design 9.5): 20 pt semibold rounded text on the controller
/// material, corner radius 10, with Start Over for resume and a progress ring for slow seeks.
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
                Text(message.text)
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .fixedSize()
                if model.showsSeekProgress, message.kind == .seek || message.kind == .frameStep {
                    ProgressRing()
                        .frame(width: 16, height: 16)
                }
                if message.showsStartOver {
                    Button("Start Over") {
                        model.startOver()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OSDView.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OSDView.cornerRadius, style: .continuous)
                    .strokeBorder(ChromeStyle.stroke(colorScheme), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))
                    .animation(.easeOut(duration: 0.12)),
                removal: .opacity.animation(.easeIn(duration: 0.25))
            ))
        }
    }
}

extension OSDView {
    static func symbol(for message: OSDMessage) -> String? {
        switch message.kind {
        case .volume:
            let level = Int(message.text.filter(\.isNumber)) ?? 0
            if level == 0 { return "speaker.slash.fill" }
            return level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .mute: return "speaker.slash.fill"
        case .resume: return "arrow.counterclockwise"
        case .seek, .frameStep: return nil
        }
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
