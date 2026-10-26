import Foundation
import Testing
@testable import ReelCore

@Suite struct ShelfStatusTests {
    private func writer(_ scratch: ScratchDirectory) -> ShelfStatusWriter {
        ShelfStatusWriter(
            directory: scratch.url.appending(path: "status", directoryHint: .isDirectory),
            appVersion: "1.2.3",
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func jsonShapeMatchesTheContract() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = writer(scratch)
        try writer.write(title: "Northern Line S01E03", position: 600, duration: 2_700)
        let json = try readJSON(writer.statusFile)
        #expect(Set(json.keys) == [
            "schema", "app", "app_version", "updated_at", "resume_title", "remaining_seconds", "position_fraction",
        ])
        #expect(json["schema"] as? Int == 1)
        #expect(json["app"] as? String == "reel")
        #expect(json["app_version"] as? String == "1.2.3")
        #expect(json["updated_at"] as? String == "2027-01-15T08:00:00Z")
        #expect(json["resume_title"] as? String == "Northern Line S01E03")
        #expect(json["remaining_seconds"] as? Int == 2_100)
        let fraction = try #require(json["position_fraction"] as? Double)
        #expect(abs(fraction - 0.2222) < 0.00001)
        let size = try Data(contentsOf: writer.statusFile).count
        #expect(size < ShelfStatus.maxFileBytes)
    }

    @Test func fileModeIs0600AndFolderIsCreated() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = writer(scratch)
        try writer.write(title: "A", position: 0, duration: 10)
        let attributes = try FileManager.default.attributesOfItem(atPath: writer.statusFile.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func atomicReplaceLeavesNoTempFileAndKeepsTheOldFileOnFailure() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = writer(scratch)
        try writer.write(title: "First", position: 1, duration: 10)
        try writer.write(title: "Second", position: 2, duration: 10)
        let names = try FileManager.default.contentsOfDirectory(atPath: writer.directory.path(percentEncoded: false)).sorted()
        #expect(names == ["reel.json"])
        #expect(try readJSON(writer.statusFile)["resume_title"] as? String == "Second")

        // A directory in the temp file's place makes the open fail: the target stays as it was.
        let temp = writer.directory.appending(path: ".reel.json.tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        #expect(throws: ShelfStatusError.self) { try writer.write(title: "Third", position: 3, duration: 10) }
        #expect(try readJSON(writer.statusFile)["resume_title"] as? String == "Second")
    }

    @Test func titleIsCutToEightyCharacters() throws {
        let long = String(repeating: "ab", count: 60)
        #expect(ShelfStatus.cut(long).count == 80)
        #expect(ShelfStatus.cut("  short  ") == "short")
        #expect(ShelfStatus.cut("Coastline Timelapse.mkv") == "Coastline Timelapse")
        #expect(ShelfStatus.cut("Mr. Robot") == "Mr. Robot")
        let emoji = String(repeating: "\u{1F3AC}", count: 100)
        #expect(ShelfStatus.cut(emoji).count == 80)
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = writer(scratch)
        try writer.write(title: long, position: 0, duration: 10)
        #expect((try readJSON(writer.statusFile)["resume_title"] as? String)?.count == 80)
    }

    @Test func valuesAreClamped() {
        let past = ShelfStatus(appVersion: "1", updatedAt: Date(), title: "t", position: 50, duration: 10)
        #expect(past.remainingSeconds == 0)
        #expect(past.positionFraction == 1)
        let unknown = ShelfStatus(appVersion: "1", updatedAt: Date(), title: "t", position: 5, duration: 0)
        #expect(unknown.positionFraction == 0)
    }

    @Test func posterIsWrittenWithTheToggleAndRemovedWithIt() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = writer(scratch)
        try writer.write(title: "A", position: 1, duration: 10)
        #expect(try readJSON(writer.statusFile)["poster"] == nil)
        #expect(!FileManager.default.fileExists(atPath: writer.posterFile.path(percentEncoded: false)))

        try writer.writePoster(Data(repeating: 7, count: 1_000))
        try writer.write(title: "A", position: 2, duration: 10)
        #expect(try readJSON(writer.statusFile)["poster"] as? String == "reel/poster.jpg")
        let attributes = try FileManager.default.attributesOfItem(atPath: writer.posterFile.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        writer.removePoster()
        #expect(!FileManager.default.fileExists(atPath: writer.posterFile.path(percentEncoded: false)))
        try writer.write(title: "A", position: 3, duration: 10)
        #expect(try readJSON(writer.statusFile)["poster"] == nil)
    }

    @Test func oversizePosterIsRefused() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = writer(scratch)
        #expect(throws: ShelfStatusError.posterTooLarge(ShelfStatusWriter.maxPosterBytes + 1)) {
            try writer.writePoster(Data(count: ShelfStatusWriter.maxPosterBytes + 1))
        }
        #expect(!FileManager.default.fileExists(atPath: writer.posterFile.path(percentEncoded: false)))
    }

    @Test func statusFolderFollowsReelHome() {
        let home = URL(filePath: "/tmp/reel-home-x", directoryHint: .isDirectory)
        let followed = ReelEnvironment(["REEL_HOME": home.path(percentEncoded: false)]).shelfStatusDirectory
        #expect(followed.standardizedFileURL == home.appending(path: "Shelf/status", directoryHint: .isDirectory).standardizedFileURL)
        let override = ReelEnvironment(["REEL_HOME": home.path(percentEncoded: false), "REEL_SHELF_STATUS": "/tmp/elsewhere"])
        #expect(override.shelfStatusDirectory.path(percentEncoded: false).hasPrefix("/tmp/elsewhere"))
        let real = ReelEnvironment(["HOME": "/Users/x"]).shelfStatusDirectory.path(percentEncoded: false)
        #expect(real.hasPrefix("/Users/x/Library/Application Support/Shelf/status"))
    }

    @Test func showInShelfDefaultsOff() throws {
        #expect(Settings().showInShelf == false)
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"version": 1}"#.utf8))
        #expect(decoded.showInShelf == false)
    }
}
