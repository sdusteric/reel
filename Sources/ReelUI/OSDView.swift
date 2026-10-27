import AppKit
import ReelCore
import SwiftUI

/// Top-left on-screen display (design 9.5): 20 pt semibold rounded text on the controller
/// material, corner radius 14, with Start Over for resume, Show for screenshots and a progress
/// ring for slow seeks.
struct OSDView: View {
    static let edgeInset: CGFloat = 20
    static let cornerRadius: CGFloat = 14

    /// The window's OSD, or the mini player's smaller one (mini player design section 5).
    struct Style: Equatable {
        var textSize: CGFloat
        var symbolSize: CGFloat
        var inset: CGFloat
        var padding: CGSize

        static let window = Style(textSize: 20, symbolSize: 17, inset: 20, padding: CGSize(width: 16, height: 10))
        static let mini = Style(textSize: 15, symbolSize: 13, inset: 10, padding: CGSize(width: 12, height: 7))
    }

    let model: PlayerModel
    var style = Style.window
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.dolbyVisionNoteVisible {
                DolbyVisionNote(
                    showInfo: { model.showInfoFromNote() },
                    dismiss: { model.dismissDolbyVisionNote() }
                )
                .transition(entryTransition)
            }
            if let message = model.osd {
                messageView(message)
            }
        }
    }

    private var entryTransition: AnyTransition {
        Motion.osdTransition(reduceMotion: reduceMotion)
    }

    private func messageView(_ message: OSDMessage) -> some View {
        HStack(spacing: 10) {
            if let symbol = OSDView.symbol(for: message) {
                Image(systemName: symbol)
                    .font(.system(size: style.symbolSize, weight: .semibold))
                    .foregroundStyle(symbolStyle(symbol))
                    .frame(width: style.symbolSize + 7)
            }
            text(for: message)
                .font(.system(size: style.textSize, weight: .semibold, design: .rounded).monospacedDigit())
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
        .padding(.horizontal, style.padding.width)
        .padding(.vertical, style.padding.height)
        .continuousSurface(radius: OSDView.cornerRadius, shadow: .small)
        .transition(entryTransition)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.text)
    }

    /// The warning glyph takes the warning colour at the symbol opacity; every other glyph is primary.
    private func symbolStyle(_ symbol: String) -> Color {
        if symbol == OSDMessage.warningSymbol { return WarningColor.onMaterial(colorScheme).opacity(0.7) }
        return Color.primary.opacity(0.7)
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
        case .noData, .damaged, .audioFailure: return OSDMessage.warningSymbol
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
            .buttonStyle(PressScaleStyle())
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

/// The Dolby Vision profile 5 note (design 9.13, mockup png/22): the OSD in a two-line variant
/// with Show Info and OK. Shown by `PlayerModel` once per file, until OK, Esc or 10 s.
struct DolbyVisionNote: View {
    static let maxWidth: CGFloat = 452

    let showInfo: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: OSDMessage.warningSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WarningColor.onMaterial(colorScheme))
                .frame(width: 20, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(DolbyVisionPolicy.noteTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.9))
                Text(DolbyVisionPolicy.noteBody)
                    .font(.system(size: 12))
                    .foregroundStyle(ChromeStyle.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    NoteButton(title: DolbyVisionPolicy.noteShowInfoButton, isPrimary: false, action: showInfo)
                    NoteButton(title: DolbyVisionPolicy.noteOKButton, isPrimary: true, action: dismiss)
                }
                .padding(.top, 6)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: DolbyVisionNote.maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .continuousSurface(radius: OSDView.cornerRadius, shadow: .small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DolbyVisionPolicy.noteTitle)
    }
}

private struct NoteButton: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.white : Color.primary.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(isPrimary ? Color(nsColor: .systemBlue) : Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}
