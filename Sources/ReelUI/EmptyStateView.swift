import SwiftUI

/// The window with no file (design 9.1): black, with centred hints. The whole window is a drop
/// target (handled by the app's content view). The hints sit on the always-black video area, so
/// they use the dark appearance's secondary and tertiary colours; light ones would be invisible.
struct EmptyStateView: View {
    var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.62))
                    )
                    .frame(width: 60, height: 60)
                    .padding(.bottom, 18)
                Text("Open a video")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .padding(.bottom, 6)
                HStack(spacing: 5) {
                    Text("Drop a file here or press")
                    Text("\u{2318}O")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.1)))
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .padding(.top, 10)
                }
            }
            .padding(24)
            .environment(\.colorScheme, .dark)
        }
    }
}
