import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CReelDeps
import Foundation
import QuartzCore
import ReelCore
import Testing
@testable import ReelEngine

/// Decoded HDR frames (design section 7.7): both decode paths produce buffers whose patch codes
/// match the generated ramps and that carry complete colour attachments, MDCV and CLL for PQ.
/// Serialized: run in parallel, its synchronous decode cases filled every cooperative pool
/// thread for the first seconds of `swift test` and held back other suites' timing checks.
@Suite(.serialized) struct HDRDecodeTests {
    static let ramps: [HDRFixture] = [.pqHEVCMKV, .pqHEVCMP4, .hlgHEVCMKV, .hlgHEVCMP4, .pqAV1, .pqVP9, .sdrH264]
    static let frameTime = MediaTime.seconds(0.5)

    struct Case: Sendable, CustomTestStringConvertible {
        var fixture: HDRFixture
        var decoder: VideoDecoderKind
        var testDescription: String { "\(fixture.rawValue) \(decoder.rawValue)" }
    }

    static let cases: [Case] = (ramps + [.dv81MP4, .dv81MKV, .dv84MP4, .dv5MP4]).flatMap { fixture in
        [VideoDecoderKind.hardware, .software].map { Case(fixture: fixture, decoder: $0) }
    }

    /// Section 16 (M3 acceptance 2): 2 codes on HEVC and H.264, 4 on AV1 and VP9.
    static func tolerance(_ fixture: HDRFixture) -> Double {
        switch fixture.videoCodec {
        case "av1", "vp9": 4
        default: 2
        }
    }

    static func string(_ buffer: CVReadOnlyPixelBuffer, _ key: CFString) -> String? {
        buffer.withUnsafeBuffer { CVBufferCopyAttachment($0, key, nil) as? String }
    }

    static func data(_ buffer: CVReadOnlyPixelBuffer, _ key: CFString) -> Data? {
        buffer.withUnsafeBuffer { CVBufferCopyAttachment($0, key, nil) as? Data }
    }

    @Test(arguments: cases)
    func everyPatchDecodesToItsGeneratedCodes(_ item: Case) throws {
        let ramps = try RampSet.load()
        let grab = try FrameGrabber.grab(url: item.fixture.url(), at: Self.frameTime, decoder: item.decoder)
        #expect(grab.frame.decoder == item.decoder)
        let limit = Self.tolerance(item.fixture)
        for patch in ramps[item.fixture.ramp].patches {
            let codes = try #require(FrameGrabber.meanCodes(grab.frame.pixelBuffer, centerX: patch.center.x, centerY: patch.center.y))
            #expect(abs(codes.y - Double(patch.codes.y)) <= limit, "\(patch.name) Y \(codes.y) against \(patch.codes.y)")
            #expect(abs(codes.cb - Double(patch.codes.cb)) <= limit, "\(patch.name) Cb \(codes.cb) against \(patch.codes.cb)")
            #expect(abs(codes.cr - Double(patch.codes.cr)) <= limit, "\(patch.name) Cr \(codes.cr) against \(patch.codes.cr)")
        }
    }

    @Test(arguments: cases)
    func buffersCarryCompleteColourAttachments(_ item: Case) throws {
        let buffer = try FrameGrabber.grab(url: item.fixture.url(), at: Self.frameTime, decoder: item.decoder).frame.pixelBuffer
        let primaries = Self.string(buffer, kCVImageBufferColorPrimariesKey)
        let transfer = Self.string(buffer, kCVImageBufferTransferFunctionKey)
        let matrix = Self.string(buffer, kCVImageBufferYCbCrMatrixKey)
        let mastering = Self.data(buffer, kCVImageBufferMasteringDisplayColorVolumeKey)
        let light = Self.data(buffer, kCVImageBufferContentLightLevelInfoKey)
        switch item.fixture.ramp {
        case .pq, .hlg:
            #expect(primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
            #expect(matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
            #expect(buffer.withUnsafeBuffer { CVPixelBufferGetPixelFormatType($0) } == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            if item.fixture.ramp == .pq {
                #expect(transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                #expect(AttachmentValues.masteringPeak(mastering) == 1_000)
                #expect(AttachmentValues.maxCLL(light) == 1_000)
                #expect(AttachmentValues.maxFALL(light) == 400)
                let points = try #require(AttachmentValues.masteringPrimaries(mastering))
                #expect(abs(points[0].x - 0.680) < 0.001 && abs(points[1].y - 0.690) < 0.001 && abs(points[3].x - 0.3127) < 0.001)
            } else {
                #expect(transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
                #expect(mastering == nil && light == nil)
            }
        case .sdr:
            #expect(primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            #expect(transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
            #expect(matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            #expect(mastering == nil && light == nil)
        }
    }

    @Test func av1AndVP9TakeColourFromTheFirstFrameWhenTheContainerSaysNothing() throws {
        // The frame probe on its own: the first decoded frame of each stream describes it fully.
        for fixture in [HDRFixture.pqAV1, .pqVP9] {
            let source = try MediaSource(url: fixture.url())
            let index = try #require(source.videoStreamIndex)
            let stream = try #require(source.stream(index))
            var packets: [Packet] = []
            while packets.count < 4, let packet = try source.readPacket() {
                if packet.streamIndex == index { packets.append(packet) }
            }
            let probed = try #require(FormatDescriptionBuilder.probeColor(parameters: stream.pointee.codecpar, packets: packets), "\(fixture.rawValue)")
            #expect(probed.transfer == AVCOL_TRC_SMPTE2084 && probed.primaries == AVCOL_PRI_BT2020 && probed.matrix == AVCOL_SPC_BT2020_NCL)
            // An unspecified container description takes every field from the frame.
            let filled = VideoColor().filling(from: probed)
            #expect(filled.isHDR && filled.isComplete)
            let demuxer = try Demuxer(url: fixture.url())
            #expect(demuxer.videoFormat?.color.transfer == AVCOL_TRC_SMPTE2084)
            #expect(demuxer.info.videoStream?.video?.color.transfer == DynamicRange.pqTransfer)
            #expect(DynamicRange.classify(demuxer.info) == .hdr10)
            demuxer.stop()
        }
    }

    @Test func streamColourReportsMasteringAndLightLevelInNits() throws {
        let demuxer = try Demuxer(url: HDRFixture.pqHEVCMKV.url())
        defer { demuxer.stop() }
        let color = try #require(demuxer.info.videoStream?.video?.color)
        let mastering = try #require(color.mastering)
        #expect(mastering.maxLuminance == 1_000)
        #expect(mastering.primariesName == "P3 D65")
        #expect(color.contentLight == ContentLightLevel(maxCLL: 1_000, maxFALL: 400))
        #expect(color.videoInfoDescription == "BT.2020, PQ, limited range")
    }

    @Test func dolbyVisionEntriesUseTheHEVCCodecTypeAndTheirHvcC() throws {
        for fixture in [HDRFixture.dv5MP4, .dv81MP4, .dv81MKV, .dv84MP4] {
            let demuxer = try Demuxer(url: fixture.url())
            let format = try #require(demuxer.videoFormat)
            demuxer.stop()
            let description = try #require(format.formatDescription)
            #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC, "\(fixture.rawValue)")
            let extensions = try #require(CMFormatDescriptionGetExtensions(description) as? [String: Any])
            let atoms = try #require(extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any])
            let hvcC = try #require(atoms["hvcC"] as? Data)
            #expect(hvcC.first == 1)
            #expect(format.isHardwareDecodeSupported)
        }
    }
}

/// SDR colour follows ColorSync the way QuickTime does: SDR frames keep the colour their stream
/// describes (untagged SD, up to 704 x 576, as SMPTE 170M and anything larger as BT.709, as
/// VideoToolbox guesses for QuickTime), Reel's images are neither forced
/// to sRGB nor adjusted, and the result matches `AVAssetImageGenerator` on the same frame.
@Suite struct ColorPipelineTests {
    @Test func untaggedHDDefaultsToBT709AndUntaggedSDToSMPTE170M() {
        let untagged = VideoColor()
        let hd = untagged.formatExtensions(width: 1920, height: 1080)
        #expect(hd[kCMFormatDescriptionExtension_ColorPrimaries] as? String == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(hd[kCMFormatDescriptionExtension_TransferFunction] as? String == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(hd[kCMFormatDescriptionExtension_YCbCrMatrix] as? String == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        let sd = untagged.formatExtensions(width: 704, height: 480)
        #expect(sd[kCMFormatDescriptionExtension_ColorPrimaries] as? String == kCMFormatDescriptionColorPrimaries_SMPTE_C as String)
        #expect(sd[kCMFormatDescriptionExtension_YCbCrMatrix] as? String == kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String)
        let resolved = untagged.resolvingDefaults(width: 704, height: 480)
        #expect(resolved.primaries == AVCOL_PRI_SMPTE170M && resolved.matrix == AVCOL_SPC_SMPTE170M && resolved.transfer == AVCOL_TRC_SMPTE170M)
        #expect(untagged.resolvingDefaults(width: 1280, height: 720).matrix == AVCOL_SPC_BT709)
    }

    /// The SD boundary is VideoToolbox's, measured on untagged H.264 and HEVC: 720 x 480 and
    /// 720 x 576 (DVD sizes) are BT.709 for QuickTime, so they are for Reel.
    @Test func untaggedSizesFollowVideoToolboxsGuess() {
        for (width, height) in [(176, 144), (320, 240), (640, 480), (704, 480), (704, 576)] {
            #expect(VideoColor.isStandardDefinition(width: width, height: height), "\(width) x \(height)")
        }
        for (width, height) in [(706, 480), (720, 480), (720, 576), (704, 578), (640, 600), (640, 720), (1920, 1080)] {
            #expect(!VideoColor.isStandardDefinition(width: width, height: height), "\(width) x \(height)")
            #expect(VideoColor().resolvingDefaults(width: width, height: height).matrix == AVCOL_SPC_BT709)
        }
    }

    @Test func taggedColourPassesThroughToTheBuffer() throws {
        var color = VideoColor(primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT709, range: AVCOL_RANGE_MPEG)
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &made)
        let buffer = try #require(made)
        color.attach(to: buffer, width: 64, height: 64)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        color.primaries = AVCOL_PRI_SMPTE170M
        color.matrix = AVCOL_SPC_SMPTE170M
        color.attach(to: buffer, width: 64, height: 64)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_SMPTE_C as String)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
    }

    @Test(arguments: [VideoDecoderKind.hardware, .software])
    func sdrImagesKeepTheirStreamColourSpaceAndAreNotAdjusted(_ decoder: VideoDecoderKind) throws {
        let grab = try FrameGrabber.grab(url: HDRFixture.sdrH264.url(), at: .seconds(0.5), decoder: decoder)
        #expect(!grab.frame.pixelBuffer.withUnsafeBuffer { HDRToneMapper.isHDR($0) })
        let image = try FrameGrabber.image(from: grab.frame.pixelBuffer)
        let space = try #require(image.colorSpace)
        // ColorSync converts from the stream's BT.709 description; nothing forces sRGB or device RGB.
        #expect(!CFEqual(space, CGColorSpaceCreateDeviceRGB()))
        #expect(space.name != CGColorSpace.sRGB)
        #expect(space.copyICCData() != nil || space.name != nil)
    }

    /// What the display layer gets for an SDR frame is the decoder's own YCbCr buffer with the
    /// stream's colour, so ColorSync converts it for the display as it does for QuickTime: the
    /// sample buffer wraps that same buffer (no RGB copy, so no saturation or gamma step), its
    /// format description repeats the buffer's colour and adds no gamma of its own, and the layer
    /// it is enqueued on has no filter or compositing filter. (The app's layer range is checked
    /// in `DynamicRangeLayerTests`.)
    @MainActor @Test(arguments: [VideoDecoderKind.hardware, .software])
    func sdrFramesReachTheDisplayLayerWithTheirOwnColour(_ decoder: VideoDecoderKind) async throws {
        let url = try fixtureURL("sdr/bars601_sd_h264.mp4")
        let grab = try FrameGrabber.grab(url: url, at: .seconds(0.5), decoder: decoder)
        let colourKeys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
        try grab.frame.pixelBuffer.withUnsafeBuffer { pixelBuffer in
            let colour = colourKeys.map { CVBufferCopyAttachment(pixelBuffer, $0, nil) as? String }
            #expect(colour == [kCVImageBufferColorPrimaries_SMPTE_C as String, kCVImageBufferTransferFunction_ITU_R_709_2 as String, kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String])
            #expect(CVBufferCopyAttachment(pixelBuffer, kCVImageBufferGammaLevelKey, nil) == nil)
            let format = try VideoOutput.formatDescription(for: pixelBuffer)
            let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any] ?? [:]
            #expect([kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix]
                .map { extensions[$0] as? String } == colour)
            #expect(extensions[kCMFormatDescriptionExtension_GammaLevel] == nil)
            let sample = try VideoOutput.sampleBuffer(pixelBuffer, format: format, time: grab.frame.presentationTime, duration: grab.frame.duration)
            let carried = try #require(CMSampleBufferGetImageBuffer(sample))
            #expect(carried === pixelBuffer, "the decoded buffer itself, not a converted copy")
            let pixelFormat = CVPixelBufferGetPixelFormatType(carried)
            #expect([kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange].contains(pixelFormat))
        }
        let target = HeadlessVideoTarget()
        target.synchronizer.setRate(0, time: grab.frame.presentationTime)
        await target.output.reserveSlot()
        #expect(await target.output.enqueue(grab.frame) == .enqueued)
        #expect(target.layer.filters?.isEmpty ?? true)
        #expect(target.layer.backgroundFilters?.isEmpty ?? true)
        #expect(target.layer.compositingFilter == nil)
        await target.output.flush(removingDisplayedImage: false)
    }

    /// Frame 12 of a bars file, from Reel and from `AVAssetImageGenerator`, matched by frame index.
    private func barsPair(_ name: String, decoder: VideoDecoderKind) async throws -> (reel: SRGBRaster, quickTime: SRGBRaster, grab: FrameGrabber.Grab) {
        let url = try fixtureURL(name)
        let times = try FrameGrabber.videoFrameTimes(url: url, count: 13)
        try #require(times.count == 13)
        let grab = try FrameGrabber.grab(url: url, at: times[12] + .seconds(0.25 / 24), decoder: decoder)
        let reel = try #require(SRGBRaster(try FrameGrabber.image(from: grab.frame.pixelBuffer)))
        let start = try await FrameGrabber.referenceFrameTime(url: url, index: 12)
        let quickTime = try #require(SRGBRaster(try await FrameGrabber.referenceImage(url: url, at: start + .seconds(0.25 / 24))))
        return (reel, quickTime, grab)
    }

    /// The bar centres of the 6 x 4 grid (sdr/bars*.mp4 from scripts/fixtures.sh).
    private func barCentres(_ raster: SRGBRaster) -> [(x: Int, y: Int, row: Int)] {
        (0..<4).flatMap { row in
            (0..<6).map { column in (raster.width * (2 * column + 1) / 12, raster.height * (2 * row + 1) / 8, row) }
        }
    }

    @Test(arguments: [VideoDecoderKind.hardware, .software])
    func taggedAndUntaggedHDBarsMatchAVFoundation(_ decoder: VideoDecoderKind) async throws {
        for name in ["sdr/bars709_h264.mp4", "sdr/bars709_untagged_h264.mp4"] {
            let (reel, quickTime, grab) = try await barsPair(name, decoder: decoder)
            #expect(grab.frame.pixelBuffer.withUnsafeBuffer {
                CVBufferCopyAttachment($0, kCVImageBufferYCbCrMatrixKey, nil) as? String
            } == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            for centre in barCentres(reel) {
                let mine = reel.mean(centerX: centre.x, centerY: centre.y)
                let theirs = quickTime.mean(centerX: centre.x, centerY: centre.y)
                #expect(abs(mine.r - theirs.r) <= 3 && abs(mine.g - theirs.g) <= 3 && abs(mine.b - theirs.b) <= 3,
                        "\(name) (\(centre.x), \(centre.y)): \(mine) against \(theirs)")
            }
        }
    }

    /// Untagged SD (704 x 480) is read as SMPTE 170M (BT.601 matrix, SMPTE C primaries), which is
    /// also what VideoToolbox guesses for AVFoundation, so every bar matches QuickTime.
    @Test(arguments: [VideoDecoderKind.hardware, .software])
    func untaggedSDBarsAreReadAsSMPTE170MAndMatchAVFoundation(_ decoder: VideoDecoderKind) async throws {
        let (reel, quickTime, grab) = try await barsPair("sdr/bars601_sd_h264.mp4", decoder: decoder)
        grab.frame.pixelBuffer.withUnsafeBuffer { buffer in
            #expect(CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            #expect(CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_SMPTE_C as String)
        }
        let centres = barCentres(reel)
        for centre in centres {
            let mine = reel.mean(centerX: centre.x, centerY: centre.y)
            let theirs = quickTime.mean(centerX: centre.x, centerY: centre.y)
            #expect(abs(mine.r - theirs.r) <= 3 && abs(mine.g - theirs.g) <= 3 && abs(mine.b - theirs.b) <= 3,
                    "(\(centre.x), \(centre.y)): \(mine) against \(theirs)")
        }
        // The 75% yellow bar keeps its green at the level of its red with the BT.601 matrix; read
        // with BT.709 green falls about 13 codes below red.
        let yellow = reel.mean(centerX: centres[1].x, centerY: centres[1].y)
        #expect(abs(yellow.r - yellow.g) <= 3, "\(yellow)")
    }

    /// AVFoundation fails every frame of a track whose sample description carries a Dolby Vision
    /// record (the fixtures have no RPU); the reference path refuses it instead of comparing
    /// against nothing.
    @Test func aDolbyVisionTrackHasNoAVFoundationReference() async throws {
        let url = try HDRFixture.dv81MP4.url()
        await #expect(throws: FrameGrabber.ReferenceError.self) {
            _ = try await FrameGrabber.referenceImage(url: url, at: .seconds(0.5))
        }
        // Reel's own path decodes the HEVC base from hvcC alone.
        let grab = try FrameGrabber.grab(url: url, at: .seconds(0.5), decoder: .hardware)
        #expect(grab.frame.decoder == .hardware)
    }

    @Test(arguments: [VideoDecoderKind.hardware, .software])
    func reelMatchesAVFoundationOnTheSameFrame(_ decoder: VideoDecoderKind) async throws {
        for url in [try HDRFixture.sdrH264.url(), try Fixture.h264.url()] {
            let time = MediaTime.seconds(12.5 / 24)
            let grab = try FrameGrabber.grab(url: url, at: time, decoder: decoder)
            let reel = try #require(SRGBRaster(try FrameGrabber.image(from: grab.frame.pixelBuffer)))
            let quickTime = try #require(SRGBRaster(try await FrameGrabber.referenceImage(url: url, at: time)))
            #expect(reel.width == quickTime.width && reel.height == quickTime.height)
            // 32 x 32 means on a 6 x 4 grid: the noise in h264_1080p30.mp4 averages out the same
            // way in both images, since both are the same decoded frame.
            for row in 0..<4 {
                for column in 0..<6 {
                    let x = reel.width * (2 * column + 1) / 12
                    let y = reel.height * (2 * row + 1) / 8
                    let mine = reel.mean(centerX: x, centerY: y, size: 32)
                    let theirs = quickTime.mean(centerX: x, centerY: y, size: 32)
                    #expect(abs(mine.r - theirs.r) <= 3 && abs(mine.g - theirs.g) <= 3 && abs(mine.b - theirs.b) <= 3,
                            "\(url.lastPathComponent) (\(x), \(y)): \(mine) against \(theirs)")
                }
            }
        }
    }
}
