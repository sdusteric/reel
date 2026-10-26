import AppKit
import Foundation
import ReelCore
import ReelEngine
import ReelUI

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--version" {
    print("Reel, FFmpeg \(BuildInfo.avformatVersion), \(BuildInfo.ffmpegLicense)")
    exit(0)
}

if arguments.first == "--settings-shot" {
    MainActor.assumeIsolated { SettingsShot.run(arguments: Array(arguments.dropFirst())) }
}

let currentDirectory = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
switch LaunchRequest.parse(arguments, currentDirectory: currentDirectory) {
case .shot(let options):
    // Never reaches NSApplication: no run loop, no window, no activation.
    ShotMode.run(options)
case .invalid(let message):
    FileHandle.standardError.write(Data("Reel: \(message)\n".utf8))
    exit(64)
case .app(let file):
    let application = NSApplication.shared
    let delegate = AppDelegate(initialFile: file)
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
