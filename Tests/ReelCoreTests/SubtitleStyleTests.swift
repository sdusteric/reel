import Testing
@testable import ReelCore

@Suite struct SubtitleStyleTests {
    @Test func defaultsMatchTheDesign() {
        let style = SubtitleStyle()
        #expect(style.size == 45)
        #expect(style.scale == 1)
        #expect(style.position == 100)
        #expect(SubtitleStyle.referenceHeight == 720)
        #expect(SubtitleStyle.fontName == "PingFang SC")
        #expect(SubtitleStyle.outline == 2.5)
        #expect(SubtitleStyle.shadowOffset == 1.4)
        #expect(SubtitleStyle.bottomMargin == 40)
        #expect(style.pointSize(forHeight: 1_080) == 67.5)
        #expect(style.pointSize(forHeight: 1_440) == 90)
    }

    @Test func sizeStepsAreFivePointsOnTheFortyFiveScale() {
        var style = SubtitleStyle()
        style.stepSize(by: 1)
        #expect(style.sizeLabel == "50")
        style.stepSize(by: 1)
        #expect(style.size == 55)
        #expect(style.sizeOSDText == "Subtitle Size 55")
        style.reset()
        style.stepSize(by: -1)
        #expect(style.size == 40)
        #expect(abs(style.scale - 40.0 / 45.0) < 1e-9)
    }

    @Test func inputConfScaleDeltaIsOneStepPerTenth() {
        #expect(SubtitleStyle.steps(forScaleDelta: 0.1) == 1)
        #expect(SubtitleStyle.steps(forScaleDelta: -0.1) == -1)
        #expect(SubtitleStyle.steps(forScaleDelta: 0.2) == 2)
        #expect(SubtitleStyle.steps(forScaleDelta: 0.04) == 1)
        #expect(SubtitleStyle.steps(forScaleDelta: 0) == 0)
    }

    @Test func sizeIsClamped() {
        var style = SubtitleStyle()
        style.stepSize(by: 100)
        #expect(style.size == SubtitleStyle.maximumSize)
        style.stepSize(by: -100)
        #expect(style.size == SubtitleStyle.minimumSize)
        #expect(SubtitleStyle(scale: 1.1).size == 50)
    }

    @Test func positionMovesByOnePercentAndShowsTheRaise() {
        var style = SubtitleStyle()
        style.movePosition(by: -1)
        style.movePosition(by: -1)
        #expect(style.position == 98)
        #expect(style.positionOSDText == "Subtitle Position 2%")
        style.movePosition(by: 500)
        #expect(style.position == 150)
        style.movePosition(by: -500)
        #expect(style.position == 0)
    }

    @Test func liftInsetWhenTheControllerOverlapsTheBand() {
        let style = SubtitleStyle()
        // A 1280 x 720 window, the default controller (80 tall, bottom 11% up).
        let controller = LayoutRect(x: 352, y: 720 - 79.2 - 80, width: 576, height: 80)
        let inset = style.liftInset(windowWidth: 1_280, windowHeight: 720, controllerFrame: controller)
        #expect(inset == 720 - controller.minY + 12)
    }

    @Test func noLiftWhenTheControllerIsAwayFromTheBand() {
        let style = SubtitleStyle()
        let raised = LayoutRect(x: 352, y: 100, width: 576, height: 80)
        #expect(style.liftInset(windowWidth: 1_280, windowHeight: 720, controllerFrame: raised) == nil)
        let corner = LayoutRect(x: 0, y: 600, width: 50, height: 80)
        #expect(style.liftInset(windowWidth: 1_280, windowHeight: 720, controllerFrame: corner) == nil)
        #expect(style.liftInset(windowWidth: 1_280, windowHeight: 720, controllerFrame: nil) == nil)
    }

    @Test func bandScalesWithTheWindow() {
        let style = SubtitleStyle()
        let small = style.subtitleBand(windowWidth: 1_280, windowHeight: 720)
        let large = style.subtitleBand(windowWidth: 2_560, windowHeight: 1_440)
        #expect(small.maxY == 720)
        #expect(abs(large.height - small.height * 2) < 1e-9)
        #expect(abs(small.width - 1_152) < 1e-9)
    }

    @Test func delayTextIsSignedWithOneDecimal() {
        #expect(SubtitleStyle.subtitleDelayOSDText(0.5) == "Subtitle Delay +0.5 s")
        #expect(SubtitleStyle.audioDelayOSDText(-0.1) == "Audio Delay -0.1 s")
        #expect(SubtitleStyle.subtitleDelayOSDText(0) == "Subtitle Delay 0.0 s")
        #expect(SubtitleStyle.delayText(-1.25) == "-1.3 s")
        var delay = 0.0
        for _ in 0..<3 { delay = SubtitleStyle.adjustedDelay(delay, by: 0.1) }
        #expect(delay == 0.3)
    }

    @Test func defaultFontFollowsTheTracksChineseScript() {
        #expect(SubtitleStyle.fontName(language: nil, title: nil, fileName: "movie.zh-Hans.srt") == "PingFang SC")
        #expect(SubtitleStyle.fontName(language: "zho", title: "简英双语", fileName: "movie.mkv") == "PingFang SC")
        #expect(SubtitleStyle.fontName(language: nil, title: nil, fileName: "trad.zh-Hant.srt") == "PingFang TC")
        #expect(SubtitleStyle.fontName(language: nil, title: nil, fileName: "movie.cht.srt") == "PingFang TC")
        #expect(SubtitleStyle.fontName(language: "chi", title: "繁體中文", fileName: "movie.mkv") == "PingFang TC")
        #expect(SubtitleStyle.fontName(language: "zh-TW", title: nil, fileName: nil) == "PingFang TC")
        #expect(SubtitleStyle.fontName(language: nil, title: nil, fileName: "hk.zh-HK.srt") == "PingFang HK")
        #expect(SubtitleStyle.fontName(language: "yue", title: nil, fileName: nil) == "PingFang HK")
        #expect(SubtitleStyle.fontName(language: "zh-MO", title: nil, fileName: nil) == "PingFang MO")
        #expect(SubtitleStyle.fontName(language: "chi", title: "粵語字幕", fileName: "movie.mkv") == "PingFang HK")
        #expect(SubtitleStyle.fontName(language: "eng", title: nil, fileName: "movie.en.srt") == "PingFang SC")
    }
}
