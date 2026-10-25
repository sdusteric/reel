import Foundation

/// Where Reel keeps its files (design section 11.3). Everything lives under `REEL_HOME`,
/// default `~/Library/Application Support/Reel`, so tests isolate state with one variable.
public struct ReelPaths: Sendable, Hashable {
    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    /// Resolves `REEL_HOME`, expanding a leading `~`. Empty or unset means the default.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let value = environment["REEL_HOME"], !value.isEmpty {
            self.init(home: URL(filePath: ReelPaths.expandTilde(value, environment: environment), directoryHint: .isDirectory))
        } else {
            let base = ReelPaths.userHome(environment: environment)
                .appending(path: "Library/Application Support/Reel", directoryHint: .isDirectory)
            self.init(home: base)
        }
    }

    public var settingsFile: URL { home.appending(path: "settings.json", directoryHint: .notDirectory) }
    public var stateFile: URL { home.appending(path: "state.json", directoryHint: .notDirectory) }
    public var resumeFile: URL { home.appending(path: "resume.json", directoryHint: .notDirectory) }
    public var logsDirectory: URL { home.appending(path: "logs", directoryHint: .isDirectory) }
    public var logFile: URL { logsDirectory.appending(path: "reel.log", directoryHint: .notDirectory) }
    public var cachesDirectory: URL { home.appending(path: "Caches", directoryHint: .isDirectory) }
    /// Thumbnail packs, one per content key (design section 11.3).
    public var thumbnailsDirectory: URL { cachesDirectory.appending(path: "thumbnails", directoryHint: .isDirectory) }

    public func thumbnailPack(for key: ContentKey) -> URL {
        thumbnailsDirectory.appending(path: "\(key.hex).\(ThumbnailPack.fileExtension)", directoryHint: .notDirectory)
    }

    /// Creates `home` and `logs` if missing.
    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    static func userHome(environment: [String: String]) -> URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(filePath: home, directoryHint: .isDirectory)
        }
        return URL.homeDirectory
    }

    static func expandTilde(_ path: String, environment: [String: String]) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return userHome(environment: environment).path(percentEncoded: false)
            .appending(path.dropFirst(path == "~" ? 1 : 2))
    }
}

/// The environment switches Reel reads (design section 11.3).
public struct ReelEnvironment: Sendable, Hashable {
    public let values: [String: String]

    public init(_ values: [String: String] = ProcessInfo.processInfo.environment) {
        self.values = values
    }

    public var paths: ReelPaths { ReelPaths(environment: values) }

    /// IINA's mpv watch_later folder, read-only. `REEL_IINA_WATCH_LATER` overrides it and an
    /// empty value disables the carry-over (tests always set it).
    public var iinaWatchLaterDirectory: URL? {
        if let value = values["REEL_IINA_WATCH_LATER"] {
            if value.isEmpty { return nil }
            return URL(filePath: ReelPaths.expandTilde(value, environment: values), directoryHint: .isDirectory)
        }
        return ReelPaths.userHome(environment: values)
            .appending(path: "Library/Application Support/com.colliderli.iina/watch_later", directoryHint: .isDirectory)
    }

    /// Test media directory: `REEL_FIXTURES`, else `build/fixtures` under `repoRoot` when given.
    public func fixturesDirectory(repoRoot: URL? = nil) -> URL? {
        if let value = values["REEL_FIXTURES"], !value.isEmpty {
            return URL(filePath: ReelPaths.expandTilde(value, environment: values), directoryHint: .isDirectory)
        }
        return repoRoot?.appending(path: "build/fixtures", directoryHint: .isDirectory)
    }

    /// `REEL_FORCE_DECODER=hw|sw` overrides the decoder policy for tests and benches.
    public var forcedDecoder: VideoDecoderKind? {
        switch values["REEL_FORCE_DECODER"]?.lowercased() {
        case "hw", "hardware": .hardware
        case "sw", "software": .software
        default: nil
        }
    }

    /// `REEL_ALLOW_AUDIO=1` lets a test or bench attach an audio renderer (then muted, volume 0).
    /// Without it, tests and reelctl attach none, so they stay silent.
    public var allowsAudioOutput: Bool { values["REEL_ALLOW_AUDIO"] == "1" }

    public var debugLogging: Bool { values["REEL_LOG"]?.lowercased() == "debug" }

    /// Cmd+S folder (design section 9.12): `REEL_SCREENSHOTS` when set, else
    /// `REEL_HOME/Screenshots` when `REEL_HOME` is set (so a test or tool with a temp home never
    /// writes to ~/Pictures), else `~/Pictures/Reel`.
    public var screenshotsDirectory: URL {
        if let value = values["REEL_SCREENSHOTS"], !value.isEmpty {
            return URL(filePath: ReelPaths.expandTilde(value, environment: values), directoryHint: .isDirectory)
        }
        if let home = values["REEL_HOME"], !home.isEmpty {
            return paths.home.appending(path: "Screenshots", directoryHint: .isDirectory)
        }
        return ReelPaths.userHome(environment: values).appending(path: "Pictures/Reel", directoryHint: .isDirectory)
    }

    /// `REEL_NO_THUMBNAILS=1` turns background thumbnail generation off (benches that measure
    /// seeks alone).
    public var thumbnailsDisabled: Bool { values["REEL_NO_THUMBNAILS"] == "1" }
}
