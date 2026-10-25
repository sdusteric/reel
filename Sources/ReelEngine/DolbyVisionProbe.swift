import CoreMedia
import CoreVideo
import CReelDeps
import Foundation
import ReelCore
import Synchronization
import VideoToolbox

/// Reads a stream's Dolby Vision configuration record (section 7.8). The Matroska
/// (`BlockAdditionMapping`) and MP4 (`dvcC`, `dvvC`, `dvwC`) demuxers export it as
/// `AV_PKT_DATA_DOVI_CONF` coded side data on the stream's codec parameters.
public enum DolbyVisionProbe {
    public static func config(of stream: UnsafePointer<AVStream>) -> DolbyVisionConfig? {
        guard let parameters = stream.pointee.codecpar else { return nil }
        return config(codecParameters: parameters)
    }

    public static func config(codecParameters parameters: UnsafePointer<AVCodecParameters>) -> DolbyVisionConfig? {
        let par = parameters.pointee
        guard par.nb_coded_side_data > 0,
              let side = av_packet_side_data_get(par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              let data = side.pointee.data else { return nil }
        return parse(UnsafeBufferPointer(start: data, count: Int(side.pointee.size)))
    }

    /// `AVDOVIDecoderConfigurationRecord` is nine `uint8_t` fields in this order: version major,
    /// version minor, profile, level, RPU, EL and BL present flags, compatibility id, and
    /// metadata compression. Reading bytes avoids importing `dovi_meta.h`.
    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> DolbyVisionConfig? {
        guard bytes.count >= 8 else { return nil }
        let profile = Int(bytes[2])
        guard profile > 0 else { return nil }
        return DolbyVisionConfig(
            profile: profile,
            level: Int(bytes[3]),
            rpu: bytes[4] != 0,
            el: bytes[5] != 0,
            bl: bytes[6] != 0,
            compatibilityID: Int(bytes[7])
        )
    }

    // MARK: Configuration box

    /// The 24-byte `DOVIDecoderConfigurationRecord` (ETSI TS 103 572): version 1.0, then profile
    /// (7 bits), level (6), RPU, EL and BL flags, compatibility id (4) and reserved bits.
    public static func configurationBox(_ config: DolbyVisionConfig) -> Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = 1
        bytes[1] = 0
        let packed = UInt16(config.profile & 0x7f) << 9 | UInt16(config.level & 0x3f) << 3
            | (config.rpu ? 4 : 0) | (config.el ? 2 : 0) | (config.bl ? 1 : 0)
        bytes[2] = UInt8(packed >> 8)
        bytes[3] = UInt8(packed & 0xff)
        bytes[4] = UInt8(config.compatibilityID & 0x0f) << 4
        return Data(bytes)
    }

    /// The sample entry box name for the profile: `dvcC` up to 7, `dvvC` for 8 to 10, `dvwC` above.
    public static func configurationBoxName(profile: Int) -> String {
        switch profile {
        case ...7: "dvcC"
        case 8...10: "dvvC"
        default: "dvwC"
        }
    }

    // MARK: Session probe (hands-on, section 7.8)

    /// What `reelctl probe --dovi-session` found: whether VideoToolbox makes a Dolby Vision HEVC
    /// session for the file, and what its first frames look like.
    public struct SessionReport: Sendable, Codable {
        public var file: String
        public var dolbyVision: DolbyVisionConfig?
        public var codecType = "dvh1"
        public var configurationBox: String?
        public var sessionCreated = false
        public var error: String?
        public var framesSubmitted = 0
        public var framesDecoded = 0
        public var failures = 0
        /// The OSStatus of the last failed frame (VideoToolbox's reason).
        public var failureStatus: Int32?
        public var pixelFormat: String?
        /// String-valued attachments of the first decoded frame, plus the names of the others.
        public var attachments: [String: String] = [:]
        /// Mean codes over the whole of the decoded frames (10-bit values for `x420`).
        public var meanY: Double?
        public var meanCb: Double?
        public var meanCr: Double?
        /// The base layer decoded as plain HEVC, for comparison.
        public var hevcMeanCb: Double?
        public var hevcMeanCr: Double?
    }

    private final class SessionCollector: Sendable {
        let frames = Mutex<[CVReadOnlyPixelBuffer]>([])
        let failures = Atomic<Int>(0)
        let lastStatus = Atomic<Int32>(0)

        func handle(_ event: DecodeEvent) {
            switch event {
            case .frame(let frame): frames.withLock { $0.append(frame.pixelBuffer) }
            case .failed(_, _, let status, _):
                failures.add(1, ordering: .relaxed)
                lastStatus.store(status, ordering: .relaxed)
            case .dropped: break
            }
        }
    }

    /// Creates a `kCMVideoCodecType_DolbyVisionHEVC` session for the file's video stream (the
    /// stream's `hvcC` plus a Dolby Vision configuration box), decodes `frames` frames and reports
    /// the output. Never throws for a session VideoToolbox refuses; that is a finding.
    public static func sessionReport(url: URL, frames: Int = 10) throws -> SessionReport {
        let source = try MediaSource(url: url)
        guard let index = source.videoStreamIndex, let stream = source.stream(index) else { throw EngineError.noPlayableStream }
        var report = SessionReport(file: url.path(percentEncoded: false))
        report.dolbyVision = config(of: stream)
        var packets: [Packet] = []
        while packets.count < frames, let packet = try source.readPacket() {
            if packet.streamIndex == index { packets.append(packet) }
        }
        let format = try FormatDescriptionBuilder.make(stream: stream, firstPackets: packets)
        guard format.codec == .hevc, let hevc = format.formatDescription else {
            report.error = "the video stream is \(format.codecName), not HEVC"
            return report
        }
        let config = report.dolbyVision ?? DolbyVisionConfig(profile: 5, level: 6, rpu: true, el: false, bl: true, compatibilityID: 0)
        let box = configurationBox(config)
        report.configurationBox = configurationBoxName(profile: config.profile)
        var extensions = (CMFormatDescriptionGetExtensions(hevc) as? [CFString: Any]) ?? [:]
        var atoms = (extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any]) ?? [:]
        atoms[configurationBoxName(profile: config.profile)] = box
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_DolbyVisionHEVC,
            width: Int32(format.width), height: Int32(format.height), extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            report.error = "CMVideoFormatDescriptionCreate: \(status)"
            return report
        }
        var dolbyFormat = format
        dolbyFormat.formatDescription = description

        let collector = SessionCollector()
        let decoder: VTVideoDecoder
        do {
            decoder = try VTVideoDecoder(format: dolbyFormat) { collector.handle($0) }
        } catch {
            report.error = String(describing: error)
            return report
        }
        report.sessionCreated = true
        for packet in packets {
            do {
                try decoder.decode(format.prepare(packet), generation: 0, output: true)
                report.framesSubmitted += 1
            } catch {
                report.error = String(describing: error)
                break
            }
        }
        decoder.drainSynchronously()
        decoder.invalidate()
        let decoded = collector.frames.withLock { $0 }
        report.framesDecoded = decoded.count
        report.failures = collector.failures.load(ordering: .relaxed)
        if report.failures > 0 { report.failureStatus = collector.lastStatus.load(ordering: .relaxed) }
        if let first = decoded.first {
            first.withUnsafeBuffer { buffer in
                let format = CVPixelBufferGetPixelFormatType(buffer)
                report.pixelFormat = String(decoding: [24, 16, 8, 0].map { UInt8((format >> $0) & 0xff) }, as: UTF8.self)
                for (key, value) in (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]) ?? [:] {
                    if let text = value as? String {
                        report.attachments[key] = text
                    } else if let data = value as? Data {
                        report.attachments[key] = data.map { String(format: "%02x", $0) }.joined()
                    } else {
                        report.attachments[key] = String(describing: type(of: value))
                    }
                }
            }
        }
        let means = decoded.compactMap(wholeFrameCodes)
        if !means.isEmpty {
            report.meanY = means.map(\.y).reduce(0, +) / Double(means.count)
            report.meanCb = means.map(\.cb).reduce(0, +) / Double(means.count)
            report.meanCr = means.map(\.cr).reduce(0, +) / Double(means.count)
        }
        if let plain = try? FrameGrabber.grab(url: url, at: .zero, decoder: .hardware), let codes = wholeFrameCodes(plain.frame.pixelBuffer) {
            report.hevcMeanCb = codes.cb
            report.hevcMeanCr = codes.cr
        }
        return report
    }

    private static func wholeFrameCodes(_ buffer: CVReadOnlyPixelBuffer) -> YCbCrCodes? {
        let (width, height) = buffer.withUnsafeBuffer { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) }
        return FrameGrabber.meanCodes(buffer, centerX: width / 2, centerY: height / 2, size: max(width, height))
    }
}
