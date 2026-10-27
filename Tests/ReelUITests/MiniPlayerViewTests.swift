import CoreGraphics
import Foundation
import ReelCore
import Testing
@testable import ReelUI

/// The mini player overlay (mini player design section 5, mockups png/29 to png/33).
@MainActor
@Suite struct MiniPlayerViewTests {
    private func model(_ scenario: ShotScenario) -> PlayerModel {
        ShotRenderer.makeModel(
            scenario: scenario,
            title: ShotRenderer.demoTitle,
            position: .seconds(ShotOptions.defaultAt),
            duration: .seconds(ShotOptions.defaultDuration)
        )
    }

    @Test func chromeShowsOnlyWhileTheMiniChromeIsVisible() {
        let model = model(.miniPaused)
        model.isPlaying = true
        #expect(!MiniPlayerContent(model: model, width: 480).showsChrome)
        model.miniChrome.pointerMoved(to: CGPoint(x: 100, y: 100))
        model.miniChrome.pointerMoved(to: CGPoint(x: 140, y: 100))
        let shown = MiniPlayerContent(model: model, width: 480)
        #expect(shown.showsChrome && shown.showsSkipButtons)
        model.miniChrome.pointerExited()
        #expect(!MiniPlayerContent(model: model, width: 480).showsChrome)
    }

    @Test func pausedWithThePointerElsewhereShowsThePauseMark() {
        let model = model(.miniPaused)
        #expect(MiniPlayerContent(model: model, width: 480).showsPauseMark)
        model.isPlaying = true
        #expect(!MiniPlayerContent(model: model, width: 480).showsPauseMark)
    }

    @Test func narrowPanelDropsTheSkipButtons() {
        let model = model(.miniSmall)
        #expect(MiniPlayerContent(model: model, width: 256).showsChrome)
        #expect(!MiniPlayerContent(model: model, width: 256).showsSkipButtons)
        #expect(MiniPlayerContent(model: model, width: 320).showsSkipButtons)
    }

    @Test func endOfEpisodePinsTheChrome() {
        let model = model(.miniNext)
        let content = MiniPlayerContent(model: model, width: 480)
        #expect(content.showsChrome && content.showsNextEpisode)
        #expect(content.nextName == "Northern Line S02E06")
        #expect(content.nextLine == "Next episode in 3 s")
        #expect(!content.showsPauseMark, "the end state has its own row")
    }

    @Test func osdIsSmallerInTheMiniPlayer() {
        #expect(OSDView.Style.window.textSize == 20 && OSDView.Style.window.inset == 20)
        #expect(OSDView.Style.mini.textSize == 15 && OSDView.Style.mini.inset == 10)
    }

    @Test func miniChromeLiftsSubtitlesAndTheWindowPathStandsAside() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.setMiniPlayer(active: true)
        model.updateMiniSubtitleAvoidance(chromeShown: true)
        await waitUntil("lifted") { engine.calls.contains(.subtitleAvoidance(MiniPlayerLayout.subtitleLift)) }
        let count = engine.calls.count
        model.updateSubtitleAvoidance(windowSize: CGSize(width: 1280, height: 720), controllerFrame: CGRect(x: 350, y: 560, width: 576, height: 80))
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.calls.count == count, "the hidden window does not move the mini player's subtitles")
    }

    @Test(arguments: ShotScenario.allCases.filter { $0.miniPanelSize != nil })
    func miniScenariosRenderAtTheirPanelSize(_ scenario: ShotScenario) throws {
        let panel = try #require(scenario.miniPanelSize)
        for appearance in ShotAppearance.allCases {
            let image = try #require(ShotRenderer.render(
                scenario: scenario, appearance: appearance, size: CGSize(width: 1280, height: 720), frame: ShotRenderer.placeholderFrame()
            ))
            #expect(image.width == Int(panel.width * 2) && image.height == Int(panel.height * 2))
            let stats = try #require(ShotRenderer.luminance(of: image))
            #expect(!stats.isBlank && stats.standardDeviation > 10, "\(scenario.rawValue) \(appearance.rawValue): \(stats)")
        }
    }

    @Test func hoverDrawsTheCornerButtonsAndPausedDoesNot() throws {
        func corner(_ scenario: ShotScenario) throws -> Double {
            let image = try #require(ShotRenderer.render(scenario: scenario, appearance: .dark, size: .zero, frame: ShotRenderer.placeholderFrame()))
            return try #require(ShotRenderer.luminance(of: image, in: CGRect(x: 16, y: 16, width: 56, height: 56))).standardDeviation
        }
        let hover = try corner(.miniHover)
        let paused = try corner(.miniPaused)
        #expect(hover > paused + 5, "the close glyph is drawn on hover only: \(hover) vs \(paused)")
    }

    @Test func colorsAreFixedInBothAppearances() throws {
        let light = try #require(ShotRenderer.render(scenario: .miniHover, appearance: .light, size: .zero, frame: ShotRenderer.placeholderFrame()))
        let dark = try #require(ShotRenderer.render(scenario: .miniHover, appearance: .dark, size: .zero, frame: ShotRenderer.placeholderFrame()))
        let bar = CGRect(x: 0, y: 270 * 2 - 60, width: 480 * 2, height: 60)
        let lightBar = try #require(ShotRenderer.luminance(of: light, in: bar))
        let darkBar = try #require(ShotRenderer.luminance(of: dark, in: bar))
        #expect(abs(lightBar.mean - darkBar.mean) < 2, "light \(lightBar.mean) vs dark \(darkBar.mean)")
    }
}
