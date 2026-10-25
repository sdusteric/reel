import Foundation

/// Playback rate rules (design sections 9.7 and 10, D45).
public enum PlaybackSpeed {
    public static let minimum = 0.25
    public static let maximum = 4.0
    public static let normal = 1.0
    public static let presets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// The Fine stepper in the speed panel.
    public static let fineStep = 0.05
    /// Alt+Cmd+] and Alt+Cmd+[.
    public static let nudgeFactor = 1.1

    /// Clamps into 0.25 to 4 and rounds away float noise, so x1.1 then /1.1 returns to 1.
    public static func clamp(_ rate: Double) -> Double {
        guard rate.isFinite, rate > 0 else { return normal }
        let rounded = (rate * 1_000_000).rounded() / 1_000_000
        return min(max(rounded, minimum), maximum)
    }

    public static func multiplied(_ rate: Double, by factor: Double) -> Double {
        clamp(rate * factor)
    }

    /// Cmd+].
    public static func doubled(_ rate: Double) -> Double { multiplied(rate, by: 2) }
    /// Cmd+[.
    public static func halved(_ rate: Double) -> Double { multiplied(rate, by: 0.5) }
    /// Alt+Cmd+].
    public static func faster(_ rate: Double) -> Double { multiplied(rate, by: nudgeFactor) }
    /// Alt+Cmd+[.
    public static func slower(_ rate: Double) -> Double { multiplied(rate, by: 1 / nudgeFactor) }
    /// Cmd+\.
    public static func reset(_ rate: Double) -> Double { normal }

    /// One Fine stepper press: snaps to the 0.05 grid, then moves one step.
    public static func stepped(_ rate: Double, by steps: Int) -> Double {
        let grid = (rate / fineStep).rounded()
        return clamp((grid + Double(steps)) * fineStep)
    }

    /// The preset equal to `rate`, for the selected segment.
    public static func preset(matching rate: Double) -> Double? {
        presets.first { abs($0 - rate) < 0.000_5 }
    }

    /// "1×", "1.5×", "0.75×", "1.21×": two decimals only when needed.
    public static func label(_ rate: Double) -> String {
        number(rate) + "×"
    }

    /// The Fine stepper value, always two decimals: "1.50×".
    public static func fineLabel(_ rate: Double) -> String {
        String(format: "%.2f×", rate)
    }

    /// "Speed 1.5×".
    public static func osdText(_ rate: Double) -> String {
        "Speed " + label(rate)
    }

    public static func isNormal(_ rate: Double) -> Bool {
        abs(rate - normal) < 0.000_5
    }

    static func number(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        let whole = hundredths / 100
        let fraction = hundredths % 100
        if fraction == 0 { return "\(whole)" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)" }
        return String(format: "%d.%02d", whole, fraction)
    }
}
