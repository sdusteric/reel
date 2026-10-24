import Foundation
import ReelCore
import ReelEngine

/// `reelctl probe <file> [--json]`: streams, codecs, decoder choice, hardware support, keyframe
/// count and duration. `reelctl probe --build-info` prints FFmpeg's license and configuration.
enum ProbeCommand {
    struct Report: Encodable {
        var file: String
        var format: String
        var durationSeconds: Double?
        var fileSize: Int64?
        var bitRate: Int?
        var streams: [StreamInfo]
        var videoStreamIndex: Int?
        var audioStreamIndex: Int?
        var videoDecoder: String?
        var decoderReason: String?
        var hardwareDecodeSupported: Bool?
        var keyframeCount: Int
        var keyframeKinds: [String: Int]
    }

    static func run(_ arguments: CommandArguments) throws -> Int32 {
        if arguments.flags.contains("--build-info") {
            try printBuildInfo(json: arguments.json)
            return 0
        }
        let report = try probe(arguments.file())
        if arguments.json {
            try printJSON(report)
        } else {
            printText(report)
        }
        return 0
    }

    static func probe(_ url: URL) throws -> Report {
        let demuxer = try Demuxer(url: url)
        defer { demuxer.stop() }
        let info = demuxer.info
        var decoder: DecoderDecision?
        var hardware: Bool?
        if let format = demuxer.videoFormat {
            let supported = format.isHardwareDecodeSupported
            hardware = supported
            var support = HardwareDecodeSupport.none
            switch format.codec {
            case .h264: support.h264 = supported
            case .hevc: support.hevc = supported
            case .vp9: support.vp9 = supported
            case .av1: support.av1 = supported
            case .other: break
            }
            let policy = DecoderPolicy(environment: ReelEnvironment(), support: support)
            decoder = policy.decide(for: VideoStreamTraits(codec: format.codecName, bitDepth: format.bitDepth))
        }
        let index = demuxer.keyframeIndex
        var kinds: [String: Int] = [:]
        for entry in index.entries { kinds[entry.kind.rawValue, default: 0] += 1 }
        return Report(
            file: url.path(percentEncoded: false),
            format: info.formatName,
            durationSeconds: info.duration?.seconds,
            fileSize: info.fileSize,
            bitRate: info.bitRate,
            streams: info.streams,
            videoStreamIndex: info.videoStreamIndex,
            audioStreamIndex: info.audioStreamIndex,
            videoDecoder: decoder?.kind.rawValue,
            decoderReason: decoder?.reason.rawValue,
            hardwareDecodeSupported: hardware,
            keyframeCount: index.count,
            keyframeKinds: kinds
        )
    }

    private static func printText(_ report: Report) {
        print("file: \(report.file)")
        print("format: \(report.format)")
        if let duration = report.durationSeconds { print("duration: \(TimeFormat.clock(MediaTime(seconds: duration), duration: MediaTime(seconds: duration))) (\(duration) s)") }
        if let size = report.fileSize { print("size: \(size) bytes") }
        for stream in report.streams {
            var line = "stream \(stream.index): \(stream.kind.rawValue) \(stream.codec)"
            if let profile = stream.profile { line += " (\(profile))" }
            if let video = stream.video {
                line += ", \(video.width)x\(video.height), \(video.bitDepth)-bit"
                if let rate = video.frameRate { line += String(format: ", %.3f fps", rate.doubleValue) }
                if video.rotation != 0 { line += ", rotated \(video.rotation)" }
                if let transfer = video.color.transfer { line += ", \(transfer)" }
            }
            if let audio = stream.audio {
                line += ", \(audio.sampleRate) Hz, \(audio.channels) ch"
                if let layout = audio.channelLayout { line += " (\(layout))" }
            }
            if let language = stream.language { line += ", \(language)" }
            if stream.index == report.videoStreamIndex || stream.index == report.audioStreamIndex { line += " [selected]" }
            print(line)
        }
        if let decoder = report.videoDecoder {
            print("video decoder: \(decoder) (\(report.decoderReason ?? "")), VideoToolbox hardware: \(report.hardwareDecodeSupported == true ? "yes" : "no")")
        }
        let kinds = report.keyframeKinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("keyframes: \(report.keyframeCount)" + (kinds.isEmpty ? "" : " (\(kinds))"))
    }

    private static func printBuildInfo(json: Bool) throws {
        let info: [(String, String)] = [
            ("license", BuildInfo.ffmpegLicense),
            ("configuration", BuildInfo.ffmpegConfiguration),
            ("avformat", BuildInfo.avformatVersion),
            ("avcodec", BuildInfo.avcodecVersion),
            ("avutil", BuildInfo.avutilVersion),
            ("libass", BuildInfo.libassVersion),
        ]
        if json {
            try printJSON(Dictionary(uniqueKeysWithValues: info))
        } else {
            for (key, value) in info {
                print("\(key): \(value)")
            }
        }
    }
}
