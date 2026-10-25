import Testing
@testable import ReelCore

/// The CPU budget of the VP9 tile check (section 7.10).
@Suite struct CheckBudgetTests {
    @Test func aNewBudgetStartsWithItsAllowance() {
        let budget = CheckBudget()
        #expect(budget.balanceNanos == CheckBudget.standardAllowanceNanos)
        #expect(budget.mayStart)
        #expect(!budget.isOverdrawn)
    }

    @Test func spendingPastTheAllowanceStopsNewChecksThenOverdraws() {
        var budget = CheckBudget(share: 0.02, allowanceNanos: 100, debtLimitNanos: 50)
        budget.spend(100)
        #expect(!budget.mayStart)
        #expect(!budget.isOverdrawn)
        budget.spend(51)
        #expect(budget.isOverdrawn)
    }

    @Test func wallTimeEarnsTheShareOfOneCoreUpToTheAllowance() {
        var budget = CheckBudget(share: 0.02, allowanceNanos: 250_000_000, debtLimitNanos: 100_000_000)
        budget.refill(now: 1_000_000_000)
        budget.spend(250_000_000)
        #expect(budget.balanceNanos == 0)
        // One second of playback earns 20 ms of CPU.
        budget.refill(now: 2_000_000_000)
        #expect(budget.balanceNanos == 20_000_000)
        // A long pause banks no more than the allowance.
        budget.refill(now: 1_000_000_000_000)
        #expect(budget.balanceNanos == 250_000_000)
    }

    @Test func aCheckThatCostsMoreThanTheShareRunsAFractionOfTheTime() {
        // 10 ms of parsing per frame at 60 fps (60% of a core) against a 2% budget: about one
        // frame in thirty is checked once the allowance is used up.
        var budget = CheckBudget()
        var now: UInt64 = 0
        var checked = 0
        let frames = 60 * 60
        for _ in 0..<frames {
            now += 16_666_667
            budget.refill(now: now)
            if budget.mayStart {
                budget.spend(10_000_000)
                checked += 1
            }
        }
        let share = Double(checked) * 10_000_000 / Double(now)
        #expect(share < 0.03, "\(share) of a core")
        #expect(checked > 0)
    }
}
