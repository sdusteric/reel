import Foundation
import Testing
@testable import ReelCore

@Suite struct SettingsStoreTests {
    @Test func defaultsMatchTheDesign() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = SettingsStore(fileURL: scratch.file("settings.json"))
        #expect(try store.load() == .missing)
        #expect(store.settings == Settings(resumePlayback: true, showRemainingTime: true, keyframePreview: true, hardwareDecoding: true))
    }

    @Test func updatesRoundTripThroughTheFile() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = SettingsStore(fileURL: scratch.file("settings.json"))
        try store.update { $0.hardwareDecoding = false }
        try store.update { $0.resumePlayback = false }
        let reopened = SettingsStore(fileURL: scratch.file("settings.json"))
        #expect(try reopened.load() == .loaded)
        #expect(reopened.settings.hardwareDecoding == false)
        #expect(reopened.settings.resumePlayback == false)
        #expect(reopened.settings.keyframePreview == true)
        #expect(try scratch.names() == ["settings.json"])
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try #"{"version": 1, "hardwareDecoding": false}"#.write(
            to: scratch.file("settings.json"), atomically: true, encoding: .utf8
        )
        let store = SettingsStore(fileURL: scratch.file("settings.json"))
        try store.load()
        #expect(store.settings.hardwareDecoding == false)
        #expect(store.settings.resumePlayback == true)
        #expect(store.settings.showRemainingTime == true)
    }

    @Test func corruptFileFallsBackToDefaultsAndKeepsTheBackup() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try "oops".write(to: scratch.file("settings.json"), atomically: true, encoding: .utf8)
        let store = SettingsStore(fileURL: scratch.file("settings.json"))
        guard case .recovered(let moved) = try store.load() else {
            Issue.record("expected recovery")
            return
        }
        #expect(FileManager.default.fileExists(atPath: moved.path(percentEncoded: false)))
        #expect(store.settings == Settings())
    }

    @Test func unchangedUpdateDoesNotWrite() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = SettingsStore(fileURL: scratch.file("settings.json"))
        try store.update { $0.resumePlayback = true }
        #expect(try scratch.names().isEmpty)
    }

    @Test func pathsInitializerUsesSettingsJSON() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        #expect(SettingsStore(paths: ReelPaths(home: scratch.url)).fileURL.lastPathComponent == "settings.json")
    }
}

@Suite struct StateStoreTests {
    @Test func firstRunValuesMatchTheDesign() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = StateStore(fileURL: scratch.file("state.json"))
        #expect(try store.load() == .missing)
        let state = store.state
        #expect(state.volume == 47)
        #expect(state.showRemainingTime)
        #expect(state.windowFrame == nil)
        #expect(state.controllerCenterX == 0.49)
        #expect(state.controllerBottomY == 0.11)
    }

    @Test func roundTripsAllFields() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = StateStore(fileURL: scratch.file("state.json"))
        let frame = WindowFrame(x: 100, y: 200, width: 1920, height: 1080)
        try store.update {
            $0.volume = 63
            $0.showRemainingTime = false
            $0.windowFrame = frame
            $0.controllerCenterX = 0.3
            $0.controllerBottomY = 0.2
        }
        try store.flush()
        let reopened = StateStore(fileURL: scratch.file("state.json"))
        try reopened.load()
        #expect(reopened.state.volume == 63)
        #expect(reopened.state.showRemainingTime == false)
        #expect(reopened.state.windowFrame == frame)
        #expect(reopened.state.controllerCenterX == 0.3)
        #expect(reopened.state.controllerBottomY == 0.2)
    }

    @Test func valuesAreClampedToTheirRanges() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = StateStore(fileURL: scratch.file("state.json"))
        try store.update {
            $0.volume = 140
            $0.controllerCenterX = -2
            $0.controllerBottomY = 7
        }
        #expect(store.state.volume == 100)
        #expect(store.state.controllerCenterX == 0)
        #expect(store.state.controllerBottomY == 1)
        try store.update { $0.volume = -5 }
        #expect(store.state.volume == 0)
        try store.update { $0.volume = .nan }
        #expect(store.state.volume == 47)
    }

    @Test func outOfRangeValuesInTheFileAreClampedOnLoad() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try #"{"version": 1, "volume": 900, "controllerCenterX": 4}"#.write(
            to: scratch.file("state.json"), atomically: true, encoding: .utf8
        )
        let store = StateStore(fileURL: scratch.file("state.json"))
        try store.load()
        #expect(store.state.volume == 100)
        #expect(store.state.controllerCenterX == 1)
        #expect(store.state.controllerBottomY == 0.11)
    }

    @Test func volumeBurstsWriteAtMostOncePerSecond() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let clock = ManualClock()
        let store = StateStore(fileURL: scratch.file("state.json"), now: clock.reader)
        for volume in stride(from: 48.0, through: 60.0, by: 1) {
            clock.advance(by: 0.05)
            try store.update { $0.volume = volume }
        }
        #expect(store.writeCount == 1)
        #expect(store.hasPendingWrite)
        try store.flush()
        #expect(store.writeCount == 2)
        let reopened = StateStore(fileURL: scratch.file("state.json"))
        try reopened.load()
        #expect(reopened.state.volume == 60)
    }

    @Test func corruptFileFallsBackToDefaults() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try "\u{0}\u{1}".write(to: scratch.file("state.json"), atomically: true, encoding: .utf8)
        let store = StateStore(fileURL: scratch.file("state.json"))
        guard case .recovered = try store.load() else {
            Issue.record("expected recovery")
            return
        }
        #expect(store.state == RememberedState())
    }
}
