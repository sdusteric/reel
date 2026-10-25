import CoreGraphics
import SwiftUI

/// What the main window shows while Picture in Picture is active (design 9.9, mockup png/16): the
/// frame from when PiP started, blurred and darkened, a tile with the PiP glyph, a line of text
/// and an Exit button. The area is always dark, so the colours are fixed.
struct PiPPlaceholder: View {
    static let tileSize: CGFloat = 60
    static let blurRadius: CGFloat = 48
    static let brightness: Double = 0.42
    static let glyphSize: CGFloat = 20
    /// The group sits this much above the centre, clear of the controller (mockup `.pipc`).
    static let bottomPadding: CGFloat = 60

    let snapshot: CGImage?
    let exit: () -> Void

    var body: some View {
        ZStack {
            Color.black
            backdrop
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .overlay(
                        Image(systemName: "pip.enter")
                            .font(.system(size: PiPPlaceholder.glyphSize, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.62))
                    )
                    .frame(width: PiPPlaceholder.tileSize, height: PiPPlaceholder.tileSize)
                Text("Playing in Picture in Picture")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .padding(.top, 18)
                Text("Playback controls here still work.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .padding(.top, 6)
                Button(action: exit) {
                    Text("Exit Picture in Picture")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .padding(.top, 16)
            }
            .padding(.bottom, PiPPlaceholder.bottomPadding)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playing in Picture in Picture")
    }

    @ViewBuilder
    private var backdrop: some View {
        if let snapshot {
            GeometryReader { proxy in
                Image(decorative: snapshot, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: PiPPlaceholder.blurRadius)
                    .overlay(Color.black.opacity(1 - PiPPlaceholder.brightness))
                    .clipped()
            }
        } else {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.06, blue: 0.14), Color(red: 0.16, green: 0.1, blue: 0.16)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
