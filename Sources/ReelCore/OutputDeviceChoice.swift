import Foundation

/// An audio output device as Core Audio lists it (`kAudioHardwarePropertyDevices`, devices with
/// output streams).
public struct AudioOutputDevice: Sendable, Codable, Hashable, Identifiable {
    /// `kAudioDevicePropertyDeviceUID`, stable across launches.
    public var uid: String
    public var name: String
    /// The system default output device (Sound settings).
    public var isDefault: Bool

    public var id: String { uid }

    public init(uid: String, name: String, isDefault: Bool = false) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
    }
}

/// Settings and Audio, Output Device: follow the system default or keep one device (section 7.11, D67).
public enum OutputDeviceChoice: Sendable, Hashable {
    case systemDefault
    /// A chosen device, stored by UID with its name so it can be listed while unplugged.
    case device(uid: String, name: String)

    public static let systemDefaultTitle = "System Default"
    public static let settingsExplanation = "System Default follows the Sound settings."

    public var uid: String? {
        if case .device(let uid, _) = self { return uid }
        return nil
    }

    /// The menu title: "System Default" or the device's name.
    public var title: String {
        switch self {
        case .systemDefault: OutputDeviceChoice.systemDefaultTitle
        case .device(_, let name): name
        }
    }

    /// Where audio goes with `devices` present now. A chosen device that is missing falls back
    /// to the system default with an OSD; the choice itself is kept for when it returns.
    public func resolve(against devices: [AudioOutputDevice]) -> OutputDeviceResolution {
        let systemDevice = devices.first(where: \.isDefault)
        switch self {
        case .systemDefault:
            return OutputDeviceResolution(uid: nil, name: systemDevice?.name, isFallback: false)
        case .device(let uid, _):
            if let device = devices.first(where: { $0.uid == uid }) {
                return OutputDeviceResolution(uid: device.uid, name: device.name, isFallback: false)
            }
            return OutputDeviceResolution(uid: nil, name: systemDevice?.name, isFallback: true)
        }
    }
}

/// The result of `OutputDeviceChoice.resolve(against:)`.
public struct OutputDeviceResolution: Sendable, Hashable {
    /// The UID for `audioOutputDeviceUniqueID`; nil plays on the system default.
    public var uid: String?
    /// The device that plays, when known.
    public var name: String?
    /// The chosen device is missing and the system default plays instead.
    public var isFallback: Bool

    public init(uid: String?, name: String?, isFallback: Bool) {
        self.uid = uid
        self.name = name
        self.isFallback = isFallback
    }

    /// "Audio: MacBook Pro Speakers" when falling back, nil otherwise.
    public var osdText: String? {
        guard isFallback else { return nil }
        return "Audio: \(name ?? OutputDeviceChoice.systemDefaultTitle)"
    }
}

extension OutputDeviceChoice: Codable {
    private enum CodingKeys: String, CodingKey {
        case uid, name
    }

    /// `{}` is the system default; `{"uid": ..., "name": ...}` a chosen device.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let uid = try container.decodeIfPresent(String.self, forKey: .uid), !uid.isEmpty else {
            self = .systemDefault
            return
        }
        self = .device(uid: uid, name: try container.decodeIfPresent(String.self, forKey: .name) ?? uid)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if case .device(let uid, let name) = self {
            try container.encode(uid, forKey: .uid)
            try container.encode(name, forKey: .name)
        }
    }
}
