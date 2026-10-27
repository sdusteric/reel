import AppKit
import AVFoundation
import ReelCore
import ReelUI
import SwiftUI

/// The window's content view (design 9.1): black and layer-backed, with the SwiftUI scene in an
/// `NSHostingView`. The scene's video surface is `VideoSurfaceView`, which holds the
/// `AVSampleBufferDisplayLayer` and handles clicks, drags and scrolls on the picture.
final class PlayerContentView: DropAcceptingView {
    let model: PlayerModel
    let videoView: VideoSurfaceView
    /// Where the surface sits in the window's scene; the mini player borrows the surface from it.
    let videoSlot = SurfaceSlotView()
    private var hostingView: NSHostingView<PlayerSceneView<SurfaceSlot>>?
    private weak var commandTarget: (any PlayerCommandTarget)?
    /// The pointer moved in the window (the paused thumbnail rule, section 7.9).
    var onPointerActivity: (() -> Void)?

    init(model: PlayerModel, actions: SceneActions, commandTarget: any PlayerCommandTarget) {
        self.model = model
        self.commandTarget = commandTarget
        videoView = VideoSurfaceView(model: model)
        super.init(frame: NSRect(origin: .zero, size: WindowSizing.emptySize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoSlot.host(videoView)
        let slot = videoSlot
        let hosting = NSHostingView(rootView: PlayerSceneView(model: model, actions: actions) {
            SurfaceSlot(view: slot)
        })
        hosting.sizingOptions = []
        // The scene draws under the transparent title bar; without this the picture is laid out
        // below it and letterboxed on all sides.
        hosting.safeAreaRegions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        addSubview(hosting)
        hostingView = hosting
        apply(plan: model.dynamicRangePlan)
        enableDrops()
        videoView.enableDrops()
        let hasMedia: () -> Bool = { [weak model] in model?.hasMedia == true }
        acceptsSubtitles = hasMedia
        videoView.acceptsSubtitles = hasMedia
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            // activeAlways: the exit must arrive even when another app is in front, or the chrome
            // would stay over the picture.
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        model.chrome.pointerMoved(to: convert(event.locationInWindow, from: nil))
        onPointerActivity?()
    }

    override func mouseEntered(with event: NSEvent) {
        model.chrome.pointerMoved(to: convert(event.locationInWindow, from: nil))
        onPointerActivity?()
    }

    // MARK: Dynamic range (section 7.7, D52)

    /// The display layer gets the plan's `layer`; the subtitle layer and the SwiftUI chrome get
    /// its `overlay`, which is always `.standard`, set explicitly so a future default change
    /// cannot raise them above SDR white.
    func apply(plan: DynamicRangePlan) {
        videoView.apply(video: plan.layer, overlay: plan.overlay)
        hostingView?.layer?.preferredDynamicRange = plan.overlay.caValue
    }

    /// What the three layers ask for now (DynamicRangeLayerTests).
    var layerDynamicRanges: (display: CALayer.DynamicRange, subtitles: CALayer.DynamicRange, chrome: CALayer.DynamicRange?) {
        (videoView.displayLayer.preferredDynamicRange, videoView.subtitleLayer.preferredDynamicRange, hostingView?.layer?.preferredDynamicRange)
    }

    override func mouseExited(with event: NSEvent) {
        model.chrome.pointerExited()
    }

    override func keyDown(with event: NSEvent) {
        guard let commandTarget, KeyHandling.handle(event, map: .standard, model: model, target: commandTarget) else {
            super.keyDown(with: event)
            return
        }
    }

    /// Mouse back and forward go to the previous and next episode (design 9.6).
    override func otherMouseDown(with event: NSEvent) {
        guard let commandTarget, VideoSurfaceView.handleSideButton(event, model: model, target: commandTarget) else {
            super.otherMouseDown(with: event)
            return
        }
    }

    /// True while the pointer is over the picture rather than the controller.
    var isPointerOverVideo: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) && !model.chrome.isPointerOverController
    }
}

/// Where the surface is: in the window's scene, or in the mini player panel.
enum VideoSurfaceMode {
    case window, mini
}

/// The picture: an `AVSampleBufferDisplayLayer` (`.resizeAspect`, black) plus the pointer
/// gestures of design 9.6. In the mini player a drag moves the panel and scrolls do nothing.
final class VideoSurfaceView: DropAcceptingView {
    static let clickDelay: Duration = .milliseconds(250)
    /// Media seconds per point of horizontal scroll.
    static let pointsPerSecond: CGFloat = 8
    /// Volume steps per point of vertical scroll.
    static let pointsPerVolumeStep: CGFloat = 6

    let model: PlayerModel
    private(set) var displayLayer = AVSampleBufferDisplayLayer()
    /// Above the display layer, sized like it; the engine draws subtitles into a sublayer (8.6).
    private(set) var subtitleLayer = CALayer()
    var onDoubleClick: (() -> Void)?
    var mode = VideoSurfaceMode.window
    /// The mini player's drag (`mode == .mini`).
    var onPanelDrag: ((DragPhase) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    /// Called after the layers changed size or backing scale (window resize, fullscreen, display).
    var onLayersResized: (() -> Void)?
    weak var commandTarget: (any PlayerCommandTarget)?

    private var pendingClick: Task<Void, Never>?
    /// The plan's ranges, reapplied to the fresh layers of each engine.
    private var videoRange = LayerDynamicRange.standard
    private var overlayRange = LayerDynamicRange.standard
    private var scrollAxis: ScrollAxis?
    private var scrollAccumulator: CGFloat = 0
    private var scrubTarget: MediaTime?

    private enum ScrollAxis { case horizontal, vertical }

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        configure(displayLayer)
        configure(subtitleLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Fresh display and subtitle layers for a new engine, replacing the previous ones. A layer's
    /// renderer can belong to one synchronizer at a time, and the old engine's subtitle sublayer
    /// must not linger, so layers are not reused across engines.
    func prepareLayers() -> (display: AVSampleBufferDisplayLayer, subtitles: CALayer) {
        let display = AVSampleBufferDisplayLayer()
        displayLayer.removeFromSuperlayer()
        displayLayer = display
        configure(display)
        let subtitles = CALayer()
        subtitleLayer.removeFromSuperlayer()
        subtitleLayer = subtitles
        configure(subtitles)
        return (display, subtitles)
    }

    func apply(video: LayerDynamicRange, overlay: LayerDynamicRange) {
        videoRange = video
        overlayRange = overlay
        displayLayer.preferredDynamicRange = video.caValue
        subtitleLayer.preferredDynamicRange = overlay.caValue
        layer?.preferredDynamicRange = overlay.caValue
    }

    private func configure(_ layer: AVSampleBufferDisplayLayer) {
        layer.preferredDynamicRange = videoRange.caValue
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        layer.frame = bounds
        self.layer?.insertSublayer(layer, at: 0)
    }

    private func configure(_ layer: CALayer) {
        layer.preferredDynamicRange = overlayRange.caValue
        layer.frame = bounds
        layer.contentsScale = backingScale
        layer.masksToBounds = true
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        self.layer?.addSublayer(layer)
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        subtitleLayer.contentsScale = backingScale
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        subtitleLayer.contentsScale = backingScale
        onLayersResized?()
    }

    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// A click on the inactive mini player acts at once; the window keeps the usual first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { mode == .mini }

    override func layout() {
        super.layout()
        let resized = subtitleLayer.frame != bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        subtitleLayer.frame = bounds
        CATransaction.commit()
        if resized { onLayersResized?() }
    }

    // MARK: Clicks: single toggles pause after 250 ms, double toggles fullscreen, drag moves the window.

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            onDoubleClick?()
            return
        }
        if let window, let next = window.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: false
        ), next.type == .leftMouseDragged {
            if mode == .mini {
                trackPanelDrag(from: event, in: window)
            } else {
                window.performDrag(with: event)
            }
            return
        }
        pendingClick?.cancel()
        pendingClick = Task { [weak self] in
            try? await Task.sleep(for: VideoSurfaceView.clickDelay)
            guard !Task.isCancelled, let self else { return }
            self.model.togglePause()
            self.pendingClick = nil
        }
    }

    /// Follows the pointer in screen points until the button goes up, then reports its velocity.
    private func trackPanelDrag(from event: NSEvent, in window: NSWindow) {
        let start = NSEvent.mouseLocation
        var velocity = PointerVelocity()
        velocity.add(start, at: event.timestamp)
        onPanelDrag?(.began)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = NSEvent.mouseLocation
            velocity.add(point, at: next.timestamp)
            if next.type == .leftMouseUp {
                onPanelDrag?(.ended(velocity: velocity.velocity))
                return
            }
            onPanelDrag?(.moved(CGVector(dx: point.x - start.x, dy: point.y - start.y)))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let commandTarget, VideoSurfaceView.handleSideButton(event, model: model, target: commandTarget) else {
            super.otherMouseDown(with: event)
            return
        }
    }

    /// `MBTN_BACK` and `MBTN_FORWARD` through the key table.
    static func handleSideButton(_ event: NSEvent, model: PlayerModel, target: any PlayerCommandTarget) -> Bool {
        guard let chord = KeyHandling.chord(forMouseButton: event.buttonNumber),
              let action = InputMap.standard.action(for: chord) else { return false }
        KeyHandling.perform(action, model: model, target: target)
        return true
    }

    // MARK: Scroll: horizontal seeks (scrubs, then exact at the end), vertical sets the volume.

    override func scrollWheel(with event: NSEvent) {
        // Scrolling the document under the mini player must not change the volume or seek.
        guard mode == .window else { return }
        guard model.hasMedia || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return }
        if event.phase == [] && event.momentumPhase == [] {
            discreteScroll(event)
            return
        }
        guard event.momentumPhase == [] else { return }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            scrollAxis = nil
            scrollAccumulator = 0
            scrubTarget = nil
        }
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        if scrollAxis == nil, deltaX != 0 || deltaY != 0 {
            scrollAxis = abs(deltaX) > abs(deltaY) ? .horizontal : .vertical
        }
        switch scrollAxis {
        case .horizontal:
            let base = scrubTarget ?? model.position
            let target = base + .seconds(Double(-deltaX / VideoSurfaceView.pointsPerSecond))
            scrubTarget = target
            if deltaX != 0 { model.scrub(to: target) }
        case .vertical:
            scrollAccumulator += deltaY
            let steps = (scrollAccumulator / VideoSurfaceView.pointsPerVolumeStep).rounded(.towardZero)
            if steps != 0 {
                scrollAccumulator -= steps * VideoSurfaceView.pointsPerVolumeStep
                model.adjustVolume(by: Double(steps))
            }
        case nil:
            break
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if scrollAxis == .horizontal, let scrubTarget {
                model.endScrub(at: scrubTarget)
            }
            scrollAxis = nil
            scrubTarget = nil
            scrollAccumulator = 0
        }
    }

    /// A mouse wheel without gesture phases: one volume step or one second per notch.
    private func discreteScroll(_ event: NSEvent) {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        if abs(deltaY) >= abs(deltaX), deltaY != 0 {
            let steps = event.hasPreciseScrollingDeltas ? deltaY / VideoSurfaceView.pointsPerVolumeStep : deltaY.sign == .minus ? -1 : 1
            model.adjustVolume(by: Double(steps.rounded(.awayFromZero)))
        } else if deltaX != 0, model.hasMedia {
            model.seek(by: deltaX < 0 ? 1 : -1, source: .pointer)
        }
    }
}

extension LayerDynamicRange {
    /// The Core Animation value (`CALayer.DynamicRange`, macOS 26 and later).
    var caValue: CALayer.DynamicRange {
        switch self {
        case .high: .high
        case .constrainedHigh: .constrainedHigh
        case .standard: .standard
        }
    }
}
