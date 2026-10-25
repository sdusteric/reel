import CoreGraphics
import ReelCore
import SwiftUI

/// Where the lift above the controller comes from (design 8.5, D32).
nonisolated public enum SubtitleAvoidance {
    /// The bottom inset for `setSubtitleAvoidance`: the window height minus the controller's top
    /// edge plus 12 pt when the visible controller overlaps the subtitle band, else nil.
    public static func inset(style: SubtitleStyle, windowSize: CGSize, controllerFrame: CGRect?) -> Double? {
        let frame = controllerFrame.map {
            LayoutRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
        }
        return style.liftInset(
            windowWidth: Double(windowSize.width),
            windowHeight: Double(windowSize.height),
            controllerFrame: frame
        )
    }
}

/// A subtitle picture for screenshots: the app draws subtitles on the engine's CALayer, but a
/// shot has no layer, so it passes libass output (or nothing, for a built-in sample) here.
public struct ShotSubtitle {
    /// A full-window picture with transparent background; nil draws the built-in sample lines.
    public var image: CGImage?
    /// Where `image` goes, in points with a top-left origin; nil means the whole window.
    public var rect: CGRect?
    /// The lift the sample lines use, from `SubtitleAvoidance.inset`.
    public var liftInset: Double?

    public init(image: CGImage? = nil, rect: CGRect? = nil, liftInset: Double? = nil) {
        self.image = image
        self.rect = rect
        self.liftInset = liftInset
    }
}

/// The subtitle layer's SwiftUI side. In the app the picture is the engine's CALayer, so this view
/// draws nothing: it works out the lift from the controller and sends it to the engine. In shots
/// it draws a provided picture.
struct SubtitleOverlay: View {
    struct Input: Equatable {
        var windowSize: CGSize
        var controllerFrame: CGRect?
        var chromeVisible: Bool
        var style: SubtitleStyle
    }

    let model: PlayerModel
    let windowSize: CGSize
    let controllerFrame: CGRect?
    var shot: ShotSubtitle?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shot {
                if let image = shot.image {
                    let rect = shot.rect ?? CGRect(origin: .zero, size: windowSize)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    SampleSubtitles(windowHeight: windowSize.height, liftInset: shot.liftInset)
                        .frame(width: windowSize.width, height: windowSize.height)
                }
            }
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .onChange(of: input, initial: true) {
            model.updateSubtitleAvoidance(windowSize: windowSize, controllerFrame: controllerFrame)
        }
    }

    private var input: Input {
        Input(
            windowSize: windowSize,
            controllerFrame: controllerFrame,
            chromeVisible: model.chrome.isVisible,
            style: model.subtitleStyle
        )
    }
}

/// Two bilingual lines in Reel's default style (white, black outline, shadow), for shots made
/// without the libass renderer.
struct SampleSubtitles: View {
    let windowHeight: CGFloat
    var liftInset: Double?

    private var factor: CGFloat { windowHeight / SubtitleStyle.referenceHeight }

    var body: some View {
        VStack(spacing: 2 * factor) {
            OutlinedText(text: "\u{522B}\u{56DE}\u{5934}\u{FF0C}\u{7EE7}\u{7EED}\u{5F80}\u{524D}\u{8D70}\u{3002}", size: SubtitleStyle.baseSize * factor, factor: factor)
            OutlinedText(text: "Don't look back. Keep walking.", size: SubtitleStyle.baseSize * 0.72 * factor, factor: factor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, liftInset.map { CGFloat($0) } ?? SubtitleStyle.bottomMargin * factor)
    }
}

private struct OutlinedText: View {
    let text: String
    let size: CGFloat
    let factor: CGFloat

    private var radius: CGFloat { SubtitleStyle.outline * factor }

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { step in
                let angle = Double(step) / 12 * 2 * .pi
                label.foregroundStyle(Color.black)
                    .offset(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius)
            }
            label.foregroundStyle(Color.black.opacity(SubtitleStyle.shadowOpacity))
                .offset(y: SubtitleStyle.shadowOffset * factor + radius)
            label.foregroundStyle(Color.white)
        }
    }

    private var label: some View {
        Text(text).font(.system(size: size, weight: .medium))
    }
}
