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

    @Test func everyScenarioChangesTheControllerRegionBetweenLightAndDark() throws {
        let m3: Set<ShotScenario> = [.hdrBadge, .videoInfo, .hdrSDR, .dvNote, .truncated, .damagedOSD, .driveGone]
        for scenario in ShotScenario.allCases where scenario != .empty && scenario != .openFailed {
            let rect = ShotRenderer.appearanceRegion(size: size, scenario: scenario)
            let light = try #require(ShotRenderer.luminance(of: try render(scenario, .light), in: rect))
            let dark = try #require(ShotRenderer.luminance(of: try render(scenario, .dark), in: rect))
            let needed = m3.contains(scenario) ? 40.0 : 20.0
            #expect(light.mean - dark.mean >= needed, "\(scenario.rawValue): light \(light.mean) vs dark \(dark.mean)")
        }
    }

    /// Pixel rect of a region given in points, origin top-left.
    private func pixels(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2)
    }

    private func differs(_ scenario: ShotScenario, from other: ShotScenario, in region: CGRect, _ appearance: ShotAppearance = .dark) throws -> Bool {
        let first = try #require(ShotRenderer.luminance(of: try render(scenario, appearance), in: region))
        let second = try #require(ShotRenderer.luminance(of: try render(other, appearance), in: region))
        return abs(first.mean - second.mean) > 1 || abs(first.standardDeviation - second.standardDeviation) > 1
    }

    @Test func theOpenFailureShowsTheTitleBarTextAndTheCardOnBlack() throws {
        for appearance in ShotAppearance.allCases {
            let image = try render(.openFailed, appearance)
            let titleRegion = ShotRenderer.appearanceRegion(size: size, scenario: .openFailed)
            let title = try #require(ShotRenderer.luminance(of: image, in: titleRegion))
            #expect(!title.isBlank, "the file name is drawn in the title bar")
            let card = try #require(ShotRenderer.luminance(of: image, in: pixels(CGRect(x: 440, y: 240, width: 400, height: 240))))
            #expect(!card.isBlank, "the card is drawn")
            let corner = try #require(ShotRenderer.luminance(of: image, in: pixels(CGRect(x: 0, y: 500, width: 200, height: 200))))
            #expect(corner.maximum < 4, "everything else stays black")
        }
    }

    @Test func theRangeSurfacesDrawWhereTheMockupsPutThem() throws {
        let topRight = pixels(CGRect(x: 1_280 - 20 - 344, y: 48, width: 344, height: 340))
        #expect(try differs(.videoInfo, from: .hdrBadge, in: topRight), "Video Info is at the top right")
        let note = pixels(CGRect(x: 20, y: 20, width: 460, height: 130))
        #expect(try differs(.dvNote, from: .hdrBadge, in: note), "the note is at the OSD position")
        let tag = pixels(CGRect(x: 800, y: 3, width: 150, height: 22))
        #expect(try differs(.hdrBadge, from: .playing, in: tag), "the tag follows the title")
        let tooltip = pixels(CGRect(x: 500, y: 34, width: 320, height: 60))
        #expect(try differs(.hdrSDR, from: .hdrBadge, in: tooltip), "the tone-mapped tag shows its tooltip")
    }

    @Test func theTruncatedTailAndTheDamagedOSDAreDrawn() throws {
        let controller = ShotRenderer.controllerPixelRect(size: size, scenario: .truncated)
        let bar = CGRect(x: controller.minX + 120, y: controller.minY + 24, width: controller.width - 240, height: 40)
        #expect(try differs(.truncated, from: .playing, in: bar))
        let osd = pixels(CGRect(x: 20, y: 20, width: 360, height: 70))
        #expect(try differs(.damagedOSD, from: .playing, in: osd))
    }

    @Test func aDisconnectedDriveDimsTheFrame() throws {
        let top = pixels(CGRect(x: 0, y: 40, width: 1_280, height: 120))
        let playing = try #require(ShotRenderer.luminance(of: try render(.playing, .dark), in: top))
        let gone = try #require(ShotRenderer.luminance(of: try render(.driveGone, .dark), in: top))
        #expect(gone.mean < playing.mean * 0.6, "brightness drops to about 38%: \(gone.mean) vs \(playing.mean)")
        let card = pixels(CGRect(x: 440, y: 260, width: 400, height: 200))
        #expect(try differs(.driveGone, from: .pausedOSD, in: card))
    }

    @Test func theScenarioNamesMatchTheAcceptanceList() {
        let names = ["hdr-badge", "video-info", "hdr-sdr", "dv-note", "open-failed", "truncated", "damaged-osd", "drive-gone"]
        for name in names {
            #expect(ShotScenario(rawValue: name) != nil, Comment(rawValue: name))
        }
        #expect(ShotScenario.allCases.count == 24)
    }

    @Test func hdrShotsTakeTheirInputsFromTheCaller() throws {
        let image = try #require(ShotRenderer.render(
            scenario: .hdrBadge,
            appearance: .dark,
            size: size,
            frame: ShotRenderer.placeholderFrame(),
            dynamicRange: .hlg,
            display: .sdr
        ))
        let plain = try render(.hdrBadge, .dark)
        let tag = pixels(CGRect(x: 800, y: 3, width: 150, height: 22))
        let first = try #require(ShotRenderer.luminance(of: image, in: tag))
        let second = try #require(ShotRenderer.luminance(of: plain, in: tag))
        #expect(abs(first.mean - second.mean) > 0.5 || abs(first.standardDeviation - second.standardDeviation) > 0.5)
    }

    @Test func subtitleShotsHaveOutlinedWhiteInk() throws {
        for scenario in [ShotScenario.subtitles, .subtitlesLifted] {
            for appearance in ShotAppearance.allCases {
                let image = try render(scenario, appearance)
                // Subtitles-lifted keeps its lines in the band above the controller; subtitles uses the bottom quarter.
                let region: CGRect
                if scenario == .subtitles {
                    region = CGRect(x: 0, y: Double(image.height) * 0.75, width: Double(image.width), height: Double(image.height) * 0.25)
                } else {
                    let controller = ShotRenderer.controllerPixelRect(size: size, scenario: scenario)
                    region = CGRect(x: 0, y: controller.minY - 330, width: Double(image.width), height: 330)
                }
                let white = whitePixels(in: image, rect: region)
                #expect(white >= 1_500, "\(scenario.rawValue) \(appearance.rawValue) has \(white) white pixels")
            }
        }
    }

    @Test func theLiftedLinesSitTwelvePointsAboveTheController() throws {
        let lift = try #require(ShotRenderer.subtitleLift(scenario: .subtitlesLifted, size: size))
        let controller = ControllerLayout.frame(in: size, centerX: 0.49, bottomY: 0.11)
        #expect(abs((size.height - lift) - (controller.minY - 12)) < 0.001)
        #expect(ShotRenderer.subtitleLift(scenario: .subtitles, size: size) == nil, "the controller sits at the top there")
        #expect(ShotRenderer.subtitleLift(scenario: .playing, size: size) == nil)
    }

    @Test func aProvidedSubtitleImageIsDrawnAtItsRect() throws {
        let white = try #require(ShotRenderer.placeholderFrame(width: 200, height: 80))
        let rect = CGRect(x: 100, y: 100, width: 200, height: 80)
        let plain = try render(.pausedOSD, .dark)
        let drawn = try #require(ShotRenderer.render(
            scenario: .pausedOSD,
            appearance: .dark,
            size: size,
            frame: ShotRenderer.placeholderFrame(),
            subtitleImage: white,
            subtitleRect: rect
        ))
        let region = CGRect(x: 200, y: 200, width: 400, height: 160)
        let before = try #require(ShotRenderer.luminance(of: plain, in: region))
        let after = try #require(ShotRenderer.luminance(of: drawn, in: region))
        #expect(abs(before.mean - after.mean) > 1 || abs(before.standardDeviation - after.standardDeviation) > 1)
    }

    @Test func aProvidedThumbnailShowsInTheHoverContainer() throws {
        let controller = ShotRenderer.controllerPixelRect(size: size, scenario: .thumbnail)
        let above = CGRect(x: controller.minX + 120, y: controller.minY - 260, width: 400, height: 250)
        let plain = try #require(ShotRenderer.luminance(of: try render(.playing, .light), in: above))
        let thumb = try #require(ShotRenderer.luminance(of: try render(.thumbnail, .light), in: above))
        #expect(abs(plain.mean - thumb.mean) > 1 || abs(plain.standardDeviation - thumb.standardDeviation) > 1)
    }

    @Test func nextEpisodeShotShowsTheCardAboveTheController() throws {
        let controller = ShotRenderer.controllerPixelRect(size: size, scenario: .nextEpisode)
        let card = CGRect(x: controller.maxX - 720, y: controller.minY - 200, width: 700, height: 180)
        let playing = try #require(ShotRenderer.luminance(of: try render(.playing, .light), in: card))
        let ended = try #require(ShotRenderer.luminance(of: try render(.nextEpisode, .light), in: card))
        #expect(abs(playing.standardDeviation - ended.standardDeviation) > 1 || abs(playing.mean - ended.mean) > 1)
    }

    @Test func controllerGeometryFollowsTheDesign() {
        #expect(ControllerLayout.width(windowWidth: 1_280) == 576)
        #expect(ControllerLayout.width(windowWidth: 720) == 440)
        #expect(ControllerLayout.width(windowWidth: 3_000) == 600)
        #expect(ControllerLayout.width(windowWidth: 400) == 280, "never more than 70% of the window")
        let frame = ControllerLayout.frame(in: size, centerX: 0.49, bottomY: 0.11)
        #expect(frame.height == 80)
        #expect(abs(frame.midX - 627.2) < 0.01)
        #expect(abs((size.height - frame.maxY) - 79.2) < 0.01)
        let clamped = ControllerLayout.frame(in: size, centerX: 0, bottomY: 0)
        #expect(clamped.minX == 16)
        #expect(clamped.maxY == size.height - 16)
        let fractions = ControllerLayout.fractions(for: frame, in: size)
        #expect(abs(fractions.centerX - 0.49) < 0.0001)
        #expect(abs(fractions.bottomY - 0.11) < 0.0001)
    }

    /// Pixels that are nearly white (every channel above 235) in `rect`, origin top-left.
    private func whitePixels(in image: CGImage, rect: CGRect) -> Int {
        guard let cropped = image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) else { return 0 }
        let width = cropped.width
        let height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var count = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset] > 235 && pixels[offset + 1] > 235 && pixels[offset + 2] > 235 {
            count += 1
        }
        return count
    }
}
