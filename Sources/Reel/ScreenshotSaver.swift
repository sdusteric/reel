import AppKit
import ReelCore
import ReelEngine
import ReelUI

/// Cmd+S (design 9.12, D43): the engine writes the frame on screen, with its subtitle, as a PNG
/// to `REEL_SCREENSHOTS`, `REEL_HOME/Screenshots` or ~/Pictures/Reel. No sound and no flash; the OSD confirms with Show.
@MainActor
final class ScreenshotSaver {
    /// Writes the PNG and returns where it went.
    typealias Capture = () async throws -> URL

    private let directory: URL
    private let log: ReelLog
    private let reveal: (URL) -> Void
    private var inFlight = false

    init(
        environment: ReelEnvironment,
        log: ReelLog,
        reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) {
        directory = environment.screenshotsDirectory
        self.log = log
        self.reveal = reveal
    }

    /// The folder the menu's Show Screenshots in Finder opens.
    var screenshotsDirectory: URL { directory }

    /// Takes one screenshot through `capture`; a second Cmd+S while one is being written is ignored.
    func take(model: PlayerModel, capture: @escaping Capture) {
        guard model.hasMedia, !inFlight else { return }
        inFlight = true
        model.onRevealScreenshot = { [reveal] url in reveal(url) }
        Task {
            defer { inFlight = false }
            do {
                let url = try await capture()
                log.info("screenshot saved to \(url.path(percentEncoded: false))")
                model.showScreenshotSaved(at: url)
            } catch {
                log.error("screenshot failed: \(error)")
                model.postOSD(OSDMessage(kind: .screenshot, text: "Screenshot Failed", symbol: "camera"))
            }
        }
    }

    /// Show Screenshots in Finder: the folder if it exists, else its parent (never created here,
    /// so merely looking does not add a folder to ~/Pictures).
    func showFolder() {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([directory.deletingLastPathComponent()])
        }
    }
}
