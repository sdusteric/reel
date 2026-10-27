import Foundation

/// The mini player's snap to a corner after a drag (mini player design section 8, row 2): an
/// underdamped spring of mass 1, or with Reduce Motion the 0.2 s ease-out with no overshoot.
/// Progress runs from 0 at release to 1 at the corner; velocities are in distances per second.
nonisolated public struct SnapSpring: Sendable {
    public static let reducedDuration: TimeInterval = 0.2
    /// Settled when less than this far from the corner and slower than `settledSpeed`.
    public static let settledDistance: Double = 0.5
    public static let settledSpeed: Double = 10

    public let reduceMotion: Bool
    private let naturalFrequency: Double
    private let dampingRatio: Double

    public init(bounce: Double = 0.15, response: Double = 0.35, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        naturalFrequency = 2 * .pi / response
        dampingRatio = 1 - bounce
    }

    public func progress(at t: TimeInterval, initialVelocity: Double) -> Double {
        if reduceMotion { return MotionCurve.easeOut.progress(at: t / SnapSpring.reducedDuration) }
        guard t > 0 else { return 0 }
        return 1 + offset(at: t, initialVelocity: initialVelocity).position
    }

    public func isSettled(at t: TimeInterval, initialVelocity: Double, distance: Double) -> Bool {
        if reduceMotion { return t >= SnapSpring.reducedDuration }
        let state = offset(at: t, initialVelocity: initialVelocity)
        return abs(state.position * distance) < SnapSpring.settledDistance
            && abs(state.velocity * distance) < SnapSpring.settledSpeed
    }

    /// Position relative to the target (starts at -1) and its velocity.
    private func offset(at t: TimeInterval, initialVelocity: Double) -> (position: Double, velocity: Double) {
        let decay = dampingRatio * naturalFrequency
        let damped = naturalFrequency * (1 - dampingRatio * dampingRatio).squareRoot()
        let a = -1.0
        let b = (initialVelocity + decay * a) / damped
        let envelope = exp(-decay * t)
        let cosine = cos(damped * t), sine = sin(damped * t)
        let position = envelope * (a * cosine + b * sine)
        let velocity = envelope * (-decay * (a * cosine + b * sine) + damped * (b * cosine - a * sine))
        return (position, velocity)
    }
}
