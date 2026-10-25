import CoreMedia
import CReelDeps
import Foundation
import ReelCore
import Testing
@testable import ReelEngine

@Suite struct FormatDescriptionTests {
    private static func atoms(_ description: CMFormatDescription) -> [String: Data] {
        guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
              let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] else { return [:] }
        return atoms.compactMapValues { $0 as? Data }
    }

    private static func extensionValue(_ description: CMFormatDescription, _ key: CFString) -> Any? {
        (CMFormatDescriptionGetExtensions(description) as? [String: Any])?[key as String]
    }

    @Test(arguments: Fixture.hardwareFixtures)
    func everyVideoToolboxCodecGetsAFormatDescription(_ fixture: Fixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        let format = try #require(demuxer.videoFormat)
        #expect(format.codec == fixture.codec)
        #expect(format.codecName == fixture.videoCodec)
        let description = try #require(format.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(description) == fixture.codec.cmCodecType)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        #expect(Int(dimensions.width) == fixture.size.width && Int(dimensions.height) == fixture.size.height)
        let atomName: String = switch fixture.codec {
        case .h264: "avcC"
        case .hevc: "hvcC"
        case .av1: "av1C"
        case .vp9: "vpcC"
        case .other: "none"
        }
        let atom = try #require(Self.atoms(description)[atomName], "\(atomName) atom")
        #expect(!atom.isEmpty)
        // Every description carries the colour keys, filled from the stream, a probed frame or the size rule.
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix] {
            #expect(Self.extensionValue(description, key) != nil, "\(key)")
        }
        #expect(format.isHardwareDecodeSupported, "VideoToolbox decodes \(fixture.videoCodec) on this Mac")
    }

    @Test(arguments: Fixture.softwareOnlyFixtures)
    func oldCodecsHaveNoVideoToolboxDescription(_ fixture: Fixture) throws {
        let demuxer = try Demuxer(url: fixture.url())
        let format = try #require(demuxer.videoFormat)
        #expect(format.codec == .other)
        #expect(format.codecName == fixture.videoCodec)
        #expect(format.formatDescription == nil)
        #expect(!format.isHardwareDecodeSupported)
        #expect(format.width == fixture.size.width && format.height == fixture.size.height)
    }

    @Test func avcCFromTheMP4IsPassedThroughUnchanged() throws {
        let url = try Fixture.h264.url()
        let source = try MediaSource(url: url)
        let stream = try #require(source.videoStreamIndex.flatMap(source.stream))
        let par = stream.pointee.codecpar.pointee
        let extradata = Data(bytes: par.extradata, count: Int(par.extradata_size))
        let format = try FormatDescriptionBuilder.make(stream: stream)
        let description = try #require(format.formatDescription)
        #expect(Self.atoms(description)["avcC"] == extradata)
        #expect(!format.convertsAnnexB)
        #expect(format.nalLengthSize == 4)
    }

    @Test func annexBParameterSetsBecomeAnAvcCRecord() throws {
        let demuxer = try Demuxer(url: Fixture.annexB.url())
        let format = try #require(demuxer.videoFormat)
        let description = try #require(format.formatDescription)
        let avcC = try #require(Self.atoms(description)["avcC"])
        #expect(avcC.first == 1, "configurationVersion")
        #expect(NALUnits.nalLengthSize(configurationRecord: avcC, codec: .h264) == 4)
        #expect(format.convertsAnnexB)
    }

    @Test func hevcRecordReportsOneTemporalLayer() throws {
        let demuxer = try Demuxer(url: Fixture.hevc10.url())
        let format = try #require(demuxer.videoFormat)
        #expect(format.hevcTemporalLayers == 1)
        #expect(format.bitDepth == 10)
        #expect(format.nalLengthSize == 4)
    }

    @Test func vp9ConfigurationIsBuiltFromCodecParameters() throws {
        let demuxer = try Demuxer(url: Fixture.vp9.url())
        let format = try #require(demuxer.videoFormat)
        let description = try #require(format.formatDescription)
        let vpcC = [UInt8](try #require(Self.atoms(description)["vpcC"]))
        #expect(vpcC.count == 12)
        #expect(vpcC[0] == 1, "version 1")
        #expect(vpcC[4] == 0, "profile 0")
        #expect(vpcC[6] >> 4 == 8, "bit depth")
        #expect((vpcC[6] >> 1) & 0x07 <= 1, "4:2:0 chroma")
        #expect(vpcC[6] & 1 == 0, "limited range")
    }

    @Test func hdr10CarriesPQBT2020AndStaticMetadataInGBROrder() throws {
        let demuxer = try Demuxer(url: Fixture.hdr10.url())
        let format = try #require(demuxer.videoFormat)
        let description = try #require(format.formatDescription)
        #expect(Self.extensionValue(description, kCMFormatDescriptionExtension_TransferFunction) as? String
            == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(Self.extensionValue(description, kCMFormatDescriptionExtension_ColorPrimaries) as? String
            == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        #expect(Self.extensionValue(description, kCMFormatDescriptionExtension_YCbCrMatrix) as? String
            == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String)
        // x265 master-display G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1).
        let mastering = try #require(Self.extensionValue(description, kCMFormatDescriptionExtension_MasteringDisplayColorVolume) as? Data)
        let expected: [UInt8] = [
            0x33, 0xc2, 0x86, 0xc4, // G
            0x1d, 0x4c, 0x0b, 0xb8, // B
            0x84, 0xd0, 0x3e, 0x80, // R
            0x3d, 0x13, 0x40, 0x42, // white point
            0x00, 0x98, 0x96, 0x80, // max 1000 cd/m2
            0x00, 0x00, 0x00, 0x01, // min 0.0001 cd/m2
        ]
        #expect([UInt8](mastering) == expected)
        let light = try #require(Self.extensionValue(description, kCMFormatDescriptionExtension_ContentLightLevelInfo) as? Data)
        #expect([UInt8](light) == [0x03, 0xe8, 0x01, 0x90], "MaxCLL 1000, MaxFALL 400")
        let info = format.color.info
        #expect(info.transfer == "smpte2084" && info.primaries == "bt2020" && info.hasHDRMetadata)
    }

    @Test func unspecifiedColourFallsBackToBT709ForHD() throws {
        // The AV1 and H.264 fixtures carry no colour tags in the stream or the first frame.
        for fixture in [Fixture.av1, .h264] {
            let format = try #require(try Demuxer(url: fixture.url()).videoFormat)
            let description = try #require(format.formatDescription)
            #expect(Self.extensionValue(description, kCMFormatDescriptionExtension_YCbCrMatrix) as? String
                == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String, "\(fixture)")
            #expect(Self.extensionValue(description, kCMFormatDescriptionExtension_FullRangeVideo) as? Bool == false)
        }
    }

    @Test func standardDefinitionFallsBackToBT601() {
        let color = VideoColor()
        let extensions = color.formatExtensions(width: 640, height: 480)
        #expect(extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String == kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String)
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String == kCMFormatDescriptionColorPrimaries_SMPTE_C as String)
    }

    @Test func probeFillsOnlyMissingFields() {
        let stream = VideoColor(primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_SMPTE2084, matrix: AVCOL_SPC_UNSPECIFIED, range: AVCOL_RANGE_MPEG)
        let frame = VideoColor(primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG, masteringDisplay: Data([1]))
        let merged = stream.filling(from: frame)
        #expect(merged.primaries == AVCOL_PRI_BT2020)
        #expect(merged.transfer == AVCOL_TRC_SMPTE2084)
        #expect(merged.matrix == AVCOL_SPC_BT2020_NCL)
        #expect(merged.masteringDisplay == Data([1]))
        #expect(stream.needsFrameProbe)
    }

    @Test func rotationComesFromTheDisplayMatrix() throws {
        let demuxer = try Demuxer(url: Fixture.rot90.url())
        let format = try #require(demuxer.videoFormat)
        // The fixture's matrix turns the picture 90 degrees counterclockwise, which is 270 clockwise.
        #expect(format.rotation == 270)
        let size = format.parameters.displaySize
        #expect(size.width == 720 && size.height == 1280)
        #expect(demuxer.info.videoStream?.video?.rotation == 270)
        let plain = try #require(try Demuxer(url: Fixture.h264.url()).videoFormat)
        #expect(plain.rotation == 0)
    }

    @Test func squarePixelsAddNoAspectExtension() throws {
        let format = try #require(try Demuxer(url: Fixture.h264.url()).videoFormat)
        let description = try #require(format.formatDescription)
        #expect(Self.extensionValue(description, kCMFormatDescriptionExtension_PixelAspectRatio) == nil)
        #expect(format.pixelAspect == Rational(1, 1))
    }
}
