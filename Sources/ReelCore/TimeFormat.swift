import Foundation

/// Time labels for the controller and OSD (design sections 9.3 and 9.5).
///
/// Seconds are floored, so a label never runs ahead of the picture. Hours appear only when the
/// duration is 1 h or more, which keeps the label width stable for the whole file.
public enum TimeFormat {
    /// "04:07", or "1:02:33" when `duration` is at least one hour.
    public static func clock(_ time: MediaTime, duration: MediaTime?) -> String {
        format(wholeSeconds(time), withHours: showsHours(duration: duration))
    }

    /// Elapsed label, e.g. "12:04".
    public static func elapsed(_ position: MediaTime, duration: MediaTime?) -> String {
        clock(position, duration: duration)
    }

    /// Remaining label, e.g. "-12:34". Computed from whole seconds so elapsed plus remaining
    /// equals the total label. Without a known duration it is "--:--".
    public static func remaining(_ position: MediaTime, duration: MediaTime?) -> String {
        guard let duration, duration > .zero else { return placeholder }
        let left = max(0, wholeSeconds(duration) - wholeSeconds(position))
        return "-" + format(left, withHours: showsHours(duration: duration))
    }

    /// "12:04 / 1:02:33", the keyboard seek OSD. The position gets hours only once it reaches
    /// an hour; the total follows the duration rule.
    public static func positionOverTotal(_ position: MediaTime, duration: MediaTime?) -> String {
        let positionLabel = format(wholeSeconds(position), withHours: showsHours(duration: position))
        guard let duration, duration > .zero else { return positionLabel }
        return "\(positionLabel) / \(clock(duration, duration: duration))"
    }

    /// Hover pill and resume labels.
    public static func hover(_ time: MediaTime, duration: MediaTime?) -> String {
        clock(time, duration: duration)
    }

    public static func showsHours(duration: MediaTime?) -> Bool {
        guard let duration else { return false }
        return duration.microseconds >= 3_600 * 1_000_000
    }

    private static let placeholder = "--:--"

    private static func wholeSeconds(_ time: MediaTime) -> Int64 {
        max(0, time.microseconds) / 1_000_000
    }

    private static func format(_ totalSeconds: Int64, withHours: Bool) -> String {
        let seconds = totalSeconds % 60
        if withHours {
            let hours = totalSeconds / 3_600
            let minutes = (totalSeconds / 60) % 60
            return "\(hours):\(pad(minutes)):\(pad(seconds))"
        }
        return "\(pad(totalSeconds / 60)):\(pad(seconds))"
    }

    private static func pad(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
