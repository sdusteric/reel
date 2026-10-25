import Foundation
import Testing
@testable import ReelCore

@Suite struct OutputDeviceChoiceTests {
    static let speakers = AudioOutputDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", isDefault: true)
    static let airPods = AudioOutputDevice(uid: "AA-BB-CC:output", name: "AirPods Pro")
    static let display = AudioOutputDevice(uid: "DisplayAudio-1", name: "Display Speakers")

    @Test func aStoredUIDResolvesWhenPresent() {
        let choice = OutputDeviceChoice.device(uid: Self.airPods.uid, name: "AirPods Pro")
        let resolution = choice.resolve(against: [Self.speakers, Self.airPods, Self.display])
        #expect(resolution == OutputDeviceResolution(uid: Self.airPods.uid, name: "AirPods Pro", isFallback: false))
        #expect(resolution.osdText == nil)
    }

    @Test func aMissingDeviceFallsBackToSystemDefaultWithAnOSD() {
        let choice = OutputDeviceChoice.device(uid: Self.airPods.uid, name: "AirPods Pro")
        let resolution = choice.resolve(against: [Self.speakers, Self.display])
        #expect(resolution.uid == nil)
        #expect(resolution.name == "MacBook Pro Speakers")
        #expect(resolution.isFallback)
        #expect(resolution.osdText == "Audio: MacBook Pro Speakers")
        // The choice is kept: it resolves again once the device returns.
        #expect(choice.resolve(against: [Self.speakers, Self.airPods]).uid == Self.airPods.uid)
    }

    @Test func systemDefaultFollowsTheSystem() {
        let resolution = OutputDeviceChoice.systemDefault.resolve(against: [Self.airPods, Self.speakers])
        #expect(resolution == OutputDeviceResolution(uid: nil, name: "MacBook Pro Speakers", isFallback: false))
        #expect(OutputDeviceChoice.systemDefault.resolve(against: []).name == nil)
        #expect(OutputDeviceChoice.device(uid: "x", name: "Gone").resolve(against: []).osdText == "Audio: System Default")
    }

    @Test func titles() {
        #expect(OutputDeviceChoice.systemDefault.title == "System Default")
        #expect(OutputDeviceChoice.device(uid: "u", name: "AirPods Pro").title == "AirPods Pro")
        #expect(OutputDeviceChoice.systemDefault.uid == nil)
        #expect(OutputDeviceChoice.device(uid: "u", name: "n").uid == "u")
    }

    @Test func choiceRoundTripsThroughStateJSON() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = StateStore(fileURL: scratch.file("state.json"))
        #expect(store.state.outputDevice == .systemDefault)
        try store.update { $0.outputDevice = .device(uid: Self.airPods.uid, name: "AirPods Pro") }
        try store.flush()
        let text = try String(contentsOf: scratch.file("state.json"), encoding: .utf8)
        #expect(text.contains(Self.airPods.uid))
        let reopened = StateStore(fileURL: scratch.file("state.json"))
        #expect(try reopened.load() == .loaded)
        #expect(reopened.state.outputDevice == .device(uid: Self.airPods.uid, name: "AirPods Pro"))

        try reopened.update { $0.outputDevice = .systemDefault }
        try reopened.flush()
        let again = StateStore(fileURL: scratch.file("state.json"))
        try again.load()
        #expect(again.state.outputDevice == .systemDefault)
    }

    @Test func anM2StateFileLoadsWithSystemDefault() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try #"{"version": 1, "volume": 60, "autoAdvance": false}"#.write(to: scratch.file("state.json"), atomically: true, encoding: .utf8)
        let store = StateStore(fileURL: scratch.file("state.json"))
        #expect(try store.load() == .loaded)
        #expect(store.state.outputDevice == .systemDefault)
        #expect(store.state.volume == 60)
    }

    @Test func codingShapes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(OutputDeviceChoice.systemDefault), as: UTF8.self) == "{}")
        #expect(String(decoding: try encoder.encode(OutputDeviceChoice.device(uid: "u", name: "n")), as: UTF8.self) == #"{"name":"n","uid":"u"}"#)
        #expect(try JSONDecoder().decode(OutputDeviceChoice.self, from: Data(#"{"uid":""}"#.utf8)) == .systemDefault)
        #expect(try JSONDecoder().decode(OutputDeviceChoice.self, from: Data(#"{"uid":"u"}"#.utf8)) == .device(uid: "u", name: "u"))
    }
}
