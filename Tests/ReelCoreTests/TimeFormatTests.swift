import Testing
@testable import ReelCore

@Suite struct TimeFormatTests {
    private static let tenMinutes = MediaTime.seconds(600)
    private static let ninetyMinutes = MediaTime.seconds(5_400)

    @Test func elapsedUnderAnHourHasNoHours() {
        #expect(TimeFormat.elapsed(.seconds(0), duration: Self.tenMinutes) == "00:00")
        #expect(TimeFormat.elapsed(.seconds(65), duration: Self.tenMinutes) == "01:05")
        #expect(TimeFormat.elapsed(.seconds(724), duration: Self.tenMinutes) == "12:04")
    }

    @Test func elapsedShowsHoursOnlyWhenDurationIsAnHourOrMore() {
        #expect(TimeFormat.elapsed(.seconds(65), duration: Self.ninetyMinutes) == "0:01:05")
        #expect(TimeFormat.elapsed(.seconds(3_753), duration: Self.ninetyMinutes) == "1:02:33")
        #expect(TimeFormat.elapsed(.seconds(65), duration: .seconds(3_600)) == "0:01:05")
        #expect(TimeFormat.elapsed(.seconds(65), duration: .seconds(3_599.9)) == "01:05")
    }

    @Test func remainingHasLeadingMinus() {
        #expect(TimeFormat.remaining(.seconds(0), duration: .seconds(754)) == "-12:34")
        #expect(TimeFormat.remaining(.seconds(100), duration: .seconds(754)) == "-10:54")
        #expect(TimeFormat.remaining(.seconds(100), duration: Self.ninetyMinutes) == "-1:28:20")
    }

    @Test func secondsAreFlooredAndRemainingAddsUpToTheTotal() {
        let duration = MediaTime.seconds(100.7)
        let position = MediaTime.seconds(40.9)
        #expect(TimeFormat.elapsed(position, duration: duration) == "00:40")
        #expect(TimeFormat.remaining(position, duration: duration) == "-01:00")
        #expect(TimeFormat.clock(duration, duration: duration) == "01:40")
    }

    @Test func remainingNeverGoesPositive() {
        #expect(TimeFormat.remaining(.seconds(700), duration: .seconds(600)) == "-00:00")
    }

    @Test func negativePositionsClampToZero() {
        #expect(TimeFormat.elapsed(.seconds(-3), duration: Self.tenMinutes) == "00:00")
    }

    @Test func unknownDurationUsesAPlaceholderForRemaining() {
        #expect(TimeFormat.remaining(.seconds(5), duration: nil) == "--:--")
        #expect(TimeFormat.remaining(.seconds(5), duration: .zero) == "--:--")
        #expect(TimeFormat.elapsed(.seconds(5), duration: nil) == "00:05")
    }

    @Test func positionOverTotalMatchesTheOSD() {
        #expect(TimeFormat.positionOverTotal(.seconds(724), duration: .seconds(3_753)) == "12:04 / 1:02:33")
        #expect(TimeFormat.positionOverTotal(.seconds(3_700), duration: .seconds(7_200)) == "1:01:40 / 2:00:00")
        #expect(TimeFormat.positionOverTotal(.seconds(724), duration: .seconds(900)) == "12:04 / 15:00")
        #expect(TimeFormat.positionOverTotal(.seconds(9), duration: nil) == "00:09")
    }
}
