import Foundation

/// A media timestamp or duration in whole microseconds.
public struct MediaTime: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var microseconds: Int64

    public init(microseconds: Int64) {
        self.microseconds = microseconds
    }

    /// Rounds to the nearest microsecond.
    public init(seconds: Double) {
        self.microseconds = Int64((seconds * 1_000_000).rounded())
    }

    /// Converts `value` expressed in units of `num / den` seconds (an FFmpeg time base),
    /// rounding to the nearest microsecond with halves away from zero, like `av_rescale`.
    public init(value: Int64, timeBaseNum num: Int32, timeBaseDen den: Int32) {
        precondition(den != 0, "time base denominator is zero")
        self.microseconds = MediaTime.rescale(value, multiplier: Int128(num) * 1_000_000, divisor: Int128(den))
    }

    public static func seconds(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }
    public static func milliseconds(_ milliseconds: Int64) -> MediaTime {
        MediaTime(microseconds: milliseconds * 1_000)
    }
    public static func microseconds(_ microseconds: Int64) -> MediaTime {
        MediaTime(microseconds: microseconds)
    }

    public static let zero = MediaTime(microseconds: 0)

    public var seconds: Double { Double(microseconds) / 1_000_000 }
    public var milliseconds: Double { Double(microseconds) / 1_000 }

    /// The value in units of `num / den` seconds, rounded to nearest (halves away from zero).
    public func value(timeBaseNum num: Int32, timeBaseDen den: Int32) -> Int64 {
        precondition(num != 0, "time base numerator is zero")
        return MediaTime.rescale(microseconds, multiplier: Int128(den), divisor: Int128(num) * 1_000_000)
    }

    /// Clamps into `range`.
    public func clamped(to range: ClosedRange<MediaTime>) -> MediaTime {
        min(max(self, range.lowerBound), range.upperBound)
    }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool { lhs.microseconds < rhs.microseconds }
    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        MediaTime(microseconds: lhs.microseconds + rhs.microseconds)
    }
    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        MediaTime(microseconds: lhs.microseconds - rhs.microseconds)
    }
    public static func += (lhs: inout MediaTime, rhs: MediaTime) { lhs = lhs + rhs }
    public static func -= (lhs: inout MediaTime, rhs: MediaTime) { lhs = lhs - rhs }
    public static prefix func - (value: MediaTime) -> MediaTime { MediaTime(microseconds: -value.microseconds) }

    public var description: String {
        let sign = microseconds < 0 ? "-" : ""
        let magnitude = microseconds.magnitude
        let fraction = String(magnitude % 1_000_000)
        let padded = String(repeating: "0", count: 6 - fraction.count) + fraction
        return "\(sign)\(magnitude / 1_000_000).\(padded)s"
    }

    // Encoded as a bare integer of microseconds so JSON stays readable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.microseconds = try container.decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(microseconds)
    }

    private static func rescale(_ value: Int64, multiplier: Int128, divisor: Int128) -> Int64 {
        var mul = multiplier
        var div = divisor
        if div < 0 { mul = -mul; div = -div }
        let product = Int128(value) * mul
        let half = div / 2
        let rounded = product >= 0 ? (product + half) / div : (product - half) / div
        return Int64(clamping: rounded)
    }
}

/// An exact rational number, used for FFmpeg time bases, frame rates and pixel aspect ratios.
public struct Rational: Hashable, Sendable, Codable, CustomStringConvertible {
    public var num: Int32
    public var den: Int32

    public init(_ num: Int32, _ den: Int32) {
        self.num = num
        self.den = den
    }

    public var isValid: Bool { num != 0 && den != 0 }
    public var doubleValue: Double { den == 0 ? 0 : Double(num) / Double(den) }
    public var description: String { "\(num)/\(den)" }
}
