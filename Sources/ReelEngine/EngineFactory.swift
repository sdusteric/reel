import CoreGraphics
import Foundation
import ReelCore

/// Entry points the app, shot mode and reelctl use to get an engine and grab frames.
public enum EngineFactory {
    /// Returns an engine ready to open `url`. The app passes `.playback` (audible, keeps the
    /// display awake); tools pass `.headless`.
    public static func make(url: URL, configuration: PlaybackEngine.Configuration = .playback) -> any PlayerEngine {
        makePlaybackEngine(configuration: configuration)
    }

    /// The concrete engine, for callers that attach a display layer or observe frames.
    public static func makePlaybackEngine(configuration: PlaybackEngine.Configuration = .playback) -> PlaybackEngine {
        PlaybackEngine(configuration: configuration)
    }

    /// Decodes the frame displayed at `time` into an image (used by shot mode). Runs off the
    /// calling actor because the decode blocks.
    public static func grabFrame(url: URL, at time: MediaTime) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            try FrameGrabber.grabImage(url: url, at: time)
        }.value
    }
}
