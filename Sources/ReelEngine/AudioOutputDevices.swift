import CoreAudio
import Foundation
import ReelCore
import Synchronization

/// The audio output devices Core Audio knows (section 7.11, D67). Only property reads: no device
/// is opened, started or attached, so listing makes no sound and needs no permission.
public enum AudioOutputDevices {
    /// Every device with at least one output stream, in Core Audio's order, with the system
    /// default output device marked.
    public static func list() -> [AudioOutputDevice] {
        let defaultID = defaultOutputDeviceID()
        return deviceIDs().compactMap { id in
            guard hasOutputStreams(id), let uid = string(id, selector: kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            let name = string(id, selector: kAudioObjectPropertyName).flatMap { $0.isEmpty ? nil : $0 } ?? uid
            return AudioOutputDevice(uid: uid, name: name, isDefault: id == defaultID)
        }
    }

    /// `kAudioHardwarePropertyDefaultOutputDevice`, nil when there is none.
    public static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceIDs() -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(kAudioHardwareBadObjectError) }
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// True when the device has an output stream (`kAudioDevicePropertyStreams`, output scope).
    static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    static func string(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Calls `onChange` on `queue` when the device list or the default output device changes (the
/// Core Audio property listeners). Stopped by `stop()` or on deinit.
public final class AudioOutputDeviceListener: Sendable {
    private struct Registration: @unchecked Sendable {
        // Core Audio removes a listener block by identity, so the exact block is kept.
        let block: AudioObjectPropertyListenerBlock
        let queue: DispatchQueue
    }

    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]
    private let registration = Mutex<Registration?>(nil)

    public init(queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in AudioOutputDeviceListener.selectors {
            var address = AudioOutputDevices.globalAddress(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, queue, block)
        }
        registration.withLock { $0 = Registration(block: block, queue: queue) }
    }

    deinit {
        stop()
    }

    public func stop() {
        guard let current = registration.withLock({ value -> Registration? in
            defer { value = nil }
            return value
        }) else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in AudioOutputDeviceListener.selectors {
            var address = AudioOutputDevices.globalAddress(selector)
            AudioObjectRemovePropertyListenerBlock(system, &address, current.queue, current.block)
        }
    }
}
