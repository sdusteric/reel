import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ReelCore

/// Every image Reel makes from an HDR frame (screenshots, thumbnails, the next-episode card,
/// Now Playing artwork, shot mode) goes through here (design section 7.7, D53).
///
/// `CIImage(cvPixelBuffer:)` reads the buffer's colour attachments into Core Image's extended
/// linear space, where 1.0 is reference white for both PQ (203 nits) and HLG (75% signal). The SDR
/// image is made by ColorSync's PQ to sRGB conversion, the one AVFoundation uses: for PQ it is
/// identical to `AVAssetImageGenerator` (QuickTime) on the same frame, mid-tones unchanged and
/// highlights rolled off above reference white. HLG is first written as PQ so it gets the same
/// curve (Core Image's own HLG to SDR path puts 75% signal at sRGB 146, darker than SDR white).
///
/// `CIToneMapHeadroom` (and `CISystemToneMap`, which matches it at headroom 1.0) map reference
/// white to half of SDR white (sRGB 188), below the 190 floor section 7.7 sets, so they are used
/// only to simulate an EDR display's headroom and as a reported reference.
public enum HDRToneMapper {
    /// BT.2408 reference white for PQ, in nits.
    public static let referenceWhiteNits = 203.0
    /// The nominal peak of HLG content.
    public static let hlgPeakNits = 1_000.0
    /// `kCGDefaultHDRImageContentHeadroom`: about 1000 / 203.
    public static let defaultContentHeadroom = Float(4.926_108)

    public enum Transfer: String, Sendable, Hashable {
        case pq, hlg
    }

    /// One context for every tone map: Core Image contexts are thread-safe and expensive to make.
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .name: "reel.hdr-tone-map",
    ])

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
    private static let extendedLinearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    private static let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)

    /// PQ or HLG from the buffer's transfer function attachment; nil for SDR.
    public static func transfer(of buffer: CVPixelBuffer) -> Transfer? {
        guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) else { return nil }
        return transfer(named: value as? String)
    }

    public static func transfer(named name: String?) -> Transfer? {
        if name == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { return .pq }
        if name == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return .hlg }
        return nil
    }

    /// True for a buffer tagged PQ or HLG.
    public static func isHDR(_ buffer: CVPixelBuffer) -> Bool {
        transfer(of: buffer) != nil
    }

    /// The content's headroom over reference white: MaxCLL / 203, else the mastering display's
    /// peak / 203, else `kCGDefaultHDRImageContentHeadroom`. HLG is always 1000 / 203.
    public static func sourceHeadroom(transfer: Transfer, contentLightLevel: Data?, masteringDisplay: Data?) -> Float {
        if transfer == .hlg { return Float(hlgPeakNits / referenceWhiteNits) }
        if let maxCLL = AttachmentValues.maxCLL(contentLightLevel), maxCLL > 0 {
            return max(1, Float(Double(maxCLL) / referenceWhiteNits))
        }
        if let peak = AttachmentValues.masteringPeak(masteringDisplay), peak > 0 {
            return max(1, Float(peak / referenceWhiteNits))
        }
        return defaultContentHeadroom
    }

    /// `sourceHeadroom` from the buffer's own attachments; nil for SDR buffers.
    public static func sourceHeadroom(of buffer: CVPixelBuffer) -> Float? {
        guard let transfer = transfer(of: buffer) else { return nil }
        let light = CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
        let mastering = CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data
        return sourceHeadroom(transfer: transfer, contentLightLevel: light, masteringDisplay: mastering)
    }

    /// The tone-mapped Core Image picture, extended linear, 1.0 = reference white.
    /// - Parameter targetHeadroom: 1.0 for SDR output; a display's current headroom to simulate EDR.
    public static func toneMappedImage(_ buffer: CVPixelBuffer, targetHeadroom: Float = 1) -> CIImage {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let source = sourceHeadroom(of: buffer) else { return image }
        let filter = CIFilter.toneMapHeadroom()
        filter.inputImage = image
        filter.sourceHeadroom = source
        filter.targetHeadroom = max(1, targetHeadroom)
        return filter.outputImage ?? image
    }

    /// The frame as an 8-bit sRGB image, tone-mapped to SDR through ColorSync's PQ conversion.
    public static func sdrImage(_ buffer: CVPixelBuffer) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        var image = CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: true])
        if transfer(of: buffer) != .pq {
            // HLG (and anything else tagged HDR): re-encode the linear picture as PQ, half float.
            guard let pq, let encoded = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: extent, format: .RGBAh, colorSpace: pq) else {
                throw EngineError.decoderFailed("Core Image could not convert the frame to PQ")
            }
            image = CIImage(cgImage: encoded, options: [.toneMapHDRtoSDR: true])
        }
        return try render(image, extent: extent)
    }

    /// The frame through `CIToneMapHeadroom` from the content's headroom to 1.0, as 8-bit sRGB.
    /// Not used for any image Reel shows or saves; `reelctl hdr` reports it for comparison.
    public static func headroomCurveImage(_ buffer: CVPixelBuffer) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        return try render(toneMappedImage(buffer, targetHeadroom: 1), extent: extent)
    }

    private static func render(_ image: CIImage, extent: CGRect) throws -> CGImage {
        guard let sRGB, let rendered = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: sRGB) else {
            throw EngineError.decoderFailed("Core Image could not tone-map the frame")
        }
        return rendered
    }

    public static func sdrImage(_ buffer: CVReadOnlyPixelBuffer) throws -> CGImage {
        try buffer.withUnsafeBuffer { try sdrImage($0) }
    }

    /// Mean extended linear sRGB value of `rect` (top-left origin, buffer pixels) after tone
    /// mapping to `targetHeadroom`: what an EDR display with that headroom is asked to show.
    public static func linearMean(_ buffer: CVPixelBuffer, rect: CGRect, targetHeadroom: Float) -> (r: Double, g: Double, b: Double)? {
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        // Core Image is y-up.
        let flipped = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        let image = toneMappedImage(buffer, targetHeadroom: targetHeadroom)
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = flipped
        guard let output = average.outputImage, let space = extendedLinearSRGB else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        }
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }
}

/// Reads the HDR static metadata attachments (the 24-byte MDCV and 4-byte CLL layouts that
/// `VideoColor` writes, big-endian).
public enum AttachmentValues {
    public static func maxCLL(_ data: Data?) -> Int? {
        guard let data, data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        return Int(bytes[0]) << 8 | Int(bytes[1])
    }

    public static func maxFALL(_ data: Data?) -> Int? {
        guard let data, data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        return Int(bytes[2]) << 8 | Int(bytes[3])
    }

    /// Mastering display peak luminance in nits.
    public static func masteringPeak(_ data: Data?) -> Double? {
        guard let data, data.count >= 24 else { return nil }
        return Double(uint32(data, at: 16)) * 0.0001
    }

    /// Mastering display minimum luminance in nits.
    public static func masteringMinimum(_ data: Data?) -> Double? {
        guard let data, data.count >= 24 else { return nil }
        return Double(uint32(data, at: 20)) * 0.0001
    }

    /// Chromaticities in R, G, B, white order (the data stores G, B, R, white).
    public static func masteringPrimaries(_ data: Data?) -> [(x: Double, y: Double)]? {
        guard let data, data.count >= 24 else { return nil }
        func point(_ offset: Int) -> (x: Double, y: Double) {
            (Double(uint16(data, at: offset)) * 0.00002, Double(uint16(data, at: offset + 2)) * 0.00002)
        }
        return [point(8), point(0), point(4), point(12)]
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) << 8 | UInt32(data[start + 1])
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        uint16(data, at: offset) << 16 | uint16(data, at: offset + 2)
    }
}
