import CoreGraphics
import ReelCore
import Testing
@testable import ReelUI

@MainActor
@Suite struct ControllerLayoutTests {
    @Test func widthIsAClampOfTheWindow() {
        #expect(ControllerLayout.width(windowWidth: 1_280) == 576)
        #expect(ControllerLayout.width(windowWidth: 1_920) == 600)
        #expect(ControllerLayout.width(windowWidth: 2_560) == 600)
        #expect(ControllerLayout.width(windowWidth: 1_000) == 450)
        #expect(ControllerLayout.width(windowWidth: 720) == 440, "the minimum")
        #expect(ControllerLayout.width(windowWidth: 400) == 280, "never more than 70% of the window")
    }

    @Test func allButtonsFitFromFiveSixtyEight() {
        let full = ControllerLayout.buttons(controllerWidth: 576, hasEpisodes: true)
        #expect(full == ControllerLayout.Buttons(previous: true, next: true, pictureInPicture: true, audio: true, speed: true))
        let exact = ControllerLayout.buttons(controllerWidth: 568, hasEpisodes: true)
        #expect(exact == full)
    }

    @Test func belowFiveSixtyEightDropsEpisodesAndPictureInPicture() {
        let buttons = ControllerLayout.buttons(controllerWidth: 567, hasEpisodes: true)
        #expect(!buttons.previous && !buttons.next && !buttons.pictureInPicture)
        #expect(buttons.audio && buttons.speed)
    }

    @Test func belowFourEightyAlsoDropsAudioAndSpeed() {
        let buttons = ControllerLayout.buttons(controllerWidth: 440, hasEpisodes: true)
        #expect(buttons == ControllerLayout.Buttons(previous: false, next: false, pictureInPicture: false, audio: false, speed: false))
        let atFourEighty = ControllerLayout.buttons(controllerWidth: 480, hasEpisodes: true)
        #expect(atFourEighty.audio && atFourEighty.speed)
        #expect(ControllerLayout.buttons(controllerWidth: 479, hasEpisodes: true).count == 0)
    }

    @Test func aFileAloneInItsFolderHidesPreviousAndNext() {
        let buttons = ControllerLayout.buttons(controllerWidth: 600, hasEpisodes: false)
        #expect(!buttons.previous && !buttons.next)
        #expect(buttons.pictureInPicture && buttons.audio && buttons.speed)
    }

    @Test func framesStayInsideTheWindow() {
        let size = CGSize(width: 1_280, height: 720)
        let frame = ControllerLayout.frame(in: size, centerX: 0.49, bottomY: 0.11)
        #expect(frame.height == 80)
        #expect(frame.width == 576)
        #expect(abs(frame.midX - 627.2) < 0.01)
        #expect(abs((size.height - frame.maxY) - 79.2) < 0.01)
        let corner = ControllerLayout.frame(in: size, centerX: 0, bottomY: 0)
        #expect(corner.minX == 16)
        #expect(corner.maxY == size.height - 16)
        let fractions = ControllerLayout.fractions(for: frame, in: size)
        #expect(abs(fractions.centerX - 0.49) < 0.0001)
        #expect(abs(fractions.bottomY - 0.11) < 0.0001)
    }

    @Test func fullscreenFixesTheBottomEdgeAt56Points() {
        let size = CGSize(width: 2_560, height: 1_440)
        let frame = ControllerLayout.frame(in: size, centerX: 0.49, bottomY: 0.3, fullscreen: true)
        #expect(size.height - frame.maxY == 56, "the stored y applies only to windows")
        #expect(frame.width == 600, "the controller keeps its size in fullscreen")
        let window = ControllerLayout.frame(in: size, centerX: 0.49, bottomY: 0.3)
        #expect(size.height - window.maxY == 432)
        #expect(window.midX == frame.midX)
    }
}
