import CoreGraphics
import Foundation
import ImageIO
import ReelCore
import ReelEngine

/// `reelctl thumbs <file> [--runs N] [--fresh-cache] [--out-dir dir] [--decoder hw|sw|auto] [--json]`
/// (design sections 9.4 and 16).
///
/// Each run generates the file's thumbnails with a `ThumbnailGenerator` into the cache under
/// `REEL_HOME` (required, so a bench never writes to the real cache), then loads the pack again
/// to time a cache reload. `--fresh-cache` deletes the file's packs before every run.
///
/// Before the timed runs, one untimed thumbnail is decoded without the cache: in the app the
/// playback engine has already opened the file and loaded VideoToolbox's decoder for the codec
/// when thumbnails start, and the warm-up reproduces that. `--cold` skips it.
enum ThumbsCommand {
    /// Budgets in milliseconds (design section 16, M2 acceptance 3).
    struct Thresholds: Encodable {
        var amortisedP95: Double
        var maxLatency: Double
        var setup: Double
        var cacheReload: Double
        var minLumaStddev: Double

        enum CodingKeys: String, CodingKey {
            case amortisedP95 = "amortised_p95_ms"
            case maxLatency = "max_latency_ms"
            case setup = "setup_ms"
            case cacheReload = "cache_reload_ms"
            case minLumaStddev = "min_luma_stddev"
        }
    }

    static func thresholds(for url: URL) -> Thresholds? {
        let budget: Double
        switch url.lastPathComponent {
        case "hevc10_1080p24.mkv", "h264_1080p30.mp4": budget = 15
        case "av1_2160p60.mkv": budget = 40
        case "vp9_2160p60.webm": budget = 60
        default: return nil
        }
        return Thresholds(amortisedP95: budget, maxLatency: 3 * budget, setup: 150, cacheReload: 50, minLumaStddev: 8)
    }

    struct Stats: Encodable {
        var count: Int
        var p50: Double?
        var p95: Double?
        var max: Double?

        init(_ values: [Double]) {
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
        }
    }

    struct PerThumb: Encodable {
        /// Time from the first submit to the k-th completion, divided by k.
        var amortised: Stats
        /// From reading a thumbnail's keyframe to its stored JPEG.
        var latency: Stats
    }

    struct Run: Encodable {
        var run: Int
        var outcome: String
        var error: String?
        var decoder: String?
        var fromCache: Bool
        var count: Int
        var keyframesTotal: Int
        var generated: Int
        var resumed: Int
        var failed: Int
        var setupMs: Double?
        var openMs: Double?
        var formatMs: Double?
        var sessionMs: Double?
        /// The priming decode of the first keyframe, inside setup.
        var primeMs: Double?
        var planMs: Double?
        var perThumbMs: PerThumb
        var totalMs: Double?
        var cacheReloadMs: Double?

        enum CodingKeys: String, CodingKey {
            case run, outcome, error, decoder, count, generated, resumed, failed
            case fromCache = "from_cache"
            case keyframesTotal = "keyframes_total"
            case setupMs = "setup_ms"
            case openMs = "open_ms"
            case formatMs = "format_ms"
            case sessionMs = "session_ms"
            case primeMs = "prime_ms"
            case planMs = "plan_ms"
            case perThumbMs = "per_thumb_ms"
            case totalMs = "total_ms"
            case cacheReloadMs = "cache_reload_ms"
        }
    }

    struct Report: Encodable {
        var file: String
        var codec: String?
        var decoder: String?
        var runs: Int
        var count: Int
        var keyframesTotal: Int
        var width: Int
        var height: Int
        /// Pixel sizes of the stored JPEGs, decoded back.
        var imageWidths: [Int]
        var imageHeights: [Int]
        var jpegBytesMean: Double?
        var minLumaStddev: Double?
        /// Worst run.
        var setupMs: Double?
        /// Every run's samples together.
        var perThumbMs: PerThumb
        var totalMs: Double?
        var cacheBytes: Int64
        var packBytes: Int64?
        /// Worst run.
        var cacheReloadMs: Double?
        var outDir: String?
        /// The untimed warm-up decode (nil with `--cold`).
        var warmupMs: Double?
        var details: [Run]
        var thresholds: Thresholds?
        var failures: [String]
        var pass: Bool?

        enum CodingKeys: String, CodingKey {
            case file, codec, decoder, runs, count, width, height, details, thresholds, failures, pass
            case keyframesTotal = "keyframes_total"
            case imageWidths = "image_widths"
            case imageHeights = "image_heights"
            case jpegBytesMean = "jpeg_bytes_mean"
            case minLumaStddev = "min_luma_stddev"
            case setupMs = "setup_ms"
            case perThumbMs = "per_thumb_ms"
            case totalMs = "total_ms"
            case cacheBytes = "cache_bytes"
            case packBytes = "pack_bytes"
            case cacheReloadMs = "cache_reload_ms"
            case outDir = "out_dir"
            case warmupMs = "warmup_ms"
        }
    }

    static func run(_ arguments: CommandArguments) async throws -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["REEL_HOME"], !home.isEmpty else {
            FileHandle.standardError.write(Data("reelctl thumbs: set REEL_HOME to a temp dir; the bench writes thumbnail packs there\n".utf8))
            return 2
        }
        let url = try arguments.file()
        let runs = try arguments.int("--runs", default: 1)
        let fresh = arguments.flags.contains("--fresh-cache")
        let outDir = arguments.options["--out-dir"].map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
        var options = ThumbnailGenerator.Options.standard
        options.decoder = try arguments.decoder()

        let paths = ReelPaths(environment: environment)
        let cache = ThumbnailCache(paths: paths)
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try SeekBenchCommand.warmCache(url)
        let key = try ContentKey(contentsOf: url)
        var warmupMs: Double?
        if !arguments.flags.contains("--cold") {
            var warmupOptions = options
            warmupOptions.maximumCount = 1
            let warmup = ThumbnailGenerator(url: url, key: nil, cache: nil, options: warmupOptions)
            warmup.start()
            let report = await warmup.finished()
            if report.finishedNanos >= report.startedNanos, report.startedNanos > 0 {
                warmupMs = Double(report.finishedNanos - report.startedNanos) / 1e6
            }
        }

        var details: [Run] = []
        var amortised: [Double] = []
        var latency: [Double] = []
        var failures: [String] = []
        var codec: String?
        var decoder: String?
        var size = (width: 0, height: 0)
        for index in 1...runs {
            if fresh { cache.remove(key) }
            let generator = ThumbnailGenerator(url: url, key: key, cache: cache, options: options)
            generator.start()
            let report = await generator.finished()
            codec = report.codec ?? codec
            decoder = report.decoder?.rawValue ?? decoder
            size = (report.width, report.height)
            if report.outcome != .completed { failures.append("run \(index): \(report.outcome.rawValue) \(report.error ?? "")") }
            let reload = measureReload(cache: cache, key: key)
            if reload == nil { failures.append("run \(index): no pack to reload") }
            amortised += report.amortisedMilliseconds
            latency += report.latencyMilliseconds
            details.append(Run(
                run: index,
                outcome: report.outcome.rawValue,
                error: report.error,
                decoder: report.decoder?.rawValue,
                fromCache: report.fromCache,
                count: report.fromCache ? report.planned : report.generated + report.resumed,
                keyframesTotal: report.keyframesTotal,
                generated: report.generated,
                resumed: report.resumed,
                failed: report.failedSlots,
                setupMs: report.setupMilliseconds,
                openMs: report.openNanos.map { Double($0) / 1e6 },
                formatMs: report.formatNanos.map { Double($0) / 1e6 },
                sessionMs: report.sessionNanos.map { Double($0) / 1e6 },
                primeMs: report.primeNanos.map { Double($0) / 1e6 },
                planMs: report.planNanos.map { Double($0) / 1e6 },
                perThumbMs: PerThumb(amortised: Stats(report.amortisedMilliseconds), latency: Stats(report.latencyMilliseconds)),
                totalMs: report.totalMilliseconds,
                cacheReloadMs: reload
            ))
        }

        let pack = cache.load(key)
        let images = pack.map { pack in (0..<pack.count).map(pack.image(at:)) } ?? []
        let inspected = images.map { inspect($0.jpeg) }
        if let outDir {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            for (index, image) in images.enumerated() {
                let name = String(format: "thumb_%03d_%.3f.jpg", index, image.pts.seconds)
                try image.jpeg.write(to: outDir.appending(path: name, directoryHint: .notDirectory))
            }
        }
        let keyframesTotal = details.map(\.keyframesTotal).max() ?? 0
        let packBytes = (try? FileManager.default.attributesOfItem(atPath: cache.packURL(for: key).path(percentEncoded: false))[.size] as? NSNumber)?.int64Value
        var report = Report(
            file: url.lastPathComponent,
            codec: codec,
            decoder: decoder,
            runs: runs,
            count: images.count,
            keyframesTotal: keyframesTotal,
            width: size.width,
            height: size.height,
            imageWidths: Array(Set(inspected.compactMap { $0?.width })).sorted(),
            imageHeights: Array(Set(inspected.compactMap { $0?.height })).sorted(),
            jpegBytesMean: images.isEmpty ? nil : Double(images.reduce(0) { $0 + $1.jpeg.count }) / Double(images.count),
            minLumaStddev: inspected.compactMap { $0?.lumaStddev }.min(),
            setupMs: details.compactMap(\.setupMs).max(),
            perThumbMs: PerThumb(amortised: Stats(amortised), latency: Stats(latency)),
            totalMs: details.compactMap(\.totalMs).max(),
            cacheBytes: cache.totalBytes,
            packBytes: packBytes,
            cacheReloadMs: details.compactMap(\.cacheReloadMs).max(),
            outDir: outDir?.path(percentEncoded: false),
            warmupMs: warmupMs,
            details: details,
            thresholds: thresholds(for: url),
            failures: failures,
            pass: nil
        )
        check(&report, decodedAll: inspected.allSatisfy { $0 != nil })
        if arguments.json {
            try printJSON(report)
        } else {
            printText(report)
        }
        return report.pass == false || !report.failures.isEmpty ? 1 : 0
    }

    /// Loads the pack from disk and slices every JPEG out of it, as the seek bar would.
    static func measureReload(cache: ThumbnailCache, key: ContentKey) -> Double? {
        let started = DispatchTime.now().uptimeNanoseconds
        guard let pack = cache.load(key) else { return nil }
        var bytes = 0
        for index in 0..<pack.count { bytes += pack.image(at: index).jpeg.count }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        return bytes > 0 || pack.count == 0 ? elapsed : nil
    }

    struct Inspection {
        var width: Int
        var height: Int
        var lumaStddev: Double
    }

    /// Decodes a JPEG and measures its luma spread (a blank or flat image has almost none).
    static func inspect(_ jpeg: Data) -> Inspection? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, !pixels.isEmpty else { return nil }
        let count = Double(pixels.count)
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / count
        let variance = pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / count
        return Inspection(width: width, height: height, lumaStddev: variance.squareRoot())
    }

    static func check(_ report: inout Report, decodedAll: Bool) {
        var failures = report.failures
        let expected = min(report.keyframesTotal, ThumbnailPack.maximumCount)
        if report.count != expected { failures.append("count \(report.count) != min(keyframes_total, 400) = \(expected)") }
        if !decodedAll { failures.append("a stored JPEG does not decode") }
        if report.imageWidths != [ThumbnailPack.standardWidth] { failures.append("image widths \(report.imageWidths), expected [384]") }
        guard let limits = report.thresholds else {
            report.failures = failures
            return
        }
        func over(_ value: Double?, _ limit: Double, _ name: String) {
            guard let value else {
                failures.append("\(name): no measurement")
                return
            }
            if value > limit { failures.append(String(format: "%@ %.1f > %.1f", name, value, limit)) }
        }
        if report.details.allSatisfy(\.fromCache) {
            failures.append("every run loaded the finished pack; pass --fresh-cache to measure generation")
        }
        over(report.perThumbMs.amortised.p95, limits.amortisedP95, "per_thumb_ms.amortised.p95")
        over(report.perThumbMs.latency.max, limits.maxLatency, "per_thumb_ms.latency.max")
        over(report.setupMs, limits.setup, "setup_ms")
        over(report.cacheReloadMs, limits.cacheReload, "cache_reload_ms")
        if let stddev = report.minLumaStddev {
            if stddev < limits.minLumaStddev { failures.append(String(format: "min_luma_stddev %.1f < %.1f", stddev, limits.minLumaStddev)) }
        } else {
            failures.append("min_luma_stddev: no images")
        }
        report.failures = failures
        report.pass = failures.isEmpty
    }

    static func printText(_ report: Report) {
        func format(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "n/a" }
        print("\(report.file) (\(report.codec ?? "?"), \(report.decoder ?? "?")): \(report.count) thumbnails of \(report.keyframesTotal) keyframes, \(report.width)x\(report.height)")
        print("  setup \(format(report.setupMs)) ms, total \(format(report.totalMs)) ms, reload \(format(report.cacheReloadMs)) ms")
        let amortised = report.perThumbMs.amortised
        let latency = report.perThumbMs.latency
        print("  per thumb amortised p50 \(format(amortised.p50)) p95 \(format(amortised.p95)) max \(format(amortised.max)) ms")
        print("  per thumb latency p50 \(format(latency.p50)) p95 \(format(latency.p95)) max \(format(latency.max)) ms")
        print("  min luma stddev \(format(report.minLumaStddev)), cache \(report.cacheBytes) bytes")
        for failure in report.failures { print("  FAIL \(failure)") }
        if let pass = report.pass { print(pass ? "PASS" : "FAIL") }
    }
}
