import CoreGraphics
import Foundation
import ReelCore
import Testing
@testable import ReelUI

/// ImageRenderer only: no window, no NSApplication run loop.
@MainActor
@Suite struct ShotRendererTests {
    private let size = CGSize(width: 1280, height: 720)

    private func render(_ scenario: ShotScenario, _ appearance: ShotAppearance) throws -> CGImage {
        try #require(ShotRenderer.render(
            scenario: scenario,
            appearance: appearance,
            size: size,
            frame: ShotRenderer.placeholderFrame()
        ))
    }

    @Test(arguments: ShotScenario.allCases)
    func everyScenarioRendersANonBlankImageAtTwiceTheSize(_ scenario: ShotScenario) throws {
        for appearance in ShotAppearance.allCases {
            let image = try render(scenario, appearance)
            #expect(image.width == 2_560)
            #expect(image.height == 1_440)
            let stats = try #require(ShotRenderer.luminance(of: image))
            #expect(!stats.isBlank, "\(scenario.rawValue) \(appearance.rawValue) looks blank: \(stats)")
            if scenario != .empty {
                #expect(stats.standardDeviation > 10, "\(scenario.rawValue) \(appearance.rawValue): \(stats)")
            }
        }
    }

    @Test func controllerFollowsTheAppearance() throws {
        let rect = ShotRenderer.controllerPixelRect(size: size).insetBy(dx: 40, dy: 20)
        let light = try #require(ShotRenderer.luminance(of: try render(.playing, .light), in: rect))
        let dark = try #require(ShotRenderer.luminance(of: try render(.playing, .dark), in: rect))
        #expect(light.mean - dark.mean >= 40, "light \(light.mean) vs dark \(dark.mean)")
    }

    @Test func emptyStateHasNoControllerAndShowsTheHint() throws {
        let image = try render(.empty, .dark)
        let controller = try #require(ShotRenderer.luminance(of: image, in: ShotRenderer.controllerPixelRect(size: size)))
        #expect(controller.mean < 2, "the empty window is black where the controller would be")
        let centre = CGRect(x: 2_560 / 2 - 300, y: 1_440 / 2 - 60, width: 600, height: 120)
        let hint = try #require(ShotRenderer.luminance(of: image, in: centre))
        #expect(hint.standardDeviation > 3, "the 'Open a video' text is drawn")
    }

    @Test func scrubbingShowsTheHoverPillAboveTheTrack() throws {
        let controller = ShotRenderer.controllerPixelRect(size: size)
        let above = CGRect(x: controller.minX, y: controller.minY - 80, width: controller.width, height: 70)
        let playing = try #require(ShotRenderer.luminance(of: try render(.playing, .light), in: above))
        let scrubbing = try #require(ShotRenderer.luminance(of: try render(.scrubbing, .light), in: above))
        #expect(abs(scrubbing.mean - playing.mean) > 1 || abs(scrubbing.standardDeviation - playing.standardDeviation) > 1)
    }

    @Test func writesAPNG() throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let output = scratch.file("shots/playing-light.png")
        try ShotRenderer.writePNG(try render(.playing, .light), to: output)
        let data = try Data(contentsOf: output)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func controllerGeometryFollowsTheDesign() {
        #expect(ControllerLayout.width(windowWidth: 1280) == 480)
        #expect(ControllerLayout.width(windowWidth: 720) == 360)
        #expect(ControllerLayout.width(windowWidth: 3000) == 560)
        #expect(ControllerLayout.width(windowWidth: 400) == 280, "never more than 70% of the window")
        let frame = ControllerLayout.frame(in: size, centerX: 0.49, bottomY: 0.11)
        #expect(frame.height == 76)
        #expect(abs(frame.midX - 627.2) < 0.01)
        #expect(abs((size.height - frame.maxY) - 79.2) < 0.01)
        let clamped = ControllerLayout.frame(in: size, centerX: 0, bottomY: 0)
        #expect(clamped.minX == 16)
        #expect(clamped.maxY == size.height - 16)
        let fractions = ControllerLayout.fractions(for: frame, in: size)
        #expect(abs(fractions.centerX - 0.49) < 0.0001)
        #expect(abs(fractions.bottomY - 0.11) < 0.0001)
    }
}
