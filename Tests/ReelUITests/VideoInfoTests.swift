import Foundation
import ReelCore
import Testing
@testable import ReelUI

@MainActor
@Suite struct VideoInfoTests {
    private func media(
        color: ColorInfo,
        dolbyVision: DolbyVisionConfig? = nil,
        width: Int = 3_840,
        height: Int = 2_160,
        profile: String? = "Main 10"
    ) -> MediaInfo {
        let base = Rational(1, 1_000)
        return MediaInfo(
            url: URL(filePath: "/Show/x.mkv"),
            formatName: "matroska,webm",
            duration: .seconds(600),
            streams: [
                StreamInfo(
                    index: 0, kind: .video, codec: "hevc", profile: profile, timeBase: base,
                    video: VideoParameters(width: width, height: height, frameRate: Rational(24_000, 1_001), bitDepth: 10, color: color)
                ),
                StreamInfo(
                    index: 1, kind: .audio, codec: "eac3", timeBase: base,
                    audio: AudioParameters(sampleRate: 48_000, channels: 6, channelLayout: "5.1(side)")
                ),
            ],
            videoStreamIndex: 0,
            audioStreamIndex: 1,
            videoDecoder: .hardware,
            dolbyVision: dolbyVision
        )
    }

    private var hdr10Color: ColorInfo {
        ColorInfo(
            primaries: "bt2020", transfer: DynamicRange.pqTransfer, matrix: "bt2020nc",
            hasHDRMetadata: true, mastering: .p3D65(), contentLight: ContentLightLevel(maxCLL: 1_000, maxFALL: 400)
        )
    }

    private func groups(_ info: MediaInfo, display: DisplayCapabilities = .xdr, setting: HDRSetting = .full) -> [[VideoInfoRow]] {
        let plan = DynamicRangePlan.make(content: DynamicRange.classify(info), setting: setting, display: display)
        return VideoInfoContent.groups(
            media: info, plan: plan, decoder: .hardware, droppedFrames: 0, damagedCount: 0, audioStreamIndex: 1
        )
    }

    private func value(_ key: String, in groups: [[VideoInfoRow]]) -> VideoInfoRow? {
        groups.flatMap { $0 }.first { $0.key == key }
    }

    @Test func aDolbyVision81FileShowsTheBaseLayerAndEveryGroup() {
        let config = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 1)
        let result = groups(media(color: hdr10Color, dolbyVision: config))
        #expect(result.map { $0.map(\.key) } == [
            ["Video", "Decoder"],
            ["Range", "Color", "Mastering", "Light level"],
            ["Display", "Headroom"],
            ["Audio", "Frames"],
        ])
        #expect(value("Video", in: result)?.value == "HEVC Main 10, 3840 \u{00D7} 2160, 23.976 fps")
        #expect(value("Decoder", in: result)?.value == "VideoToolbox, hardware")
        #expect(value("Range", in: result)?.value == "Dolby Vision 8.1")
        #expect(value("Range", in: result)?.detail == "Playing the HDR10 base layer. The Dolby Vision layer is not applied.")
        #expect(value("Color", in: result)?.value == "BT.2020, PQ, limited range")
        #expect(value("Mastering", in: result)?.value == "1000 nits peak, P3 D65")
        #expect(value("Light level", in: result)?.value == "MaxCLL 1000, MaxFALL 400 nits")
        #expect(value("Display", in: result)?.value == "Built-in XDR display, HDR")
        #expect(value("Headroom", in: result)?.value == "3.2\u{00D7} now, 16\u{00D7} at most")
        #expect(value("Audio", in: result)?.value == "E-AC-3 5.1, 48 kHz")
        #expect(value("Frames", in: result)?.value == "0 dropped, 0 damaged")
    }

    @Test func anHDR10FileHasNoSecondLineAndFollowsTheDisplay() {
        let info = media(color: hdr10Color)
        let xdr = groups(info)
        #expect(value("Range", in: xdr)?.value == "HDR10")
        #expect(value("Range", in: xdr)?.detail == nil)
        let sdr = groups(info, display: .sdr)
        #expect(value("Display", in: sdr)?.value == "SDR display, SDR")
        #expect(value("Headroom", in: sdr)?.value == "1\u{00D7} now, 1\u{00D7} at most")
    }

    @Test func profile5SaysTheColoursAreWrong() {
        let config = DolbyVisionConfig(profile: 5, level: 6, rpu: true, el: false, bl: true, compatibilityID: 0)
        let result = groups(media(color: ColorInfo(), dolbyVision: config, profile: nil))
        #expect(value("Range", in: result)?.value == "Dolby Vision 5")
        #expect(value("Range", in: result)?.detail?.contains("colors are wrong") == true)
        #expect(value("Color", in: result)?.value == "Unspecified")
        #expect(value("Mastering", in: result) == nil)
        #expect(value("Video", in: result)?.value == "HEVC 10-bit, 3840 \u{00D7} 2160, 23.976 fps")
    }

    @Test func anSDRFileHasNoMasteringRows() {
        let color = ColorInfo(primaries: "bt709", transfer: "bt709", matrix: "bt709")
        let result = groups(media(color: color, width: 1_920, height: 1_080))
        #expect(value("Range", in: result)?.value == "SDR")
        #expect(value("Color", in: result)?.value == "BT.709, BT.709, limited range")
        #expect(value("Mastering", in: result) == nil)
        #expect(value("Light level", in: result) == nil)
    }

    @Test func frameRatesAreTrimmed() {
        #expect(VideoInfoContent.frameRateText(24) == "24")
        #expect(VideoInfoContent.frameRateText(24_000.0 / 1_001.0) == "23.976")
        #expect(VideoInfoContent.frameRateText(30_000.0 / 1_001.0) == "29.97")
        #expect(VideoInfoContent.frameRateText(59.94) == "59.94")
    }

    @Test func softwareDecodingNamesTheLibrary() {
        #expect(VideoInfoContent.decoderText(.software, codec: "av1") == "dav1d, software")
        #expect(VideoInfoContent.decoderText(.software, codec: "vp9") == "libavcodec, software")
    }

    @Test func theModelUpdatesTheRowsInPlace() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var options = FakeEngine.Options()
        options.dynamicRange = .hdr10
        let (model, _, _) = makeModel(engine: FakeEngine(options: options), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("hdr.mkv"))
        await waitUntil("range") { model.dynamicRange == .hdr10 }
        #expect(value("Display", in: model.videoInfoGroups)?.value == "Built-in XDR display, HDR")
        model.setDisplay(.sdr)
        model.setDroppedFrames(4)
        model.handle(.damaged(at: .seconds(30), kind: .audio))
        let rows = model.videoInfoGroups
        #expect(value("Display", in: rows)?.value == "SDR display, SDR")
        #expect(value("Frames", in: rows)?.value == "4 dropped, 1 damaged")
        #expect(value("Decoder", in: rows)?.value == "VideoToolbox, hardware")
        #expect(value("Video", in: rows)?.value.hasPrefix("HEVC") == true)
    }

    @Test func theKeyAndTheTagOpenAndCloseIt() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _, _) = makeModel(engine: FakeEngine(), scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        model.toggleVideoInfo()
        #expect(model.videoInfoVisible)
        model.toggleVideoInfo()
        #expect(!model.videoInfoVisible)
        model.toggleVideoInfo()
        await model.close()
        #expect(!model.videoInfoVisible, "closing the file closes the panel")
    }
}
