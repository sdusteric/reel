import AppKit
import ReelCore
import ReelUI
import SwiftUI

/// `Reel --settings-shot <out.png> [dark]`: renders the Settings form with `ImageRenderer`, like
/// `--shot`. No window and no run loop. The settings file lives in `REEL_HOME`, which must be set.
@MainActor
enum SettingsShot {
    static func run(arguments: [String]) -> Never {
        guard let out = arguments.first, let home = ProcessInfo.processInfo.environment["REEL_HOME"], !home.isEmpty else {
            FileHandle.standardError.write(Data("Reel: --settings-shot <out.png> [dark] needs REEL_HOME\n".utf8))
            exit(64)
        }
        let dark = arguments.contains("dark")
        let store = SettingsStore(paths: ReelPaths(home: URL(filePath: home, directoryHint: .isDirectory)))
        let model = SettingsModel(store: store, log: .disabled)
        // A fixed device list: the shot never asks Core Audio.
        let devices = OutputDeviceModel(
            stateStore: StateStore(paths: ReelPaths(home: URL(filePath: home, directoryHint: .isDirectory))),
            list: { [AudioOutputDevice(uid: "speakers", name: "MacBook Pro Speakers", isDefault: true)] },
            log: .disabled
        )
        let view = SettingsView(model: model, outputDevices: devices, updates: nil)
            .environment(\.colorScheme, dark ? .dark : .light)
        // The grouped Form is AppKit-backed and ImageRenderer draws it blank, so a hosting view that
        // never joins a window is drawn into a bitmap instead.
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        var image: CGImage?
        appearance?.performAsCurrentDrawingAppearance {
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                image = rep.cgImage
            }
        }
        guard let image else {
            FileHandle.standardError.write(Data("Reel: no image\n".utf8))
            exit(1)
        }
        do {
            try ShotRenderer.writePNG(image, to: URL(filePath: out))
        } catch {
            FileHandle.standardError.write(Data("Reel: \(error)\n".utf8))
            exit(1)
        }
        print("wrote \(out) (\(image.width)x\(image.height))")
        exit(0)
    }
}
