import ReelCore
import SwiftUI

/// The end-of-episode card (design 9.8, mockup png/14): 360 pt wide, 20 pt radius, a 128 x 72
/// thumbnail of the next file with a countdown ring, its name, and Cancel and Play Now.
struct NextEpisodeCard: View {
    static let width: CGFloat = 360
    static let padding: CGFloat = 12
    static let cornerRadius: CGFloat = 20
    static let thumbnailSize = CGSize(width: 128, height: 72)
    static let ringSize: CGFloat = 34
    static let buttonHeight: CGFloat = 26

    let model: PlayerModel
    let autoAdvance: AutoAdvance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Next Episode")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.9))
                    Spacer(minLength: 6)
                    Text(autoAdvance.remainingLabel)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(ChromeStyle.secondaryText(colorScheme))
                }
                Text(autoAdvance.nextName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    CardButton(title: "Cancel", prominent: false) { autoAdvance.cancel() }
                        .keyboardShortcut(.cancelAction)
                    CardButton(title: "Play Now", prominent: true) { autoAdvance.playNow() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(height: NextEpisodeCard.thumbnailSize.height)
        }
        .padding(NextEpisodeCard.padding)
        .frame(width: NextEpisodeCard.width)
        .continuousSurface(radius: NextEpisodeCard.cornerRadius)
        .onHover { autoAdvance.setHovered($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next Episode")
        .accessibilityValue("\(autoAdvance.nextName), \(autoAdvance.remainingLabel)")
    }

    private var thumbnail: some View {
        Button {
            autoAdvance.playNow()
        } label: {
            ZStack {
                if let image = autoAdvance.thumbnail {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.primary.opacity(0.14))
                }
                Circle()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: NextEpisodeCard.ringSize, height: NextEpisodeCard.ringSize)
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 2.5)
                    .frame(width: NextEpisodeCard.ringSize, height: NextEpisodeCard.ringSize)
                Circle()
                    .trim(from: 0, to: autoAdvance.progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: NextEpisodeCard.ringSize, height: NextEpisodeCard.ringSize)
                    .animation(reduceMotion ? nil : .linear(duration: AutoAdvance.tickInterval), value: autoAdvance.progress)
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: NextEpisodeCard.thumbnailSize.width, height: NextEpisodeCard.thumbnailSize.height)
            .clipShape(RoundedRectangle(cornerRadius: NextEpisodeCard.cornerRadius - NextEpisodeCard.padding, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play Now")
    }
}

/// A 26 pt capsule button: Cancel on a hover tint, Play Now in the accent colour.
private struct CardButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: NextEpisodeCard.buttonHeight)
                .background(
                    Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(hovering ? 0.16 : 0.1))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
    }
}
