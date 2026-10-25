import AppKit
import Observation
import ReelCore
import ReelEngine
import ReelUI

/// AppKit lifecycle (design 9.1, D2): one window, the menu bar, the Settings window, Now Playing,
/// the episode folder watch and saving on quit. Reel never activates itself; the system does that
/// when the user launches it.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let initialFile: URL?
    private let environment = ReelEnvironment()
    private let log: ReelLog
    private let settingsStore: SettingsStore
    private let stateStore: StateStore
    private let resumeStore: ResumeStore
    private let settingsModel: SettingsModel
    private let trackMenus = TrackMenus()
    private var model: PlayerModel?
    private var windowController: PlayerWindowController?
    private var settingsWindow: SettingsWindowController?
    private var updater: Updater?
    private var episodeNavigator: EpisodeNavigator?
    private var screenshots: ScreenshotSaver?
    private var nowPlaying: NowPlaying?
    private var observers: [AnyObject] = []
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
        updater = Updater.make()
        NSApplication.shared.mainMenu = MainMenu.make(trackMenus: trackMenus, offersUpdates: updater != nil)
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
            log: log,
            episodeList: EpisodeNavigator.scanner(log: log),
            episodeThumbnail: { await EpisodeNavigator.cardThumbnail(for: $0) }
        )
        let model = PlayerModel(dependencies: dependencies)
        self.model = model
        trackMenus.model = model
        settingsModel.onChange = { [weak model] settings in
            model?.setShowRemainingTime(settings.showRemainingTime)
        }
        let screenshots = ScreenshotSaver(environment: environment, log: log)
        self.screenshots = screenshots
        let controller = PlayerWindowController(model: model, stateStore: stateStore, screenshots: screenshots, log: log) { [weak self] in
            self?.showSettings(nil)
        }
        windowController = controller
        startObserving(model, controller: controller)
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
        windowController?.pictureInPicture.stop()
        nowPlaying?.clear()
        Task {
            await model.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveForTermination()
        episodeNavigator?.stop()
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

    // MARK: Observing the model

    /// The folder watch, Now Playing and the PiP controls follow the model.
    private func startObserving(_ model: PlayerModel, controller: PlayerWindowController) {
        let navigator = EpisodeNavigator(log: log)
        navigator.onFolderChange = { [weak model] in
            guard let model else { return }
            Task { await model.refreshEpisodes() }
        }
        episodeNavigator = navigator
        observers.append(ModelObserver(read: { model.media?.url }, onChange: { url in
            navigator.watch(fileAt: url)
        }))

        let nowPlaying = NowPlaying(publisher: SystemNowPlayingPublisher(), commands: SystemRemoteCommands())
        self.nowPlaying = nowPlaying
        nowPlaying.onTick = { [weak self] in self?.refreshNowPlaying() }
        observers.append(ModelObserver(read: { NowPlayingKey(model) }, onChange: { [weak self] _ in
            self?.refreshNowPlaying()
            controller.pictureInPicture.refresh()
        }))
    }

    private func refreshNowPlaying() {
        guard let model, let nowPlaying else { return }
        guard model.hasMedia else {
            nowPlaying.clear()
            return
        }
        let engine = windowController?.engine
        let position = model.position
        Task {
            let artwork = await engine?.thumbnail(at: position)?.jpeg
            nowPlaying.update(NowPlaying.state(for: model, artwork: artwork), model: model)
        }
    }

    // MARK: Menu actions: app and file

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                model: settingsModel, updates: updater.map { UpdateSettingsModel(updater: $0) }
            )
        }
        settingsWindow?.showWindow(sender)
    }

    @objc func checkForUpdates(_ sender: Any?) { updater?.checkForUpdates() }

    @objc func openDocument(_ sender: Any?) { windowController?.openDocument() }
    @objc func closeFile(_ sender: Any?) { windowController?.closeFile() }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = model?.media?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Playback menu

    @objc func togglePause(_ sender: Any?) { perform(.togglePause) }
    @objc func seekForward(_ sender: Any?) { perform(.seek(seconds: PlayerModel.keyboardSeekStep)) }
    @objc func seekBackward(_ sender: Any?) { perform(.seek(seconds: -PlayerModel.keyboardSeekStep)) }
    @objc func frameForward(_ sender: Any?) { perform(.frameStep(forward: true)) }
    @objc func frameBackward(_ sender: Any?) { perform(.frameStep(forward: false)) }
    @objc func nextEpisode(_ sender: Any?) { perform(.episode(forward: true)) }
    @objc func previousEpisode(_ sender: Any?) { perform(.episode(forward: false)) }

    @objc func toggleAutoAdvance(_ sender: Any?) {
        guard let model else { return }
        model.setAutoAdvanceEnabled(!model.autoAdvanceEnabled)
    }

    @objc func doubleSpeed(_ sender: Any?) { model?.doubleSpeed() }
    @objc func halveSpeed(_ sender: Any?) { model?.halveSpeed() }
    @objc func increaseSpeed(_ sender: Any?) { model?.increaseSpeed() }
    @objc func decreaseSpeed(_ sender: Any?) { model?.decreaseSpeed() }
    @objc func resetSpeed(_ sender: Any?) { model?.resetSpeed() }

    @objc func selectSpeedPreset(_ sender: Any?) {
        guard let rate = (sender as? NSMenuItem)?.representedObject as? Double else { return }
        model?.setRate(rate, announce: true)
    }

    @objc func abLoop(_ sender: Any?) { perform(.abLoop) }
    @objc func toggleFileLoop(_ sender: Any?) { perform(.toggleFileLoop) }

    // MARK: Video menu

    @objc func scaleHalf(_ sender: Any?) { perform(.windowScale(.factor(0.5))) }
    @objc func scaleActual(_ sender: Any?) { perform(.windowScale(.factor(1))) }
    @objc func scaleDouble(_ sender: Any?) { perform(.windowScale(.factor(2))) }
    @objc func scaleFit(_ sender: Any?) { perform(.windowScale(.fitScreen)) }
    @objc func toggleFullscreen(_ sender: Any?) { perform(.toggleFullscreen) }
    @objc func togglePictureInPicture(_ sender: Any?) { perform(.togglePictureInPicture) }
    @objc func cycleVideoTrack(_ sender: Any?) { perform(.cycleTrack(.video)) }

    @objc func selectVideoTrack(_ sender: Any?) {
        guard let model, let index = (sender as? NSMenuItem)?.representedObject as? Int,
              let count = model.tracks?.video.count, count > 1 else { return }
        // PlayerModel selects video only by cycling (Ctrl+Cmd+V), so cycle until it lands on the
        // chosen track, at most once round.
        for _ in 0..<count where model.tracks?.selectedVideo != index {
            model.cycleVideo()
        }
    }

    @objc func takeScreenshot(_ sender: Any?) { perform(.screenshot) }
    @objc func showScreenshots(_ sender: Any?) { screenshots?.showFolder() }

    // MARK: Audio menu

    @objc func selectAudioTrack(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        model?.selectAudio(index)
    }

    @objc func cycleAudioTrack(_ sender: Any?) { perform(.cycleTrack(.audio)) }
    @objc func volumeUp(_ sender: Any?) { perform(.adjustVolume(delta: 5)) }
    @objc func volumeDown(_ sender: Any?) { perform(.adjustVolume(delta: -5)) }
    @objc func toggleMute(_ sender: Any?) { perform(.toggleMute) }
    @objc func increaseAudioDelay(_ sender: Any?) { perform(.adjustAudioDelay(seconds: AppDelegate.delayStep)) }
    @objc func decreaseAudioDelay(_ sender: Any?) { perform(.adjustAudioDelay(seconds: -AppDelegate.delayStep)) }
    @objc func resetAudioDelay(_ sender: Any?) { perform(.setAudioDelay(seconds: 0)) }

    // MARK: Subtitles menu

    /// The menus step delays like the plain keys (Shift+X, "(").
    static let delayStep = 0.5

    @objc func selectSubtitleTrack(_ sender: Any?) {
        guard let selection = (sender as? NSMenuItem)?.representedObject as? SubtitleSelection else { return }
        model?.selectSubtitle(selection)
    }

    @objc func cycleSubtitleTrack(_ sender: Any?) { perform(.cycleTrack(.subtitle)) }
    @objc func addSubtitleFile(_ sender: Any?) { windowController?.addSubtitleFile() }
    @objc func toggleSubtitlesVisible(_ sender: Any?) { perform(.toggleSubtitleVisibility) }
    @objc func increaseSubtitleDelay(_ sender: Any?) { perform(.adjustSubtitleDelay(seconds: AppDelegate.delayStep)) }
    @objc func decreaseSubtitleDelay(_ sender: Any?) { perform(.adjustSubtitleDelay(seconds: -AppDelegate.delayStep)) }
    @objc func resetSubtitleDelay(_ sender: Any?) { perform(.setSubtitleDelay(seconds: 0)) }
    @objc func subtitleLarger(_ sender: Any?) { perform(.adjustSubtitleScale(delta: 0.1)) }
    @objc func subtitleSmaller(_ sender: Any?) { perform(.adjustSubtitleScale(delta: -0.1)) }
    @objc func subtitleUp(_ sender: Any?) { perform(.adjustSubtitlePosition(delta: -1)) }
    @objc func subtitleDown(_ sender: Any?) { perform(.adjustSubtitlePosition(delta: 1)) }
    @objc func resetSubtitleStyle(_ sender: Any?) { model?.resetSubtitleStyle() }

    private func perform(_ action: InputAction) {
        guard let model, let windowController else { return }
        KeyHandling.perform(action, model: model, target: windowController)
    }

    // MARK: Validation: enabling, checkmarks and titles that follow the state (design 9.11)

    private static let alwaysEnabled: Set<Selector> = [
        #selector(showSettings(_:)), #selector(checkForUpdates(_:)), #selector(openDocument(_:)),
        #selector(toggleAutoAdvance(_:)), #selector(showScreenshots(_:)), #selector(toggleFullscreen(_:)),
    ]

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        guard let model else { return false }
        updateTitleAndState(menuItem, action: action, model: model)
        if AppDelegate.alwaysEnabled.contains(action) { return true }
        guard model.hasMedia else { return false }
        switch action {
        case #selector(nextEpisode(_:)): return model.hasNextEpisode
        case #selector(previousEpisode(_:)): return model.hasPreviousEpisode
        case #selector(cycleVideoTrack(_:)): return (model.tracks?.video.count ?? 0) > 1
        case #selector(cycleAudioTrack(_:)): return (model.tracks?.audio.count ?? 0) > 1
        case #selector(cycleSubtitleTrack(_:)), #selector(toggleSubtitlesVisible(_:)):
            return !(model.tracks?.subtitles.isEmpty ?? true)
        case #selector(resetAudioDelay(_:)): return model.audioDelay != 0
        case #selector(resetSubtitleDelay(_:)): return model.subtitleDelay != 0
        case #selector(resetSpeed(_:)): return !PlaybackSpeed.isNormal(model.rate)
        case #selector(selectSubtitleTrack(_:)), #selector(selectAudioTrack(_:)), #selector(selectVideoTrack(_:)):
            return menuItem.representedObject != nil
        default: return true
        }
    }

    private func updateTitleAndState(_ menuItem: NSMenuItem, action: Selector, model: PlayerModel) {
        switch action {
        case #selector(togglePause(_:)):
            menuItem.title = model.isPlaying ? "Pause" : "Play"
        case #selector(toggleAutoAdvance(_:)):
            menuItem.state = model.autoAdvanceEnabled ? .on : .off
        case #selector(toggleFileLoop(_:)):
            menuItem.state = model.loop.fileLoop ? .on : .off
        case #selector(abLoop(_:)):
            menuItem.title = model.loop.menuTitle
        case #selector(toggleSubtitlesVisible(_:)):
            menuItem.state = model.tracks?.subtitlesVisible ?? true ? .on : .off
        case #selector(toggleFullscreen(_:)):
            menuItem.title = windowController?.isFullscreen == true ? "Exit Full Screen" : "Enter Full Screen"
        case #selector(togglePictureInPicture(_:)):
            menuItem.title = model.isPictureInPictureActive ? "Exit Picture in Picture" : "Enter Picture in Picture"
        case #selector(selectSpeedPreset(_:)):
            if let rate = menuItem.representedObject as? Double {
                menuItem.state = abs(model.rate - rate) < 0.001 ? .on : .off
            }
        default:
            break
        }
    }
}

/// What Now Playing and the PiP controls show; a change refreshes them. The position is left
/// out on purpose: Now Playing extrapolates it, and seeks show up as state changes.
private struct NowPlayingKey: Equatable {
    var url: URL?
    var title: String?
    var isPlaying: Bool
    var rate: Double
    var state: PlaybackState
    var hasNext: Bool
    var hasPrevious: Bool
    var duration: MediaTime?

    @MainActor
    init(_ model: PlayerModel) {
        url = model.media?.url
        title = model.title
        isPlaying = model.isPlaying
        rate = model.rate
        state = model.playbackState
        hasNext = model.hasNextEpisode
        hasPrevious = model.hasPreviousEpisode
        duration = model.duration
    }
}

/// Calls `onChange` with the value of `read` now and whenever the observed model properties it
/// reads change (Observation; re-armed after every change).
@MainActor
final class ModelObserver<Value: Equatable> {
    private let read: () -> Value
    private let onChange: (Value) -> Void
    private var last: Value?
    private var started = false

    init(read: @escaping () -> Value, onChange: @escaping (Value) -> Void) {
        self.read = read
        self.onChange = onChange
        observe()
    }

    private func observe() {
        let value = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard !started || value != last else { return }
        started = true
        last = value
        onChange(value)
    }
}
