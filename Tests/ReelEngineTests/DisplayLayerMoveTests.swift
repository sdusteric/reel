import AVFoundation
import Foundation
import QuartzCore
import Testing
@testable import ReelCore
@testable import ReelEngine

/// The mini player moves the one display layer between the window and its panel (mini player
/// design section 3, spike S1). Headless: the layer moves between two plain host layers.
@Suite(.serialized) struct DisplayLayerMoveTests {
    @MainActor
    @Test func layerKeepsPresentingWhenMovedBetweenHosts() async throws {
        let engine = EnergyTests.make()
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
        let hostA = CALayer(), hostB = CALayer()
        hostA.addSublayer(layer)
        await engine.attach(displayLayer: layer)
        _ = try await engine.open(Fixture.hevc10.url())
        await engine.play()
        try await Task.sleep(for: .milliseconds(500))
        for move in 0..<5 {
            let before = await engine.energyCounters().framesDecoded
            layer.removeFromSuperlayer()
            (move.isMultiple(of: 2) ? hostB : hostA).addSublayer(layer)
            try await Task.sleep(for: .milliseconds(250))
            #expect(layer.sampleBufferRenderer.status != .failed, "move \(move)")
            #expect(!layer.sampleBufferRenderer.requiresFlushToResumeDecoding, "move \(move)")
            let after = await engine.energyCounters().framesDecoded
            #expect(after > before, "frames keep coming after move \(move): \(before) then \(after)")
            try await Task.sleep(for: .milliseconds(1750))
        }
        await engine.close()
    }

    @Test func subtitleFloorSurvivesANewFile() async throws {
        let engine = EnergyTests.make()
        await engine.setSubtitleMinimumHeight(208)
        _ = try await engine.open(Fixture.h264.url())
        #expect(engine.subtitlePresenter.settingsSnapshot.minimumHeightPoints == 208)
        await engine.setSubtitleMinimumHeight(nil)
        #expect(engine.subtitlePresenter.settingsSnapshot.minimumHeightPoints == nil)
        await engine.close()
    }
}
