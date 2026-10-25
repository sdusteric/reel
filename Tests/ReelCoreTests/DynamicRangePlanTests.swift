import Foundation
import Testing
@testable import ReelCore

@Suite struct DynamicRangePlanTests {
    static let dv81 = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 1)
    static let dv84 = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 4)
    static let dv82 = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 2)
    static let dv5 = DolbyVisionConfig(profile: 5, level: 6, rpu: true, el: false, bl: true, compatibilityID: 0)

    // MARK: Classification

    @Test func transferFunctionClassifiesTheContent() {
        let cases: [(String?, DynamicRange)] = [
            ("smpte2084", .hdr10), ("arib-std-b67", .hlg), ("bt709", .sdr), ("smpte170m", .sdr),
            ("iec61966-2-1", .sdr), ("bt2020-10", .sdr), (nil, .sdr),
        ]
        for (transfer, expected) in cases {
            #expect(DynamicRange.classify(color: ColorInfo(transfer: transfer), dolbyVision: nil) == expected, "\(transfer ?? "nil")")
        }
        #expect(DynamicRange.classify(color: nil, dolbyVision: nil) == .sdr)
    }

    @Test func aDolbyVisionRecordWinsOverTheTransfer() {
        let pq = ColorInfo(primaries: "bt2020", transfer: "smpte2084", matrix: "bt2020nc")
        #expect(DynamicRange.classify(color: pq, dolbyVision: Self.dv81) == .dolbyVision(Self.dv81))
        #expect(DynamicRange.classify(color: ColorInfo(transfer: "arib-std-b67"), dolbyVision: Self.dv84).dolbyVisionBase == .hlg)
    }

    @Test func mediaInfoClassifiesItsSelectedVideoStream() {
        let video = StreamInfo(
            index: 0, kind: .video, codec: "hevc", timeBase: Rational(1, 1_000),
            video: VideoParameters(width: 1920, height: 1080, bitDepth: 10, color: ColorInfo(transfer: "smpte2084"))
        )
        var info = MediaInfo(url: URL(filePath: "/tmp/pq.mkv"), formatName: "matroska,webm", streams: [video], videoStreamIndex: 0)
        #expect(DynamicRange.classify(info) == .hdr10)
        info.dolbyVision = Self.dv5
        #expect(DynamicRange.classify(info).kind == .dolbyVision)
        info.videoStreamIndex = nil
        info.dolbyVision = nil
        #expect(DynamicRange.classify(info) == .sdr)
    }

    @Test func kindsTagsAndRangeNames() {
        let cases: [(DynamicRange, DynamicRange.Kind, String?, String, Bool)] = [
            (.sdr, .sdr, nil, "SDR", false),
            (.hdr10, .hdr10, "HDR10", "HDR10", true),
            (.hlg, .hlg, "HLG", "HLG", true),
            (.dolbyVision(Self.dv81), .dolbyVision, "Dolby Vision", "Dolby Vision 8.1", true),
            (.dolbyVision(Self.dv84), .dolbyVision, "Dolby Vision", "Dolby Vision 8.4", true),
            (.dolbyVision(Self.dv82), .dolbyVision, "Dolby Vision", "Dolby Vision 8.2", false),
            (.dolbyVision(Self.dv5), .dolbyVision, "Dolby Vision 5", "Dolby Vision 5", true),
        ]
        for (range, kind, tag, name, hdr) in cases {
            #expect(range.kind == kind)
            #expect(range.tag == tag)
            #expect(range.rangeName == name)
            #expect(range.isHDR == hdr, "\(name)")
        }
    }

    @Test func dynamicRangeEncodesKindAndBase() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(DynamicRange.hlg), as: UTF8.self) == #"{"kind":"hlg"}"#)
        let dv = String(decoding: try encoder.encode(DynamicRange.dolbyVision(Self.dv84)), as: UTF8.self)
        #expect(dv.contains(#""kind":"dolbyVision""#))
        #expect(dv.contains(#""base":"hlg""#))
        #expect(dv.contains(#""compatibilityID":4"#))
        for range in [DynamicRange.sdr, .hdr10, .hlg, .dolbyVision(Self.dv5)] {
            #expect(try JSONDecoder().decode(DynamicRange.self, from: encoder.encode(range)) == range)
        }
    }

    // MARK: The section 7.7 table

    struct Row: Sendable, CustomTestStringConvertible {
        var content: DynamicRange
        var setting: HDRSetting
        var display: DisplayCapabilities
        var layer: LayerDynamicRange
        var presentation: DynamicRangePresentation
        var tag: String?
        var detail: String?

        var testDescription: String { "\(content.rangeName), \(setting.rawValue), \(display.name)" }
    }

    static let displays: [DisplayCapabilities] = [.sdr, .xdr, .external]

    /// Every content, setting and display, with the expectations written out from the table.
    static let table: [Row] = {
        var rows: [Row] = []
        let contents: [DynamicRange] = [.sdr, .hdr10, .hlg, .dolbyVision(dv81), .dolbyVision(dv84), .dolbyVision(dv82), .dolbyVision(dv5)]
        for content in contents {
            for setting in HDRSetting.allCases {
                for display in displays {
                    let hdr = content.isHDR
                    let layer: LayerDynamicRange = !hdr ? .standard : [.full: .high, .limited: .constrainedHigh, .off: .standard][setting]!
                    let toneMapped = hdr && (setting == .off || display == .sdr)
                    rows.append(Row(
                        content: content, setting: setting, display: display, layer: layer,
                        presentation: !hdr ? .sdr : (toneMapped ? .toneMapToSDR : .edr),
                        tag: content.tag, detail: toneMapped ? "SDR" : nil
                    ))
                }
            }
        }
        return rows
    }()

    @Test(arguments: table)
    func planFollowsTheTable(_ row: Row) {
        let plan = DynamicRangePlan.make(content: row.content, setting: row.setting, display: row.display)
        #expect(plan.layer == row.layer)
        #expect(plan.overlay == .standard)
        #expect(plan.presentation == row.presentation)
        #expect(plan.tag == row.tag)
        #expect(plan.tagDetail == row.detail)
        #expect(plan.note == (row.content == .dolbyVision(Self.dv5)))
        #expect(plan.warning == plan.note)
    }

    @Test func sdrContentIsAlwaysStandardWithoutATag() {
        for setting in HDRSetting.allCases {
            for display in Self.displays + [.headroom(8)] {
                let plan = DynamicRangePlan.make(content: .sdr, setting: setting, display: display)
                #expect(plan.layer == .standard)
                #expect(plan.tag == nil)
                #expect(plan.tagDetail == nil)
                #expect(plan.tagTooltip == nil)
                #expect(plan.accessibilityLabel == nil)
            }
        }
    }

    /// The criterion's grid for the PQ ramp: layer from the setting, overlay standard, tag HDR10,
    /// detail exactly when the display is SDR or the setting is Off.
    @Test func pqRampGridMatchesTheCriterion() {
        let layers: [HDRSetting: LayerDynamicRange] = [.full: .high, .limited: .constrainedHigh, .off: .standard]
        for display in Self.displays {
            for setting in HDRSetting.allCases {
                let plan = DynamicRangePlan.make(content: .hdr10, setting: setting, display: display)
                #expect(plan.layer == layers[setting])
                #expect(plan.overlay == .standard)
                #expect(plan.tag == "HDR10")
                #expect((plan.tagDetail == "SDR") == (display == .sdr || setting == .off))
            }
        }
    }

    @Test func dolbyVisionProfile81PlaysAsHDR10AndProfile5WarnsWithANote() {
        let p81 = DynamicRangePlan.make(content: .dolbyVision(Self.dv81), setting: .full, display: .xdr)
        #expect(p81.layer == .high)
        #expect(p81.tag == "Dolby Vision")
        #expect(!p81.note)
        let p5 = DynamicRangePlan.make(content: .dolbyVision(Self.dv5), setting: .full, display: .xdr)
        #expect(p5.note)
        #expect(p5.warning)
        #expect(p5.tag == "Dolby Vision 5")
    }

    @Test func headroomOneIsToneMappedAndFourIsEDR() {
        #expect(DynamicRangePlan.make(content: .hdr10, setting: .full, display: .headroom(1.0)).presentation == .toneMapToSDR)
        #expect(DynamicRangePlan.make(content: .hlg, setting: .full, display: .headroom(1.0)).presentation == .toneMapToSDR)
        #expect(DynamicRangePlan.make(content: .hdr10, setting: .full, display: .headroom(4.0)).presentation == .edr)
    }

    /// A headroom change at runtime (the window moves to an SDR display and back) changes the
    /// presentation, tag detail and Video Info, never the display layer.
    @Test func displayChangeAtRuntimeKeepsTheLayer() {
        var display = DisplayCapabilities.xdr
        let before = DynamicRangePlan.make(content: .hdr10, setting: .full, display: display)
        display = .sdr
        let onSDR = DynamicRangePlan.make(content: .hdr10, setting: .full, display: display)
        display = .xdr
        let back = DynamicRangePlan.make(content: .hdr10, setting: .full, display: display)
        #expect(before.layer == .high && onSDR.layer == .high && back.layer == .high)
        #expect(before.presentation == .edr)
        #expect(onSDR.presentation == .toneMapToSDR)
        #expect(onSDR.tagDetail == "SDR")
        #expect(back == before)
    }

    @Test func tooltipsAndAccessibility() {
        let hdr = DynamicRangePlan.make(content: .hdr10, setting: .full, display: .xdr)
        #expect(hdr.tagTooltip == "High dynamic range. Click for details.")
        #expect(hdr.accessibilityLabel == "Dynamic range, HDR10")
        let sdrDisplay = DynamicRangePlan.make(content: .hdr10, setting: .full, display: .sdr)
        #expect(sdrDisplay.tagTooltip == "This display shows standard dynamic range, so the HDR picture is tone-mapped to fit it.")
        #expect(sdrDisplay.accessibilityLabel == "Dynamic range, HDR10, tone-mapped to standard range")
        let off = DynamicRangePlan.make(content: .hlg, setting: .off, display: .xdr)
        #expect(off.tagTooltip == DynamicRangePlan.toneMappedSettingTooltip)
    }

    // MARK: Video Info

    @Test func videoInfoRowsForDolbyVisionOnTheXDRDisplay() {
        let plan = DynamicRangePlan.make(content: .dolbyVision(Self.dv81), setting: .full, display: .xdr)
        #expect(plan.videoInfo == [
            VideoInfoRow(key: "Range", value: "Dolby Vision 8.1", detail: "Playing the HDR10 base layer. The Dolby Vision layer is not applied."),
            VideoInfoRow(key: "Display", value: "Built-in XDR display, HDR"),
            VideoInfoRow(key: "Headroom", value: "3.2\u{00D7} now, 16\u{00D7} at most"),
        ])
        #expect(abs(DisplayCapabilities.xdr.headroomFraction - 0.2) < 1e-9)
    }

    @Test func videoInfoRowsOnAnSDRDisplay() {
        let plan = DynamicRangePlan.make(content: .hdr10, setting: .full, display: .sdr)
        #expect(plan.videoInfo[0] == VideoInfoRow(key: "Range", value: "HDR10"))
        #expect(plan.videoInfo[1] == VideoInfoRow(key: "Display", value: "SDR display, SDR"))
        #expect(plan.videoInfo[2].value == "1\u{00D7} now, 1\u{00D7} at most")
    }

    @Test func colourMasteringAndLightLevelText() {
        let color = ColorInfo(
            primaries: "bt2020", transfer: "smpte2084", matrix: "bt2020nc", fullRange: false, hasHDRMetadata: true,
            mastering: .p3D65(maxLuminance: 1_000), contentLight: ContentLightLevel(maxCLL: 1_000, maxFALL: 400)
        )
        #expect(color.videoInfoDescription == "BT.2020, PQ, limited range")
        #expect(color.mastering?.videoInfoDescription == "1000 nits peak, P3 D65")
        #expect(color.contentLight?.videoInfoDescription == "MaxCLL 1000, MaxFALL 400 nits")
        #expect(ColorInfo(primaries: "bt709", transfer: "bt709", fullRange: true).videoInfoDescription == "BT.709, BT.709, full range")
        #expect(ColorInfo(primaries: "bt2020", transfer: "arib-std-b67").videoInfoDescription == "BT.2020, HLG, limited range")
    }

    // MARK: Displays

    @Test func displayPresetsParse() {
        #expect(DisplayCapabilities.preset("sdr") == .sdr)
        #expect(DisplayCapabilities.preset("XDR") == .xdr)
        #expect(DisplayCapabilities.preset("external") == .external)
        #expect(DisplayCapabilities.preset("headroom=2.5")?.potentialHeadroom == 2.5)
        #expect(DisplayCapabilities.preset("headroom=0.5") == nil)
        #expect(DisplayCapabilities.preset("headroom=abc") == nil)
        #expect(DisplayCapabilities.preset("projector") == nil)
        #expect(!DisplayCapabilities.sdr.supportsEDR)
        #expect(DisplayCapabilities.xdr.supportsEDR && DisplayCapabilities.external.supportsEDR)
        #expect(!DisplayCapabilities.headroom(1.0).supportsEDR)
        #expect(DisplayCapabilities(name: "odd", potentialHeadroom: .nan, currentHeadroom: 0.2).potentialHeadroom == 1)
    }

    @Test func headroomMultipliersDropATrailingZero() {
        #expect(DynamicRangePlan.multiplier(16) == "16\u{00D7}")
        #expect(DynamicRangePlan.multiplier(3.2) == "3.2\u{00D7}")
        #expect(DynamicRangePlan.multiplier(4.96) == "5\u{00D7}")
    }
}
