import CoreGraphics
import Testing
import ReelCore
@testable import ReelUI

@Suite struct MiniPlayerGeometryTests {
    let visible = CGRect(x: 0, y: 0, width: 2560, height: 1414)

    @Test func defaultSizeFitsTheBoxForEachAspect() {
        #expect(MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 1, visible: visible) == CGSize(width: 480, height: 270))
        #expect(MiniPlayerGeometry.size(aspect: 4 / 3, boxScale: 1, visible: visible) == CGSize(width: 480, height: 360))
        let wide = MiniPlayerGeometry.size(aspect: 2.39, boxScale: 1, visible: visible)
        #expect(wide.width == 480 && abs(wide.height - 200.84) < 0.01)
        let tall = MiniPlayerGeometry.size(aspect: 9 / 16, boxScale: 1, visible: visible)
        #expect(abs(tall.width - 202.5) < 0.01 && tall.height == 360)
    }

    @Test func boxScaleIsClampedToTheSmallestAndLargestBox() {
        #expect(MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 0.1, visible: visible) == CGSize(width: 256, height: 144))
        let big = MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 10, visible: visible)
        #expect(abs(big.height - 707) < 0.01 && abs(big.width - 1256.89) < 0.01)
    }

    @Test func cornersSitTwentyPointsInsideTheVisibleFrame() {
        let size = CGSize(width: 480, height: 270)
        let shifted = CGRect(x: 0, y: 70, width: 2560, height: 1344) // a Dock at the bottom
        #expect(MiniPlayerGeometry.frame(size: size, corner: .bottomRight, visible: shifted).origin == CGPoint(x: 2060, y: 90))
        #expect(MiniPlayerGeometry.frame(size: size, corner: .topLeft, visible: shifted).origin == CGPoint(x: 20, y: 1124))
    }

    @Test func releaseVelocityProjectsTowardTheCornerItWasThrownAt() {
        let frame = CGRect(x: 1160, y: 565, width: 480, height: 270) // centre (1400, 700)
        #expect(MiniPlayerGeometry.corner(releasing: frame, velocity: CGVector(dx: 2000, dy: -1500), visible: visible) == .bottomRight)
        #expect(MiniPlayerGeometry.corner(releasing: frame, velocity: .zero, visible: visible) == .bottomRight)
        let upperLeft = CGRect(x: 960, y: 665, width: 480, height: 270) // centre (1200, 800)
        #expect(MiniPlayerGeometry.corner(releasing: upperLeft, velocity: .zero, visible: visible) == .topLeft)
        #expect(MiniPlayerGeometry.corner(releasing: upperLeft, velocity: CGVector(dx: 1500, dy: -1500), visible: visible) == .bottomRight)
    }

    @Test func aMissingScreenFallsBack() {
        #expect(MiniPlayerGeometry.screen(saved: "B", available: ["A", "B"], fallback: "A") == "B")
        #expect(MiniPlayerGeometry.screen(saved: "C", available: ["A", "B"], fallback: "A") == "A")
        #expect(MiniPlayerGeometry.screen(saved: nil, available: ["A"], fallback: "A") == "A")
    }

    @Test func skipButtonsNeedThreeHundredTwentyPoints() {
        #expect(MiniPlayerGeometry.showsSkipButtons(width: 320))
        #expect(!MiniPlayerGeometry.showsSkipButtons(width: 319.5))
    }

    @Test func boxScaleRoundTrips() {
        let size = MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 1.5, visible: visible)
        #expect(abs(MiniPlayerGeometry.boxScale(for: size, aspect: 16 / 9) - 1.5) < 0.0001)
    }
}

@Suite struct SnapSpringTests {
    @Test func startsAtZeroAndSettlesWithinSixHundredMilliseconds() {
        let spring = SnapSpring(reduceMotion: false)
        #expect(spring.progress(at: 0, initialVelocity: 0) == 0)
        #expect(abs(spring.progress(at: 0.6, initialVelocity: 0) - 1) < 0.005)
        #expect(spring.isSettled(at: 0.6, initialVelocity: 0, distance: 300))
        #expect(!spring.isSettled(at: 0.05, initialVelocity: 0, distance: 300))
    }

    @Test func overshootStaysUnderOnePercent() {
        let spring = SnapSpring(reduceMotion: false)
        let peak = stride(from: 0.0, through: 1.0, by: 0.005).map { spring.progress(at: $0, initialVelocity: 0) }.max() ?? 0
        #expect(peak < 1.01)
    }

    @Test func releaseVelocityCarriesIntoTheSpring() {
        let spring = SnapSpring(reduceMotion: false)
        #expect(spring.progress(at: 0.02, initialVelocity: 5) > spring.progress(at: 0.02, initialVelocity: 0))
    }

    @Test func reduceMotionIsATwoHundredMillisecondEaseOutWithNoOvershoot() {
        let spring = SnapSpring(reduceMotion: true)
        #expect(spring.progress(at: 0.2, initialVelocity: 5) == 1)
        #expect(stride(from: 0.0, through: 0.3, by: 0.01).allSatisfy { spring.progress(at: $0, initialVelocity: 5) <= 1 })
        #expect(spring.isSettled(at: 0.2, initialVelocity: 5, distance: 300))
    }
}
