import Darwin
import Foundation
import ReelCore
import ReelEngine
import Synchronization

/// `reelctl decode-bench <file> [--decoder hw|sw|auto]`: decodes every video packet as fast as the
/// decoder takes them and reports frames per second and CPU seconds. Packets are read into memory
/// first, so the numbers are decode only.
enum DecodeBenchCommand {
    struct Report: Encodable {
        var file: String
        var codec: String
        var decoder: String
        var usesHardware: Bool?
        var packets: Int
        var frames: Int
        var failures: Int
        var wallSeconds: Double
        var cpuSeconds: Double
        var framesPerSecond: Double
    }

    private final class Counter: Sendable {
        let frames = Atomic<Int>(0)
        let failures = Atomic<Int>(0)
    }

    static func run(_ arguments: CommandArguments) async throws -> Int32 {
        let url = try arguments.file()
        let report = try bench(url, decoder: arguments.decoder())
        if arguments.json {
            try printJSON(report)
        } else {
            print("\(report.file): \(report.codec), \(report.decoder) decoder" + (report.usesHardware.map { $0 ? " (hardware)" : " (VideoToolbox software)" } ?? ""))
            print(String(format: "%d frames in %.3f s: %.1f fps, %.2f CPU s, %d failures", report.frames, report.wallSeconds, report.framesPerSecond, report.cpuSeconds, report.failures))
        }
        return report.frames > 0 ? 0 : 1
    }

    static func bench(_ url: URL, decoder requested: VideoDecoderKind?) throws -> Report {
        let demuxer = try Demuxer(url: url)
        defer { demuxer.stop() }
        guard let format = demuxer.videoFormat, let parameters = demuxer.videoParameters else {
            throw EngineError.noPlayableStream
        }
        let kind = requested ?? (format.isHardwareDecodeSupported ? .hardware : .software)

        let source = try MediaSource(url: url)
        var packets: [Packet] = []
        while let packet = try source.readPacket() {
            if packet.streamIndex == source.videoStreamIndex { packets.append(format.prepare(packet)) }
        }

        let counter = Counter()
        let handler: DecodeHandler = { event in
            switch event {
            case .frame: counter.frames.add(1, ordering: .relaxed)
            // Real-time mode is off here, so a drop is unexpected: count it with the frames that
            // did not come out.
            case .failed, .dropped: counter.failures.add(1, ordering: .relaxed)
            }
        }
        let videoDecoder: any VideoDecoding = kind == .hardware
            ? try VTVideoDecoder(format: format, handler: handler)
            : try SoftwareVideoDecoder(parameters: parameters, format: format, handler: handler)
        defer { videoDecoder.invalidate() }
        (videoDecoder as? VTVideoDecoder)?.setRealTime(false)

        let cpuStart = cpuSeconds()
        let start = ContinuousClock.now
        for packet in packets {
            try videoDecoder.decode(packet, generation: 0, output: true)
            if let software = videoDecoder as? SoftwareVideoDecoder {
                while software.pendingJobs > 16 { Thread.sleep(forTimeInterval: 0.0002) }
            }
        }
        videoDecoder.drainSynchronously()
        let elapsed = ContinuousClock.now - start
        let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let frames = counter.frames.load(ordering: .relaxed)
        return Report(
            file: url.path(percentEncoded: false),
            codec: format.codecName,
            decoder: kind.rawValue,
            usesHardware: (videoDecoder as? VTVideoDecoder)?.usesHardware,
            packets: packets.count,
            frames: frames,
            failures: counter.failures.load(ordering: .relaxed),
            wallSeconds: wall,
            cpuSeconds: cpuSeconds() - cpuStart,
            framesPerSecond: wall > 0 ? Double(frames) / wall : 0
        )
    }

    /// User plus system CPU time of this process.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
