import ReelCore
import Testing
@testable import ReelUI

@MainActor
@Suite struct DynamicRangeTagTests {
    private let dolbyVision81 = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 1)
    private let dolbyVision84 = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 4)
    private let dolbyVision5 = DolbyVisionConfig(profile: 5, level: 6, rpu: true, el: false, bl: true, compatibilityID: 0)

    private func content(
        _ range: DynamicRange,
        setting: HDRSetting = .full,
        display: DisplayCapabilities = .xdr
    ) -> DynamicRangeTagContent? {
        DynamicRangeTagContent(plan: DynamicRangePlan.make(content: range, setting: setting, display: display))
    }

    @Test func sdrFilesHaveNoTag() {
        #expect(content(.sdr) == nil)
        #expect(content(.sdr, setting: .off, display: .sdr) == nil)
    }

    @Test func hdr10AndHLGNameTheirRange() throws {
        let hdr10 = try #require(content(.hdr10))
        #expect(hdr10.text == "HDR10")
        #expect(hdr10.detail == nil)
        #expect(!hdr10.warning)
        #expect(hdr10.tooltip == "High dynamic range. Click for details.")
        #expect(hdr10.accessibilityLabel == "Dynamic range, HDR10")
        let hlg = try #require(content(.hlg, setting: .limited, display: .external))
        #expect(hlg.text == "HLG")
        #expect(hlg.detail == nil, "Limited still shows HDR")
    }

    @Test func aToneMappedPictureAddsSDRAndTheMatchingTooltip() throws {
        let onSDRDisplay = try #require(content(.hdr10, display: .sdr))
        #expect(onSDRDisplay.detail == "SDR")
        #expect(onSDRDisplay.tooltip == "This display shows standard dynamic range, so the HDR picture is tone-mapped to fit it.")
        #expect(onSDRDisplay.accessibilityLabel == "Dynamic range, HDR10, tone-mapped to standard range")
        let off = try #require(content(.hlg, setting: .off, display: .xdr))
        #expect(off.detail == "SDR")
        #expect(off.tooltip == DynamicRangePlan.toneMappedSettingTooltip)
    }

    @Test func dolbyVisionNamesItsProfileOnlyWithoutACompatibleBase() throws {
        let p81 = try #require(content(.dolbyVision(dolbyVision81)))
        #expect(p81.text == "Dolby Vision")
        #expect(!p81.warning)
        let p84 = try #require(content(.dolbyVision(dolbyVision84)))
        #expect(p84.text == "Dolby Vision")
        let p5 = try #require(content(.dolbyVision(dolbyVision5)))
        #expect(p5.text == "Dolby Vision 5")
        #expect(p5.warning, "profile 5 carries the warning glyph")
    }

    @Test func theTagIsPartOfTheTitleBarOnlyForHDR() throws {
        let model = ShotRenderer.makeModel(scenario: .hdrBadge, title: "x.mkv", position: .seconds(12), duration: .seconds(60))
        #expect(DynamicRangeTagContent(plan: model.dynamicRangePlan)?.text == "HDR10")
        let sdr = ShotRenderer.makeModel(scenario: .playing, title: "x.mkv", position: .seconds(12), duration: .seconds(60))
        #expect(DynamicRangeTagContent(plan: sdr.dynamicRangePlan) == nil)
    }

    @Test func thePlanTextHasNoDashes() throws {
        for range in [DynamicRange.hdr10, .hlg, .dolbyVision(dolbyVision5)] {
            let tag = try #require(content(range, display: .sdr))
            for text in [tag.text, tag.detail ?? "", tag.tooltip, tag.accessibilityLabel] {
                #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
            }
        }
    }
}
