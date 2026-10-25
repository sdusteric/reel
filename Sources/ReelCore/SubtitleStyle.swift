import Foundation

/// A rectangle in points with a top-left origin, as SwiftUI lays out the window.
public struct LayoutRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }

    public func intersects(_ other: LayoutRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }
}

/// Reel's default subtitle style and the size and position rules (design sections 8.4 and 8.5).
/// Values are on libass's 720-line reference (`PlayResY` 720).
public struct SubtitleStyle: Sendable, Hashable, Codable {
    public static let referenceHeight = 720.0
    public static let fontName = "PingFang SC"
    /// Medium.
    public static let fontWeight = 500
    /// IINA `subTextSize` 45 on mpv's 720-line scale: 6.25% of the video height.
    public static let baseSize = 45.0
    public static let outline = 2.5
    public static let shadowOffset = 1.4
    public static let shadowOpacity = 0.6
    public static let blur = 0.6
    public static let bottomMargin = 40.0
    public static let maximumLineWidthFraction = 0.9
    /// One size step on the 45 scale: Shift+G / Shift+F and the panel stepper (45, 50, 55).
    public static let sizeStep = 5.0
    public static let minimumSize = 20.0
    public static let maximumSize = 120.0
    /// mpv `sub-pos`: 100 is the bottom, 0 the top, up to 150 below the bottom.
    public static let defaultPosition = 100.0
    public static let positionRange = 0.0...150.0
    /// The lifted line's bottom edge sits this far above the controller's top edge.
    public static let liftGap = 12.0
    /// Lines a bottom band is sized for when checking the controller overlap.
    static let bandLines = 2.0
    static let lineHeight = 1.25

    /// The PingFang family for Reel's default style on one track: HK for Hong Kong and Cantonese
    /// tracks, MO for Macau, TC for other Traditional tracks, else SC. The same Medium face in the
    /// track's own glyph forms (section 8.4).
    public static func fontName(language: String?, title: String?, fileName: String?) -> String {
        var tags: [LanguageTag] = []
        if let language, let tag = LanguageTag(language) { tags.append(tag) }
        if let fileName {
            // The dot tokens between the stem and the extension ("hk.zh-HK.srt" gives zh-HK).
            tags += fileName.split(separator: ".").dropFirst().dropLast().compactMap { LanguageTag(String($0)) }
        }
        if tags.contains(where: { $0.isChinese && $0.region == "MO" }) { return "PingFang MO" }
        let hongKongTag = tags.contains { $0.code == "yue" || ($0.isChinese && $0.region == "HK") }
        let hongKongText = [title, fileName].compactMap(\.self).contains { $0.contains("粵") || $0.contains("粤") || $0.contains("港") }
        if hongKongTag || hongKongText { return "PingFang HK" }
        if tags.contains(where: { $0.chineseScript == .traditional })
            || SubtitleCharsetDetector.saysTraditional(fileName: fileName, title: title) {
            return "PingFang TC"
        }
        return fontName
    }

    /// The user's size on the 45 scale.
    public var size: Double
    /// mpv `sub-pos`.
    public var position: Double

    public init(size: Double = SubtitleStyle.baseSize, position: Double = SubtitleStyle.defaultPosition) {
        self.size = SubtitleStyle.clampSize(size)
        self.position = SubtitleStyle.clampPosition(position)
    }

    /// The libass font scale (`ass_set_font_scale`): 1 at size 45.
    public var scale: Double { size / SubtitleStyle.baseSize }

    public init(scale: Double, position: Double = SubtitleStyle.defaultPosition) {
        self.init(size: (scale * SubtitleStyle.baseSize).rounded(), position: position)
    }

    /// One Shift+G (positive) or Shift+F (negative) press, or a panel stepper press. Input.conf's
    /// `add sub-scale 0.1` is one step, so 45 goes to 50, 55, and to 40.
    public mutating func stepSize(by steps: Int) {
        let grid = (size / SubtitleStyle.sizeStep).rounded()
        size = SubtitleStyle.clampSize((grid + Double(steps)) * SubtitleStyle.sizeStep)
    }

    /// Input.conf's `add sub-scale` delta in steps: 0.1 is one step.
    public static func steps(forScaleDelta delta: Double) -> Int {
        guard delta != 0, delta.isFinite else { return 0 }
        let steps = Int((abs(delta) / 0.1).rounded())
        return (delta > 0 ? 1 : -1) * max(1, steps)
    }

    /// r (-1, up), Shift+R and t (+1, down): 1% of the video height per step.
    public mutating func movePosition(by delta: Double) {
        position = SubtitleStyle.clampPosition(position + delta)
    }

    public mutating func reset() {
        self = SubtitleStyle()
    }

    /// The panel and OSD number: "45", "50".
    public var sizeLabel: String { String(Int(size.rounded())) }

    /// "Subtitle Size 50".
    public var sizeOSDText: String { "Subtitle Size \(sizeLabel)" }

    /// How far the lines sit above the default, as a percentage of the video height.
    public var raisedPercent: Int { Int((SubtitleStyle.defaultPosition - position).rounded()) }

    /// "Subtitle Position 2%" after two presses of r.
    public var positionOSDText: String { "Subtitle Position \(raisedPercent)%" }

    /// Font size in points for a video or window `height` points tall, at this style's size.
    public func pointSize(forHeight height: Double) -> Double {
        size * height / SubtitleStyle.referenceHeight
    }

    // MARK: Lift above the controller (section 8.5, D32)

    /// The band where bottom-aligned lines are drawn, in a window of `windowSize`: centred, 90% of
    /// the width, from the window bottom up through the margin and two lines.
    public func subtitleBand(windowWidth: Double, windowHeight: Double) -> LayoutRect {
        let factor = windowHeight / SubtitleStyle.referenceHeight
        let height = (SubtitleStyle.bottomMargin + SubtitleStyle.bandLines * size * SubtitleStyle.lineHeight) * factor
        let width = windowWidth * SubtitleStyle.maximumLineWidthFraction
        return LayoutRect(x: (windowWidth - width) / 2, y: windowHeight - height, width: width, height: height)
    }

    /// The bottom inset for `setSubtitleAvoidance`: window height minus the controller's top edge
    /// plus 12 when the visible controller overlaps the subtitle band, else nil (no lift).
    public func liftInset(windowWidth: Double, windowHeight: Double, controllerFrame: LayoutRect?) -> Double? {
        guard let controllerFrame, windowHeight > 0, windowWidth > 0 else { return nil }
        let band = subtitleBand(windowWidth: windowWidth, windowHeight: windowHeight)
        guard controllerFrame.intersects(band) else { return nil }
        return windowHeight - controllerFrame.minY + SubtitleStyle.liftGap
    }

    // MARK: Delay text

    /// "Subtitle Delay +0.5 s", "Subtitle Delay 0.0 s".
    public static func subtitleDelayOSDText(_ seconds: Double) -> String {
        "Subtitle Delay " + delayText(seconds)
    }

    /// "Audio Delay -0.1 s".
    public static func audioDelayOSDText(_ seconds: Double) -> String {
        "Audio Delay " + delayText(seconds)
    }

    /// Signed with one decimal; zero has no sign. Rounded to 0.1 s so repeated 0.1 steps do not
    /// show float noise.
    public static func delayText(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded())
        if tenths == 0 { return "0.0 s" }
        let sign = tenths > 0 ? "+" : "-"
        let magnitude = abs(tenths)
        return "\(sign)\(magnitude / 10).\(magnitude % 10) s"
    }

    /// Adds `delta` to a delay and rounds to milliseconds.
    public static func adjustedDelay(_ seconds: Double, by delta: Double) -> Double {
        ((seconds + delta) * 1_000).rounded() / 1_000
    }

    static func clampSize(_ value: Double) -> Double {
        guard value.isFinite else { return baseSize }
        return min(max(value, minimumSize), maximumSize)
    }

    static func clampPosition(_ value: Double) -> Double {
        guard value.isFinite else { return defaultPosition }
        return min(max(value, positionRange.lowerBound), positionRange.upperBound)
    }
}
