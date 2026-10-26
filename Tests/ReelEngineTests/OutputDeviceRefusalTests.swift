import AVFoundation
import ReelObjCSupport
import ReelObjCTestSupport
import Testing
@testable import ReelEngine

/// A renderer's output device setter can raise an Objective-C exception (a Bluetooth device that is
/// reconnecting). No renderer here is attached to a synchronizer or fed audio.
@Suite struct OutputDeviceRefusalTests {
    struct Refused: Error, CustomStringConvertible {
        var description: String
    }

    @Test func wrapperReturnsNoWithTheExceptionWhenTheSetterRaises() throws {
        let renderer = ReelThrowingAudioRenderer()
        var caught: (any Error)?
        do {
            try ReelObjCSupport.setOutputDevice(on: renderer, uid: "01-29-B5-19-8D-4F:output")
        } catch {
            caught = error
        }
        let text = try #require(caught).localizedDescription
        #expect(text.contains("NSInvalidArgumentException"))
        #expect(text.contains("device not ready"))
    }

    @Test func wrapperSucceedsOnAnOrdinaryRenderer() throws {
        let renderer = AVSampleBufferAudioRenderer()
        // AVFoundation raises for nil on this OS, so only a listed device is set.
        guard let uid = AudioOutputDevices.list().first?.uid else { return }
        try ReelObjCSupport.setOutputDevice(on: renderer, uid: uid)
        #expect(renderer.audioOutputDeviceUniqueID == uid)
    }

    @Test func refusalFallsBackToTheDefaultOutputAndReportsOnce() {
        var slot = RendererDeviceSlot()
        var calls: [String?] = []
        let result = slot.request("bt", defaultUID: { "speakers" }) { uid in
            calls.append(uid)
            if uid == "bt" { throw Refused(description: "device not ready") }
        }
        #expect(result.refusal == OutputRefusal(uid: "bt", reason: "device not ready"))
        #expect(calls == ["bt", "speakers"], "falls back to the pinned default output")
        #expect(slot.applied == "speakers")
    }

    @Test func theChosenDeviceIsTriedAgainOnTheNextRequest() {
        var slot = RendererDeviceSlot()
        var works = false
        let setter: (String?) throws -> Void = { uid in
            if uid == "bt", !works { throw Refused(description: "not ready") }
        }
        #expect(slot.request("bt", defaultUID: { "speakers" }, setter).refusal != nil)
        works = true
        #expect(slot.request("bt", defaultUID: { "speakers" }, setter).refusal == nil, "the device list changed and the device accepts now")
        #expect(slot.applied == "bt")
        #expect(slot.request("bt", defaultUID: { "speakers" }, setter) == DeviceRouteResult())
    }

    @Test func aFailingFallbackSetterDoesNotThrow() {
        var slot = RendererDeviceSlot()
        let result = slot.request("bt", defaultUID: { "speakers" }) { _ in throw Refused(description: "nope") }
        #expect(result.refusal?.uid == "bt")
        #expect(slot.applied == nil)
    }

    @Test func goingBackToTheSystemDefaultPinsTheDefaultOutput() {
        var slot = RendererDeviceSlot()
        var calls: [String?] = []
        let setter: (String?) throws -> Void = { calls.append($0) }
        _ = slot.request("bt", defaultUID: { "speakers" }, setter)
        _ = slot.request(nil, defaultUID: { "speakers" }, setter)
        #expect(calls == ["bt", "speakers"])
        #expect(slot.applied == "speakers")
    }

    @Test func aDefaultChangeRepinsWhileOnTheSystemDefault() {
        var slot = RendererDeviceSlot()
        var calls: [String?] = []
        let setter: (String?) throws -> Void = { calls.append($0) }
        _ = slot.request("bt", defaultUID: { "speakers" }, setter)
        _ = slot.request(nil, defaultUID: { "speakers" }, setter)
        _ = slot.request(nil, defaultUID: { "speakers" }, setter)
        _ = slot.request(nil, defaultUID: { "headphones" }, setter)
        #expect(calls == ["bt", "speakers", "headphones"])
    }

    @Test func aDefaultChangeRepinsTheFallbackWhileTheChosenDeviceKeepsRefusing() {
        var slot = RendererDeviceSlot()
        var calls: [String?] = []
        let setter: (String?) throws -> Void = { uid in
            calls.append(uid)
            if uid == "bt" { throw Refused(description: "not ready") }
        }
        _ = slot.request("bt", defaultUID: { "speakers" }, setter)
        _ = slot.request("bt", defaultUID: { "headphones" }, setter)
        #expect(slot.applied == "headphones")
        #expect(!calls.contains(nil))
    }

    @Test func aFailedDefaultReadLeavesTheDeviceUntouchedAndReportsOnce() {
        var slot = RendererDeviceSlot()
        var calls: [String?] = []
        let setter: (String?) throws -> Void = { calls.append($0) }
        _ = slot.request("bt", defaultUID: { "speakers" }, setter)
        let first = slot.request(nil, defaultUID: { nil }, setter)
        let second = slot.request(nil, defaultUID: { nil }, setter)
        #expect(first.defaultUnreadable)
        #expect(!second.defaultUnreadable, "logged once")
        #expect(calls == ["bt"])
        #expect(slot.applied == "bt")
        let empty = slot.request(nil, defaultUID: { "" }, setter)
        #expect(!empty.defaultUnreadable)
        #expect(!calls.contains(nil) && !calls.contains(""))
    }

    @Test func refusalHasTheOSDTextAndLogLine() {
        let refusal = OutputRefusal(uid: "bt", reason: "device not ready")
        #expect(refusal.logLine(deviceName: "Audioengine 2+") == "audio output: Audioengine 2+ refused, using system output (device not ready)")
    }
}

extension OutputDeviceRefusalTests {
    @Test func theSystemDefaultIsNeverSetOnAFreshRenderer() {
        var slot = RendererDeviceSlot()
        var calls = 0
        #expect(slot.request(nil, defaultUID: { "speakers" }) { _ in calls += 1 } == DeviceRouteResult())
        #expect(calls == 0, "an untouched renderer follows the default itself")
    }

    @Test func defaultOutputUIDMatchesTheListedDefault() {
        let listed = AudioOutputDevices.list().first(where: \.isDefault)?.uid
        #expect(AudioOutputDevices.defaultOutputUID() == listed)
    }
}
