import CoreGraphics
import Foundation
import ReelCore

/// Which files Reel opens (design section 5). Used by the Open panel, drag and drop and the
/// file argument on launch.
nonisolated public enum SupportedMedia {
    public static let videoExtensions: [String] = [
        "mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "m2v", "ogv",
    ]
    public static let audioExtensions: [String] = ["ogg", "wav", "mp3", "aac", "flac"]
    public static let allExtensions: Set<String> = Set(videoExtensions + audioExtensions)

    /// A local file whose extension (any case) is one Reel plays.
    public static func isSupported(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath else { return false }
        return allExtensions.contains(url.pathExtension.lowercased())
    }

    /// The first playable file in a drop or an Open panel result. One window, so one file.
    public static func firstPlayable(in urls: [URL]) -> URL? {
        urls.first(where: isSupported)
    }
}

/// What the app binary was asked to do on launch.
nonisolated public enum LaunchRequest: Equatable, Sendable {
    /// The normal app, optionally opening a file.
    case app(file: URL?)
    /// Background screenshot mode: no `NSApplication.run`, no window.
    case shot(ShotOptions)
    case invalid(String)

    /// Parses the arguments after the program name. A relative file path resolves against
    /// `currentDirectory`. Flags AppKit adds (`-NSDocumentRevisionsDebugMode YES`, `-psn_...`)
    /// are skipped.
    public static func parse(_ arguments: [String], currentDirectory: URL) -> LaunchRequest {
        if arguments.contains("--shot") {
            switch ShotOptions.parse(arguments, currentDirectory: currentDirectory) {
            case .success(let options): return .shot(options)
            case .failure(let error): return .invalid(error.message)
            }
        }
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-psn_") {
                index += 1
            } else if argument.hasPrefix("-") {
                // AppKit-style "-Key Value" pairs.
                index += 2
            } else {
                return .app(file: URL(filePath: argument, relativeTo: currentDirectory).absoluteURL)
            }
        }
        return .app(file: nil)
    }
}

/// Window sizing rules for a newly opened video (design section 9.1). Pure so it can be tested.
nonisolated public enum WindowSizing {
    public static let emptySize = CGSize(width: 720, height: 450)
    /// The first open fits the video into this fraction of the screen's visible frame.
    public static let screenFraction: CGFloat = 0.8

    /// First open: the video's display size in points, scaled down to fit 80% of `visible`, centred.
    public static func firstOpenFrame(videoSize: CGSize, visible: CGRect) -> CGRect {
        let size = fit(videoSize, into: CGSize(width: visible.width * screenFraction, height: visible.height * screenFraction))
        return centred(size, at: CGPoint(x: visible.midX, y: visible.midY), clampedTo: visible)
    }

    /// Later opens keep the current centre and width, take the height from the new aspect and
    /// stay on screen.
    public static func laterOpenFrame(videoSize: CGSize, current: CGRect, visible: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return current }
        var size = CGSize(width: current.width, height: (current.width * videoSize.height / videoSize.width).rounded())
        size = fit(size, into: visible.size)
        return centred(size, at: CGPoint(x: current.midX, y: current.midY), clampedTo: visible)
    }

    /// The window scale keys: 0.5, 1 and 2 times the video size, or fit to 80% of the screen.
    public static func scaledFrame(videoSize: CGSize, scale: WindowScale, current: CGRect, visible: CGRect) -> CGRect {
        let size: CGSize
        switch scale {
        case .factor(let factor):
            size = fit(CGSize(width: videoSize.width * factor, height: videoSize.height * factor), into: visible.size)
        case .fitScreen:
            size = fit(videoSize, into: visible.size, allowGrowth: true)
        }
        return centred(size, at: CGPoint(x: current.midX, y: current.midY), clampedTo: visible)
    }

    static func fit(_ size: CGSize, into bounds: CGSize, allowGrowth: Bool = false) -> CGSize {
        guard size.width > 0, size.height > 0 else { return emptySize }
        var scale = min(bounds.width / size.width, bounds.height / size.height)
        if !allowGrowth { scale = min(scale, 1) }
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    public static func centred(_ size: CGSize, at centre: CGPoint, clampedTo visible: CGRect) -> CGRect {
        var origin = CGPoint(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded())
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }
}

/// Local log at `REEL_HOME/logs/reel.log`, rotated at 5 MB, never sent anywhere (design 11.3).
/// Also echoes to stderr.
public nonisolated final class ReelLog: Sendable {
    public static let rotationBytes: UInt64 = 5 * 1024 * 1024

    private let fileURL: URL?
    private let debugEnabled: Bool

    public init(paths: ReelPaths?, debug: Bool = false) {
        fileURL = paths?.logFile
        debugEnabled = debug
    }

    public static let disabled = ReelLog(paths: nil)

    public func info(_ message: String) { write("info", message) }
    public func error(_ message: String) { write("error", message) }
    public func debug(_ message: String) {
        if debugEnabled { write("debug", message) }
    }

    private func write(_ level: String, _ message: String) {
        let line = "\(Date().formatted(.iso8601)) [\(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard let fileURL else { return }
        let manager = FileManager.default
        let path = fileURL.path(percentEncoded: false)
        do {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: path),
               let size = (try manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value,
               size > ReelLog.rotationBytes {
                let rotated = fileURL.appendingPathExtension("1")
                if manager.fileExists(atPath: rotated.path(percentEncoded: false)) {
                    try manager.removeItem(at: rotated)
                }
                try manager.moveItem(at: fileURL, to: rotated)
            }
        } catch {
            FileHandle.standardError.write(Data("log rotation failed: \(error)\n".utf8))
        }
        if !manager.fileExists(atPath: path) {
            manager.createFile(atPath: path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            FileHandle.standardError.write(Data("log write failed: \(error)\n".utf8))
        }
    }
}
