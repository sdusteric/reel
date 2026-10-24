import AppKit
import ReelCore
import ReelEngine
import ReelUI

/// AppKit lifecycle (design 9.1, D2): one window, the menu bar, the Settings window, and saving
/// on quit. Reel never activates itself; the system does that when the user launches it.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let initialFile: URL?
    private let environment = ReelEnvironment()
    private let log: ReelLog
    private let settingsStore: SettingsStore
    private let stateStore: StateStore
    private let resumeStore: ResumeStore
    private let settingsModel: SettingsModel
    private var model: PlayerModel?
    private var windowController: PlayerWindowController?
    private var settingsWindow: SettingsWindowController?
    private var isTerminating = false
    /// A file AppKit asked to open before the window existed.
    private var pendingOpen: URL?

    init(initialFile: URL?) {
        self.initialFile = initialFile
        let paths = environment.paths
        log = ReelLog(paths: paths, debug: environment.debugLogging)
        do {
            try paths.createDirectories()
        } catch {
            log.error("could not create \(paths.home.path(percentEncoded: false)): \(error)")
        }
        settingsStore = SettingsStore(paths: paths)
        stateStore = StateStore(paths: paths)
        resumeStore = ResumeStore(paths: paths)
        for (name, load) in [("settings", settingsStore.load), ("state", stateStore.load), ("resume", resumeStore.load)] {
            do {
                let outcome = try load()
                if outcome != .loaded, outcome != .missing { log.info("\(name).json: \(outcome)") }
            } catch {
                log.error("\(name).json load failed: \(error)")
            }
        }
        settingsModel = SettingsModel(store: settingsStore, log: log)
        super.init()
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = MainMenu.make()
        let settingsStore = settingsStore
        let dependencies = PlayerModel.Dependencies(
            makeEngine: { [weak self] url in
                let settings = settingsStore.settings
                if let controller = self?.windowController {
                    return await controller.makeEngine(for: url, settings: settings)
                }
                return EngineFactory.make(url: url)
            },
            settings: { settingsStore.settings },
            resumeStore: resumeStore,
            stateStore: stateStore,
            iina: IINAWatchLater(environment: environment),
            log: log
        )
        let model = PlayerModel(dependencies: dependencies)
        self.model = model
        settingsModel.onChange = { [weak model] settings in
            model?.setShowRemainingTime(settings.showRemainingTime)
        }
        let controller = PlayerWindowController(model: model, stateStore: stateStore, log: log) { [weak self] in
            self?.showSettings(nil)
        }
        windowController = controller
        controller.present()
        if let url = pendingOpen ?? initialFile {
            pendingOpen = nil
            controller.open(url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = SupportedMedia.firstPlayable(in: urls) else { return }
        guard let windowController else {
            pendingOpen = url
            return
        }
        // AppKit can also report the launch argument here; it is already open.
        if let initialFile, url.standardizedFileURL == initialFile.standardizedFileURL,
           model?.media?.url.standardizedFileURL == url.standardizedFileURL || model?.playbackState == .opening {
            return
        }
        windowController.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !isTerminating else { return .terminateNow }
        isTerminating = true
        Task {
            await model.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveForTermination()
        do {
            try stateStore.flush()
            try resumeStore.flush()
        } catch {
            log.error("final save failed: \(error)")
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: settingsModel)
        }
        settingsWindow?.showWindow(sender)
    }

    @objc func openDocument(_ sender: Any?) { windowController?.openDocument() }
    @objc func closeFile(_ sender: Any?) { windowController?.closeFile() }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = model?.media?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func togglePause(_ sender: Any?) { perform(.togglePause) }
    @objc func seekForward(_ sender: Any?) { perform(.seek(seconds: PlayerModel.keyboardSeekStep)) }
    @objc func seekBackward(_ sender: Any?) { perform(.seek(seconds: -PlayerModel.keyboardSeekStep)) }
    @objc func frameForward(_ sender: Any?) { perform(.frameStep(forward: true)) }
    @objc func frameBackward(_ sender: Any?) { perform(.frameStep(forward: false)) }
    @objc func volumeUp(_ sender: Any?) { perform(.adjustVolume(delta: 5)) }
    @objc func volumeDown(_ sender: Any?) { perform(.adjustVolume(delta: -5)) }
    @objc func toggleMute(_ sender: Any?) { perform(.toggleMute) }
    @objc func scaleHalf(_ sender: Any?) { perform(.windowScale(.factor(0.5))) }
    @objc func scaleActual(_ sender: Any?) { perform(.windowScale(.factor(1))) }
    @objc func scaleDouble(_ sender: Any?) { perform(.windowScale(.factor(2))) }
    @objc func scaleFit(_ sender: Any?) { perform(.windowScale(.fitScreen)) }
    @objc func toggleFullscreen(_ sender: Any?) { perform(.toggleFullscreen) }

    private func perform(_ action: InputAction) {
        guard let model, let windowController else { return }
        KeyHandling.perform(action, model: model, target: windowController)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let needsMedia: Set<Selector> = [
            #selector(closeFile(_:)), #selector(showInFinder(_:)), #selector(togglePause(_:)),
            #selector(seekForward(_:)), #selector(seekBackward(_:)), #selector(frameForward(_:)),
            #selector(frameBackward(_:)), #selector(scaleHalf(_:)), #selector(scaleActual(_:)),
            #selector(scaleDouble(_:)), #selector(scaleFit(_:)),
        ]
        guard let action = menuItem.action else { return true }
        if action == #selector(togglePause(_:)) {
            menuItem.title = model?.isPlaying == true ? "Pause" : "Play"
        }
        if needsMedia.contains(action) {
            return model?.hasMedia == true
        }
        return true
    }
}
