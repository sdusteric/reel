import Foundation
import Testing
@testable import ReelCore

@Suite struct ResumeStoreTests {
    private let key = ContentKey(hex: String(repeating: "ab", count: 32))
    private let otherKey = ContentKey(hex: String(repeating: "cd", count: 32))
    private let duration = MediaTime.seconds(3_600)

    private func makeStore(
        _ scratch: ScratchDirectory,
        clock: ManualClock = ManualClock()
    ) -> ResumeStore {
        ResumeStore(fileURL: scratch.file("resume.json"), now: clock.reader)
    }

    @Test func savesAndReadsBackAPosition() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        let result = try store.record(
            key: key, position: .seconds(754.5), duration: duration, audioStreamIndex: 2, path: "/v/a.mkv"
        )
        #expect(result == .saved)
        let entry = try #require(store.entry(for: key))
        #expect(entry.position == .seconds(754.5))
        #expect(entry.duration == duration)
        #expect(entry.audioStreamIndex == 2)
        #expect(entry.lastPath == "/v/a.mkv")
        #expect(entry.updatedAt == clock.now)
    }

    @Test func positionsUnderFiveSecondsAreNotSaved() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        let result = try store.record(key: key, position: .seconds(4.9), duration: duration, path: "/v/a.mkv")
        #expect(result == .tooEarly)
        #expect(store.entry(for: key) == nil)
        #expect(!store.hasPendingWrite)
        #expect(try scratch.names().isEmpty)
        #expect(try store.record(key: key, position: .seconds(5), duration: duration, path: "/v/a.mkv") == .saved)
    }

    @Test func earlyPositionLeavesAnExistingEntryAlone() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        try store.record(key: key, position: .seconds(900), duration: duration, path: "/v/a.mkv")
        #expect(try store.record(key: key, position: .seconds(2), duration: duration, path: "/v/a.mkv") == .tooEarly)
        #expect(store.entry(for: key)?.position == .seconds(900))
    }

    @Test func withinThirtySecondsOfTheEndDeletesTheEntry() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        try store.record(key: key, position: .seconds(900), duration: duration, path: "/v/a.mkv")
        clock.advance(by: 2)
        let result = try store.record(key: key, position: .seconds(3_571), duration: duration, path: "/v/a.mkv")
        #expect(result == .finished)
        #expect(store.entry(for: key) == nil)
        #expect(store.entryCount == 0)
    }

    @Test func thirtySecondsExactlyFromTheEndStillSaves() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        let result = try store.record(key: key, position: .seconds(3_570), duration: duration, path: "/v/a.mkv")
        #expect(result == .saved)
    }

    @Test func finishedDeletionIsPersisted() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        try store.record(key: key, position: .seconds(900), duration: duration, path: "/v/a.mkv")
        try store.flush()
        clock.advance(by: 5)
        try store.record(key: key, position: .seconds(3_590), duration: duration, path: "/v/a.mkv")
        try store.flush()
        let reopened = makeStore(scratch, clock: clock)
        #expect(try reopened.load() == .loaded)
        #expect(reopened.entry(for: key) == nil)
    }

    @Test func unknownDurationStillSavesAfterFiveSeconds() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        #expect(try store.record(key: key, position: .seconds(60), duration: .zero, path: "/v/live.ts") == .saved)
    }

    @Test func writesAreDebouncedToOnePerSecond() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        try store.record(key: key, position: .seconds(10), duration: duration, path: "/v/a.mkv")
        #expect(store.writeCount == 1)
        for step in 1...9 {
            clock.advance(by: 0.1)
            try store.record(key: key, position: .seconds(10 + Double(step)), duration: duration, path: "/v/a.mkv")
        }
        #expect(store.writeCount == 1)
        #expect(store.hasPendingWrite)
        clock.advance(by: 0.2)
        #expect(try store.flushIfDue())
        #expect(store.writeCount == 2)
        #expect(!store.hasPendingWrite)
        #expect(try !store.flushIfDue())
    }

    @Test func recordWritesAgainOnceTheIntervalHasPassed() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        try store.record(key: key, position: .seconds(10), duration: duration, path: "/v/a.mkv")
        clock.advance(by: 1)
        try store.record(key: key, position: .seconds(11), duration: duration, path: "/v/a.mkv")
        #expect(store.writeCount == 2)
    }

    @Test func flushWritesPendingChangesImmediately() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        try store.record(key: key, position: .seconds(10), duration: duration, path: "/v/a.mkv")
        clock.advance(by: 0.1)
        try store.record(key: key, position: .seconds(77), duration: duration, path: "/v/a.mkv")
        #expect(store.writeCount == 1)
        #expect(try store.flush())
        #expect(store.writeCount == 2)
        #expect(try !store.flush())
        let reopened = makeStore(scratch, clock: clock)
        try reopened.load()
        #expect(reopened.entry(for: key)?.position == .seconds(77))
    }

    @Test func identicalPositionDoesNotRewriteTheFile() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        try store.record(key: key, position: .seconds(10), duration: duration, path: "/v/a.mkv")
        try store.flush()
        let before = store.writeCount
        try store.record(key: key, position: .seconds(10), duration: duration, path: "/v/a.mkv")
        try store.flush()
        #expect(store.writeCount == before)
    }

    @Test func fileHasASchemaVersionAndLeavesNoTempFiles() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        try store.record(key: key, position: .seconds(10), duration: duration, path: "/v/a.mkv")
        #expect(try scratch.names() == ["resume.json"])
        let data = try Data(contentsOf: scratch.file("resume.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 2)
        let entries = try #require(json["entries"] as? [String: Any])
        #expect(entries[key.hex] != nil)
    }

    @Test func entriesSurviveARestart() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        try store.record(key: key, position: .seconds(100), duration: duration, audioStreamIndex: 1, path: "/v/a.mkv")
        try store.record(key: otherKey, position: .seconds(200), duration: duration, path: "/v/b.mkv")
        try store.flush()
        let reopened = makeStore(scratch, clock: clock)
        #expect(try reopened.load() == .loaded)
        #expect(reopened.entryCount == 2)
        #expect(reopened.entry(for: key)?.audioStreamIndex == 1)
        #expect(reopened.entry(for: otherKey)?.lastPath == "/v/b.mkv")
    }

    @Test func missingFileLoadsAsEmpty() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        #expect(try store.load() == .missing)
        #expect(store.entryCount == 0)
    }

    @Test func missingDirectoryIsCreatedOnFirstWrite() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let nested = scratch.file("a/b/resume.json")
        let store = ResumeStore(fileURL: nested)
        try store.record(key: key, position: .seconds(10), duration: duration, path: "/v/a.mkv")
        #expect(FileManager.default.fileExists(atPath: nested.path(percentEncoded: false)))
    }

    @Test func corruptFileIsMovedAsideAndTheStoreStartsEmpty() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try "{ not json".write(to: scratch.file("resume.json"), atomically: true, encoding: .utf8)
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        let outcome = try store.load()
        guard case .recovered(let moved) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(moved.lastPathComponent.hasPrefix("resume.json.corrupt-"))
        #expect(try String(contentsOf: moved, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: scratch.file("resume.json").path(percentEncoded: false)))
        #expect(store.entryCount == 0)
        // The store is usable afterwards.
        try store.record(key: key, position: .seconds(30), duration: duration, path: "/v/a.mkv")
        #expect(try scratch.names().count == 2)
    }

    @Test func wrongShapeCountsAsCorrupt() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try "[1, 2, 3]".write(to: scratch.file("resume.json"), atomically: true, encoding: .utf8)
        let store = makeStore(scratch)
        guard case .recovered = try store.load() else {
            Issue.record("expected recovery")
            return
        }
    }

    @Test func secondCorruptFileDoesNotOverwriteTheFirstBackup() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        for text in ["bad one", "bad two"] {
            try text.write(to: scratch.file("resume.json"), atomically: true, encoding: .utf8)
            try makeStore(scratch, clock: clock).load()
        }
        let backups = try scratch.names().filter { $0.hasPrefix("resume.json.corrupt-") }
        #expect(backups.count == 2)
    }

    @Test func newerSchemaVersionIsKeptAside() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try #"{"version": 99, "entries": {}}"#.write(to: scratch.file("resume.json"), atomically: true, encoding: .utf8)
        let store = makeStore(scratch)
        guard case .newerVersion(let moved) = try store.load() else {
            Issue.record("expected newerVersion")
            return
        }
        #expect(moved.lastPathComponent.hasPrefix("resume.json.newer-"))
        #expect(store.entryCount == 0)
    }

    @Test func writeFailureIsReportedAndLeavesTheChangePending() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        // A regular file where the directory should be makes every write fail.
        try "x".write(to: scratch.file("blocker"), atomically: true, encoding: .utf8)
        let store = ResumeStore(fileURL: scratch.file("blocker/resume.json"))
        #expect(throws: (any Error).self) {
            try store.record(key: key, position: .seconds(10), duration: duration, path: "/v/a.mkv")
        }
        #expect(store.hasPendingWrite)
        #expect(store.entry(for: key)?.position == .seconds(10))
    }

    @Test func removeDeletesAnEntry() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        try store.record(key: key, position: .seconds(100), duration: duration, path: "/v/a.mkv")
        try store.remove(key: key)
        try store.flush()
        #expect(store.entry(for: key) == nil)
    }

    @Test func entriesPastTheLimitDropTheOldest() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        for index in 0..<(ResumeStore.maximumEntries + 3) {
            clock.advance(by: 1)
            let entryKey = ContentKey(hex: String(format: "%064x", index))
            try store.record(key: entryKey, position: .seconds(60), duration: duration, path: "/v/\(index).mkv")
        }
        #expect(store.entryCount == ResumeStore.maximumEntries)
        #expect(store.entry(for: ContentKey(hex: String(format: "%064x", 0))) == nil)
        #expect(store.entry(for: ContentKey(hex: String(format: "%064x", ResumeStore.maximumEntries + 2))) != nil)
    }

    @Test func pathsInitializerUsesResumeJSONUnderHome() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = ResumeStore(paths: ReelPaths(home: scratch.url))
        #expect(store.fileURL.lastPathComponent == "resume.json")
        #expect(store.fileURL.deletingLastPathComponent().standardizedFileURL == scratch.url.standardizedFileURL)
    }

    // MARK: Schema 2

    private var sampleChoices: ResumeChoices {
        ResumeChoices(
            subtitle: .track(TrackIdentity(streamIndex: 3, language: "zho", title: "简英双语", codec: "ass")),
            subtitleDelay: 0.5,
            audioDelay: -0.1,
            subtitleSize: 50,
            subtitlePosition: 98,
            loop: LoopState(start: .seconds(10), end: .seconds(20))
        )
    }

    @Test func choicesAreSavedAndReadBack() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        try store.record(key: key, position: .seconds(100), duration: duration, choices: sampleChoices, path: "/v/a.mkv")
        try store.flush()
        let reopened = makeStore(scratch, clock: clock)
        #expect(try reopened.load() == .loaded)
        #expect(reopened.entry(for: key)?.choices == sampleChoices)
    }

    @Test func recordWithoutChoicesKeepsTheSavedOnes() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        try store.record(key: key, position: .seconds(100), duration: duration, choices: sampleChoices, path: "/v/a.mkv")
        try store.record(key: key, position: .seconds(160), duration: duration, path: "/v/a.mkv")
        #expect(store.entry(for: key)?.position == .seconds(160))
        #expect(store.entry(for: key)?.choices == sampleChoices)
        try store.record(key: key, position: .seconds(170), duration: duration, choices: .empty, path: "/v/a.mkv")
        #expect(store.entry(for: key)?.choices.isEmpty == true)
    }

    @Test func offSubtitleChoiceRoundTrips() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        let choices = ResumeChoices(subtitle: .off)
        try store.record(key: key, position: .seconds(100), duration: duration, choices: choices, path: "/v/a.mkv")
        try store.flush()
        let reopened = makeStore(scratch, clock: clock)
        try reopened.load()
        #expect(reopened.entry(for: key)?.subtitle == .off)
    }

    @Test func updateChoicesNeedsAnExistingEntry() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = makeStore(scratch)
        #expect(try !store.updateChoices(key: key, choices: sampleChoices))
        try store.record(key: key, position: .seconds(100), duration: duration, path: "/v/a.mkv")
        #expect(try store.updateChoices(key: key, choices: sampleChoices))
        #expect(store.entry(for: key)?.subtitleDelay == 0.5)
        #expect(store.entry(for: key)?.position == .seconds(100))
    }

    @Test func versionOneFileLoadsWithEmptyChoicesAndIsWrittenAsVersionTwo() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let v1 = """
            {
              "entries" : {
                "\(key.hex)" : {
                  "audioStreamIndex" : 1,
                  "duration" : 3600000000,
                  "lastPath" : "/v/a.mkv",
                  "position" : 754500000,
                  "updatedAt" : "2026-10-01T10:00:00Z"
                }
              },
              "version" : 1
            }
            """
        try v1.write(to: scratch.file("resume.json"), atomically: true, encoding: .utf8)
        let clock = ManualClock()
        let store = makeStore(scratch, clock: clock)
        #expect(try store.load() == .loaded)
        let entry = try #require(store.entry(for: key))
        #expect(entry.position == .seconds(754.5))
        #expect(entry.audioStreamIndex == 1)
        #expect(entry.choices.isEmpty)
        try store.record(key: otherKey, position: .seconds(50), duration: duration, path: "/v/b.mkv")
        try store.flush()
        let data = try Data(contentsOf: scratch.file("resume.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 2)
        let reopened = makeStore(scratch, clock: clock)
        try reopened.load()
        #expect(reopened.entry(for: key)?.position == .seconds(754.5))
    }
}
