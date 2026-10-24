import AppKit
import ReelCore
import ReelEngine
import ReelUI

/// The one player window (design 9.1): borderless-feeling, black, sized to the video, with the
/// traffic lights fading together with the SwiftUI chrome.
final class PlayerWindowController: NSWindowController, NSWindowDelegate, PlayerCommandTarget {
    let model: PlayerModel
    private let stateStore: StateStore
    private let log: ReelLog
    private let showSettingsAction: () -> Void
    private var contentView: PlayerContentView?
    private var videoSize: CGSize?

    init(model: PlayerModel, stateStore: StateStore, log: ReelLog, showSettings: @escaping () -> Void) {
        self.model = model
        self.stateStore = stateStore
        self.log = log
        showSettingsAction = showSettings
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
        content.onDrop = { [weak self] url in self?.open(url) }
        content.videoView.onDrop = { [weak self] url in self?.open(url) }
        content.videoView.onDoubleClick = { [weak self] in self?.toggleFullscreen() }
        content.videoView.contextMenuProvider = { [weak self] in self?.contextMenu() }
        window.contentView = content
        contentView = content
        placeEmptyWindow()

        model.onChromeVisibilityChange = { [weak self] visible in self?.chromeVisibilityChanged(visible) }
        model.onOpened = { [weak self] info in self?.fitWindow(to: info) }
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
    /// display awake while playing, rendering into this window's display layer. The engine reads
    /// the decoder and preview settings when it is created, so changes apply to the next file.
    func makeEngine(for url: URL, settings: ReelCore.Settings) async -> any PlayerEngine {
        var configuration = PlaybackEngine.Configuration.playback
        configuration.hardwareDecoding = settings.hardwareDecoding
        configuration.keyframePreview = settings.keyframePreview
        let engine = EngineFactory.makePlaybackEngine(configuration: configuration)
        if let layer = contentView?.videoView.prepareDisplayLayer() {
            await engine.attach(displayLayer: layer)
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
        Task {
            await model.close()
            window?.title = "Reel"
            window?.contentAspectRatio = NSSize(width: 0, height: 0)
            window?.resizeIncrements = NSSize(width: 1, height: 1)
            videoSize = nil
        }
    }

    func showSettings() {
        showSettingsAction()
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

    // MARK: Fullscreen

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    func exitFullscreen() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
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
        if !visible, contentView?.isPointerOverVideo == true {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open\u{2026}", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "")
        let play = menu.addItem(withTitle: model.isPlaying ? "Pause" : "Play", action: #selector(AppDelegate.togglePause(_:)), keyEquivalent: "")
        play.isEnabled = model.hasMedia
        let show = menu.addItem(withTitle: "Show in Finder", action: #selector(AppDelegate.showInFinder(_:)), keyEquivalent: "")
        show.isEnabled = model.hasMedia
        return menu
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

    func windowWillClose(_ notification: Notification) {
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
