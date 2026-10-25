import CoreMedia
import CoreVideo
import CReelDeps
import Foundation
import ReelCore

/// Colour description of a video stream in FFmpeg terms, plus HDR static metadata already encoded
/// the way Core Media wants it. Built from codecpar, or from a decoded frame when codecpar says
/// "unspecified" (design section 7.3).
public struct VideoColor: Sendable, Hashable {
    public var primaries: AVColorPrimaries
    public var transfer: AVColorTransferCharacteristic
    public var matrix: AVColorSpace
    public var range: AVColorRange
    /// `MasteringDisplayColorVolume`: 24 bytes, primaries in G, B, R order, big-endian.
    public var masteringDisplay: Data?
    /// `ContentLightLevelInfo`: MaxCLL and MaxFALL, 2 bytes each, big-endian.
    public var contentLightLevel: Data?

    public init(
        primaries: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED,
        transfer: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED,
        matrix: AVColorSpace = AVCOL_SPC_UNSPECIFIED,
        range: AVColorRange = AVCOL_RANGE_UNSPECIFIED,
        masteringDisplay: Data? = nil,
        contentLightLevel: Data? = nil
    ) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
    }

    public init(codecParameters parameters: UnsafePointer<AVCodecParameters>) {
        let par = parameters.pointee
        self.init(primaries: par.color_primaries, transfer: par.color_trc, matrix: par.color_space, range: par.color_range)
        let count = par.nb_coded_side_data
        if let mastering = av_packet_side_data_get(par.coded_side_data, count, AV_PKT_DATA_MASTERING_DISPLAY_METADATA),
           mastering.pointee.size >= MemoryLayout<AVMasteringDisplayMetadata>.size {
            let metadata = UnsafeRawPointer(mastering.pointee.data).load(as: AVMasteringDisplayMetadata.self)
            masteringDisplay = VideoColor.masteringDisplayData(metadata)
        }
        if let light = av_packet_side_data_get(par.coded_side_data, count, AV_PKT_DATA_CONTENT_LIGHT_LEVEL),
           light.pointee.size >= MemoryLayout<AVContentLightMetadata>.size {
            let metadata = UnsafeRawPointer(light.pointee.data).load(as: AVContentLightMetadata.self)
            contentLightLevel = VideoColor.contentLightLevelData(metadata)
        }
    }

    public init(frame: UnsafePointer<AVFrame>) {
        let value = frame.pointee
        self.init(primaries: value.color_primaries, transfer: value.color_trc, matrix: value.colorspace, range: value.color_range)
        if let side = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA),
           side.pointee.size >= MemoryLayout<AVMasteringDisplayMetadata>.size {
            let metadata = UnsafeRawPointer(side.pointee.data).load(as: AVMasteringDisplayMetadata.self)
            masteringDisplay = VideoColor.masteringDisplayData(metadata)
        }
        if let side = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL),
           side.pointee.size >= MemoryLayout<AVContentLightMetadata>.size {
            let metadata = UnsafeRawPointer(side.pointee.data).load(as: AVContentLightMetadata.self)
            contentLightLevel = VideoColor.contentLightLevelData(metadata)
        }
    }

    /// True when primaries, transfer and matrix are all specified.
    public var isComplete: Bool {
        primaries != AVCOL_PRI_UNSPECIFIED && transfer != AVCOL_TRC_UNSPECIFIED && matrix != AVCOL_SPC_UNSPECIFIED
    }

    /// Fills unspecified fields from `other` (a probed frame), keeping what is already known.
    public func filling(from other: VideoColor) -> VideoColor {
        var merged = self
        if merged.primaries == AVCOL_PRI_UNSPECIFIED { merged.primaries = other.primaries }
        if merged.transfer == AVCOL_TRC_UNSPECIFIED { merged.transfer = other.transfer }
        if merged.matrix == AVCOL_SPC_UNSPECIFIED { merged.matrix = other.matrix }
        if merged.range == AVCOL_RANGE_UNSPECIFIED { merged.range = other.range }
        if merged.masteringDisplay == nil { merged.masteringDisplay = other.masteringDisplay }
        if merged.contentLightLevel == nil { merged.contentLightLevel = other.contentLightLevel }
        return merged
    }

    public var isFullRange: Bool { range == AVCOL_RANGE_JPEG }

    /// PQ or HLG transfer.
    public var isHDR: Bool { transfer == AVCOL_TRC_SMPTE2084 || transfer == AVCOL_TRC_ARIB_STD_B67 }

    /// Colour is partly unspecified, or the stream is HDR without container-level static metadata
    /// (HEVC carries it in SEI), so the first decoded frame should be read.
    public var needsFrameProbe: Bool {
        !isComplete || (isHDR && masteringDisplay == nil && contentLightLevel == nil)
    }

    // MARK: Core Media values

    public var primariesValue: CFString? {
        switch primaries {
        case AVCOL_PRI_BT709: kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020: kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: kCMFormatDescriptionColorPrimaries_P3_D65
        case AVCOL_PRI_SMPTE431: kCMFormatDescriptionColorPrimaries_DCI_P3
        case AVCOL_PRI_BT470BG: kCMFormatDescriptionColorPrimaries_EBU_3213
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: kCMFormatDescriptionColorPrimaries_SMPTE_C
        default: nil
        }
    }

    public var transferValue: CFString? {
        switch transfer {
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12:
            kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_LINEAR: kCMFormatDescriptionTransferFunction_Linear
        case AVCOL_TRC_IEC61966_2_1: kCMFormatDescriptionTransferFunction_sRGB
        case AVCOL_TRC_GAMMA22: kCMFormatDescriptionTransferFunction_UseGamma
        case AVCOL_TRC_SMPTE240M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995
        default: nil
        }
    }

    public var matrixValue: CFString? {
        switch matrix {
        case AVCOL_SPC_BT709: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_BT2020_NCL: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_SMPTE240M: kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995
        default: nil
        }
    }

    /// Format description extensions for the colour, with the size-based fallback when a field is
    /// still unknown (`isStandardDefinition`): SMPTE-C/601 for SD, BT.709 otherwise.
    public func formatExtensions(width: Int, height: Int) -> [CFString: Any] {
        let hd = !VideoColor.isStandardDefinition(width: width, height: height)
        let resolved = resolvingDefaults(width: width, height: height)
        // A specified value Core Media has no name for falls back the same way.
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: resolved.primariesValue
                ?? (hd ? kCMFormatDescriptionColorPrimaries_ITU_R_709_2 : kCMFormatDescriptionColorPrimaries_SMPTE_C),
            kCMFormatDescriptionExtension_TransferFunction: resolved.transferValue ?? kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: resolved.matrixValue
                ?? (hd ? kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 : kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4),
            kCMFormatDescriptionExtension_FullRangeVideo: isFullRange,
        ]
        if transfer == AVCOL_TRC_GAMMA22 { extensions[kCMFormatDescriptionExtension_GammaLevel] = 2.2 }
        if let masteringDisplay { extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = masteringDisplay }
        if let contentLightLevel { extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = contentLightLevel }
        return extensions
    }

    /// Sets the colour attachments on a decoded buffer so they propagate into sample buffers.
    public func attach(to buffer: CVBuffer, width: Int, height: Int) {
        let extensions = formatExtensions(width: width, height: height)
        let keys: [(CFString, CFString)] = [
            (kCMFormatDescriptionExtension_ColorPrimaries, kCVImageBufferColorPrimariesKey),
            (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunctionKey),
            (kCMFormatDescriptionExtension_YCbCrMatrix, kCVImageBufferYCbCrMatrixKey),
            (kCMFormatDescriptionExtension_GammaLevel, kCVImageBufferGammaLevelKey),
        ]
        for (extensionKey, attachmentKey) in keys {
            if let value = extensions[extensionKey] {
                CVBufferSetAttachment(buffer, attachmentKey, value as CFTypeRef, .shouldPropagate)
            }
        }
        if let masteringDisplay {
            CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, masteringDisplay as CFData, .shouldPropagate)
        }
        if let contentLightLevel {
            CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, contentLightLevel as CFData, .shouldPropagate)
        }
    }

    /// The ReelCore summary, with FFmpeg's names for each field.
    public var info: ColorInfo {
        func name(_ pointer: UnsafePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }
        return ColorInfo(
            primaries: primaries == AVCOL_PRI_UNSPECIFIED ? nil : name(av_color_primaries_name(primaries)),
            transfer: transfer == AVCOL_TRC_UNSPECIFIED ? nil : name(av_color_transfer_name(transfer)),
            matrix: matrix == AVCOL_SPC_UNSPECIFIED ? nil : name(av_color_space_name(matrix)),
            fullRange: isFullRange,
            hasHDRMetadata: masteringDisplay != nil || contentLightLevel != nil,
            mastering: VideoColor.masteringDisplayInfo(masteringDisplay),
            contentLight: contentLightLevel.flatMap { data in
                AttachmentValues.maxCLL(data).map { ContentLightLevel(maxCLL: $0, maxFALL: AttachmentValues.maxFALL(data) ?? 0) }
            }
        )
    }

    /// ReelCore's mastering display from the 24-byte Core Media layout.
    public static func masteringDisplayInfo(_ data: Data?) -> MasteringDisplay? {
        guard let points = AttachmentValues.masteringPrimaries(data), points.count == 4,
              let peak = AttachmentValues.masteringPeak(data), let minimum = AttachmentValues.masteringMinimum(data) else { return nil }
        func chromaticity(_ point: (x: Double, y: Double)) -> Chromaticity {
            Chromaticity(x: (point.x * 100_000).rounded() / 100_000, y: (point.y * 100_000).rounded() / 100_000)
        }
        return MasteringDisplay(
            red: chromaticity(points[0]),
            green: chromaticity(points[1]),
            blue: chromaticity(points[2]),
            whitePoint: chromaticity(points[3]),
            minLuminance: minimum,
            maxLuminance: peak
        )
    }

    /// Colour for a stream that tags nothing and has no in-band description: SMPTE 170M for SD,
    /// BT.709 otherwise (section 7.3), as QuickTime assumes.
    public func resolvingDefaults(width: Int, height: Int) -> VideoColor {
        let hd = !VideoColor.isStandardDefinition(width: width, height: height)
        var resolved = self
        if resolved.primaries == AVCOL_PRI_UNSPECIFIED { resolved.primaries = hd ? AVCOL_PRI_BT709 : AVCOL_PRI_SMPTE170M }
        if resolved.transfer == AVCOL_TRC_UNSPECIFIED { resolved.transfer = hd ? AVCOL_TRC_BT709 : AVCOL_TRC_SMPTE170M }
        if resolved.matrix == AVCOL_SPC_UNSPECIFIED { resolved.matrix = hd ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M }
        return resolved
    }

    /// The size VideoToolbox (and so QuickTime and `AVAssetImageGenerator`) reads as SD when a
    /// stream tags no colour: at most 704 x 576. Measured on H.264 and HEVC (2026-10-25): 640 x 480,
    /// 704 x 480 and 704 x 576 get SMPTE-C and BT.601; 706 x 480, 720 x 480, 720 x 576, 704 x 578 and
    /// 640 x 600 get BT.709 (`ColorInfoGuessedBy = VideoToolbox` on the decoded buffer).
    public static func isStandardDefinition(width: Int, height: Int) -> Bool {
        width <= 704 && height <= 576
    }

    // MARK: HDR static metadata

    /// ISO 23001-8 / HEVC SEI layout: G, B, R primaries and white point in 0.00002 units, then max
    /// and min luminance in 0.0001 cd/m2, all big-endian. FFmpeg stores the primaries as R, G, B.
    public static func masteringDisplayData(_ metadata: AVMasteringDisplayMetadata) -> Data? {
        guard metadata.has_primaries != 0, metadata.has_luminance != 0 else { return nil }
        func quantize(_ value: AVRational, unit: Double) -> UInt32 {
            guard value.den != 0 else { return 0 }
            return UInt32(clamping: Int64((Double(value.num) / Double(value.den) / unit).rounded()))
        }
        var data = Data()
        func append16(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        let primaries = metadata.display_primaries
        for point in [primaries.1, primaries.2, primaries.0] {
            append16(quantize(point.0, unit: 0.00002))
            append16(quantize(point.1, unit: 0.00002))
        }
        append16(quantize(metadata.white_point.0, unit: 0.00002))
        append16(quantize(metadata.white_point.1, unit: 0.00002))
        for luminance in [metadata.max_luminance, metadata.min_luminance] {
            let value = quantize(luminance, unit: 0.0001)
            append16(value >> 16)
            append16(value & 0xffff)
        }
        return data
    }

    public static func contentLightLevelData(_ metadata: AVContentLightMetadata) -> Data {
        var data = Data()
        for value in [metadata.MaxCLL, metadata.MaxFALL] {
            let clamped = UInt16(clamping: value)
            data.append(UInt8(truncatingIfNeeded: clamped >> 8))
            data.append(UInt8(truncatingIfNeeded: clamped))
        }
        return data
    }
}
