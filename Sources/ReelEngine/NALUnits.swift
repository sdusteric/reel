import Foundation
import ReelCore

/// H.264 and HEVC NAL unit parsing: Annex B conversion, parameter sets and the reference checks
/// the exact seek uses to skip frames nothing depends on (design section 7.5, step 4).
public enum NALUnits {
    public enum Codec: Sendable, Hashable {
        case h264
        case hevc
    }

    /// The NAL unit type from the first header byte.
    public static func type(of header: UInt8, codec: Codec) -> Int {
        switch codec {
        case .h264: Int(header & 0x1f)
        case .hevc: Int((header >> 1) & 0x3f)
        }
    }

    // MARK: Annex B

    /// Splits an Annex B byte stream into NAL unit payloads (start codes and trailing zero bytes removed).
    public static func splitAnnexB(_ bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        var payloadStarts: [Int] = []
        var startCodeStarts: [Int] = []
        let count = bytes.count
        var index = 0
        while index + 3 <= count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                startCodeStarts.append(index)
                payloadStarts.append(index + 3)
                index += 3
            } else {
                index += 1
            }
        }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(payloadStarts.count)
        for (position, start) in payloadStarts.enumerated() {
            var end = position + 1 < payloadStarts.count ? startCodeStarts[position + 1] : count
            // Drops trailing_zero_8bits and the leading zero of a 4-byte start code.
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            if end > start { ranges.append(start..<end) }
        }
        return ranges
    }

    public static func splitAnnexB(_ data: Data) -> [Data] {
        data.withUnsafeBytes { raw in splitAnnexB(raw).map { Data(raw[$0]) } }
    }

    /// True when the buffer starts with a 3 or 4-byte start code.
    public static func looksLikeAnnexB(_ bytes: UnsafeRawBufferPointer) -> Bool {
        if bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1 { return true }
        return bytes.count >= 3 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1
    }

    public static func looksLikeAnnexB(_ data: Data) -> Bool {
        data.withUnsafeBytes { looksLikeAnnexB($0) }
    }

    /// Rewrites start codes as 4-byte big-endian lengths. Access unit delimiters are dropped, since
    /// VideoToolbox does not need them, and parameter sets stay in band.
    public static func annexBToLengthPrefixed(_ bytes: UnsafeRawBufferPointer, codec: Codec) -> [UInt8] {
        let units = splitAnnexB(bytes)
        let delimiter = codec == .h264 ? 9 : 35
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 4 * units.count)
        for unit in units {
            if type(of: bytes[unit.lowerBound], codec: codec) == delimiter { continue }
            let length = UInt32(unit.count)
            output.append(UInt8(truncatingIfNeeded: length >> 24))
            output.append(UInt8(truncatingIfNeeded: length >> 16))
            output.append(UInt8(truncatingIfNeeded: length >> 8))
            output.append(UInt8(truncatingIfNeeded: length))
            output.append(contentsOf: bytes[unit])
        }
        return output
    }

    public static func annexBToLengthPrefixed(_ data: Data, codec: Codec) -> Data {
        data.withUnsafeBytes { Data(annexBToLengthPrefixed($0, codec: codec)) }
    }

    /// Splits length-prefixed NAL units. Stops at the first length that runs past the buffer.
    public static func splitLengthPrefixed(_ bytes: UnsafeRawBufferPointer, lengthSize: Int) -> [Range<Int>] {
        guard (1...4).contains(lengthSize) else { return [] }
        var ranges: [Range<Int>] = []
        var offset = 0
        while offset + lengthSize <= bytes.count {
            var length = 0
            for byte in 0..<lengthSize { length = (length << 8) | Int(bytes[offset + byte]) }
            offset += lengthSize
            guard length > 0, offset + length <= bytes.count else { break }
            ranges.append(offset..<(offset + length))
            offset += length
        }
        return ranges
    }

    /// The parameter sets needed for a format description, in the order Core Media wants them
    /// (H.264: SPS, PPS; HEVC: VPS, SPS, PPS). Nil when one is missing.
    public static func parameterSets(inAnnexB data: Data, codec: Codec) -> [Data]? {
        let wanted: [Int] = codec == .h264 ? [7, 8] : [32, 33, 34]
        let units = splitAnnexB(data)
        var sets: [Data] = []
        for kind in wanted {
            guard let unit = units.first(where: { !$0.isEmpty && type(of: $0[$0.startIndex], codec: codec) == kind }) else {
                return nil
            }
            sets.append(unit)
        }
        return sets
    }

    // MARK: Decoder configuration records

    /// NAL length size from an avcC or hvcC record.
    public static func nalLengthSize(configurationRecord data: Data, codec: Codec) -> Int? {
        let bytes = [UInt8](data)
        switch codec {
        case .h264:
            guard bytes.count >= 5, bytes[0] == 1 else { return nil }
            return Int(bytes[4] & 0x03) + 1
        case .hevc:
            guard bytes.count >= 23, bytes[0] == 1 else { return nil }
            return Int(bytes[21] & 0x03) + 1
        }
    }

    /// `numTemporalLayers` from an hvcC record (0 means unknown).
    public static func hevcTemporalLayerCount(hvcC data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 23, bytes[0] == 1 else { return nil }
        return Int((bytes[21] >> 3) & 0x07)
    }

    // MARK: Reference checks

    /// What a packet's VCL NAL units say about it.
    public struct PictureFlags: Sendable, Hashable {
        /// No later picture references this one (H.264 nal_ref_idc 0, HEVC sub-layer non-reference
        /// with a single temporal sub-layer).
        public var isDisposable: Bool
        /// HEVC RASL picture: references pictures before the CRA it follows.
        public var isRASL: Bool
        /// H.264 IDR or HEVC IDR/BLA.
        public var isIDR: Bool
        /// HEVC CRA.
        public var isCRA: Bool
        /// The packet had at least one VCL NAL unit.
        public var hasPicture: Bool

        public init(isDisposable: Bool = false, isRASL: Bool = false, isIDR: Bool = false, isCRA: Bool = false, hasPicture: Bool = false) {
            self.isDisposable = isDisposable
            self.isRASL = isRASL
            self.isIDR = isIDR
            self.isCRA = isCRA
            self.hasPicture = hasPicture
        }
    }

    /// HEVC VCL types 0, 2, 4, ..., 14 are sub-layer non-reference pictures.
    public static func isHEVCSubLayerNonReference(_ nalType: Int) -> Bool {
        nalType <= 14 && nalType % 2 == 0
    }

    public static func isHEVCRASL(_ nalType: Int) -> Bool { nalType == 8 || nalType == 9 }

    /// Inspects the VCL NAL units of one length-prefixed packet.
    /// - Parameter hevcTemporalLayers: hvcC `numTemporalLayers`; HEVC non-reference skipping is
    ///   only safe when it is exactly 1.
    public static func pictureFlags(
        _ bytes: UnsafeRawBufferPointer,
        lengthSize: Int,
        codec: Codec,
        hevcTemporalLayers: Int
    ) -> PictureFlags {
        var flags = PictureFlags()
        var allDisposable = true
        for unit in splitLengthPrefixed(bytes, lengthSize: lengthSize) {
            let header = bytes[unit.lowerBound]
            let nalType = type(of: header, codec: codec)
            switch codec {
            case .h264:
                guard (1...5).contains(nalType) else { continue }
                flags.hasPicture = true
                if nalType == 5 { flags.isIDR = true }
                let refIdc = (header >> 5) & 0x03
                if refIdc != 0 { allDisposable = false }
            case .hevc:
                guard nalType < 32 else { continue }
                flags.hasPicture = true
                if (16...20).contains(nalType) { flags.isIDR = true }
                if nalType == 21 { flags.isCRA = true }
                if isHEVCRASL(nalType) { flags.isRASL = true }
                if !(hevcTemporalLayers == 1 && isHEVCSubLayerNonReference(nalType)) { allDisposable = false }
            }
        }
        flags.isDisposable = flags.hasPicture && allDisposable
        return flags
    }

    public static func pictureFlags(_ data: Data, lengthSize: Int, codec: Codec, hevcTemporalLayers: Int) -> PictureFlags {
        data.withUnsafeBytes { pictureFlags($0, lengthSize: lengthSize, codec: codec, hevcTemporalLayers: hevcTemporalLayers) }
    }

    /// The keyframe kind for the index, from the NAL types of a key packet.
    public static func keyframeKind(_ flags: PictureFlags) -> KeyframeIndex.Kind {
        if flags.isIDR { return .idr }
        if flags.isCRA { return .cra }
        return .other
    }
}
