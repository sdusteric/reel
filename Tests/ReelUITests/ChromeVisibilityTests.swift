import Foundation
import Testing
@testable import ReelUI

@MainActor
@Suite struct ChromeVisibilityTests {
    private func make(_ clock: TestClock) -> ChromeVisibility {
        ChromeVisibility(now: { clock.now }, sleep: longSleep)
    }

    @Test func visibleAtStartAndWhilePaused() {
        let clock = TestClock()
        let chrome = make(clock)
        #expect(chrome.isVisible)
        clock.advance(by: 60)
        chrome.evaluate()
        #expect(chrome.isVisible, "paused chrome never hides")
        #expect(chrome.hideDeadline == nil)
    }

    @Test func hidesTwoAndAHalfSecondsAfterInputWhilePlaying() {
        let clock = TestClock()
        let chrome = make(clock)
        chrome.setPlaying(true)
        #expect(chrome.hideDeadline == clock.now + 2.5)
        clock.advance(by: 2.4)
        chrome.evaluate()
        #expect(chrome.isVisible)
        clock.advance(by: 0.1)
        chrome.evaluate()
        #expect(!chrome.isVisible)
    }

    @Test func pointerMovementOfTwoPointsShowsAndRestartsTheTimer() {
        let clock = TestClock()
        let chrome = make(clock)
        chrome.setPlaying(true)
        chrome.pointerMoved(to: CGPoint(x: 100, y: 100))
        clock.advance(by: 3)
        chrome.evaluate()
        #expect(!chrome.isVisible)

        chrome.pointerMoved(to: CGPoint(x: 101, y: 101))
        #expect(!chrome.isVisible, "1.4 pt of movement is jitter")
        chrome.pointerMoved(to: CGPoint(x: 103, y: 101))
        #expect(chrome.isVisible)
        clock.advance(by: 2)
        chrome.evaluate()
        #expect(chrome.isVisible)
        clock.advance(by: 0.5)
        chrome.evaluate()
        #expect(!chrome.isVisible)
    }

    @Test func neverHidesOverTheControllerOrDuringADrag() {
        let clock = TestClock()
        let chrome = make(clock)
        chrome.setPlaying(true)
        chrome.setPointerOverController(true)
        clock.advance(by: 10)
        chrome.evaluate()
        #expect(chrome.isVisible)
        chrome.setPointerOverController(false)
        chrome.setDragging(true)
        clock.advance(by: 10)
        chrome.evaluate()
        #expect(chrome.isVisible)
        chrome.setDragging(false)
        clock.advance(by: 2.5)
        chrome.evaluate()
        #expect(!chrome.isVisible, "the timer restarts when the drag ends")
    }

    @Test func playbackKeysShowForTheAutoHidePeriod() {
        let clock = TestClock()
        let chrome = make(clock)
        chrome.setPlaying(true)
        clock.advance(by: 3)
        chrome.evaluate()
        #expect(!chrome.isVisible)
        chrome.playbackKeyPressed()
        #expect(chrome.isVisible)
        clock.advance(by: 2.5)
        chrome.evaluate()
        #expect(!chrome.isVisible)
    }

    @Test func pausingShowsAtOnce() {
        let clock = TestClock()
        let chrome = make(clock)
        var changes: [Bool] = []
        chrome.onChange = { changes.append($0) }
        chrome.setPlaying(true)
        clock.advance(by: 3)
        chrome.evaluate()
        chrome.setPlaying(false)
        #expect(chrome.isVisible)
        #expect(changes == [false, true])
    }

    @Test func fadeTimingsFollowTheDesign() {
        #expect(ChromeVisibility.duration(visible: true, reduceMotion: false) == 0.22)
        #expect(ChromeVisibility.duration(visible: false, reduceMotion: false) == 0.35)
        #expect(ChromeVisibility.duration(visible: true, reduceMotion: true) == 0.1)
        #expect(ChromeVisibility.duration(visible: false, reduceMotion: true) == 0.1)
    }

    @Test func modelSwitchesTheTimeUpdateRateWithTheChrome() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let clock = TestClock()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch, clock: clock)
        await model.open(try scratch.makeMediaFile("a.mkv"))
        await waitUntil("playing") { model.isPlaying }
        clock.advance(by: 3)
        model.chrome.evaluate()
        #expect(!model.chrome.isVisible)
        model.chrome.playbackKeyPressed()
        await model.waitForEngineCommands()
        let intervals = engine.calls.compactMap { call -> Double? in
            if case .timeInterval(let seconds) = call { return seconds }
            return nil
        }
        #expect(intervals == [0.1, 1, 0.1])
    }

    @Test func leavingTheWindowHidesAtOnceWhilePlayingOrPaused() {
        let clock = TestClock()
        let chrome = make(clock)
        #expect(chrome.isVisible)
        chrome.pointerExited()
        #expect(!chrome.isVisible, "paused: hidden as soon as the pointer leaves")
        chrome.evaluate()
        #expect(!chrome.isVisible, "and stays hidden")

        chrome.pointerMoved(to: CGPoint(x: 10, y: 10))
        #expect(chrome.isVisible, "coming back shows it")
        chrome.setPlaying(true)
        chrome.setPointerOverController(true)
        chrome.pointerExited()
        #expect(!chrome.isVisible, "playing, leaving straight from the controller")
    }

    @Test func aKeyWhileOutsideShowsThenHidesEvenWhenPaused() {
        let clock = TestClock()
        let chrome = make(clock)
        chrome.pointerExited()
        chrome.playbackKeyPressed()
        #expect(chrome.isVisible)
        clock.advance(by: 2.5)
        chrome.evaluate()
        #expect(!chrome.isVisible)
        chrome.setPlaying(true)
        chrome.setPlaying(false)
        #expect(!chrome.isVisible, "pausing with the pointer outside does not cover the picture")
    }

    @Test func aPanelOrDragKeepsTheChromeWhenThePointerLeaves() {
        let clock = TestClock()
        let chrome = make(clock)
        chrome.setPlaying(true)
        chrome.setPanelOpen(true)
        chrome.pointerExited()
        #expect(chrome.isVisible)
        chrome.setPanelOpen(false)
        clock.advance(by: 2.5)
        chrome.evaluate()
        #expect(!chrome.isVisible)
    }
}
