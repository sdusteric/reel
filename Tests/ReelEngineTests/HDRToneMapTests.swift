import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import ReelCore
import Testing
@testable import ReelEngine

/// Images Reel makes from HDR frames (design section 7.7, D53): tone-mapped to 8-bit sRGB with
/// highlights rolled off, reference white near SDR white, black kept, neutrals neutral.
/// Serialized: run in parallel, its synchronous decode cases filled every cooperative pool
/// thread for the first seconds of `swift test` and held back other suites' timing checks.
@Suite(.serialized) struct HDRToneMapTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var fixture: HDRFixture
        var decoder: VideoDecoderKind
        var testDescription: String { "\(fixture.rawValue) \(decoder.rawValue)" }
    }

    static let cases: [Case] = [HDRFixture.pqHEVCMKV, .pqHEVCMP4, .hlgHEVCMKV, .hlgHEVCMP4, .pqAV1, .pqVP9, .dv81MP4, .dv84MP4].flatMap { fixture in
        [VideoDecoderKind.hardware, .software].map { Case(fixture: fixture, decoder: $0) }
    }

    /// The reference white patch: 203 nits for PQ, signal 0.75 for HLG.
    static func isReferenceWhite(_ patch: RampSet.Patch, _ transfer: RampSet.Transfer) -> Bool {
        transfer == .pq ? patch.nits == HDRToneMapper.referenceWhiteNits : patch.signal == 0.75
    }

    /// Checks the section 7.7 pass rules on the neutral patches of `raster` (sized like the ramp
    /// when `scale` is 1). Returns the reference white value.
    @discardableResult
    static func checkPassRules(_ raster: SRGBRaster, ramp: RampSet.Ramp, transfer: RampSet.Transfer, label: String) -> Double? {
        let neutral = ramp.patches.filter { $0.kind == "neutral" }
        let values = neutral.map { raster.mean(centerX: $0.center.x, centerY: $0.center.y) }
        let lumas = values.map { $0.luma.rounded() }
        for index in lumas.indices.dropFirst() where lumas[index - 1] < 255 {
            #expect(lumas[index] > lumas[index - 1], "\(label): \(neutral[index].name) \(lumas[index]) after \(lumas[index - 1])")
        }
        #expect(Set(lumas).count >= (transfer == .pq ? 7 : 5), "\(label): distinct values \(lumas)")
        #expect(lumas[0] <= 3, "\(label): black is \(lumas[0])")
        for (patch, value) in zip(neutral, values) {
            #expect(value.neutralSpread <= 3, "\(label): \(patch.name) is not neutral: \(value)")
        }
        guard let index = neutral.firstIndex(where: { isReferenceWhite($0, transfer) }) else {
            Issue.record("\(label): no reference white patch")
            return nil
        }
        let white = lumas[index]
        #expect((190...250).contains(white), "\(label): reference white \(white)")
        return white
    }

    @Test(arguments: cases)
    func toneMappedFramesFollowThePassRules(_ item: Case) throws {
        let ramps = try RampSet.load()
        let grab = try FrameGrabber.grab(url: item.fixture.url(), at: .seconds(0.5), decoder: item.decoder)
        #expect(grab.frame.pixelBuffer.withUnsafeBuffer { HDRToneMapper.isHDR($0) })
        let image = try FrameGrabber.image(from: grab.frame.pixelBuffer)
        #expect(image.width == 1920 && image.height == 1080)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(image.bitsPerComponent == 8)
        let raster = try #require(SRGBRaster(image))
        let white = Self.checkPassRules(raster, ramp: ramps[item.fixture.ramp], transfer: item.fixture.ramp, label: item.testDescription)
        // A display without EDR headroom shows this picture (section 16, M3 acceptance 9).
        #expect((225...255).contains(white ?? 0))
    }

    @Test func pqMatchesQuickTimeOnTheSameFrame() async throws {
        let ramps = try RampSet.load()
        let url = try HDRFixture.pqHEVCMP4.url()
        let mine = try #require(SRGBRaster(try FrameGrabber.grabImage(url: url, at: .seconds(0.5), decoder: .hardware)))
        let quickTime = try #require(SRGBRaster(try await FrameGrabber.referenceImage(url: url, at: .seconds(0.5))))
        for patch in ramps.pq.patches where patch.kind == "neutral" {
            let a = mine.mean(centerX: patch.center.x, centerY: patch.center.y)
            let b = quickTime.mean(centerX: patch.center.x, centerY: patch.center.y)
            #expect(abs(a.g - b.g) <= 3, "\(patch.name): \(a.g) against QuickTime \(b.g)")
        }
    }

    @Test func sourceHeadroomComesFromMaxCLLThenMasteringPeakThenTheDefault() {
        let light = Data([0x03, 0xe8, 0x01, 0x90]) // 1000, 400
        var mastering = Data(repeating: 0, count: 24)
        mastering[16] = 0x00; mastering[17] = 0x3d; mastering[18] = 0x09; mastering[19] = 0x00 // 4000000 = 400 nits
        #expect(abs(HDRToneMapper.sourceHeadroom(transfer: .pq, contentLightLevel: light, masteringDisplay: mastering) - Float(1_000.0 / 203)) < 1e-4)
        #expect(abs(HDRToneMapper.sourceHeadroom(transfer: .pq, contentLightLevel: nil, masteringDisplay: mastering) - Float(400.0 / 203)) < 1e-4)
        #expect(HDRToneMapper.sourceHeadroom(transfer: .pq, contentLightLevel: nil, masteringDisplay: nil) == HDRToneMapper.defaultContentHeadroom)
        #expect(HDRToneMapper.sourceHeadroom(transfer: .pq, contentLightLevel: Data([0, 0, 0, 0]), masteringDisplay: nil) == HDRToneMapper.defaultContentHeadroom)
        #expect(abs(HDRToneMapper.sourceHeadroom(transfer: .hlg, contentLightLevel: light, masteringDisplay: nil) - Float(1_000.0 / 203)) < 1e-4)
        #expect(AttachmentValues.masteringPeak(mastering) == 400)
        #expect(AttachmentValues.maxCLL(Data([1])) == nil)
    }

    @Test func sdrFramesAreNotToneMapped() throws {
        let grab = try FrameGrabber.grab(url: HDRFixture.sdrH264.url(), at: .seconds(0.5), decoder: .hardware)
        #expect(grab.frame.pixelBuffer.withUnsafeBuffer { HDRToneMapper.sourceHeadroom(of: $0) } == nil)
        let ramps = try RampSet.load()
        let raster = try #require(SRGBRaster(try FrameGrabber.image(from: grab.frame.pixelBuffer)))
        // Signal 1.0 is SDR white and stays there; 0.75 keeps its BT.709 value (about 197).
        let white = try #require(ramps.sdr.patches.first { $0.signal == 1 })
        #expect(raster.mean(centerX: white.center.x, centerY: white.center.y).luma >= 250)
        let threeQuarters = try #require(ramps.sdr.patches.first { $0.signal == 0.75 })
        #expect(abs(raster.mean(centerX: threeQuarters.center.x, centerY: threeQuarters.center.y).luma - 197) <= 4)
    }

    @Test func anEDRDisplayKeepsReferenceWhiteAndRollsOffAboveItsHeadroom() throws {
        let ramps = try RampSet.load()
        let grab = try FrameGrabber.grab(url: HDRFixture.pqHEVCMKV.url(), at: .seconds(0.5), decoder: .hardware)
        func linear(_ name: String, headroom: Float) throws -> Double {
            let patch = try #require(ramps.pq.patches.first { $0.name == name })
            let rect = CGRect(x: patch.center.x - 8, y: patch.center.y - 8, width: 16, height: 16)
            return try #require(grab.frame.pixelBuffer.withUnsafeBuffer { HDRToneMapper.linearMean($0, rect: rect, targetHeadroom: headroom) }).g
        }
        // Headroom 16 is more than the content needs (MaxCLL 1000 is 4.93 times 203 nits).
        #expect(abs(try linear("203 nits", headroom: 16) - 1) < 0.02)
        #expect(abs(try linear("1000 nits", headroom: 16) - 4.93) < 0.1)
        // Headroom 2: reference white dims a little, 1000 nits lands on the display's peak.
        #expect(try linear("1000 nits", headroom: 2) <= 2.01)
        #expect(try linear("400 nits", headroom: 2) < (try linear("1000 nits", headroom: 2)))
    }

    @Test(arguments: [VideoDecoderKind.hardware, .software])
    func thumbnailsOfHDRFramesAreToneMapped(_ decoder: VideoDecoderKind) async throws {
        let ramps = try RampSet.load()
        for fixture in [HDRFixture.pqHEVCMKV, .hlgHEVCMP4, .pqAV1] {
            var options = ThumbnailGenerator.Options()
            options.decoder = decoder
            let generator = ThumbnailGenerator(url: try fixture.url(), key: nil, cache: nil, options: options)
            generator.start()
            _ = await generator.finished()
            let thumbnail = try #require(generator.thumbnail(at: .seconds(0.5)), "\(fixture.rawValue)")
            generator.close()
            let source = try #require(CGImageSourceCreateWithData(thumbnail.jpeg as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 384 && image.height == 216)
            let raster = try #require(SRGBRaster(image))
            let ramp = ramps[fixture.ramp]
            let white = try #require(ramp.patches.first { Self.isReferenceWhite($0, fixture.ramp) })
            let value = raster.mean(centerX: white.center.x * 384 / ramp.width, centerY: white.center.y * 216 / ramp.height, size: 6)
            #expect((185...250).contains(value.luma), "\(fixture.rawValue) \(decoder.rawValue): \(value)")
        }
    }
}
