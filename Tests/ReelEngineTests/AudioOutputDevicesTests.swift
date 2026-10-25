import Foundation
import ReelCore
import Testing
@testable import ReelEngine

/// Section 7.11: the device list comes from Core Audio property reads only. Nothing here opens a
/// device, attaches a renderer or makes a sound.
@Suite struct AudioOutputDevicesTests {
    @Test func listsOutputDevicesWithUIDsNamesAndOneDefault() {
        let devices = AudioOutputDevices.list()
        // A Mac without any output device (a headless CI host) lists none; this one has speakers.
        guard !devices.isEmpty else { return }
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
        }
        #expect(Set(devices.map(\.uid)).count == devices.count, "UIDs are unique")
        #expect(devices.filter(\.isDefault).count <= 1)
        if AudioOutputDevices.defaultOutputDeviceID() != nil {
            #expect(devices.filter(\.isDefault).count == 1, "the system default output is listed")
        }
    }

    @Test func listingTwiceGivesTheSameDevices() {
        #expect(AudioOutputDevices.list() == AudioOutputDevices.list())
    }

    @Test func listenerRegistersAndStopsWithoutCallingBack() {
        let listener = AudioOutputDeviceListener(queue: DispatchQueue(label: "reel.test.devices")) {}
        listener.stop()
        listener.stop()
    }

    @Test func preferredDeviceIsKeptWithoutAnyRenderer() {
        let previous = AudioOutput.preferredOutputDevice
        defer { AudioOutput.setPreferredOutputDevice(previous) }
        AudioOutput.setPreferredOutputDevice("test-uid")
        #expect(AudioOutput.preferredOutputDevice == "test-uid")
        AudioOutput.setPreferredOutputDevice(nil)
        #expect(AudioOutput.preferredOutputDevice == nil)
        #expect(AudioOutput.attachDecision(mode: .playback, allowsAudio: false, isTestProcess: true) == .none, "tests never get a renderer")
    }
}
