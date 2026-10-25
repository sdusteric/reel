import Foundation
import Testing
@testable import ReelCore

@Suite struct ThumbnailPackTests {
    private func jpeg(_ seed: UInt8, length: Int = 64) -> Data {
        Data([0xFF, 0xD8] + (0..<length).map { UInt8(truncatingIfNeeded: Int($0) &+ Int(seed)) } + [0xFF, 0xD9])
    }

    private func samplePack() -> ThumbnailPack {
        ThumbnailPack(width: 384, height: 216, images: [
            (.seconds(20), jpeg(3)), (.seconds(0.083), jpeg(1)), (.seconds(10), jpeg(2, length: 300)),
        ])
    }

    @Test func roundTripsThroughBytes() throws {
        let pack = samplePack()
        let decoded = try ThumbnailPack(data: pack.encoded)
        #expect(decoded.width == 384)
        #expect(decoded.height == 216)
        #expect(decoded.count == 3)
        #expect(decoded.entries.map(\.pts) == [.seconds(0.083), .seconds(10), .seconds(20)])
        #expect(decoded.image(at: 1).jpeg == jpeg(2, length: 300))
        #expect(decoded.image(at: 1) == ThumbnailImage(jpeg: jpeg(2, length: 300), pts: .seconds(10), width: 384, height: 216))
    }

    @Test func headerLayoutIsStable() throws {
        let data = samplePack().encoded
        #expect(data.prefix(8) == Data("REELTHMB".utf8))
        #expect(Array(data[8..<12]) == [1, 0, 0, 0])
        #expect(Array(data[12..<16]) == [0x80, 0x01, 0, 0])
        #expect(Array(data[20..<24]) == [3, 0, 0, 0])
        let blobs = 68 + 304 + 68
        #expect(data.count == ThumbnailPack.headerSize + 3 * ThumbnailPack.indexEntrySize + blobs)
    }

    @Test func lookupReturnsTheLastAtOrBefore() throws {
        let pack = samplePack()
        #expect(pack.thumbnail(atOrBefore: .seconds(15))?.pts == .seconds(10))
        #expect(pack.thumbnail(atOrBefore: .seconds(10))?.pts == .seconds(10))
        #expect(pack.thumbnail(atOrBefore: .seconds(9.99))?.pts == .seconds(0.083))
        #expect(pack.thumbnail(atOrBefore: .seconds(500))?.pts == .seconds(20))
        // Before the first keyframe the first thumbnail stands in, as a scrub would show it.
        #expect(pack.thumbnail(atOrBefore: .zero)?.pts == .seconds(0.083))
        #expect(ThumbnailPack(width: 384, height: 216, images: []).thumbnail(atOrBefore: .zero) == nil)
    }

    @Test func badDataIsRejected() throws {
        let good = samplePack().encoded
        #expect(throws: ThumbnailPackError.badMagic) { try ThumbnailPack(data: Data("NOTATHMB".utf8) + good.dropFirst(8)) }
        #expect(throws: ThumbnailPackError.truncated) { try ThumbnailPack(data: good.prefix(10)) }
        #expect(throws: ThumbnailPackError.truncated) { try ThumbnailPack(data: good.prefix(30)) }
        var wrongVersion = good
        wrongVersion[8] = 9
        #expect(throws: ThumbnailPackError.unsupportedVersion(9)) { try ThumbnailPack(data: wrongVersion) }
        #expect(throws: (any Error).self) { try ThumbnailPack(data: good.dropLast(5)) }
    }

    @Test func writesAtomicallyAndLoadsMapped() throws {
        let scratch = try ScratchDirectory("reel-thumbs")
        defer { scratch.remove() }
        let paths = ReelPaths(home: scratch.url)
        let key = ContentKey(hex: String(repeating: "ab", count: 32))
        let url = paths.thumbnailPack(for: key)
        try samplePack().write(to: url)
        let loaded = try ThumbnailPack.load(contentsOf: url)
        #expect(loaded.count == 3)
        #expect(loaded.image(at: 2).jpeg == jpeg(3))
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.thumbnailsDirectory.path(percentEncoded: false))
        #expect(files == ["\(key.hex).thumbs"])
    }

    // MARK: Plan

    @Test func fewKeyframesAreAllTaken() {
        let keyframes = (0..<6).map { MediaTime.seconds(Double($0) * 10.4 + 0.083) }
        let plan = ThumbnailPlan(keyframes: keyframes, duration: .seconds(60))
        #expect(plan.times == keyframes)
        #expect(plan.count == 6)
    }

    @Test func manyKeyframesAreCappedAtFourHundred() {
        let keyframes = (0..<2_000).map { MediaTime.seconds(Double($0) * 0.5) }
        let plan = ThumbnailPlan(keyframes: keyframes, duration: .seconds(1_000))
        #expect(plan.count == 400)
        #expect(plan.times.first == .zero)
        #expect(plan.times == plan.times.sorted())
        // Evenly spread: neighbours are 2.5 s apart.
        #expect(plan.times[1] == .seconds(2.5))
        #expect(plan.times.last == .seconds(997.5))
    }

    @Test func unevenKeyframesStillGiveFourHundred() {
        // Dense keyframes in the first minute, sparse after: time sampling alone gives duplicates.
        let dense = (0..<600).map { MediaTime.seconds(Double($0) * 0.1) }
        let sparse = (1...40).map { MediaTime.seconds(60 + Double($0) * 60) }
        let plan = ThumbnailPlan(keyframes: dense + sparse, duration: .seconds(2_460))
        #expect(plan.count == 400)
        #expect(Set(plan.times).count == 400)
        #expect(sparse.allSatisfy { plan.times.contains($0) })
    }

    @Test func coarseToFineVisitsEveryEighthFirst() {
        let order = ThumbnailPlan.coarseToFine(count: 20)
        #expect(order.count == 20)
        #expect(Set(order) == Set(0..<20))
        #expect(Array(order.prefix(3)) == [0, 8, 16])
        #expect(Array(order[3..<5]) == [4, 12])
        #expect(order[5...].prefix(5) == [2, 6, 10, 14, 18])
        #expect(ThumbnailPlan.coarseToFine(count: 0).isEmpty)
    }

    @Test func slotForAHoverIsTheLastKeyframeAtOrBefore() {
        let plan = ThumbnailPlan(keyframes: [.seconds(0), .seconds(5), .seconds(10)], duration: .seconds(15))
        #expect(plan.slot(for: .seconds(7)) == 1)
        #expect(plan.slot(for: .seconds(10)) == 2)
        #expect(plan.slot(for: .seconds(-1)) == 0)
        #expect(ThumbnailPlan(keyframes: [], duration: nil).slot(for: .zero) == nil)
    }
}

@Suite struct ReelPathsM2Tests {
    @Test func thumbnailsLiveUnderCaches() {
        let paths = ReelPaths(home: URL(filePath: "/tmp/reel-home", directoryHint: .isDirectory))
        #expect(paths.thumbnailsDirectory.path(percentEncoded: false).hasSuffix("/reel-home/Caches/thumbnails/"))
        let key = ContentKey(hex: "00ff")
        #expect(paths.thumbnailPack(for: key).lastPathComponent == "00ff.thumbs")
    }

    @Test func screenshotsHonourTheOverride() {
        let override = ReelEnvironment(["REEL_SCREENSHOTS": "/tmp/shots", "HOME": "/Users/test"])
        #expect(override.screenshotsDirectory.path(percentEncoded: false).hasPrefix("/tmp/shots"))
        let tilde = ReelEnvironment(["REEL_SCREENSHOTS": "~/caps", "HOME": "/Users/test"])
        #expect(tilde.screenshotsDirectory.path(percentEncoded: false).hasPrefix("/Users/test/caps"))
        let fallback = ReelEnvironment(["HOME": "/Users/test"])
        #expect(fallback.screenshotsDirectory.path(percentEncoded: false).hasPrefix("/Users/test/Pictures/Reel"))
    }

    @Test func thumbnailsCanBeTurnedOff() {
        #expect(ReelEnvironment(["REEL_NO_THUMBNAILS": "1"]).thumbnailsDisabled)
        #expect(!ReelEnvironment([:]).thumbnailsDisabled)
    }
}
