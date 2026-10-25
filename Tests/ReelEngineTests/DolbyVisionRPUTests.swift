import AVFoundation
import CoreVideo
import Foundation
import ReelCore
import Testing
@testable import ReelEngine

/// Dolby Vision files with real RPUs (section 7.8): the ramps re-encoded by make-dovi-rpu.c with
/// Dolby Vision metadata on every frame. AVFoundation and VideoToolbox accept them, unlike the
/// record-only fixtures, so they show that Reel's base-layer playback matches QuickTime on an
/// identity reshaping, and what VideoToolbox does with a profile 5 stream.
@Suite struct DolbyVisionRPUTests {
    static let files: [HDRFixture] = [.dv81RPU, .dv84RPU, .dv5RPU]

    /// HEVC NAL unit types in a length-prefixed (hvcC) packet.
    static func nalTypes(_ packet: Packet) -> [Int] {
        var types: [Int] = []
        let bytes = packet.bytes
        var offset = 0
        while offset + 5 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            types.append(Int(bytes[offset + 4] >> 1) & 0x3f)
            offset += 4 + length
        }
        return types
    }

    @Test(arguments: files)
    func everyFrameCarriesAnRPUAndTheRecordMatches(_ fixture: HDRFixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        defer { demuxer.stop() }
        let config = try #require(demuxer.info.dolbyVision)
        let expected = try #require(fixture.dolbyVision)
        #expect(config.profile == expected.profile)
        #expect(config.compatibilityID == expected.compatibility)
        #expect(config.rpu && config.bl && !config.el)
        let packets = try VP9TileCheckTests.videoPackets(fixture.url()).packets
        #expect(packets.count == HDRFixture.frameCount)
        #expect(packets.allSatisfy { DolbyVisionRPUTests.nalTypes($0).contains(62) })
    }

    /// Reel plays the base layer: the HDR10 base of 8.1 and the HLG base of 8.4 decode to the
    /// generated codes on both decoders, the RPU NAL units pass through untouched.
    @Test(arguments: [VideoDecoderKind.hardware, .software])
    func theBaseLayersDecodeToTheRampCodes(_ decoder: VideoDecoderKind) throws {
        let ramps = try RampSet.load()
        for fixture in [HDRFixture.dv81RPU, .dv84RPU] {
            let buffer = try FrameGrabber.grab(url: fixture.url(), at: .seconds(0.5), decoder: decoder).frame.pixelBuffer
            let set = fixture.ramp == .pq ? ramps.pq : ramps.hlg
            for patch in set.patches {
                let codes = try #require(FrameGrabber.meanCodes(buffer, centerX: patch.center.x, centerY: patch.center.y))
                #expect(abs(codes.y - Double(patch.codes.y)) <= 2 && abs(codes.cb - Double(patch.codes.cb)) <= 2 && abs(codes.cr - Double(patch.codes.cr)) <= 2,
                        "\(fixture) \(patch.name): \(codes)")
            }
            #expect(buffer.withUnsafeBuffer { HDRToneMapper.transfer(of: $0) } == (fixture.ramp == .pq ? .pq : .hlg))
        }
    }

    @Test(arguments: files)
    func plansFollowThePolicy(_ fixture: HDRFixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        defer { demuxer.stop() }
        let plan = DynamicRangePlan.make(content: DynamicRange.classify(demuxer.info), setting: .full, display: .xdr)
        #expect(plan.layer == .high)
        if fixture == .dv5RPU {
            #expect(plan.tag == "Dolby Vision 5")
            #expect(plan.note && plan.warning)
        } else {
            #expect(plan.tag == "Dolby Vision")
            #expect(!plan.note && !plan.warning)
        }
    }

    /// The sRGB frame AVAssetImageGenerator (QuickTime's path) makes, at neutral patch centres.
    static func referenceNeutrals(_ url: URL, ramp: [RampSet.Patch]) async throws -> [Int] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(value: 12, timescale: 24))
        let width = image.width, height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return ramp.filter { $0.kind == "neutral" }.map { patch in
            let (x, y) = patch.center
            return Int(pixels[(y * width + x) * 4 + 1])
        }
    }

    /// QuickTime renders the 8.1 file (identity reshaping) exactly as the plain HDR10 ramp, which
    /// is what Reel shows for it; the record-only fixture does not decode in AVFoundation at all.
    @Test func avFoundationPlaysProfile81AsItsHDR10Base() async throws {
        let ramps = try RampSet.load()
        let dolby = try await DolbyVisionRPUTests.referenceNeutrals(HDRFixture.dv81RPU.url(), ramp: ramps.pq.patches)
        let plain = try await DolbyVisionRPUTests.referenceNeutrals(HDRFixture.pqHEVCMP4.url(), ramp: ramps.pq.patches)
        #expect(dolby == plain, "\(dolby) against \(plain)")
        await #expect(throws: (any Error).self) {
            _ = try await DolbyVisionRPUTests.referenceNeutrals(HDRFixture.dv81MP4.url(), ramp: ramps.pq.patches)
        }
    }

    /// VideoToolbox's Dolby Vision session decodes profile 5 with real RPUs and attaches each
    /// frame's RPU to the output buffer; the picture it returns is the base, unreshaped (the
    /// display pipeline, not the decoder, would apply it). Without RPUs it fails (dv5.mp4).
    @Test func theDolbyVisionSessionPassesProfile5RPUsOnUnreshaped() throws {
        let report = try DolbyVisionProbe.sessionReport(url: HDRFixture.dv5RPU.url())
        #expect(report.sessionCreated)
        #expect(report.failures == 0)
        #expect(report.framesDecoded == report.framesSubmitted && report.framesDecoded > 0)
        #expect(report.attachments["DolbyVisionRPUData"]?.isEmpty == false)
        #expect(report.meanCb == report.hevcMeanCb && report.meanCr == report.hevcMeanCr)
        let recordOnly = try DolbyVisionProbe.sessionReport(url: HDRFixture.dv5MP4.url())
        #expect(recordOnly.framesDecoded == 0)
    }
}
