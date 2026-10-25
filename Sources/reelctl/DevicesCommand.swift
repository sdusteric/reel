import Foundation
import ReelCore
import ReelEngine

/// `reelctl devices --json`: the audio output devices from Core Audio (section 7.11). Only
/// property reads: no renderer is attached, no device is opened and nothing plays.
enum DevicesCommand {
    struct Report: Encodable {
        var devices: [AudioOutputDevice]
        var defaultCount: Int
    }

    static func run(_ arguments: CommandArguments) throws -> Int32 {
        guard arguments.positional.isEmpty else { throw UsageError("devices takes no file") }
        let devices = AudioOutputDevices.list()
        if arguments.json {
            try printJSON(Report(devices: devices, defaultCount: devices.filter(\.isDefault).count))
        } else {
            for device in devices {
                print("\(device.isDefault ? "*" : " ") \(device.name)  \(device.uid)")
            }
        }
        return devices.isEmpty ? 1 : 0
    }
}
