import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import ReelCore
import Testing
@testable import ReelEngine

/// Cmd+S (design section 9.12, D43): the frame on screen at native size with the subtitle, as a
/// PNG in `REEL_SCREENSHOTS`. Every test points that variable at a folder it made.
@Suite struct ScreenshotTests {
    private static func image(at url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Near-white pixels in the bottom quarter.
    private static func whitePixelsInBottomQuarter(_ image: CGImage) throws -> Int {
        let width = image.width
        let height = image.height
        let bytes = try #require(SubtitleInk.rasterize(image, width: width, height: height))
        var count = 0
        for row in (height * 3 / 4)..<height {
            for column in 0..<width {
                let base = (row * width + column) * 4
                if bytes[base] > 230, bytes[base + 1] > 230, bytes[base + 2] > 230 { count += 1 }
            }
        }
        return count
    }

    @Test func fileNamesCarryTheStemAndThePosition() {
        #expect(Screenshot.fileName(stem: "Northern.Line.S01E02", position: .seconds(1_864.5)) == "Northern.Line.S01E02 00-31-04.png")
        #expect(Screenshot.fileName(stem: "film", position: .seconds(3_725)) == "film 01-02-05.png")
        #expect(Screenshot.fileName(stem: "clip", position: .zero) == "clip 00-00-00.png")
    }

    @Test func aScreenshotIsANativeSizePNGInTheScreenshotsFolder() async throws {
        let folder = try TemporaryFolder()
        let shots = folder.url.appending(path: "Screenshots", directoryHint: .isDirectory)
        let engine = M2Engines.make(environment: ["REEL_SCREENSHOTS": shots.path(percentEncoded: false)])
        let url = try Fixture.h264.url()
        _ = try await engine.open(url)
        _ = await engine.seekAndWait(.exact(.seconds(12)))
        let first = try await engine.takeScreenshot()
        #expect(first.deletingLastPathComponent().standardizedFileURL == shots.standardizedFileURL)
        #expect(first.lastPathComponent == "h264_1080p30 00-00-12.png")
        let image = try Self.image(at: first)
        #expect(image.width == 1920 && image.height == 1080)
        let second = try await engine.takeScreenshot()
        #expect(second.lastPathComponent == "h264_1080p30 00-00-12 2.png", "an existing file is never replaced")
        let contents = try FileManager.default.contentsOfDirectory(atPath: shots.path(percentEncoded: false))
        #expect(contents.count == 2)
        await engine.close()
    }

    @Test func theSubtitleIsCompositedAtTheVideosSize() async throws {
        let folder = try TemporaryFolder()
        let engine = M2Engines.make(external: false, environment: ["REEL_SCREENSHOTS": folder.url.path(percentEncoded: false)])
        _ = try await engine.open(SubtitleFixture.tracks.url())
        await engine.selectSubtitle(.embedded(streamIndex: 5))
        _ = await engine.seekAndWait(.exact(.seconds(2)))
        _ = await M2Engines.waitForSubtitle(engine) { $0.bitmap != nil }
        let with = try Self.image(at: try await engine.takeScreenshot())
        await engine.setSubtitlesVisible(false)
        let without = try Self.image(at: try await engine.takeScreenshot())
        #expect(with.width == 1280 && with.height == 720)
        let inked = try Self.whitePixelsInBottomQuarter(with)
        let plain = try Self.whitePixelsInBottomQuarter(without)
        #expect(inked > plain + 1_000, "white text in the bottom quarter: \(inked) against \(plain)")
        await engine.close()
    }

    @Test func shotModeDrawsTheSubtitleThePlayerWouldShow() async throws {
        let tracks = try SubtitleFixture.tracks.url()
        let shown = try #require(try await EngineFactory.renderSubtitle(url: tracks, at: .seconds(2), width: 1280, height: 720))
        #expect(abs(shown.rect.centerX - 640) < 64 && shown.rect.maxY > 540)
        let lifted = try #require(try await EngineFactory.renderSubtitle(url: tracks, at: .seconds(2), width: 1280, height: 720, bottomInset: 200))
        #expect(lifted.rect.maxY < shown.rect.maxY - 100)
        #expect(try await EngineFactory.renderSubtitle(url: tracks, at: .seconds(3.5), width: 1280, height: 720) == nil)
        let pgs = try #require(try await EngineFactory.renderSubtitle(
            url: try SubtitleFixture.pgs.url(), at: .seconds(2), width: 1920, height: 1080, selection: .embedded(streamIndex: 1)
        ))
        #expect(abs(pgs.rect.x - 660) <= 2 && abs(pgs.rect.y - 900) <= 2)
    }

    @Test func noFileIsOpenThrows() async throws {
        let folder = try TemporaryFolder()
        let engine = M2Engines.make(environment: ["REEL_SCREENSHOTS": folder.url.path(percentEncoded: false)])
        await #expect(throws: EngineError.notOpen) { try await engine.takeScreenshot() }
        await engine.close()
    }

    @Test func theScreenshotFolderDefaultsToPicturesReelUnderHome() {
        // Only the path is computed; nothing is written there.
        let environment = ReelEnvironment(["HOME": "/Users/someone"])
        #expect(environment.screenshotsDirectory.path(percentEncoded: false) == "/Users/someone/Pictures/Reel/")
    }
}
