import AppKit
import ReelCore
import SwiftUI

/// The copy of the failure card (design 9.14), from a `MediaProblem`. The copy itself lives in
/// ReelCore; this adds what the card shows around it.
struct FailureCardContent: Equatable {
    var title: String
    /// The file name, middle-truncated at 520 pt; nil when the card is about a drive.
    var fileName: String?
    var explanation: String
    /// The technical reason, also in the log.
    var detail: String?
    var buttons: [MediaProblemButton]
    /// The SF Symbol for the tile, and whether an exclamation mark is drawn over it.
    var symbol: String
    var showsExclamation: Bool

    /// `savedPosition` is the resume time as the controller shows it ("31:04").
    init(problem: MediaProblem, fileName: String?, detail: String?, savedPosition: String?) {
        title = problem.title
        if case .volumeGone = problem {
            self.fileName = nil
        } else {
            self.fileName = fileName
        }
        explanation = problem.explanation(savedPosition: savedPosition)
        self.detail = detail?.isEmpty == false ? detail : nil
        buttons = problem.buttons
        // Fixed names, never looked up with NSImage: that call connects to the window server and
        // registers a shot-mode process as an application.
        symbol = problem.symbolName
        showsExclamation = problem.showsExclamation
    }
}

/// The failure card (mockups png/23 and png/26): a tile with a glyph, a title, the file name,
/// the explanation, the technical detail and capsule buttons. The video area is always black or a
/// dimmed frame, so the colours are fixed.
struct FailureCard: View {
    static let tileSize: CGFloat = 60
    static let tileRadius: CGFloat = 16
    static let glyphSize: CGFloat = 28
    static let fileNameWidth: CGFloat = 520
    /// 46 characters of 13 pt text.
    static let explanationWidth: CGFloat = 330
    static let buttonHeight: CGFloat = 26

    let content: FailureCardContent
    let action: (MediaProblemButton) -> Void

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: FailureCard.tileRadius, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: FailureCard.tileRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
                .overlay(glyph)
                .frame(width: FailureCard.tileSize, height: FailureCard.tileSize)
                .padding(.bottom, 18)
            Text(content.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
            if let fileName = content.fileName {
                Text(fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: FailureCard.fileNameWidth)
                    .padding(.top, 3)
            }
            Text(content.explanation)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: FailureCard.explanationWidth)
                .padding(.top, 12)
            if let detail = content.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: FailureCard.fileNameWidth)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                ForEach(Array(content.buttons.enumerated()), id: \.offset) { index, button in
                    FailureButton(title: button.title, isPrimary: index == content.buttons.count - 1) {
                        action(button)
                    }
                }
            }
            .padding(.top, 20)
        }
        .padding(24)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
    }
}

extension FailureCard {
    @ViewBuilder
    fileprivate var glyph: some View {
        ZStack {
            Image(systemName: content.symbol)
                .font(.system(size: FailureCard.glyphSize, weight: .regular))
            if content.showsExclamation {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .offset(y: 2)
            }
        }
        .foregroundStyle(Color.white.opacity(0.62))
    }
}

private struct FailureButton: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        let label = Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 12)
            .frame(height: FailureCard.buttonHeight)
            .background(Capsule().fill(isPrimary ? Color(nsColor: .systemBlue) : Color.white.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(isPrimary ? 0 : 0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        if isPrimary {
            Button(action: action) { label }
                .buttonStyle(PressScaleStyle())
                .keyboardShortcut(.defaultAction)
        } else {
            Button(action: action) { label }
                .buttonStyle(PressScaleStyle())
        }
    }
}
