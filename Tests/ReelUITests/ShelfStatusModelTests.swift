import CoreGraphics
import Foundation
import ImageIO
import ReelCore
import Synchronization
import Testing
@testable import ReelUI

private func testImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    var generator = SystemRandomNumberGenerator()
    for y in stride(from: 0, to: height, by: 4) {
        for x in stride(from: 0, to: width, by: 4) {
            context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                 blue: .random(in: 0...1, using: &generator), alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
    }
    return context.makeImage()!
}

@MainActor
@Suite struct ShelfStatusModelTests {
    private final class Toggle: Sendable {
        let value = Mutex(false)
    }

    private func makeShelfModel(scratch: UIScratch, toggle: Toggle) -> (PlayerModel, ShelfStatusWriter, FakeEngine) {
        let writer = ShelfStatusWriter(directory: scratch.file("status"), appVersion: "9.9")
        let engine = FakeEngine()
        let dependencies = PlayerModel.Dependencies(
            makeEngine: { _ in engine },
            settings: { Settings(showInShelf: toggle.value.withLock { $0 }) },
            resumeStore: ResumeStore(fileURL: scratch.file("resume.json")),
            shelfStatus: writer,
            episodeThumbnail: { _ in testImage(width: 1_280, height: 720) },
            sleep: longSleep
        )
        return (PlayerModel(dependencies: dependencies), writer, engine)
    }

    private func status(_ writer: ShelfStatusWriter) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: writer.statusFile)) as? [String: Any])
    }

    @Test func pauseResumeAndCloseWriteTheStatusWithoutAPathOrName() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, writer, _) = makeShelfModel(scratch: scratch, toggle: Toggle())
        let file = try scratch.makeMediaFile("movie.mkv")
        await model.open(file)
        await waitUntil("playing") { model.playbackState == .playing }
        model.handle(.time(.seconds(60)))
        model.pause()
        let paused = try status(writer)
        #expect(paused["resume_title"] as? String == "movie")
        #expect(paused["remaining_seconds"] as? Int == 540)
        #expect(paused["poster"] == nil)
        model.handle(.time(.seconds(90)))
        model.play()
        #expect(try status(writer)["remaining_seconds"] as? Int == 510)
        model.handle(.time(.seconds(120)))
        await model.close()
        #expect(try status(writer)["remaining_seconds"] as? Int == 480)
        let text = try String(contentsOf: writer.statusFile, encoding: .utf8)
        #expect(!text.contains(scratch.url.path(percentEncoded: false)))
        #expect(!text.contains("file://"))
    }

    @Test func quitWritesTheStatus() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, writer, _) = makeShelfModel(scratch: scratch, toggle: Toggle())
        await model.open(try scratch.makeMediaFile("movie.mkv"))
        await waitUntil("playing") { model.playbackState == .playing }
        model.handle(.time(.seconds(30)))
        model.saveForTermination()
        #expect(try status(writer)["remaining_seconds"] as? Int == 570)
    }

    @Test func posterIsWrittenOnlyWhileTheToggleIsOn() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let toggle = Toggle()
        let (model, writer, _) = makeShelfModel(scratch: scratch, toggle: toggle)
        await model.open(try scratch.makeMediaFile("movie.mkv"))
        await waitUntil("playing") { model.playbackState == .playing }
        model.pause()
        await model.shelfPosterTask?.value
        #expect(!FileManager.default.fileExists(atPath: writer.posterFile.path(percentEncoded: false)), "off by default")

        toggle.value.withLock { $0 = true }
        model.publishShelfStatus()
        await model.shelfPosterTask?.value
        let jpeg = try Data(contentsOf: writer.posterFile)
        #expect(jpeg.count <= ShelfStatusWriter.maxPosterBytes)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width <= ShelfStatusWriter.maxPosterWidth)
        #expect(try status(writer)["poster"] as? String == "reel/poster.jpg")

        toggle.value.withLock { $0 = false }
        model.publishShelfStatus()
        #expect(!FileManager.default.fileExists(atPath: writer.posterFile.path(percentEncoded: false)))
        #expect(try status(writer)["poster"] == nil)
    }

    @Test func posterEncoderStaysUnderTheLimits() throws {
        let jpeg = try #require(ShelfPoster.jpeg(from: testImage(width: 1_920, height: 1_080)))
        #expect(jpeg.count <= ShelfStatusWriter.maxPosterBytes)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 240)
    }
}
