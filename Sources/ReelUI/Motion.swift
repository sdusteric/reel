import QuartzCore
import SwiftUI

/// A CSS-style cubic bezier, shared by SwiftUI animations and Core Animation timing functions so
/// the chrome, the traffic lights and the window frame move on one curve (design 15.2).
nonisolated public struct MotionCurve: Equatable, Sendable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// `cubic-bezier(0.23, 1, 0.32, 1)`: a strong ease-out for anything the user caused.
    public static let easeOut = MotionCurve(0.23, 1, 0.32, 1)
    /// `cubic-bezier(0.4, 0, 1, 1)`: exits.
    public static let easeIn = MotionCurve(0.4, 0, 1, 1)
    /// `cubic-bezier(0.65, 0, 0.35, 1)`: state changes that stay on screen.
    public static let easeInOut = MotionCurve(0.65, 0, 0.35, 1)

    public var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }

    public func animation(duration: TimeInterval) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }

    /// The eased progress (0 to 1) at `fraction` (0 to 1) of the duration.
    public func progress(at fraction: Double) -> Double {
        let time = min(max(fraction, 0), 1)
        var low = 0.0
        var high = 1.0
        var parameter = time
        for _ in 0..<40 {
            let x = MotionCurve.bezier(parameter, x1, x2)
            if abs(x - time) < 1e-7 { break }
            if x < time { low = parameter } else { high = parameter }
            parameter = (low + high) / 2
        }
        return MotionCurve.bezier(parameter, y1, y2)
    }

    private static func bezier(_ s: Double, _ c1: Double, _ c2: Double) -> Double {
        let inverse = 1 - s
        return 3 * inverse * inverse * s * c1 + 3 * inverse * s * s * c2 + s * s * s
    }
}

/// How long and how a moving thing runs outside SwiftUI (the window frame), with Reduce Motion
/// applied. Public because the app target drives `NSWindow`.
nonisolated public enum MotionTiming {
    /// A new video or Cmd+0 to 3 resizes the window over 0.2 s; with Reduce Motion it jumps,
    /// because the picture would scale under the pointer.
    public static let windowResizeDuration: TimeInterval = 0.2

    public static func windowResizeDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : windowResizeDuration
    }

    public static var windowResizeTimingFunction: CAMediaTimingFunction { MotionCurve.easeOut.timingFunction }

    /// The mini player's one move (mini player design section 8, row 1): the picture travels
    /// between the window and its corner over 0.3 s on the shared ease-out. With Reduce Motion
    /// the window and the panel cross-fade, 0.15 s each, with no travel.
    public static let miniPlayerMove: TimeInterval = 0.3
    /// The window's title bar and controller fade out before the picture leaves.
    public static let miniPlayerChromeOut: TimeInterval = 0.1
    public static let miniPlayerReducedFade: TimeInterval = 0.15

    public static func miniPlayerMove(reduceMotion: Bool) -> (duration: TimeInterval, travels: Bool) {
        reduceMotion ? (miniPlayerReducedFade, false) : (miniPlayerMove, true)
    }

    public static var miniPlayerMoveTimingFunction: CAMediaTimingFunction { MotionCurve.easeOut.timingFunction }
}

/// One leg of a movement: the curve (nil is linear), its duration and an optional delay.
struct MotionLeg: Equatable {
    var curve: MotionCurve?
    var duration: TimeInterval
    var delay: TimeInterval = 0

    static let reduced = MotionLeg(curve: nil, duration: 0.1)

    var animation: Animation {
        var base = curve.map { $0.animation(duration: duration) } ?? .linear(duration: duration)
        if delay > 0 { base = base.delay(delay) }
        return base
    }
}

/// A surface that fades in (optionally growing from `scale`) and leaves by opacity alone. With
/// Reduce Motion both legs are the 0.1 s opacity change and nothing scales.
struct EnterExit: Equatable {
    var scale: CGFloat?
    var enter: MotionLeg
    var exit: MotionLeg

    static let reduced = EnterExit(scale: nil, enter: .reduced, exit: .reduced)

    func transition(anchor: UnitPoint) -> AnyTransition {
        guard let scale else {
            return .asymmetric(
                insertion: .opacity.animation(enter.animation),
                removal: .opacity.animation(exit.animation)
            )
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: scale, anchor: anchor)).animation(enter.animation),
            removal: .opacity.animation(exit.animation)
        )
    }
}

/// The curves and durations of design 15.2. With Reduce Motion every movement is a 0.1 s
/// opacity change, or nothing when there is no opacity to change.
enum Motion {
    static func easeOut(_ duration: TimeInterval) -> Animation {
        MotionCurve.easeOut.animation(duration: duration)
    }

    static func easeIn(_ duration: TimeInterval) -> Animation {
        MotionCurve.easeIn.animation(duration: duration)
    }

    static func easeInOut(_ duration: TimeInterval) -> Animation {
        MotionCurve.easeInOut.animation(duration: duration)
    }

    static let reduced = Animation.linear(duration: 0.1)

    // MARK: Specs

    /// OSD: opacity and scale 0.96 to 1 from the top left, 0.12 s in, opacity 0.25 s out.
    static func osdSpec(reduceMotion: Bool) -> EnterExit {
        if reduceMotion { return .reduced }
        return EnterExit(
            scale: 0.96,
            enter: MotionLeg(curve: .easeOut, duration: 0.12),
            exit: MotionLeg(curve: .easeIn, duration: 0.25)
        )
    }

    /// Track panels and Video Info: opacity and scale 0.96 to 1 from the trigger, 0.16 s in,
    /// opacity 0.12 s out.
    static func panelSpec(reduceMotion: Bool) -> EnterExit {
        if reduceMotion { return .reduced }
        return EnterExit(
            scale: 0.96,
            enter: MotionLeg(curve: .easeOut, duration: 0.16),
            exit: MotionLeg(curve: .easeIn, duration: 0.12)
        )
    }

    // MARK: Transitions

    static func osdTransition(reduceMotion: Bool) -> AnyTransition {
        osdSpec(reduceMotion: reduceMotion).transition(anchor: .topLeading)
    }

    /// Panel open from the point over its trigger (`anchor`), see `PanelAnchor`.
    static func panelTransition(reduceMotion: Bool, anchor: UnitPoint) -> AnyTransition {
        panelSpec(reduceMotion: reduceMotion).transition(anchor: anchor)
    }

    /// Next card: opacity and 12 pt of travel, 0.32 s in and 0.2 s out.
    static func cardTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(reduced) }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 12)).animation(easeOut(0.32)),
            removal: .opacity.combined(with: .offset(y: 12)).animation(easeIn(0.2))
        )
    }

    // MARK: Animations

    /// The seek track grows with a spring of 0.18 s; with Reduce Motion the thumb fades in 0.1 s.
    static func seekTrack(reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : .spring(duration: 0.18)
    }

    /// The volume slider widens over 0.12 s; with Reduce Motion it jumps (nil).
    static func volumeWiden(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : easeInOut(0.12)
    }

    /// The empty-state tile reacting to a file drag: 0.16 s ease-out in, 0.12 s ease-in out.
    static func dropTarget(targeted: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return reduced }
        return targeted ? easeOut(0.16) : easeIn(0.12)
    }

    /// A step button pressed in a burst: the fill follows the pointer-down at once and fades
    /// back over 0.1 s.
    static let pressRelease = Animation.easeOut(duration: 0.1)
}

/// Where a panel grows from, as a point in the panel's own unit square, so the scale starts
/// over the button or tag that opened it even when the panel was clamped away from it.
enum PanelAnchor {
    /// `(pointX - originX) / width` kept inside 0 to 1.
    static func fraction(pointX: CGFloat, originX: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0.5 }
        return min(max((pointX - originX) / width, 0), 1)
    }

    /// Track and speed panels sit above their button: the point is on the panel's bottom edge,
    /// under the button's centre. Both x values are in the same coordinate space.
    static func track(buttonMidX: CGFloat, panelOriginX: CGFloat, panelWidth: CGFloat) -> UnitPoint {
        UnitPoint(x: fraction(pointX: buttonMidX, originX: panelOriginX, width: panelWidth), y: 1)
    }

    /// Video Info hangs under the title bar at the top right: the point is on its top edge, over
    /// the tag's centre. `nil` (tag not measured yet) grows from the top leading corner.
    static func videoInfo(tagMidX: CGFloat?, windowWidth: CGFloat) -> UnitPoint {
        guard let tagMidX else { return .topLeading }
        let originX = windowWidth - VideoInfoPanel.rightInset - VideoInfoPanel.width
        return UnitPoint(x: fraction(pointX: tagMidX, originX: originX, width: VideoInfoPanel.width), y: 0)
    }
}
