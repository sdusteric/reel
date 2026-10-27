import AppKit
import SwiftUI
import Testing
@testable import ReelUI

@MainActor
@Suite struct MotionTests {
    // MARK: Chrome reveal

    @Test func chromeRevealIsMostlyOpaqueBy60Milliseconds() {
        #expect(ChromeVisibility.revealOpacity(elapsed: 0.06, reduceMotion: false) >= 0.9)
        #expect(ChromeVisibility.revealOpacity(elapsed: 0, reduceMotion: false) == 0)
        #expect(abs(ChromeVisibility.revealOpacity(elapsed: ChromeVisibility.fadeInDuration, reduceMotion: false) - 1) < 1e-6)
    }

    @Test func chromeUsesTheSharedCurvesInAndOut() {
        #expect(ChromeVisibility.curve(visible: true) == MotionCurve.easeOut)
        #expect(ChromeVisibility.curve(visible: false) == MotionCurve.easeIn)
        #expect(ChromeVisibility.animation(visible: true, reduceMotion: false) == Motion.easeOut(0.16))
        #expect(ChromeVisibility.animation(visible: false, reduceMotion: false) == Motion.easeIn(0.35))
        #expect(ChromeVisibility.animation(visible: true, reduceMotion: true) == Motion.reduced)
        #expect(ChromeVisibility.animation(visible: false, reduceMotion: true) == Motion.reduced)
    }

    @Test func curveProgressIsMonotonicAndHitsTheEnds() {
        for curve in [MotionCurve.easeOut, .easeIn, .easeInOut] {
            var previous = -1.0
            for step in 0...20 {
                let value = curve.progress(at: Double(step) / 20)
                #expect(value >= previous)
                previous = value
            }
            #expect(abs(curve.progress(at: 0)) < 1e-6)
            #expect(abs(curve.progress(at: 1) - 1) < 1e-6)
        }
    }

    // MARK: Reduce Motion

    @Test func osdDropsItsScaleWithReduceMotion() {
        let normal = Motion.osdSpec(reduceMotion: false)
        #expect(normal.scale == 0.96)
        #expect(normal.enter == MotionLeg(curve: .easeOut, duration: 0.12))
        #expect(normal.exit == MotionLeg(curve: .easeIn, duration: 0.25))
        let reduced = Motion.osdSpec(reduceMotion: true)
        #expect(reduced.scale == nil)
        #expect(reduced.enter == .reduced)
        #expect(reduced.exit == .reduced)
        #expect(MotionLeg.reduced.animation == Motion.reduced)
    }

    @Test func seekTrackSpringBecomesTheReducedFade() {
        #expect(Motion.seekTrack(reduceMotion: false) == .spring(duration: 0.18))
        #expect(Motion.seekTrack(reduceMotion: true) == Motion.reduced)
    }

    @Test func volumeWidenJumpsWithReduceMotion() {
        #expect(Motion.volumeWiden(reduceMotion: false) == Motion.easeInOut(0.12))
        #expect(Motion.volumeWiden(reduceMotion: true) == nil)
    }

    @Test func windowFrameDoesNotAnimateWithReduceMotion() {
        #expect(MotionTiming.windowResizeDuration(reduceMotion: false) == 0.2)
        #expect(MotionTiming.windowResizeDuration(reduceMotion: true) == 0)
    }

    @Test func miniPlayerMoveUsesTheSharedEaseOut() {
        let normal = MotionTiming.miniPlayerMove(reduceMotion: false)
        #expect(normal.duration == 0.3 && normal.travels)
        let reduced = MotionTiming.miniPlayerMove(reduceMotion: true)
        #expect(reduced.duration == 0.15 && !reduced.travels)
        #expect(MotionTiming.miniPlayerChromeOut == 0.1)
        var points: [Float] = [0, 0]
        var expected: [Float] = [0, 0]
        for index in 1...2 {
            MotionTiming.miniPlayerMoveTimingFunction.getControlPoint(at: index, values: &points)
            MotionCurve.easeOut.timingFunction.getControlPoint(at: index, values: &expected)
            #expect(points == expected)
        }
    }

    @Test func panelSpecScalesOnlyWithoutReduceMotion() {
        #expect(Motion.panelSpec(reduceMotion: false).scale == 0.96)
        #expect(Motion.panelSpec(reduceMotion: true) == .reduced)
    }

    @Test func dropTargetAnimationIsReducedWithReduceMotion() {
        #expect(Motion.dropTarget(targeted: true, reduceMotion: false) == Motion.easeOut(0.16))
        #expect(Motion.dropTarget(targeted: false, reduceMotion: false) == Motion.easeIn(0.12))
        #expect(Motion.dropTarget(targeted: true, reduceMotion: true) == Motion.reduced)
        #expect(EmptyStateStyle.scale(highlighted: true, reduceMotion: true) == 1)
        #expect(EmptyStateStyle.scale(highlighted: true, reduceMotion: false) == 1.04)
    }

    // MARK: Panel anchors

    @Test func anchorIsUnderTheButtonWhenThePanelIsCentredOnIt() {
        let anchor = PanelAnchor.track(buttonMidX: 400, panelOriginX: 240, panelWidth: 320)
        #expect(anchor == UnitPoint(x: 0.5, y: 1))
    }

    @Test func anchorFollowsTheButtonWhenThePanelIsClamped() {
        // Clamped against the left edge: the panel starts at 16, the button is at 60.
        let left = PanelAnchor.track(buttonMidX: 60, panelOriginX: 16, panelWidth: 320)
        #expect(left.y == 1)
        #expect(abs(left.x - 44.0 / 320) < 1e-9)
        // Clamped against the right edge: the button is near the panel's right end.
        let right = PanelAnchor.track(buttonMidX: 700, panelOriginX: 400, panelWidth: 320)
        #expect(abs(right.x - 300.0 / 320) < 1e-9)
    }

    @Test func anchorStaysInsideThePanel() {
        #expect(PanelAnchor.track(buttonMidX: -50, panelOriginX: 16, panelWidth: 320).x == 0)
        #expect(PanelAnchor.track(buttonMidX: 900, panelOriginX: 16, panelWidth: 320).x == 1)
        #expect(PanelAnchor.fraction(pointX: 5, originX: 0, width: 0) == 0.5)
    }

    @Test func videoInfoGrowsFromTheTopOverTheTag() {
        // Window 1280 wide: the panel spans 916 to 1260. A tag at 640 is left of it, so x is 0.
        let wide = PanelAnchor.videoInfo(tagMidX: 640, windowWidth: 1280)
        #expect(wide == UnitPoint(x: 0, y: 0))
        // A tag above the panel in a narrow window.
        let narrow = PanelAnchor.videoInfo(tagMidX: 500, windowWidth: 700)
        let originX = 700 - VideoInfoPanel.rightInset - VideoInfoPanel.width
        #expect(narrow.y == 0)
        #expect(abs(narrow.x - (500 - originX) / VideoInfoPanel.width) < 1e-9)
        #expect(PanelAnchor.videoInfo(tagMidX: nil, windowWidth: 1280) == .topLeading)
    }

    // MARK: Press feedback

    @Test func stepperFillFollowsPressAndHover() {
        #expect(PressFillStyle.fillOpacity(pressed: false, hovering: false) == 0)
        #expect(PressFillStyle.fillOpacity(pressed: false, hovering: true) == 0.08)
        #expect(PressFillStyle.fillOpacity(pressed: true, hovering: true) == 0.16)
        #expect(PressFillStyle.fillOpacity(pressed: true, hovering: false) == 0.16)
    }

    // MARK: Drop target

    @Test func dropTargetFollowsTheDragLifecycle() {
        let state = DropTargetState()
        #expect(!state.isDropTargeted)
        state.dragged(operation: .copy)
        #expect(state.isDropTargeted)
        state.dragged(operation: .copy)
        #expect(state.isDropTargeted)
        state.exited()
        #expect(!state.isDropTargeted)
        state.dragged(operation: .copy)
        state.performed()
        #expect(!state.isDropTargeted)
        state.dragged(operation: .copy)
        state.concluded()
        #expect(!state.isDropTargeted)
    }

    @Test func dropTargetIgnoresRejectedDragsAndClearsWhenTheDragBecomesInvalid() {
        let state = DropTargetState()
        state.dragged(operation: [])
        #expect(!state.isDropTargeted)
        state.dragged(operation: .copy)
        state.dragged(operation: [])
        #expect(!state.isDropTargeted)
    }

    @Test func emptyStateHighlightsOnlyWithoutMedia() {
        #expect(EmptyStateStyle.isHighlighted(targeted: true, hasMedia: false))
        #expect(!EmptyStateStyle.isHighlighted(targeted: true, hasMedia: true))
        #expect(!EmptyStateStyle.isHighlighted(targeted: false, hasMedia: false))
    }
}
