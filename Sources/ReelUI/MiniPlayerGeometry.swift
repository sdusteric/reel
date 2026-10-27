import CoreGraphics
import ReelCore

/// Size and place of the mini player (mini player design section 4). AppKit screen
/// coordinates, y up. Pure so it can be tested.
nonisolated public enum MiniPlayerGeometry {
    public static let defaultBox = CGSize(width: 480, height: 360)
    public static let minimumBox = CGSize(width: 256, height: 192)
    /// Distance from both edges of the visible frame.
    public static let inset: CGFloat = 20
    public static let skipButtonsMinimumWidth: CGFloat = 320
    /// Subtitles keep the size they have at this panel height, so a size 45 line stays 13 pt or more.
    public static let subtitleFloorHeight: CGFloat = 208
    /// UIScrollView's normal rate, used to project a flick to where it would come to rest.
    public static let decelerationRate: CGFloat = 0.998

    /// The video's aspect fitted into the default box times `boxScale`, with the box clamped
    /// between the smallest box and half the visible frame.
    public static func size(aspect: CGFloat, boxScale: Double, visible: CGRect) -> CGSize {
        let scale = boxScale.isFinite && boxScale > 0 ? CGFloat(boxScale) : 1
        let box = CGSize(
            width: min(max(defaultBox.width * scale, minimumBox.width), visible.width / 2),
            height: min(max(defaultBox.height * scale, minimumBox.height), visible.height / 2)
        )
        guard aspect.isFinite, aspect > 0 else { return box }
        let fitted = aspect >= box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
        return CGSize(width: rounded(fitted.width), height: rounded(fitted.height))
    }

    /// The box scale that gives `size` for `aspect` (the inverse of `size`, unclamped).
    public static func boxScale(for size: CGSize, aspect: CGFloat) -> Double {
        let defaultAspect = defaultBox.width / defaultBox.height
        return Double(aspect >= defaultAspect ? size.width / defaultBox.width : size.height / defaultBox.height)
    }

    public static func frame(size: CGSize, corner: MiniPlayerCorner, visible: CGRect) -> CGRect {
        let left = visible.minX + inset
        let right = visible.maxX - inset - size.width
        let bottom = visible.minY + inset
        let top = visible.maxY - inset - size.height
        let origin: CGPoint
        switch corner {
        case .topLeft: origin = CGPoint(x: left, y: top)
        case .topRight: origin = CGPoint(x: right, y: top)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        }
        return CGRect(origin: origin, size: size)
    }

    /// The corner whose quadrant holds the frame's centre projected by the release velocity
    /// (points per second), so a flick lands where it was thrown.
    public static func corner(releasing frame: CGRect, velocity: CGVector, visible: CGRect) -> MiniPlayerCorner {
        let travel = decelerationRate / (1 - decelerationRate) / 1000
        let x = frame.midX + velocity.dx * travel
        let y = frame.midY + velocity.dy * travel
        let right = x > visible.midX
        let top = y > visible.midY
        return top ? (right ? .topRight : .topLeft) : (right ? .bottomRight : .bottomLeft)
    }

    /// The saved display if it is still connected, else `fallback` (the main screen).
    public static func screen(saved: String?, available: [String], fallback: String) -> String {
        guard let saved, available.contains(saved) else { return fallback }
        return saved
    }

    public static func showsSkipButtons(width: CGFloat) -> Bool {
        width >= skipButtonsMinimumWidth
    }

    private static func rounded(_ value: CGFloat) -> CGFloat {
        (value * 1000).rounded() / 1000
    }
}
