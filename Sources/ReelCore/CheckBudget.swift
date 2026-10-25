/// CPU budget of a background integrity check (the VP9 tile check, section 7.10): a token
/// bucket in nanoseconds of thread CPU time. It fills at `share` of one core while playback runs,
/// up to `allowance`, and starts full. A check starts only at a keyframe while the balance is
/// positive and stops mid-GOP when it owes more than `debtLimit`, so its average cost stays at
/// `share` of a core whatever the stream's bit rate.
public struct CheckBudget: Sendable, Equatable {
    /// 2% of one core: VP9 up to about 2 Mbit/s is checked completely (section 7.10).
    public static let standardShare = 0.02
    public static let standardAllowanceNanos: Int64 = 250_000_000
    public static let standardDebtLimitNanos: Int64 = 100_000_000

    public let share: Double
    public let allowanceNanos: Int64
    public let debtLimitNanos: Int64
    /// CPU nanoseconds the check may still spend; negative while it owes.
    public private(set) var balanceNanos: Int64
    private var lastRefillNanos: UInt64?

    public init(
        share: Double = CheckBudget.standardShare,
        allowanceNanos: Int64 = CheckBudget.standardAllowanceNanos,
        debtLimitNanos: Int64 = CheckBudget.standardDebtLimitNanos
    ) {
        self.share = share
        self.allowanceNanos = allowanceNanos
        self.debtLimitNanos = debtLimitNanos
        balanceNanos = allowanceNanos
    }

    /// Adds `share` of the wall time since the last refill, capped at the allowance.
    public mutating func refill(now: UInt64) {
        defer { lastRefillNanos = now }
        guard let last = lastRefillNanos, now > last else { return }
        let earned = Int64(Double(now - last) * share)
        balanceNanos = min(allowanceNanos, balanceNanos + earned)
    }

    public mutating func spend(_ nanos: Int64) {
        balanceNanos -= max(0, nanos)
    }

    /// A check may start at the next keyframe.
    public var mayStart: Bool { balanceNanos > 0 }

    /// The check must stop where it is.
    public var isOverdrawn: Bool { balanceNanos < -debtLimitNanos }
}
