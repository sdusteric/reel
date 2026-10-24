import Foundation
import Testing
@testable import ReelEngine

@Suite struct NALUnitsTests {
    // H.264 headers: forbidden(1) nal_ref_idc(2) type(5).
    private static let h264SPS: [UInt8] = [0x67, 0x64, 0x00, 0x1f]
    private static let h264PPS: [UInt8] = [0x68, 0xee, 0x3c, 0x80]
    private static let h264IDR: [UInt8] = [0x65, 0x88, 0x84]
    private static let h264RefSlice: [UInt8] = [0x41, 0x9a, 0x00]      // ref_idc 2, type 1
    private static let h264NonRefSlice: [UInt8] = [0x01, 0x9e, 0x00]   // ref_idc 0, type 1
    private static let h264AUD: [UInt8] = [0x09, 0xf0]

    /// HEVC two-byte header with `type` and temporal id 0.
    private static func hevcHeader(_ type: Int) -> [UInt8] { [UInt8(type << 1), 0x01] }

    private static func lengthPrefixed(_ units: [[UInt8]], lengthSize: Int = 4) -> Data {
        var data = Data()
        for unit in units {
            for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: unit.count >> shift))
            }
            data.append(contentsOf: unit)
        }
        return data
    }

    @Test func splitsAnnexBWithThreeAndFourByteStartCodesAndTrailingZeros() {
        var stream: [UInt8] = [0, 0, 0, 1] + Self.h264SPS
        stream += [0, 0, 1] + Self.h264PPS + [0, 0] // trailing_zero_8bits
        stream += [0, 0, 0, 1] + Self.h264IDR
        let units = NALUnits.splitAnnexB(Data(stream))
        #expect(units.map { [UInt8]($0) } == [Self.h264SPS, Self.h264PPS, Self.h264IDR])
        #expect(NALUnits.looksLikeAnnexB(Data(stream)))
        #expect(!NALUnits.looksLikeAnnexB(Self.lengthPrefixed([Self.h264IDR])))
    }

    @Test func convertsStartCodesToFourByteLengthsAndDropsDelimiters() {
        let stream: [UInt8] = [0, 0, 0, 1] + Self.h264AUD + [0, 0, 0, 1] + Self.h264SPS + [0, 0, 1] + Self.h264IDR
        let converted = NALUnits.annexBToLengthPrefixed(Data(stream), codec: .h264)
        #expect(converted == Self.lengthPrefixed([Self.h264SPS, Self.h264IDR]))
        let ranges = converted.withUnsafeBytes { NALUnits.splitLengthPrefixed($0, lengthSize: 4) }
        #expect(ranges.count == 2)
    }

    @Test func dropsHEVCAccessUnitDelimiters() {
        let aud = Self.hevcHeader(35) + [0x50]
        let slice = Self.hevcHeader(1) + [0xaa, 0xbb]
        let stream: [UInt8] = [0, 0, 0, 1] + aud + [0, 0, 1] + slice
        #expect(NALUnits.annexBToLengthPrefixed(Data(stream), codec: .hevc) == Self.lengthPrefixed([slice]))
    }

    @Test func findsParameterSetsInOrder() throws {
        let stream: [UInt8] = [0, 0, 0, 1] + Self.h264PPS + [0, 0, 0, 1] + Self.h264SPS + [0, 0, 1] + Self.h264IDR
        let sets = try #require(NALUnits.parameterSets(inAnnexB: Data(stream), codec: .h264))
        #expect(sets.map { [UInt8]($0) } == [Self.h264SPS, Self.h264PPS])
        #expect(NALUnits.parameterSets(inAnnexB: Data([0, 0, 1] + Self.h264IDR), codec: .h264) == nil)
    }

    @Test func h264NonReferenceSlicesAreDisposable() {
        let nonRef = NALUnits.pictureFlags(Self.lengthPrefixed([Self.h264NonRefSlice]), lengthSize: 4, codec: .h264, hevcTemporalLayers: 0)
        #expect(nonRef.isDisposable && nonRef.hasPicture)
        let ref = NALUnits.pictureFlags(Self.lengthPrefixed([Self.h264RefSlice]), lengthSize: 4, codec: .h264, hevcTemporalLayers: 0)
        #expect(!ref.isDisposable)
        let idr = NALUnits.pictureFlags(Self.lengthPrefixed([Self.h264SPS, Self.h264PPS, Self.h264IDR]), lengthSize: 4, codec: .h264, hevcTemporalLayers: 0)
        #expect(idr.isIDR && !idr.isDisposable)
        // SEI and parameter sets alone are not a picture, so never "disposable".
        let seiOnly = NALUnits.pictureFlags(Self.lengthPrefixed([[0x06, 0x05]]), lengthSize: 4, codec: .h264, hevcTemporalLayers: 0)
        #expect(!seiOnly.hasPicture && !seiOnly.isDisposable)
    }

    @Test func mixedReferenceAndNonReferenceSlicesAreKept() {
        let flags = NALUnits.pictureFlags(Self.lengthPrefixed([Self.h264NonRefSlice, Self.h264RefSlice]), lengthSize: 4, codec: .h264, hevcTemporalLayers: 0)
        #expect(!flags.isDisposable)
    }

    @Test func hevcSubLayerNonReferenceTypesAreTheEvenOnesUpToFourteen() {
        #expect((0...31).filter(NALUnits.isHEVCSubLayerNonReference) == [0, 2, 4, 6, 8, 10, 12, 14])
        for type in [0, 2, 4, 6, 8, 10, 12, 14] {
            let flags = NALUnits.pictureFlags(Self.lengthPrefixed([Self.hevcHeader(type) + [0x80]]), lengthSize: 4, codec: .hevc, hevcTemporalLayers: 1)
            #expect(flags.isDisposable, "type \(type)")
        }
        for type in [1, 3, 5, 7, 9, 19, 21] {
            let flags = NALUnits.pictureFlags(Self.lengthPrefixed([Self.hevcHeader(type) + [0x80]]), lengthSize: 4, codec: .hevc, hevcTemporalLayers: 1)
            #expect(!flags.isDisposable, "type \(type)")
        }
    }

    @Test func hevcSkippingNeedsExactlyOneTemporalLayer() {
        let trailN = Self.lengthPrefixed([Self.hevcHeader(0) + [0x80]])
        #expect(NALUnits.pictureFlags(trailN, lengthSize: 4, codec: .hevc, hevcTemporalLayers: 1).isDisposable)
        #expect(!NALUnits.pictureFlags(trailN, lengthSize: 4, codec: .hevc, hevcTemporalLayers: 2).isDisposable)
        #expect(!NALUnits.pictureFlags(trailN, lengthSize: 4, codec: .hevc, hevcTemporalLayers: 0).isDisposable)
    }

    @Test func hevcRASLAndRandomAccessKinds() {
        for type in [8, 9] {
            let flags = NALUnits.pictureFlags(Self.lengthPrefixed([Self.hevcHeader(type)]), lengthSize: 4, codec: .hevc, hevcTemporalLayers: 1)
            #expect(flags.isRASL)
        }
        #expect(!NALUnits.pictureFlags(Self.lengthPrefixed([Self.hevcHeader(7)]), lengthSize: 4, codec: .hevc, hevcTemporalLayers: 1).isRASL)
        let cra = NALUnits.pictureFlags(Self.lengthPrefixed([Self.hevcHeader(32), Self.hevcHeader(21)]), lengthSize: 4, codec: .hevc, hevcTemporalLayers: 1)
        #expect(cra.isCRA && NALUnits.keyframeKind(cra) == .cra)
        let idr = NALUnits.pictureFlags(Self.lengthPrefixed([Self.hevcHeader(19)]), lengthSize: 4, codec: .hevc, hevcTemporalLayers: 1)
        #expect(NALUnits.keyframeKind(idr) == .idr)
    }

    @Test func readsLengthSizeAndTemporalLayersFromConfigurationRecords() {
        var hvcC = [UInt8](repeating: 0, count: 23)
        hvcC[0] = 1
        hvcC[21] = (1 << 3) | 0x03 // numTemporalLayers 1, lengthSizeMinusOne 3
        #expect(NALUnits.hevcTemporalLayerCount(hvcC: Data(hvcC)) == 1)
        #expect(NALUnits.nalLengthSize(configurationRecord: Data(hvcC), codec: .hevc) == 4)
        let avcC: [UInt8] = [1, 0x64, 0, 0x1f, 0xfd, 0xe1]
        #expect(NALUnits.nalLengthSize(configurationRecord: Data(avcC), codec: .h264) == 2)
        #expect(NALUnits.nalLengthSize(configurationRecord: Data([0, 0, 0, 1]), codec: .h264) == nil)
    }

    @Test func lengthPrefixedSplitStopsAtTruncatedUnit() {
        var data = Self.lengthPrefixed([Self.h264IDR])
        data.append(contentsOf: [0, 0, 0, 50, 1, 2])
        let ranges = data.withUnsafeBytes { NALUnits.splitLengthPrefixed($0, lengthSize: 4) }
        #expect(ranges == [4..<7])
    }

    @Test func realH264StreamHasDisposableFramesAndTheFirstPacketIsAnIDR() throws {
        let demuxer = try Demuxer(url: Fixture.h264.url())
        let format = try #require(demuxer.videoFormat)
        let source = try MediaSource(url: Fixture.h264.url())
        var disposable = 0
        var pictures = 0
        var firstKind: NALUnits.PictureFlags?
        while pictures < 120, let packet = try source.readPacket() {
            guard packet.streamIndex == source.videoStreamIndex else { continue }
            let flags = format.pictureFlags(format.prepare(packet))
            if firstKind == nil { firstKind = flags }
            if flags.hasPicture { pictures += 1 }
            if flags.isDisposable { disposable += 1 }
        }
        #expect(firstKind?.isIDR == true)
        #expect(pictures == 120)
        #expect(disposable > 0, "x264 with B-frames has non-reference B pictures")
        #expect(disposable < pictures)
    }

    @Test func annexBTransportStreamPacketsAreConvertedForVideoToolbox() throws {
        let demuxer = try Demuxer(url: Fixture.annexB.url())
        let format = try #require(demuxer.videoFormat)
        #expect(format.convertsAnnexB)
        #expect(format.nalLengthSize == 4)
        let source = try MediaSource(url: Fixture.annexB.url())
        var checked = 0
        while checked < 10, let packet = try source.readPacket() {
            guard packet.streamIndex == source.videoStreamIndex else { continue }
            #expect(NALUnits.looksLikeAnnexB(packet.bytes))
            let prepared = format.prepare(packet)
            #expect(!NALUnits.looksLikeAnnexB(prepared.bytes))
            let units = NALUnits.splitLengthPrefixed(prepared.bytes, lengthSize: 4)
            #expect(!units.isEmpty)
            #expect(units.last?.upperBound == prepared.size, "length prefixes cover the whole packet")
            #expect(prepared.pts == packet.pts && prepared.isKeyframe == packet.isKeyframe)
            checked += 1
        }
        #expect(checked == 10)
    }
}
