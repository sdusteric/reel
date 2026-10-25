import AppKit
import ReelCore
import ReelEngine
import ReelUI

/// The one player window (design 9.1): borderless-feeling, black, sized to the video, with the
/// traffic lights fading together with the SwiftUI chrome. It owns the outputs of the current
/// engine: the display layer, the subtitle layer and Picture in Picture.
final class PlayerWindowController: NSWindowController, NSWindowDelegate, PlayerCommandTarget {
    let model: PlayerModel
    private let stateStore: StateStore
    private let log: ReelLog
    private let showSettingsAction: () -> Void
    private let screenshots: ScreenshotSaver
    private var contentView: PlayerContentView?
    private var videoSize: CGSize?
    /// The engine of the open file; the model closes it, this keeps its outputs in step.
    private(set) var engine: PlaybackEngine?
    let pictureInPicture: PictureInPicture

    init(
        model: PlayerModel,
        stateStore: StateStore,
        screenshots: ScreenshotSaver,
        log: ReelLog,
        showSettings: @escaping () -> Void
    ) {
        self.model = model
        self.stateStore = stateStore
        self.screenshots = screenshots
        self.log = log
        showSettingsAction = showSettings
        pictureInPicture = PictureInPicture(model: model, log: log)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowSizing.emptySize),
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isRestorable = false
        window.minSize = NSSize(width: 320, height: 200)
        super.init(window: window)
        window.delegate = self

        let actions = SceneActions(toggleFullscreen: { [weak self] in self?.toggleFullscreen() })
        let content = PlayerContentView(model: model, actions: actions, commandTarget: self)
        let open: (URL) -> Void = { [weak self] url in self?.open(url) }
        let useSubtitle: (URL) -> Void = { [weak model] url in model?.useSubtitleFile(url) }
        content.onDrop = open
        content.videoView.onDrop = open
        content.onSubtitleDrop = useSubtitle
        content.videoView.onSubtitleDrop = useSubtitle
        content.videoView.onDoubleClick = { [weak self] in self?.toggleFullscreen() }
        content.videoView.contextMenuProvider = { [weak self] in self.map { MainMenu.contextMenu(model: $0.model) } }
        content.videoView.commandTarget = self
        content.videoView.onLayersResized = { [weak self] in self?.engine?.subtitleLayerDidLayout() }
        window.contentView = content
        contentView = content
        placeEmptyWindow()

        model.onChromeVisibilityChange = { [weak self] visible in self?.chromeVisibilityChanged(visible) }
        model.onOpened = { [weak self] info in self?.fitWindow(to: info) }
        model.onPictureInPictureRequest = { [weak self] wanted in self?.pictureInPicture.toggle(wanted) }
        model.onAddSubtitleFile = { [weak self] in self?.addSubtitleFile() }
        pictureInPicture.onActiveChange = { [weak self] active in
            guard let engine = self?.engine else { return }
            Task { await engine.setPictureInPictureActive(active) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Shows the window without activating the app (activation is the system's call on launch).
    func present() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(contentView)
    }

    // MARK: Engine

    /// The only place the app creates an engine: an audible `PlaybackEngine` that keeps the
    /// display awake while playing, rendering into this window's display and subtitle layers.
    /// The engine reads the decoder and preview settings when it is created, so changes apply to
    /// the next file.
    func makeEngine(for url: URL, settings: ReelCore.Settings) async -> any PlayerEngine {
        var configuration = PlaybackEngine.Configuration.playback
        configuration.hardwareDecoding = settings.hardwareDecoding
        configuration.keyframePreview = settings.keyframePreview
        let engine = EngineFactory.makePlaybackEngine(configuration: configuration)
        pictureInPicture.stop()
        self.engine = engine
        if let layers = contentView?.videoView.prepareLayers() {
            pictureInPicture.attach(layers.display)
            engine.attach(subtitleLayer: layers.subtitles)
            await engine.attach(displayLayer: layers.display)
        }
        return engine
    }

    // MARK: Opening

    func open(_ url: URL) {
        guard SupportedMedia.isSupported(url) else {
            log.info("ignored unsupported file \(url.lastPathComponent)")
            return
        }
        window?.title = url.lastPathComponent
        window?.representedURL = nil
        Task { await model.open(url) }
    }

    func openDocument() {
        OpenAndDrop.runOpenPanel(for: window) { [weak self] url in self?.open(url) }
    }

    func closeFile() {
        pictureInPicture.stop()
        Task {
            await model.close()
            engine = nil
            window?.title = "Reel"
            window?.contentAspectRatio = NSSize(width: 0, height: 0)
            window?.resizeIncrements = NSSize(width: 1, height: 1)
            videoSize = nil
        }
    }

    func showSettings() {
        showSettingsAction()
    }

    /// Add Subtitle File (the panel's footer row and the Subtitles menu).
    func addSubtitleFile() {
        guard model.hasMedia else { return }
        OpenAndDrop.runSubtitlePanel(for: window, videoURL: model.media?.url) { [weak model] url in
            model?.useSubtitleFile(url)
        }
    }

    // MARK: Screenshot

    func takeScreenshot() {
        guard let engine else { return }
        screenshots.take(model: model) { try await engine.takeScreenshot() }
    }

    // MARK: Window sizing

    private var visibleFrame: CGRect {
        (window?.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func placeEmptyWindow() {
        guard let window else { return }
        var frame = CGRect(origin: .zero, size: WindowSizing.emptySize)
        if let saved = stateStore.state.windowFrame {
            frame.origin = CGPoint(x: saved.x + saved.width / 2 - frame.width / 2, y: saved.y + saved.height / 2 - frame.height / 2)
            frame = WindowSizing.centred(frame.size, at: CGPoint(x: frame.midX, y: frame.midY), clampedTo: visibleFrame)
            window.setFrame(window.frameRect(forContentRect: frame), display: false)
        } else {
            window.setContentSize(frame.size)
            window.center()
        }
    }

    private func fitWindow(to info: MediaInfo) {
        guard let window, let video = info.videoStream?.video else { return }
        let display = video.displaySize
        guard display.width > 0, display.height > 0 else { return }
        let backing = window.screen?.backingScaleFactor ?? 1
        // Pixels to points, so a 1080p video opens at 1920x1080 on a 1x display.
        let size = CGSize(width: CGFloat(display.width) / backing, height: CGFloat(display.height) / backing)
        let previous = videoSize
        videoSize = size
        let target: CGRect
        if previous != nil {
            let current = window.contentRect(forFrameRect: window.frame)
            target = WindowSizing.laterOpenFrame(videoSize: size, current: current, visible: visibleFrame)
        } else if let saved = stateStore.state.windowFrame {
            let reference = CGRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            target = WindowSizing.laterOpenFrame(videoSize: size, current: reference, visible: visibleFrame)
        } else {
            target = WindowSizing.firstOpenFrame(videoSize: size, visible: visibleFrame)
        }
        window.contentAspectRatio = size
        guard !window.styleMask.contains(.fullScreen) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().setFrame(window.frameRect(forContentRect: target), display: true)
        }
    }

    func scaleWindow(_ scale: WindowScale) {
        guard let window, let videoSize, !window.styleMask.contains(.fullScreen) else { return }
        let current = window.contentRect(forFrameRect: window.frame)
        let target = WindowSizing.scaledFrame(videoSize: videoSize, scale: scale, current: current, visible: visibleFrame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().setFrame(window.frameRect(forContentRect: target), display: true)
        }
    }

    // MARK: Fullscreen (design 9.1 M2 polish, D41)

    /// The menu bar and the Dock hide in fullscreen and come back at the screen edges.
    static let fullscreenPresentation: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock]

    var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    func exitFullscreen() {
        guard isFullscreen else { return }
        window?.toggleFullScreen(nil)
    }

    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
    ) -> NSApplication.PresentationOptions {
        proposedOptions.union(PlayerWindowController.fullscreenPresentation)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        model.setFullscreen(true)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        model.setFullscreen(false)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        model.setFullscreen(false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        model.setFullscreen(false)
        engine?.subtitleLayerDidLayout()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        engine?.subtitleLayerDidLayout()
    }

    // MARK: Chrome

    private func chromeVisibilityChanged(_ visible: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ChromeVisibility.duration(visible: visible, reduceMotion: reduceMotion)
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            for type in buttons {
                window?.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
            }
        }
        // The cursor hides with the chrome over the picture; in fullscreen the whole screen is
        // the picture, so it hides wherever it is outside the controller.
        if !visible, contentView?.isPointerOverVideo == true || (isFullscreen && !model.chrome.isPointerOverController) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        guard window?.inLiveResize != true else { return }
        saveFrame()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        engine?.subtitleLayerDidLayout()
    }

    /// Closing the window while PiP is active stops PiP and closes the file (design 9.9).
    func windowWillClose(_ notification: Notification) {
        pictureInPicture.stop()
        model.chrome.invalidate()
    }

    private func saveFrame() {
        guard let window, model.hasMedia, !window.styleMask.contains(.fullScreen) else { return }
        // Stored as the content rect, the size the sizing rules work in.
        let frame = window.contentRect(forFrameRect: window.frame)
        do {
            try stateStore.update { state in
                state.windowFrame = WindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            }
        } catch {
            log.error("window frame save failed: \(error)")
        }
    }
}
