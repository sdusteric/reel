import CoreVideo
import CReelDeps
import Foundation
import ReelCore
import Testing
@testable import ReelEngine

@Suite struct DolbyVisionProbeTests {
    static let withRecord: [HDRFixture] = [.dv81MP4, .dv81MKV, .dv84MP4, .dv5MP4]

    @Test(arguments: withRecord)
    func demuxerReportsTheRecord(_ fixture: HDRFixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        defer { demuxer.stop() }
        let config = try #require(demuxer.info.dolbyVision)
        let expected = try #require(fixture.dolbyVision)
        #expect(config.profile == expected.profile)
        #expect(config.compatibilityID == expected.compatibility)
        #expect(config.level == 6)
        #expect(config.rpu)
        #expect(!config.el)
        #expect(config.bl)
    }

    @Test(arguments: withRecord)
    func classificationAndPolicyFollowTheRecord(_ fixture: HDRFixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        defer { demuxer.stop() }
        let range = DynamicRange.classify(demuxer.info)
        #expect(range.kind == .dolbyVision)
        switch fixture {
        case .dv81MP4, .dv81MKV: #expect(range.dolbyVisionBase == .hdr10)
        case .dv84MP4: #expect(range.dolbyVisionBase == .hlg)
        default: #expect(range.dolbyVisionBase == .unsupported)
        }
    }

    @Test func profile5UsesTheDolbyVisionSampleEntryAndStillDemuxesAsHEVC() throws {
        let source = try MediaSource(url: HDRFixture.dv5MP4.url())
        let index = try #require(source.videoStreamIndex)
        let stream = try #require(source.stream(index))
        #expect(String(cString: avcodec_get_name(stream.pointee.codecpar.pointee.codec_id)) == "hevc")
        let config = try #require(DolbyVisionProbe.config(of: stream))
        #expect(config.profile == 5)
        #expect(config.compatibilityID == 0)
    }

    @Test(arguments: [HDRFixture.pqHEVCMP4, .pqHEVCMKV, .hlgHEVCMP4, .pqAV1, .pqVP9, .sdrH264])
    func rampsWithoutARecordReportNone(_ fixture: HDRFixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        defer { demuxer.stop() }
        #expect(demuxer.info.dolbyVision == nil)
    }

    @Test func classicHDR10FixtureHasNoRecord() throws {
        let demuxer = try Demuxer(url: Fixture.hdr10.url())
        defer { demuxer.stop() }
        #expect(demuxer.info.dolbyVision == nil)
        #expect(DynamicRange.classify(demuxer.info) == .hdr10)
    }

    @Test func recordBytesParse() {
        // AVDOVIDecoderConfigurationRecord: version 1.0, profile 8, level 6, RPU, no EL, BL, compatibility 4.
        let bytes: [UInt8] = [1, 0, 8, 6, 1, 0, 1, 4, 0]
        let config = bytes.withUnsafeBufferPointer(DolbyVisionProbe.parse)
        #expect(config == DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 4))
    }

    @Test func shortOrEmptyRecordsAreIgnored() {
        #expect([UInt8]([1, 0, 8, 6, 1, 0, 1]).withUnsafeBufferPointer(DolbyVisionProbe.parse) == nil)
        #expect([UInt8]([1, 0, 0, 0, 0, 0, 0, 0, 0]).withUnsafeBufferPointer(DolbyVisionProbe.parse) == nil)
        #expect([UInt8]().withUnsafeBufferPointer(DolbyVisionProbe.parse) == nil)
    }

    @Test func mediaInfoCarriesTheRecordThroughJSON() throws {
        let demuxer = try Demuxer(url: HDRFixture.dv81MKV.url())
        defer { demuxer.stop() }
        let decoded = try JSONDecoder().decode(MediaInfo.self, from: JSONEncoder().encode(demuxer.info))
        #expect(decoded.dolbyVision == demuxer.info.dolbyVision)
    }

    // MARK: M3-2: decode, plans and the session probe

    @Test(arguments: [VideoDecoderKind.hardware, .software])
    func profile81DecodesToThePQRampCodes(_ decoder: VideoDecoderKind) throws {
        let ramps = try RampSet.load()
        let dolby = try FrameGrabber.grab(url: HDRFixture.dv81MP4.url(), at: .seconds(0.5), decoder: decoder).frame.pixelBuffer
        let plain = try FrameGrabber.grab(url: HDRFixture.pqHEVCMP4.url(), at: .seconds(0.5), decoder: decoder).frame.pixelBuffer
        for patch in ramps.pq.patches {
            let a = try #require(FrameGrabber.meanCodes(dolby, centerX: patch.center.x, centerY: patch.center.y))
            let b = try #require(FrameGrabber.meanCodes(plain, centerX: patch.center.x, centerY: patch.center.y))
            #expect(abs(a.y - Double(patch.codes.y)) <= 2 && abs(a.cb - Double(patch.codes.cb)) <= 2 && abs(a.cr - Double(patch.codes.cr)) <= 2, "\(patch.name): \(a)")
            #expect(abs(a.y - b.y) <= 2 && abs(a.cb - b.cb) <= 2 && abs(a.cr - b.cr) <= 2, "\(patch.name): \(a) against \(b)")
        }
        #expect(dolby.withUnsafeBuffer { HDRToneMapper.transfer(of: $0) } == .pq)
    }

    @Test func profile84PlaysTheHLGBase() throws {
        let buffer = try FrameGrabber.grab(url: HDRFixture.dv84MP4.url(), at: .seconds(0.5), decoder: .hardware).frame.pixelBuffer
        #expect(buffer.withUnsafeBuffer { HDRToneMapper.transfer(of: $0) } == .hlg)
        #expect(buffer.withUnsafeBuffer { CVBufferCopyAttachment($0, kCVImageBufferColorPrimariesKey, nil) as? String } == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
    }

    @Test(arguments: withRecord)
    func plansFollowThePolicy(_ fixture: HDRFixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        defer { demuxer.stop() }
        let plan = DynamicRangePlan.make(content: DynamicRange.classify(demuxer.info), setting: .full, display: .xdr)
        #expect(plan.layer == .high)
        #expect(plan.overlay == .standard)
        switch fixture {
        case .dv5MP4:
            #expect(plan.tag == "Dolby Vision 5")
            #expect(plan.note && plan.warning)
        default:
            #expect(plan.tag == "Dolby Vision")
            #expect(!plan.note && !plan.warning)
        }
    }

    @Test func configurationBoxPacksTheRecordBits() {
        let box = DolbyVisionProbe.configurationBox(DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: 1))
        #expect(box.count == 24)
        // version 1.0; profile 8 (7 bits), level 6 (6 bits), rpu 1, el 0, bl 1; compatibility 1 in the high nibble.
        #expect(Array(box.prefix(5)) == [1, 0, 0x10, 0x35, 0x10])
        #expect(box.dropFirst(5).allSatisfy { $0 == 0 })
        #expect(DolbyVisionProbe.configurationBoxName(profile: 5) == "dvcC")
        #expect(DolbyVisionProbe.configurationBoxName(profile: 8) == "dvvC")
        #expect(DolbyVisionProbe.configurationBoxName(profile: 20) == "dvwC")
    }

    @Test func theSessionProbeReportsOnProfile5WithoutCrashing() throws {
        let report = try DolbyVisionProbe.sessionReport(url: HDRFixture.dv5MP4.url())
        #expect(report.dolbyVision?.profile == 5)
        #expect(report.codecType == "dvh1")
        #expect(report.configurationBox == "dvcC")
        #expect(report.framesSubmitted > 0 || report.error != nil)
        #expect(report.framesDecoded + report.failures <= report.framesSubmitted)
        _ = try JSONEncoder().encode(report)
    }
}
