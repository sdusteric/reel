import AppKit
import Foundation
import QuartzCore
import ReelCore
import ReelUI
import Testing
@testable import Reel

/// A command target that does nothing (no window, no panels).
final class NullCommandTarget: PlayerCommandTarget {
    var screenshots = 0
    var videoInfoToggles = 0

    func openDocument() {}
    func closeFile() {}
    func showSettings() {}
    func toggleFullscreen() {}
    func exitFullscreen() {}
    func scaleWindow(_ scale: WindowScale) {}
    func takeScreenshot() { screenshots += 1 }
}

/// Section 7.7: the display layer follows the plan; subtitles and the chrome always stay at SDR
/// white. `PlayerContentView` is built without a window and never shown.
@Suite struct DynamicRangeLayerTests {
    static let dolbyVision5 = DolbyVisionConfig(profile: 5, level: 6, rpu: true, el: false, bl: true, compatibilityID: 0)
    static let dolbyVision81 = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 1)

    static func makeView(model: PlayerModel? = nil) -> (PlayerContentView, NullCommandTarget) {
        let target = NullCommandTarget()
        let view = PlayerContentView(model: model ?? makeAppModel(), actions: SceneActions(), commandTarget: target)
        return (view, target)
    }

    static func expected(_ range: LayerDynamicRange) -> CALayer.DynamicRange {
        switch range {
        case .high: .high
        case .constrainedHigh: .constrainedHigh
        case .standard: .standard
        }
    }

    @Test func displayLayerFollowsThePlanWhileSubtitlesAndChromeStayStandard() throws {
        let (view, _) = Self.makeView()
        let contents: [DynamicRange] = [.sdr, .hdr10, .hlg, .dolbyVision(Self.dolbyVision81), .dolbyVision(Self.dolbyVision5)]
        for content in contents {
            for setting in HDRSetting.allCases {
                for display in [DisplayCapabilities.sdr, .xdr, .external] {
                    let plan = DynamicRangePlan.make(content: content, setting: setting, display: display)
                    view.apply(plan: plan)
                    let ranges = view.layerDynamicRanges
                    #expect(ranges.display == Self.expected(plan.layer), "\(content.rangeName) \(setting) on \(display.name)")
                    #expect(ranges.subtitles == .standard)
                    #expect(ranges.chrome == .standard, "the hosting view of the SwiftUI chrome")
                }
            }
        }
        let hdr = DynamicRangePlan.make(content: .hdr10, setting: .full, display: .xdr)
        view.apply(plan: hdr)
        #expect(view.layerDynamicRanges.display == .high)
        view.apply(plan: DynamicRangePlan.make(content: .hdr10, setting: .limited, display: .xdr))
        #expect(view.layerDynamicRanges.display == .constrainedHigh)
        view.apply(plan: DynamicRangePlan.make(content: .hdr10, setting: .off, display: .xdr))
        #expect(view.layerDynamicRanges.display == .standard)
    }

    @Test func freshLayersForANewEngineKeepThePlan() {
        let (view, _) = Self.makeView()
        view.apply(plan: DynamicRangePlan.make(content: .hlg, setting: .full, display: .xdr))
        let layers = view.videoView.prepareLayers()
        #expect(layers.display.preferredDynamicRange == .high)
        #expect(layers.subtitles.preferredDynamicRange == .standard)
        #expect(view.layerDynamicRanges.display == .high)
    }

    /// Section 7.7, SDR colour follows ColorSync: for SDR content the display layer, old and fresh,
    /// stays at standard range with no filter, background filter or compositing filter, so
    /// nothing changes the saturation or gamma the window server's colour matching gives it.
    @Test func sdrContentGetsAPlainDisplayLayer() {
        let (view, _) = Self.makeView()
        view.apply(plan: DynamicRangePlan.make(content: .sdr, setting: .full, display: .xdr))
        for layer in [view.videoView.displayLayer, view.videoView.prepareLayers().display] {
            #expect(layer.preferredDynamicRange == .standard)
            #expect(layer.filters?.isEmpty ?? true)
            #expect(layer.backgroundFilters?.isEmpty ?? true)
            #expect(layer.compositingFilter == nil)
        }
    }

    @Test func theViewStartsFromTheModelsPlan() {
        let model = makeAppModel()
        let (view, _) = Self.makeView(model: model)
        #expect(model.dynamicRangePlan.layer == .standard)
        #expect(view.layerDynamicRanges.display == .standard)
        #expect(view.layerDynamicRanges.subtitles == .standard)
        #expect(view.layerDynamicRanges.chrome == .standard)
    }

    /// The window moving to an SDR display (headroom 1.0) changes the presentation to tone-mapped
    /// SDR and back, through `DisplayRangeMonitor`, without reopening the file or touching the layer.
    @Test func headroomChangeAtRuntimeSwitchesThePlanWithoutReopening() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let engines = EngineList()
        let model = makeAppModel(engines: engines)
        await model.open(try scratch.makeFile("ramp.mkv"))
        await eventually("playing") { model.playbackState == .playing }
        let engine = try #require(engines.all.first)
        engine.emit(.dynamicRange(.hdr10))
        await eventually("HDR10") { model.dynamicRange == .hdr10 }

        let center = NotificationCenter()
        let display = DisplayBox(.headroom(4))
        let monitor = DisplayRangeMonitor(window: nil, read: { display.value }, center: center, scheduler: FakeScheduler()) { [weak model] in
            model?.setDisplay($0)
        }
        defer { monitor.stop() }
        let (view, _) = Self.makeView(model: model)
        view.apply(plan: model.dynamicRangePlan)
        #expect(model.dynamicRangePlan.presentation == .edr)
        #expect(model.dynamicRangePlan.tagDetail == nil)
        #expect(view.layerDynamicRanges.display == .high)

        display.value = .headroom(1)
        center.post(name: NSWindow.didChangeScreenNotification, object: nil)
        #expect(model.displayCapabilities.potentialHeadroom == 1)
        #expect(model.dynamicRangePlan.presentation == .toneMapToSDR)
        #expect(model.dynamicRangePlan.tagDetail == "SDR")
        view.apply(plan: model.dynamicRangePlan)
        #expect(view.layerDynamicRanges.display == .high, "the layer depends on the content and the setting only")

        display.value = .headroom(4)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(model.dynamicRangePlan.presentation == .edr)
        #expect(engines.all.count == 1)
        #expect(engine.calls.filter { if case .open = $0 { true } else { false } }.count == 1, "never reopened")
    }
}
