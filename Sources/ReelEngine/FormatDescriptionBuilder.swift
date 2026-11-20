import CoreMedia
import CReelDeps
import Foundation
import ReelCore
import VideoToolbox

/// The video codecs VideoToolbox can take directly.
public enum VideoCodec: String, Sendable, Hashable {
    case h264, hevc, av1, vp9
    /// Anything else (MPEG-4 Part 2, FLV1, MPEG-2, VC-1, ...): software only.
    case other

    init(_ id: AVCodecID) {
        switch id {
        case AV_CODEC_ID_H264: self = .h264
        case AV_CODEC_ID_HEVC: self = .hevc
        case AV_CODEC_ID_AV1: self = .av1
        case AV_CODEC_ID_VP9: self = .vp9
        default: self = .other
        }
    }

    public var cmCodecType: CMVideoCodecType? {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .av1: kCMVideoCodecType_AV1
        case .vp9: kCMVideoCodecType_VP9
        case .other: nil
        }
    }

    var nalCodec: NALUnits.Codec? {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        default: nil
        }
    }
}

/// Everything the decoders need to know about the selected video stream.
public struct VideoFormat: Sendable {
    public var codec: VideoCodec
    /// FFmpeg codec name, e.g. "hevc".
    public var codecName: String
    public var width: Int
    public var height: Int
    public var bitDepth: Int
    public var color: VideoColor
    public var pixelAspect: Rational?
    /// Display rotation, clockwise degrees: 0, 90, 180 or 270.
    public var rotation: Int
    public var frameRate: Rational?
    /// H.264/HEVC NAL length size in the packets the decoder receives (4 after Annex B conversion).
    public var nalLengthSize: Int?
    /// Packets arrive with start codes and are rewritten to 4-byte lengths before decode.
    public var convertsAnnexB: Bool
    /// hvcC `numTemporalLayers` (HEVC only, 0 when unknown).
    public var hevcTemporalLayers: Int
    /// avcC or hvcC built from Annex B parameter sets. libavcodec gets it as extradata so it parses
    /// the converted, length-prefixed packets the store holds.
    public var convertedConfigurationRecord: Data?
    /// The compressed format description for VideoToolbox; nil for codecs it cannot take.
    public var formatDescription: CMVideoFormatDescription?
    /// The stream's field order (codecpar); VideoToolbox frames of an interlaced stream are
    /// deinterlaced by it.
    public var fieldOrder: FieldOrder = .progressive

    /// ReelCore's description of the stream.
    public var parameters: VideoParameters {
        VideoParameters(
            width: width,
            height: height,
            pixelAspect: pixelAspect,
            frameRate: frameRate,
            bitDepth: bitDepth,
            rotation: rotation,
            color: color.info
        )
    }

    public var frameDuration: MediaTime? { parameters.frameDuration }

    /// True when VideoToolbox reports a hardware decoder for this codec.
    public var isHardwareDecodeSupported: Bool {
        guard let type = codec.cmCodecType, formatDescription != nil else { return false }
        if codec == .vp9 { FormatDescriptionBuilder.registerSupplementalDecoders() }
        return VTIsHardwareDecodeSupported(type)
    }

    /// Rewrites an Annex B packet to length prefixes when the stream needs it; otherwise returns it.
    public func prepare(_ packet: Packet) -> Packet {
        guard convertsAnnexB, let nalCodec = codec.nalCodec, NALUnits.looksLikeAnnexB(packet.bytes) else { return packet }
        let converted = NALUnits.annexBToLengthPrefixed(packet.bytes, codec: nalCodec)
        return Packet(copying: packet, payload: converted) ?? packet
    }

    /// Reference flags of a prepared packet. AV1, VP9 and software codecs report nothing.
    public func pictureFlags(_ packet: Packet) -> NALUnits.PictureFlags {
        guard let nalCodec = codec.nalCodec, let nalLengthSize else { return NALUnits.PictureFlags() }
        return NALUnits.pictureFlags(packet.bytes, lengthSize: nalLengthSize, codec: nalCodec, hevcTemporalLayers: hevcTemporalLayers)
    }

    /// True when a frame that nothing references may be left out of a seek's pre-target decode
    /// (H.264 nal_ref_idc 0, HEVC sub-layer non-reference with one temporal sub-layer).
    public func isDisposable(_ packet: Packet) -> Bool {
        pictureFlags(packet).isDisposable
    }
}

/// Builds Core Media format descriptions from FFmpeg stream parameters (design section 7.3).
public enum FormatDescriptionBuilder {
    private static let supplementalDecodersRegistered: Void = {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
    }()

    /// Registers the VP9 supplemental decoder. Safe to call any number of times.
    public static func registerSupplementalDecoders() {
        supplementalDecodersRegistered
    }

    /// Describes `stream`. `firstPackets` are the stream's first packets in decode order: they supply
    /// Annex B parameter sets when extradata has none, and the first-frame colour probe when
    /// codecpar leaves colour unspecified.
    public static func make(stream: UnsafePointer<AVStream>, firstPackets: [Packet] = []) throws -> VideoFormat {
        guard let parameters = stream.pointee.codecpar else { throw EngineError.noPlayableStream }
        let par = parameters.pointee
        let codec = VideoCodec(par.codec_id)
        let width = Int(par.width)
        let height = Int(par.height)
        guard width > 0, height > 0 else { throw EngineError.openFailed("video stream has no dimensions") }

        var color = VideoColor(codecParameters: parameters)
        if color.needsFrameProbe, let probed = probeColor(parameters: parameters, packets: firstPackets) {
            color = color.filling(from: probed)
        }

        var format = VideoFormat(
            codec: codec,
            codecName: String(cString: avcodec_get_name(par.codec_id)),
            width: width,
            height: height,
            bitDepth: bitDepth(par),
            color: color,
            pixelAspect: pixelAspect(stream),
            rotation: rotation(par),
            frameRate: frameRate(stream),
            nalLengthSize: nil,
            convertsAnnexB: false,
            hevcTemporalLayers: 0,
            convertedConfigurationRecord: nil,
            formatDescription: nil
        )
        format.fieldOrder = FieldOrder(par.field_order)

        var extensions = color.formatExtensions(width: width, height: height)
        if let pixelAspect = format.pixelAspect, pixelAspect.num != pixelAspect.den {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: Int(pixelAspect.num),
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: Int(pixelAspect.den),
            ] as [CFString: Any]
        }
        let extradata = par.extradata_size > 0 && par.extradata != nil
            ? Data(bytes: par.extradata, count: Int(par.extradata_size)) : Data()

        switch codec {
        case .h264, .hevc:
            let nalCodec: NALUnits.Codec = codec == .h264 ? .h264 : .hevc
            let atomName = codec == .h264 ? "avcC" : "hvcC"
            var record = extradata
            if record.first != 1 {
                // Annex B (ts, raw streams): parameter sets from extradata or the first key packet.
                let sources = [extradata] + firstPackets.filter(\.isKeyframe).prefix(2).map(\.data)
                guard let sets = sources.lazy.compactMap({ NALUnits.parameterSets(inAnnexB: $0, codec: nalCodec) }).first else {
                    throw EngineError.unsupportedCodec("\(format.codecName) without parameter sets")
                }
                record = try configurationRecord(parameterSets: sets, codec: nalCodec)
                format.convertsAnnexB = true
                format.convertedConfigurationRecord = record
            }
            format.nalLengthSize = format.convertsAnnexB ? 4 : NALUnits.nalLengthSize(configurationRecord: record, codec: nalCodec)
            if codec == .hevc { format.hevcTemporalLayers = NALUnits.hevcTemporalLayerCount(hvcC: record) ?? 0 }
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [atomName: record]
        case .av1:
            guard extradata.count >= 4, extradata.first == 0x81 else {
                return format // No av1C: software decode with dav1d.
            }
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = ["av1C": extradata]
        case .vp9:
            registerSupplementalDecoders()
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = ["vpcC": vpcC(par, bitDepth: format.bitDepth, color: color)]
        case .other:
            return format
        }

        guard let type = codec.cmCodecType else { return format }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: type,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw MediaStatusError(status: status, operation: "CMVideoFormatDescriptionCreate(\(format.codecName))")
        }
        format.formatDescription = description
        return format
    }

    /// The avcC or hvcC record Core Media builds from raw parameter sets, with 4-byte NAL lengths.
    public static func configurationRecord(parameterSets: [Data], codec: NALUnits.Codec) throws -> Data {
        var description: CMFormatDescription?
        let status: OSStatus = withPointers(parameterSets) { pointers, sizes in
            switch codec {
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            case .hevc:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw MediaStatusError(status: status, operation: "format description from parameter sets")
        }
        let atomName = codec == .h264 ? "avcC" : "hvcC"
        guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
              let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
              let record = atoms[atomName] as? Data else {
            throw EngineError.unsupportedCodec("no \(atomName) from parameter sets")
        }
        return record
    }

    private static func withPointers<R>(_ sets: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let buffers = sets.map { data -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(1, data.count))
            _ = buffer.initialize(from: data)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        return body(buffers.compactMap { buffer in buffer.baseAddress.map { UnsafePointer($0) } }, sets.map(\.count))
    }

    /// VPCodecConfigurationBox payload (version 1, flags 0). FFmpeg does not put vpcC in extradata
    /// for VP9; mkv and mp4 fill codecpar fields instead.
    public static func vpcC(_ par: AVCodecParameters, bitDepth: Int, color: VideoColor) -> Data {
        var chroma: UInt8 = 1 // 4:2:0 colocated with luma
        if let descriptor = av_pix_fmt_desc_get(AVPixelFormat(rawValue: par.format))?.pointee {
            switch (descriptor.log2_chroma_w, descriptor.log2_chroma_h) {
            case (1, 1): chroma = par.chroma_location == AVCHROMA_LOC_LEFT ? 0 : 1
            case (1, 0): chroma = 2
            case (0, 0): chroma = 3
            default: break
            }
        }
        func byte(_ value: UInt32) -> UInt8 { value < 256 ? UInt8(value) : 2 }
        let profile = UInt8(clamping: max(0, par.profile))
        let level = UInt8(clamping: max(0, par.level))
        let fullRange: UInt8 = color.isFullRange ? 1 : 0
        var data = Data([1, 0, 0, 0])
        data.append(contentsOf: [
            profile, level, (UInt8(clamping: bitDepth) << 4) | (chroma << 1) | fullRange,
            byte(color.primaries.rawValue), byte(color.transfer.rawValue), byte(color.matrix.rawValue),
        ])
        data.append(contentsOf: [0, 0]) // codecInitializationDataSize
        return data
    }

    // MARK: Stream properties

    static func bitDepth(_ par: AVCodecParameters) -> Int {
        if let descriptor = av_pix_fmt_desc_get(AVPixelFormat(rawValue: par.format)) {
            return Int(descriptor.pointee.comp.0.depth)
        }
        if par.codec_id == AV_CODEC_ID_HEVC, par.profile == 2 { return 10 }
        return 8
    }

    static func pixelAspect(_ stream: UnsafePointer<AVStream>) -> Rational? {
        var ratio = stream.pointee.sample_aspect_ratio
        if ratio.num <= 0 || ratio.den <= 0 { ratio = stream.pointee.codecpar.pointee.sample_aspect_ratio }
        guard ratio.num > 0, ratio.den > 0 else { return nil }
        return Rational(ratio.num, ratio.den)
    }

    static func frameRate(_ stream: UnsafePointer<AVStream>) -> Rational? {
        for rate in [stream.pointee.avg_frame_rate, stream.pointee.r_frame_rate] where rate.num > 0 && rate.den > 0 {
            return Rational(rate.num, rate.den)
        }
        return nil
    }

    /// Clockwise rotation from the display matrix. `av_display_rotation_get` returns the
    /// counterclockwise angle, so a matrix of +90 means the picture is shown turned 270 clockwise.
    static func rotation(_ par: AVCodecParameters) -> Int {
        guard let side = av_packet_side_data_get(par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX),
              side.pointee.size >= 36 else { return 0 }
        let counterclockwise = av_display_rotation_get(UnsafeRawPointer(side.pointee.data).assumingMemoryBound(to: Int32.self))
        guard counterclockwise.isFinite else { return 0 }
        let quarterTurns = Int((-counterclockwise / 90).rounded())
        return ((quarterTurns % 4) + 4) % 4 * 90
    }

    // MARK: Colour probe

    /// Software-decodes the first frame with libavcodec to read in-band colour and HDR metadata
    /// (AV1 in mkv often leaves codecpar unspecified). Costs a few milliseconds at open.
    public static func probeColor(parameters: UnsafePointer<AVCodecParameters>, packets: [Packet]) -> VideoColor? {
        guard let start = packets.firstIndex(where: \.isKeyframe) else { return nil }
        guard let context = try? SoftwareVideoDecoder.openCodecContext(parameters: parameters, threads: 1) else { return nil }
        var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&contextPointer) }
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let frame else { return nil }
        // Drains right after the keyframe: with B-frame reordering the decoder would otherwise
        // decode several more frames before returning one (163 ms instead of 56 on 20 Mbps H.264).
        for packet in packets[start...].prefix(8) {
            guard avcodec_send_packet(context, packet.avPacket) >= 0 else { continue }
            if avcodec_receive_frame(context, frame) >= 0 { return VideoColor(frame: frame) }
            avcodec_send_packet(context, nil)
            if avcodec_receive_frame(context, frame) >= 0 { return VideoColor(frame: frame) }
            return nil
        }
        return nil
    }
}
