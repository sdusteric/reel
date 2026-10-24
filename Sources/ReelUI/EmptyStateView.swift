import SwiftUI

/// The window with no file (design 9.1): black, with centred hints. The whole window is a drop
/// target (handled by the app's content view). The hints sit on the always-black video area, so
/// they use the dark appearance's secondary and tertiary colours; light ones would be invisible.
struct EmptyStateView: View {
    var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 6) {
                Text("Open a video")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Drop a file here or press \u{2318}O")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
