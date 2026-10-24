import Foundation
import Testing
@testable import ReelCore

@Suite struct IINAWatchLaterTests {
    @Test func fileNameIsUppercaseHexMD5OfThePath() {
        // md5 of "/Users/a/b.mkv" computed with the md5 tool.
        #expect(IINAWatchLater.fileName(forPath: "/Users/a/b.mkv") == "632467BC4D88D0CCD0C493117DEABC6D")
    }

    @Test func parsesStartFromAWatchLaterFile() {
        let text = """
        # /Users/a/b.mkv
        start=1383.456000
        vid=1
        aid=2
        """
        #expect(IINAWatchLater.parseStart(text) == MediaTime.seconds(1383.456))
    }

    @Test func ignoresMissingNegativeAndGarbageValues() {
        #expect(IINAWatchLater.parseStart("") == nil)
        #expect(IINAWatchLater.parseStart("vid=1\naid=2") == nil)
        #expect(IINAWatchLater.parseStart("start=-4") == nil)
        #expect(IINAWatchLater.parseStart("start=abc") == nil)
        #expect(IINAWatchLater.parseStart("start=nan") == nil)
        #expect(IINAWatchLater.parseStart("substart=7") == nil)
    }

    @Test func readsFromAFakeFolderByPathHash() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let media = URL(filePath: "/Users/a/b.mkv")
        try "start=61.5\n".write(
            to: scratch.file("632467BC4D88D0CCD0C493117DEABC6D"), atomically: true, encoding: .utf8
        )
        let reader = IINAWatchLater(directory: scratch.url)
        #expect(try reader.startPosition(forFileAt: media) == MediaTime.seconds(61.5))
        #expect(try reader.startPosition(forFileAt: URL(filePath: "/Users/a/other.mkv")) == nil)
    }

    @Test func nilDirectoryDisablesTheFallback() throws {
        let reader = IINAWatchLater(directory: nil)
        #expect(try reader.startPosition(forFileAt: URL(filePath: "/Users/a/b.mkv")) == nil)
        #expect(reader.fileURL(forPath: "/x") == nil)
    }

    @Test func environmentSelectsTheFolder() throws {
        let disabled = IINAWatchLater(environment: ReelEnvironment(["REEL_IINA_WATCH_LATER": ""]))
        #expect(disabled.directory == nil)
        let fake = IINAWatchLater(environment: ReelEnvironment(["REEL_IINA_WATCH_LATER": "/tmp/fake-wl"]))
        #expect(fake.directory == URL(filePath: "/tmp/fake-wl", directoryHint: .isDirectory))
        let standard = IINAWatchLater(environment: ReelEnvironment(["HOME": "/Users/test"]))
        let expected = URL(
            filePath: "/Users/test/Library/Application Support/com.colliderli.iina/watch_later",
            directoryHint: .isDirectory
        )
        #expect(standard.directory == expected)
    }
}
