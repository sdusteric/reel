import CoreGraphics
import Foundation
import ReelCore
import Testing
@testable import ReelUI

@MainActor
@Suite struct SubtitleLiftTests {
    private let size = CGSize(width: 1_280, height: 720)
    private let style = SubtitleStyle()

    private var defaultFrame: CGRect {
        ControllerLayout.frame(in: size, centerX: 0.49, bottomY: 0.11)
    }

    @Test func liftsToTwelvePointsAboveAnOverlappingController() throws {
        let inset = try #require(SubtitleAvoidance.inset(style: style, windowSize: size, controllerFrame: defaultFrame))
        #expect(abs(inset - (720 - defaultFrame.minY + 12)) < 0.001)
        #expect(inset > 100)
    }

    @Test func noLiftWhenTheControllerIsAwayFromTheBand() {
        let top = ControllerLayout.frame(in: size, centerX: 0.5, bottomY: 0.82)
        #expect(SubtitleAvoidance.inset(style: style, windowSize: size, controllerFrame: top) == nil, "dragged to the top")
        let middle = ControllerLayout.frame(in: size, centerX: 0.5, bottomY: 0.5)
        #expect(SubtitleAvoidance.inset(style: style, windowSize: size, controllerFrame: middle) == nil)
        #expect(SubtitleAvoidance.inset(style: style, windowSize: size, controllerFrame: nil) == nil, "no controller on screen")
    }

    @Test func aMovedControllerStillOverlapsAtTheEdgeOfTheBand() {
        let band = style.subtitleBand(windowWidth: 1_280, windowHeight: 720)
        let touching = CGRect(x: 400, y: band.minY - 80 + 1, width: 480, height: 80)
        #expect(SubtitleAvoidance.inset(style: style, windowSize: size, controllerFrame: touching) != nil)
        let above = CGRect(x: 400, y: band.minY - 80 - 1, width: 480, height: 80)
        #expect(SubtitleAvoidance.inset(style: style, windowSize: size, controllerFrame: above) == nil)
    }

    @Test func modelSendsTheInsetWhileTheChromeShowsAndReleasesWhenItMovesAway() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))

        model.updateSubtitleAvoidance(windowSize: size, controllerFrame: defaultFrame)
        await model.waitForEngineCommands()
        let expected = try #require(SubtitleAvoidance.inset(style: style, windowSize: size, controllerFrame: defaultFrame))
        #expect(engine.calls.contains(.subtitleAvoidance(expected)))

        // Same input again: nothing new is sent.
        model.updateSubtitleAvoidance(windowSize: size, controllerFrame: defaultFrame)
        await model.waitForEngineCommands()
        #expect(engine.calls.filter { $0 == .subtitleAvoidance(expected) }.count == 1)

        // The controller is dragged to the top while visible: the lines come down at once.
        let top = ControllerLayout.frame(in: size, centerX: 0.5, bottomY: 0.82)
        model.updateSubtitleAvoidance(windowSize: size, controllerFrame: top)
        await model.waitForEngineCommands()
        #expect(engine.calls.last == .subtitleAvoidance(nil))
    }

    @Test func linesComeDownOnlyAfterTheChromeHasFadedOut() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let clock = TestClock()
        let release = ReleaseGate()
        let fadeOut = ChromeVisibility.fadeOutDuration
        let (model, _, _) = makeModel(
            engineFactory: { _ in engine },
            scratch: scratch,
            clock: clock,
            sleep: { seconds in
                // Only the lift release waits exactly the fade-out time; every other timer stays asleep.
                if seconds == fadeOut {
                    await release.wait()
                } else {
                    await longSleep(seconds)
                }
            }
        )
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.updateSubtitleAvoidance(windowSize: size, controllerFrame: defaultFrame)
        clock.advance(by: 3)
        model.chrome.evaluate()
        #expect(!model.chrome.isVisible)

        model.updateSubtitleAvoidance(windowSize: size, controllerFrame: defaultFrame)
        await model.waitForEngineCommands()
        #expect(!engine.calls.contains(.subtitleAvoidance(nil)), "text never moves under a fading controller")
        await release.open()
        await waitUntil("the lines come down") { engine.calls.contains(.subtitleAvoidance(nil)) }
    }

    @Test func showingTheChromeAgainCancelsTheRelease() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let clock = TestClock()
        let (model, _, _) = makeModel(engine: engine, scratch: scratch, clock: clock)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.updateSubtitleAvoidance(windowSize: size, controllerFrame: defaultFrame)
        clock.advance(by: 3)
        model.chrome.evaluate()
        model.updateSubtitleAvoidance(windowSize: size, controllerFrame: defaultFrame)
        model.chrome.playbackKeyPressed()
        model.updateSubtitleAvoidance(windowSize: size, controllerFrame: defaultFrame)
        await model.waitForEngineCommands()
        #expect(!engine.calls.contains(.subtitleAvoidance(nil)))
    }

    @Test func aBiggerSizeWidensTheBand() {
        var big = SubtitleStyle()
        big.stepSize(by: 3)
        let normal = style.subtitleBand(windowWidth: 1_280, windowHeight: 720)
        let wide = big.subtitleBand(windowWidth: 1_280, windowHeight: 720)
        #expect(wide.height > normal.height)
        let frame = CGRect(x: 400, y: normal.minY - 80 - 4, width: 480, height: 80)
        #expect(SubtitleAvoidance.inset(style: style, windowSize: size, controllerFrame: frame) == nil)
        #expect(SubtitleAvoidance.inset(style: big, windowSize: size, controllerFrame: frame) != nil)
    }
}

/// A gate a test opens by hand.
private actor ReleaseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
