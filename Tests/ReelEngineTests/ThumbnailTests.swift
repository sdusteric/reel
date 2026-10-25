import CoreGraphics
import Foundation
import ImageIO
import ReelCore
import Testing
@testable import ReelEngine

/// Seek-bar thumbnails (design section 9.4): count, sizes, non-blank images, pts order, the pack
/// cache and its eviction, partial resume, pause and cancel. Budgets are measured by
/// `reelctl thumbs`, not here.
@Suite struct ThumbnailTests {
    /// A temp dir for one test's cache, removed by its exact path.
    struct TempDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "reel-thumbs-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Video key packets in the file, by reading all of it.
    static func keyframeCount(_ url: URL) throws -> Int {
        let source = try MediaSource(url: url)
        var times = Set<MediaTime>()
        while let packet = try source.readPacket() {
            if packet.streamIndex == source.videoStreamIndex, packet.isKeyframe, let time = packet.time { times.insert(time) }
        }
        return times.count
    }

    /// Pixel size and luma standard deviation of a JPEG.
    static func inspect(_ jpeg: Data) -> (width: Int, height: Int, stddev: Double)? {
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
        guard drawn else { return nil }
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        let variance = pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(pixels.count)
        return (width, height, variance.squareRoot())
    }

    static func generate(_ url: URL, key: ContentKey? = nil, cache: ThumbnailCache? = nil, options: ThumbnailGenerator.Options = .standard) async -> (ThumbnailGenerator, ThumbnailGenerator.Report) {
        let generator = ThumbnailGenerator(url: url, key: key, cache: cache, options: options)
        generator.start()
        return (generator, await generator.finished())
    }

    // MARK: Generation

    @Test(arguments: [Fixture.hevc10, .h264, .av1, .vp9, .nocues, .annexB])
    func generatesOneThumbnailPerKeyframe(_ fixture: Fixture) async throws {
        let url = try fixture.url()
        let keyframes = try ThumbnailTests.keyframeCount(url)
        let (generator, report) = await ThumbnailTests.generate(url)
        #expect(report.outcome == .completed, "\(report.error ?? "")")
        #expect(report.keyframesTotal == keyframes)
        #expect(report.planned == min(keyframes, ThumbnailPack.maximumCount))
        #expect(report.generated == report.planned)
        #expect(report.failedSlots == 0)
        #expect(report.decoder == .hardware)
        #expect(report.setupNanos != nil)
        #expect(report.amortisedMilliseconds.count == report.generated)
        #expect(report.latencyMilliseconds.allSatisfy { $0 > 0 })
        #expect(generator.progress == (report.planned, report.planned))

        let pack = try #require(generator.pack())
        #expect(pack.count == report.planned)
        #expect(pack.width == 384)
        #expect(pack.height == 216)
        let times = pack.entries.map(\.pts)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "pts must increase strictly")
        for index in 0..<pack.count {
            let image = pack.image(at: index)
            let inspected = try #require(ThumbnailTests.inspect(image.jpeg))
            #expect(inspected.width == 384)
            #expect(inspected.height == 216)
            #expect(inspected.stddev >= 8, "thumbnail \(index) at \(image.pts) looks blank")
        }
    }

    @Test func completionsFollowTheCoarseToFineOrder() async throws {
        let url = try Fixture.av1.url()
        let (_, report) = await ThumbnailTests.generate(url, options: ThumbnailGenerator.Options(maximumInFlight: 1))
        let slots = report.completions.map(\.slot)
        #expect(slots == ThumbnailPlan.coarseToFine(count: report.planned))
        // Each slot shows a later keyframe than every slot before it.
        let bySlot = report.completions.sorted { $0.slot < $1.slot }.map(\.pts)
        #expect(zip(bySlot, bySlot.dropFirst()).allSatisfy { $0 < $1 })
        #expect(report.completions.allSatisfy { $0.finishedNanos > $0.startedNanos })
    }

    /// Low Power Mode's option (section 7.9): only the coarse pass, every 8th slot, and the pack
    /// is stored as partial so a later full run continues it.
    @Test func coarseOnlyStopsAfterEveryEighthSlot() async throws {
        let url = try Fixture.syncH264.url()
        let (generator, report) = await ThumbnailTests.generate(url, options: ThumbnailGenerator.Options(coarseOnly: true))
        #expect(report.planned > 8)
        let slots = report.completions.map(\.slot)
        #expect(!slots.isEmpty)
        #expect(slots.allSatisfy { $0 % 8 == 0 }, "\(slots)")
        #expect(Set(slots).count == (report.planned + 7) / 8)
        #expect(report.generated == (report.planned + 7) / 8)
        let pack = try #require(generator.pack())
        #expect(pack.count == report.generated, "the pack holds the coarse thumbnails only")
    }

    @Test func openingWindowStaysCoarseAndTheReportTimesTheWholeRun() async throws {
        let url = try Fixture.h264.url()
        let (_, report) = await ThumbnailTests.generate(url)
        let order = ThumbnailPlan.coarseToFine(count: report.planned)
        let window = min(ThumbnailGenerator.Options.standard.maximumInFlight, order.count)
        // The opening window is reordered by packet size, never mixed with later slots.
        #expect(Set(report.completions.prefix(window).map(\.slot)) == Set(order.prefix(window)))
        #expect(report.startedNanos > 0)
        #expect(report.finishedNanos >= report.startedNanos)
        let lastStored = try #require(report.completions.map(\.finishedNanos).max())
        #expect(report.finishedNanos >= lastStored)
    }

    @Test func hoverLookupReturnsTheKeyframeAtOrBefore() async throws {
        let url = try Fixture.hevc10.url()
        let (generator, report) = await ThumbnailTests.generate(url)
        #expect(report.outcome == .completed)
        let pack = try #require(generator.pack())
        let second = pack.entries[1].pts
        #expect(generator.thumbnail(at: second)?.pts == second)
        #expect(generator.thumbnail(at: second + .seconds(1))?.pts == second)
        #expect(generator.thumbnail(at: second - .milliseconds(1))?.pts == pack.entries[0].pts)
        #expect(generator.thumbnail(at: .seconds(10_000))?.pts == pack.entries.last?.pts)
    }

    @Test(arguments: [Fixture.mpeg4, .flv1])
    func softwareDecodesCodecsVideoToolboxCannot(_ fixture: Fixture) async throws {
        let url = try fixture.url()
        let (generator, report) = await ThumbnailTests.generate(url)
        #expect(report.outcome == .completed, "\(report.error ?? "")")
        #expect(report.decoder == .software)
        #expect(report.generated >= 1)
        let pack = try #require(generator.pack())
        let expectedHeight = Int((384.0 * Double(fixture.size.height) / Double(fixture.size.width) / 2).rounded()) * 2
        #expect(pack.height == expectedHeight)
        let inspected = try #require(ThumbnailTests.inspect(pack.image(at: 0).jpeg))
        #expect(inspected.width == 384)
        #expect(inspected.height == expectedHeight)
        #expect(inspected.stddev >= 8)
    }

    @Test func forcedSoftwareGivesTheSameThumbnails() async throws {
        let url = try Fixture.h264.url()
        let (generator, report) = await ThumbnailTests.generate(url, options: ThumbnailGenerator.Options(decoder: .software))
        #expect(report.outcome == .completed, "\(report.error ?? "")")
        #expect(report.decoder == .software)
        let pack = try #require(generator.pack())
        #expect(pack.count == report.planned)
        #expect(pack.count == 6)
        for index in 0..<pack.count {
            let inspected = try #require(ThumbnailTests.inspect(pack.image(at: index).jpeg))
            #expect(inspected.width == 384 && inspected.height == 216)
            #expect(inspected.stddev >= 8)
        }
    }

    @Test func rotatedVideoKeepsItsDisplayOrientation() async throws {
        let url = try Fixture.rot90.url()
        let (generator, report) = await ThumbnailTests.generate(url)
        #expect(report.outcome == .completed, "\(report.error ?? "")")
        // 1280 x 720 shown turned a quarter: 720 x 1280, so 384 x 682.
        let pack = try #require(generator.pack())
        #expect(pack.width == 384)
        #expect(pack.height == 682)
        let inspected = try #require(ThumbnailTests.inspect(pack.image(at: 0).jpeg))
        #expect(inspected.width == 384)
        #expect(inspected.height == 682)
    }

    // MARK: Cache

    @Test func cacheRoundTripSkipsDecoding() async throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let url = try Fixture.hevc10.url()
        let key = try ContentKey(contentsOf: url)
        let cache = ThumbnailCache(directory: directory.url)

        let (first, firstReport) = await ThumbnailTests.generate(url, key: key, cache: cache)
        #expect(firstReport.outcome == .completed)
        #expect(!firstReport.fromCache)
        let written = try #require(first.pack())
        #expect(FileManager.default.fileExists(atPath: cache.packURL(for: key).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: cache.partialURL(for: key).path(percentEncoded: false)))
        #expect(cache.totalBytes == Int64(written.encoded.count))

        let (second, secondReport) = await ThumbnailTests.generate(url, key: key, cache: cache)
        #expect(secondReport.fromCache)
        #expect(secondReport.completions.isEmpty)
        #expect(secondReport.setupNanos == nil, "a cached pack needs no decoder")
        let loaded = try #require(second.pack())
        #expect(loaded.encoded == written.encoded)
        #expect(second.progress == (written.count, written.count))
        #expect(second.thumbnail(at: .seconds(30))?.jpeg == written.thumbnail(atOrBefore: .seconds(30))?.jpeg)
    }

    @Test func partialPackIsResumed() async throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let url = try Fixture.av1.url()
        let key = try ContentKey(contentsOf: url)
        let cache = ThumbnailCache(directory: directory.url)

        let (full, fullReport) = await ThumbnailTests.generate(url)
        #expect(fullReport.outcome == .completed)
        let complete = try #require(full.pack())
        let kept = (0..<3).map { complete.image(at: $0 * 2) }
        let partial = ThumbnailPack(width: complete.width, height: complete.height, images: kept.map { (pts: $0.pts, jpeg: $0.jpeg) })
        try cache.store(partial, for: key, complete: false)
        #expect(cache.load(key) == nil)

        let (resumed, report) = await ThumbnailTests.generate(url, key: key, cache: cache)
        #expect(report.outcome == .completed)
        #expect(report.resumed == 3)
        #expect(report.generated == complete.count - 3)
        let pack = try #require(resumed.pack())
        #expect(pack.entries.map(\.pts) == complete.entries.map(\.pts))
        #expect(pack.image(at: 2).jpeg == kept[1].jpeg, "a resumed thumbnail is reused, not decoded again")
        #expect(cache.load(key) != nil)
        #expect(!FileManager.default.fileExists(atPath: cache.partialURL(for: key).path(percentEncoded: false)))
    }

    @Test func evictionRemovesTheOldestPacksAboveTheCap() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let blob = Data([0xFF, 0xD8] + [UInt8](repeating: 7, count: 10_000) + [0xFF, 0xD9])
        let pack = ThumbnailPack(width: 384, height: 216, images: [(pts: .zero, jpeg: blob)])
        let size = Int64(pack.encoded.count)
        let cache = ThumbnailCache(directory: directory.url, byteLimit: size * 3)
        let keys = (0..<4).map { ContentKey(hex: String(repeating: String($0), count: 64)) }
        for (age, key) in keys.prefix(3).enumerated() {
            try cache.store(pack, for: key, complete: true)
            let date = Date(timeIntervalSinceNow: -Double(1_000 - age * 100))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: cache.packURL(for: key).path(percentEncoded: false))
        }
        #expect(cache.totalBytes == size * 3)
        // Loading the oldest makes it the most recently used, so the second oldest goes first.
        #expect(cache.load(keys[0]) != nil)
        try cache.store(pack, for: keys[3], complete: true)
        #expect(cache.totalBytes == size * 3)
        #expect(cache.load(keys[1]) == nil)
        #expect(cache.load(keys[0]) != nil)
        #expect(cache.load(keys[2]) != nil)
        #expect(cache.load(keys[3]) != nil)
    }

    @Test func theKeptPackSurvivesEvenAboveTheCap() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let pack = ThumbnailPack(width: 384, height: 216, images: [(pts: .zero, jpeg: Data(repeating: 1, count: 5_000))])
        let cache = ThumbnailCache(directory: directory.url, byteLimit: 100)
        let key = ContentKey(hex: String(repeating: "c", count: 64))
        try cache.store(pack, for: key, complete: true)
        #expect(cache.load(key) != nil)
        #expect(cache.evict().count == 1)
        #expect(cache.totalBytes == 0)
    }

    @Test func corruptPacksAreDeletedOnLoad() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let cache = ThumbnailCache(directory: directory.url)
        let key = ContentKey(hex: String(repeating: "d", count: 64))
        try Data("not a pack".utf8).write(to: cache.packURL(for: key))
        #expect(cache.load(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.packURL(for: key).path(percentEncoded: false)))
    }

    @Test func cacheLivesUnderReelHome() {
        let paths = ReelPaths(home: URL(filePath: "/tmp/reel-home-test", directoryHint: .isDirectory))
        let cache = ThumbnailCache(paths: paths)
        let key = ContentKey(hex: "ab")
        #expect(cache.packURL(for: key) == paths.thumbnailPack(for: key))
        #expect(cache.byteLimit == 500_000_000)
        #expect(cache.partialURL(for: key).lastPathComponent == "ab.partial")
    }

    // MARK: Pause and cancel

    @Test func pauseHoldsSubmissionsUntilResume() async throws {
        let url = try Fixture.hevc10.url()
        let generator = ThumbnailGenerator(url: url, key: nil, cache: nil)
        generator.pause()
        generator.start()
        let planned = await instantWhen { generator.progress.total > 0 }
        #expect(planned != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(generator.progress.done == 0)
        generator.resume()
        let report = await generator.finished()
        #expect(report.outcome == .completed)
        #expect(report.generated == report.planned)
    }

    @Test func closeCancelsWithoutStoringAFinishedPack() async throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let url = try Fixture.vp9.url()
        let key = try ContentKey(contentsOf: url)
        let cache = ThumbnailCache(directory: directory.url)
        let generator = ThumbnailGenerator(url: url, key: key, cache: cache)
        generator.pause()
        generator.start()
        _ = await instantWhen { generator.progress.total > 0 }
        generator.close()
        let report = await generator.finished()
        #expect(report.outcome == .cancelled)
        #expect(report.generated == 0)
        #expect(cache.load(key) == nil)
        #expect(generator.thumbnail(at: .zero) == nil)
    }

    @Test func aGeneratorThatNeverStartedFinishesAtOnce() async {
        let generator = ThumbnailGenerator(url: URL(filePath: "/nonexistent.mkv"), key: nil, cache: nil)
        let report = await generator.finished()
        #expect(report.outcome == .cancelled)
    }

    @Test func aMissingFileFails() async {
        let (_, report) = await ThumbnailTests.generate(URL(filePath: "/nonexistent/reel-missing.mkv"))
        #expect(report.outcome == .failed)
        #expect(report.error != nil)
    }
}
