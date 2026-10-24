import Foundation
import Testing
@testable import ReelCore

@Suite struct MediaTimeTests {
    @Test func secondsRoundToNearestMicrosecond() {
        #expect(MediaTime(seconds: 1.5).microseconds == 1_500_000)
        #expect(MediaTime(seconds: 0.0000014).microseconds == 1)
        #expect(MediaTime(seconds: -2.25).microseconds == -2_250_000)
        #expect(MediaTime.milliseconds(40).seconds == 0.04)
    }

    @Test func rescalesFromMatroskaAndMP4TimeBases() {
        // mkv: 1/1000
        #expect(MediaTime(value: 41, timeBaseNum: 1, timeBaseDen: 1000).microseconds == 41_000)
        // 90 kHz (mpegts): 3003 ticks is one 29.97 fps frame
        #expect(MediaTime(value: 3003, timeBaseNum: 1, timeBaseDen: 90_000).microseconds == 33_367)
        // 24000/1001 frame rate as a frame duration
        #expect(MediaTime(value: 1, timeBaseNum: 1001, timeBaseDen: 24_000).microseconds == 41_708)
    }

    @Test func rescaleRoundsHalvesAwayFromZero() {
        // 1/3 us per tick: 3 ticks = 1 us, 1.5 ticks rounds; check symmetric behaviour on negatives.
        #expect(MediaTime(value: 1, timeBaseNum: 1, timeBaseDen: 2_000_000).microseconds == 1)
        #expect(MediaTime(value: -1, timeBaseNum: 1, timeBaseDen: 2_000_000).microseconds == -1)
        #expect(MediaTime(value: 1, timeBaseNum: 1, timeBaseDen: 3_000_000).microseconds == 0)
    }

    @Test func rescaleSurvivesLargeValuesWithoutOverflow() {
        // A 90 kHz timestamp after 24 hours, multiplied by 1e6 overflows Int64 without Int128.
        let ticks: Int64 = 90_000 * 86_400
        #expect(MediaTime(value: ticks, timeBaseNum: 1, timeBaseDen: 90_000).seconds == 86_400)
    }

    @Test func convertsBackToTimeBaseUnits() {
        let time = MediaTime(seconds: 10.4)
        #expect(time.value(timeBaseNum: 1, timeBaseDen: 1000) == 10_400)
        #expect(time.value(timeBaseNum: 1, timeBaseDen: 90_000) == 936_000)
        #expect(MediaTime(microseconds: 20_833).value(timeBaseNum: 1, timeBaseDen: 48_000) == 1000)
    }

    @Test func arithmeticAndOrdering() {
        let first = MediaTime.seconds(5)
        let second = MediaTime.milliseconds(250)
        #expect(first + second == .seconds(5.25))
        #expect(first - second == .seconds(4.75))
        #expect(-second == .milliseconds(-250))
        #expect(second < first)
        #expect([first, second, .zero].sorted() == [.zero, second, first])
        #expect(MediaTime.seconds(12).clamped(to: .zero ... .seconds(10)) == .seconds(10))
        #expect(MediaTime.seconds(-1).clamped(to: .zero ... .seconds(10)) == .zero)
    }

    @Test func codesAsBareMicroseconds() throws {
        let data = try JSONEncoder().encode([MediaTime.milliseconds(1500)])
        #expect(String(decoding: data, as: UTF8.self) == "[1500000]")
        let decoded = try JSONDecoder().decode([MediaTime].self, from: data)
        #expect(decoded == [.milliseconds(1500)])
    }

    @Test func descriptionShowsSecondsWithSixDecimals() {
        #expect(MediaTime(microseconds: 1_000_042).description == "1.000042s")
        #expect(MediaTime(microseconds: -500_000).description == "-0.500000s")
    }

    @Test func frameDurationFromFrameRate() {
        let video = VideoParameters(width: 1920, height: 1080, frameRate: Rational(24, 1))
        #expect(video.frameDuration == MediaTime(microseconds: 41_667))
        #expect(VideoParameters(width: 1, height: 1).frameDuration == nil)
    }

    @Test func displaySizeAppliesPixelAspectAndRotation() {
        let anamorphic = VideoParameters(width: 1440, height: 1080, pixelAspect: Rational(4, 3))
        #expect(anamorphic.displaySize == (1920, 1080))
        let rotated = VideoParameters(width: 1920, height: 1080, rotation: 90)
        #expect(rotated.displaySize == (1080, 1920))
    }

    @Test func volumeCurveIsCubic() {
        #expect(VolumeCurve.gain(forVolume: 100) == 1)
        #expect(VolumeCurve.gain(forVolume: 0) == 0)
        #expect(abs(VolumeCurve.gain(forVolume: 50) - 0.125) < 1e-6)
        #expect(VolumeCurve.gain(forVolume: 150) == 1)
        #expect(VolumeCurve.firstRunVolume == 47)
    }
}
