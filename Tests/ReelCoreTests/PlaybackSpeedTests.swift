import Testing
@testable import ReelCore

@Suite struct PlaybackSpeedTests {
    @Test func doubleAndHalf() {
        #expect(PlaybackSpeed.doubled(1) == 2)
        #expect(PlaybackSpeed.halved(1) == 0.5)
        #expect(PlaybackSpeed.doubled(PlaybackSpeed.halved(1.5)) == 1.5)
    }

    @Test func nudgesByOnePointOneAndBack() {
        #expect(PlaybackSpeed.faster(1) == 1.1)
        #expect(PlaybackSpeed.faster(1.1) == 1.21)
        #expect(PlaybackSpeed.slower(PlaybackSpeed.faster(1)) == 1)
        #expect(PlaybackSpeed.reset(2.5) == 1)
    }

    @Test func clampsToQuarterAndFour() {
        #expect(PlaybackSpeed.doubled(4) == 4)
        #expect(PlaybackSpeed.doubled(3) == 4)
        #expect(PlaybackSpeed.halved(0.25) == 0.25)
        #expect(PlaybackSpeed.halved(0.3) == 0.25)
        #expect(PlaybackSpeed.clamp(.nan) == 1)
        #expect(PlaybackSpeed.clamp(-2) == 1)
        #expect(PlaybackSpeed.clamp(.infinity) == 1)
    }

    @Test func presetsMatchThePanel() {
        #expect(PlaybackSpeed.presets == [0.5, 0.75, 1, 1.25, 1.5, 2])
        #expect(PlaybackSpeed.preset(matching: 1.5) == 1.5)
        #expect(PlaybackSpeed.preset(matching: 1.21) == nil)
    }

    @Test func fineStepperSnapsToFiveHundredths() {
        #expect(PlaybackSpeed.stepped(1, by: 1) == 1.05)
        #expect(PlaybackSpeed.stepped(1.21, by: 1) == 1.25)
        #expect(PlaybackSpeed.stepped(1.21, by: -1) == 1.15)
        #expect(PlaybackSpeed.stepped(4, by: 1) == 4)
        #expect(PlaybackSpeed.stepped(0.25, by: -1) == 0.25)
    }

    @Test func labelUsesTwoDecimalsOnlyWhenNeeded() {
        #expect(PlaybackSpeed.label(1) == "1×")
        #expect(PlaybackSpeed.label(1.5) == "1.5×")
        #expect(PlaybackSpeed.label(0.75) == "0.75×")
        #expect(PlaybackSpeed.label(1.21) == "1.21×")
        #expect(PlaybackSpeed.label(1.331) == "1.33×")
        #expect(PlaybackSpeed.label(2) == "2×")
        #expect(PlaybackSpeed.label(0.25) == "0.25×")
        #expect(PlaybackSpeed.fineLabel(1.5) == "1.50×")
        #expect(PlaybackSpeed.osdText(1.5) == "Speed 1.5×")
    }

    @Test func normalIsRecognisedDespiteFloatNoise() {
        #expect(PlaybackSpeed.isNormal(1.000_000_1))
        #expect(!PlaybackSpeed.isNormal(1.05))
    }
}
