import CoreMedia
import Foundation
import ReelCore
import ReelEngine
import Synchronization

/// `reelctl seek-bench <file> [--runs N] [--json]` (design sections 7.6 and 14).
///
/// - First frame after open: a fresh engine per run.
/// - One resident engine for the rest: keyframe (scrub) seeks to random targets, exact seeks to the
///   worst-case targets (the frame before each next keyframe) and to random targets.
/// - Latency ends when the target frame's enqueue on the video receiver of a standalone display
///   layer returns `.enqueued`.
/// - Every exact seek must land on the expected frame pts, and sampled targets must match a
///   sequential software decode with a luma PSNR of at least 35 dB.
enum SeekBenchCommand {
    static let minimumPSNR = 35.0
    /// Pause between seeks on the resident engine, like a person pressing keys.
    static let pause: Duration = .milliseconds(100)

    struct Thresholds: Encodable {
        var firstFrame: Double
        var keyframeSeek: Double
        var exactWorst: Double
    }

    /// Acceptance thresholds in milliseconds (design section 7.6). VP9 is reported, not gated.
    static func thresholds(for url: URL) -> Thresholds? {
        switch url.lastPathComponent {
        case "hevc10_1080p24.mkv": Thresholds(firstFrame: 200, keyframeSeek: 50, exactWorst: 250)
        case "h264_1080p30.mp4": Thresholds(firstFrame: 200, keyframeSeek: 50, exactWorst: 350)
        case "av1_2160p60.mkv": Thresholds(firstFrame: 200, keyframeSeek: 80, exactWorst: 550)
        default: nil
        }
    }

    struct Stats: Encodable {
        var count: Int
        var p50: Double?
        var p95: Double?
        var max: Double?
        var mean: Double?
        var samples: [Double]

        init(_ values: [Double]) {
            samples = values
            count = values.count
            let sorted = values.sorted()
            func rank(_ fraction: Double) -> Double? {
                guard !sorted.isEmpty else { return nil }
                let index = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
                return sorted[Swift.min(Swift.max(index, 0), sorted.count - 1)]
            }
            p50 = rank(0.5)
            p95 = rank(0.95)
            max = sorted.last
            mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    struct Miss: Encodable {
        var kind: String
        var target: Double
        var expected: Double?
        var landed: Double?
    }

    struct PSNRSample: Encodable {
        var target: Double
        var landed: Double?
        var reference: Double?
        var decibels: Double?
    }

    struct SeekCounts: Encodable {
        var keyframeStarts = 0
        var continued = 0
        var previews = 0
        var storeHits = 0
        var framesDecoded = 0
        var framesSkipped = 0
    }

    struct Report: Encodable {
        var file: String
        var codec: String
        var decoder: String?
        var runs: Int
        var gopSeconds: Double?
        var firstFrame: Stats
        var keyframeSeek: Stats
        var exactWorst: Stats
        var exactWorstPreview: Stats
        var exactRandom: Stats
        var exactCounts: SeekCounts
        var exactChecked: Int
        var exactLandedCorrect: Int
        var misses: [Miss]
        var psnr: [PSNRSample]
        var thresholds: Thresholds?
        var failures: [String]
        /// Nil when the file has no thresholds (VP9 is report only).
        var pass: Bool?
    }

    /// Every video frame's pts and the keyframes, from one read of the file.
    struct Scan {
        var frames: [MediaTime]
        var keyframes: [MediaTime]
        var codec: String

        /// The frame displayed at `time`: the largest pts at or before it (or the first frame).
        func expected(at time: MediaTime) -> MediaTime? {
            var low = 0
            var high = frames.count
            while low < high {
                let mid = (low + high) / 2
                if frames[mid] <= time { low = mid + 1 } else { high = mid }
            }
            return low > 0 ? frames[low - 1] : frames.first
        }

        /// The frame just before each keyframe after the first: decoding it needs the whole GOP.
        var worstCaseTargets: [MediaTime] {
            keyframes.dropFirst().compactMap { key in
                let index = frames.firstIndex { $0 >= key } ?? frames.count
                return index > 0 ? frames[index - 1] : nil
            }
        }
    }

    static func scan(_ url: URL) throws -> Scan {
        let source = try MediaSource(url: url)
        guard let videoIndex = source.videoStreamIndex else { throw EngineError.noPlayableStream }
        let codec = source.streamInfo(videoIndex, video: nil)?.codec ?? "unknown"
        var frames: [MediaTime] = []
        var keyframes: [MediaTime] = []
        while let packet = try source.readPacket() {
            guard packet.streamIndex == videoIndex, let time = packet.pts ?? packet.dts else { continue }
            frames.append(time)
            if packet.isKeyframe { keyframes.append(time) }
        }
        frames.sort()
        keyframes.sort()
        return Scan(frames: frames, keyframes: keyframes, codec: codec)
    }

    /// Reads the whole file once so every run sees a warm page cache.
    static func warmCache(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {}
    }

    static func run(_ arguments: CommandArguments) async throws -> Int32 {
        let url = try arguments.file()
        let runs = try arguments.int("--runs", default: 20)
        let samples = try arguments.int("--psnr-samples", default: 5)
        var random = SplitMix64(seed: UInt64(try arguments.int("--seed", default: 7)))
        let configuration = headlessConfiguration(decoder: try arguments.decoder())
        let report = try await bench(url, runs: runs, psnrSamples: samples, configuration: configuration, random: &random)
        if arguments.json {
            try printJSON(report)
        } else {
            printText(report)
        }
        return report.pass == false || !report.failures.isEmpty ? 1 : 0
    }

    static func bench(
        _ url: URL,
        runs: Int,
        psnrSamples: Int,
        configuration: PlaybackEngine.Configuration,
        random: inout SplitMix64
    ) async throws -> Report {
        try warmCache(url)
        let scan = try scan(url)
        guard scan.frames.count > 2, let firstKey = scan.keyframes.first, let lastFrame = scan.frames.last else {
            throw EngineError.openFailed("not enough video frames to bench")
        }
        var failures: [String] = []

        // First frame after open, fresh engine each run.
        var firstFrame: [Double] = []
        for _ in 0..<runs {
            let engine = PlaybackEngine(configuration: configuration)
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await engine.open(url)
            if let report = await engine.lastReport, let milliseconds = report.targetMilliseconds {
                firstFrame.append(Double(report.requestedAtNanos &- started) / 1e6 + milliseconds)
            } else {
                failures.append("open did not show a first frame")
            }
            await engine.close()
        }

        let engine = PlaybackEngine(configuration: configuration)
        _ = try await engine.open(url)
        let decoder = await engine.videoDecoderKind
        var misses: [Miss] = []

        // Keyframe seeks: random targets, each in a different GOP from the one on screen.
        var keyframeSeek: [Double] = []
        var shownKey = firstKey
        for _ in 0..<runs where scan.keyframes.count > 1 {
            var index = Int(random.next() % UInt64(scan.keyframes.count))
            if scan.keyframes[index] == shownKey { index = (index + 1) % scan.keyframes.count }
            let key = scan.keyframes[index]
            let next = index + 1 < scan.keyframes.count ? scan.keyframes[index + 1] : lastFrame
            let span = max(next.microseconds - key.microseconds, 1)
            let target = key + MediaTime(microseconds: Int64(random.next() % UInt64(span)))
            guard let report = await engine.seekAndWait(.scrub(target)), let milliseconds = report.targetMilliseconds else {
                failures.append("scrub to \(target) did not land")
                continue
            }
            keyframeSeek.append(milliseconds)
            if report.landedPTS != key {
                misses.append(Miss(kind: "keyframe", target: target.seconds, expected: key.seconds, landed: report.landedPTS?.seconds))
            }
            shownKey = key
        }
        // Let the background exact seek after the last scrub settle.
        try await Task.sleep(for: .milliseconds(400))

        var counts = SeekCounts()
        var checked = 0
        var correct = 0
        func exact(_ target: MediaTime, kind: String) async -> SeekReport? {
            try? await Task.sleep(for: pause)
            guard let report = await engine.seekAndWait(.exact(target)), report.targetMilliseconds != nil, !report.cancelled else {
                failures.append("\(kind) exact seek to \(target) did not land")
                return nil
            }
            checked += 1
            let expected = scan.expected(at: target)
            if report.landedPTS == expected {
                correct += 1
            } else {
                misses.append(Miss(kind: kind, target: target.seconds, expected: expected?.seconds, landed: report.landedPTS?.seconds))
            }
            switch report.start {
            case .keyframe: counts.keyframeStarts += 1
            case .continueDecoder: counts.continued += 1
            case .alreadyDisplayed: break
            }
            if report.previewMilliseconds != nil { counts.previews += 1 }
            if report.storeHit { counts.storeHits += 1 }
            counts.framesDecoded += report.framesDecoded
            counts.framesSkipped += report.framesSkipped
            return report
        }

        // Exact seeks to worst-case targets, cycling through the GOPs in a shuffled order.
        let worst = scan.worstCaseTargets
        var exactWorst: [Double] = []
        var exactWorstPreview: [Double] = []
        var order: [MediaTime] = []
        while order.count < runs, !worst.isEmpty {
            var round = worst
            random.shuffle(&round)
            if round.first == order.last, round.count > 1 { round.swapAt(0, round.count - 1) }
            order.append(contentsOf: round)
        }
        for target in order.prefix(runs) {
            guard let report = await exact(target, kind: "worst") else { continue }
            if let milliseconds = report.targetMilliseconds { exactWorst.append(milliseconds) }
            if let preview = report.previewMilliseconds { exactWorstPreview.append(preview) }
        }

        // Exact seeks to random targets.
        var exactRandom: [Double] = []
        for _ in 0..<runs {
            let span = UInt64(max(lastFrame.microseconds - firstKey.microseconds, 1))
            let target = firstKey + MediaTime(microseconds: Int64(random.next() % span))
            if let report = await exact(target, kind: "random"), let milliseconds = report.targetMilliseconds {
                exactRandom.append(milliseconds)
            }
        }

        // Frame correctness: sampled worst-case targets against one sequential software decode.
        var psnr: [PSNRSample] = []
        let sampled = sampleTargets(worst, count: psnrSamples)
        var landedFrames: [(MediaTime, DecodedFrame?)] = []
        for target in sampled {
            _ = await exact(target, kind: "psnr")
            landedFrames.append((target, await engine.lastLandedFrame()))
        }
        await engine.close()
        let references = try await Task.detached(priority: .userInitiated) {
            try sequentialFrames(url, at: sampled)
        }.value
        for (target, frame) in landedFrames {
            let reference = references[target]
            var sample = PSNRSample(target: target.seconds, landed: frame.flatMap { MediaTime($0.presentationTime) }?.seconds, reference: reference.flatMap { MediaTime($0.presentationTime) }?.seconds)
            if let frame, let reference {
                sample.decibels = FrameGrabber.lumaPSNR(frame.pixelBuffer, reference.pixelBuffer).map { $0.isInfinite ? 99 : $0 }
            }
            if (sample.decibels ?? 0) < minimumPSNR || sample.landed != sample.reference {
                failures.append(String(format: "frame at %.3f s: PSNR %.1f dB, landed %@ vs reference %@", target.seconds, sample.decibels ?? 0, "\(sample.landed ?? -1)", "\(sample.reference ?? -1)"))
            }
            psnr.append(sample)
        }

        if checked != correct {
            failures.append("\(checked - correct) of \(checked) exact seeks landed on the wrong frame")
        }
        let limits = thresholds(for: url)
        let firstStats = Stats(firstFrame)
        let keyframeStats = Stats(keyframeSeek)
        let worstStats = Stats(exactWorst)
        var pass: Bool?
        if let limits {
            var ok = failures.isEmpty
            for (name, value, limit) in [
                ("first frame", firstStats.p95, limits.firstFrame),
                ("keyframe seek", keyframeStats.p95, limits.keyframeSeek),
                ("exact worst-case seek", worstStats.p95, limits.exactWorst),
            ] where (value ?? .infinity) > limit {
                ok = false
                failures.append(String(format: "%@ p95 %.1f ms is over %.0f ms", name, value ?? -1, limit))
            }
            pass = ok
        }
        let gop: Double? = scan.keyframes.count > 1
            ? (scan.keyframes[scan.keyframes.count - 1] - firstKey).seconds / Double(scan.keyframes.count - 1) : nil
        return Report(
            file: url.path(percentEncoded: false),
            codec: scan.codec,
            decoder: decoder?.rawValue,
            runs: runs,
            gopSeconds: gop,
            firstFrame: firstStats,
            keyframeSeek: keyframeStats,
            exactWorst: worstStats,
            exactWorstPreview: Stats(exactWorstPreview),
            exactRandom: Stats(exactRandom),
            exactCounts: counts,
            exactChecked: checked,
            exactLandedCorrect: correct,
            misses: misses,
            psnr: psnr,
            thresholds: limits,
            failures: failures,
            pass: pass
        )
    }

    /// `count` targets spread over the list.
    static func sampleTargets(_ targets: [MediaTime], count: Int) -> [MediaTime] {
        guard !targets.isEmpty, count > 0 else { return [] }
        if targets.count <= count { return targets }
        return (0..<count).map { targets[$0 * (targets.count - 1) / max(count - 1, 1)] }
    }

    private final class ReferenceSink: Sendable {
        let wanted: Set<MediaTime>
        let frames = Mutex<[MediaTime: DecodedFrame]>([:])

        init(wanted: Set<MediaTime>) {
            self.wanted = wanted
        }

        var count: Int { frames.withLock { $0.count } }
    }

    /// One libavcodec decode from the first packet, keeping the frames whose pts is in `targets`.
    static func sequentialFrames(_ url: URL, at targets: [MediaTime]) throws -> [MediaTime: DecodedFrame] {
        guard let last = targets.max() else { return [:] }
        let demuxer = try Demuxer(url: url)
        defer { demuxer.stop() }
        guard let format = demuxer.videoFormat, let parameters = demuxer.videoParameters else { throw EngineError.noPlayableStream }
        let sink = ReferenceSink(wanted: Set(targets))
        let decoder = try SoftwareVideoDecoder(parameters: parameters, format: format) { event in
            guard case .frame(let frame) = event, let time = MediaTime(frame.presentationTime), sink.wanted.contains(time) else { return }
            sink.frames.withLock { $0[time] = frame }
        }
        defer { decoder.invalidate() }
        let source = try MediaSource(url: url)
        while let packet = try source.readPacket() {
            guard packet.streamIndex == source.videoStreamIndex else { continue }
            try decoder.decode(format.prepare(packet), generation: 0, output: true)
            while decoder.pendingJobs > 16 { Thread.sleep(forTimeInterval: 0.0005) }
            if let pts = packet.pts, pts > last + .seconds(2), sink.count == sink.wanted.count { break }
        }
        decoder.drainSynchronously()
        return sink.frames.withLock { $0 }
    }

    private static func printText(_ report: Report) {
        func line(_ name: String, _ stats: Stats) {
            guard let p50 = stats.p50, let p95 = stats.p95, let max = stats.max else {
                print("\(name): no samples")
                return
            }
            print(String(format: "%@: p50 %.1f ms, p95 %.1f ms, max %.1f ms (%d runs)", name, p50, p95, max, stats.count))
        }
        print("\(report.file): \(report.codec), \(report.decoder ?? "?") decoder, GOP \(String(format: "%.2f", report.gopSeconds ?? 0)) s")
        line("first frame after open", report.firstFrame)
        line("keyframe seek", report.keyframeSeek)
        line("exact seek, worst case", report.exactWorst)
        line("  keyframe preview", report.exactWorstPreview)
        line("exact seek, random", report.exactRandom)
        print("exact seeks landed on the expected frame: \(report.exactLandedCorrect) of \(report.exactChecked)")
        for sample in report.psnr {
            print(String(format: "  PSNR at %.3f s: %.1f dB", sample.target, sample.decibels ?? 0))
        }
        if let thresholds = report.thresholds {
            print(String(format: "thresholds: first frame %.0f, keyframe %.0f, exact %.0f ms", thresholds.firstFrame, thresholds.keyframeSeek, thresholds.exactWorst))
        }
        for failure in report.failures { print("FAIL: \(failure)") }
        print(report.pass.map { $0 ? "PASS" : "FAIL" } ?? (report.failures.isEmpty ? "REPORT ONLY" : "FAIL"))
    }
}

/// A small seeded generator so bench targets repeat between runs.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func shuffle<T>(_ array: inout [T]) {
        array.shuffle(using: &self)
    }
}
