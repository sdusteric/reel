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
    private var hostingView: NSHostingView<PlayerSceneView<VideoSurface>>?
    private weak var commandTarget: (any PlayerCommandTarget)?

    init(model: PlayerModel, actions: SceneActions, commandTarget: any PlayerCommandTarget) {
        self.model = model
        self.commandTarget = commandTarget
        videoView = VideoSurfaceView(model: model)
        super.init(frame: NSRect(origin: .zero, size: WindowSizing.emptySize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let videoView = videoView
        let hosting = NSHostingView(rootView: PlayerSceneView(model: model, actions: actions) {
            VideoSurface(view: videoView)
        })
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
        enableDrops()
        videoView.enableDrops()
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
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        model.chrome.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        model.chrome.pointerMoved(to: convert(event.locationInWindow, from: nil))
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

    /// True while the pointer is over the picture rather than the controller.
    var isPointerOverVideo: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) && !model.chrome.isPointerOverController
    }
}

/// Hosts the display layer inside the SwiftUI scene.
struct VideoSurface: NSViewRepresentable {
    let view: VideoSurfaceView

    func makeNSView(context: Context) -> VideoSurfaceView { view }
    func updateNSView(_ nsView: VideoSurfaceView, context: Context) {}
}

/// The picture: an `AVSampleBufferDisplayLayer` (`.resizeAspect`, black) plus the pointer
/// gestures of design 9.6.
final class VideoSurfaceView: DropAcceptingView {
    static let clickDelay: Duration = .milliseconds(250)
    /// Media seconds per point of horizontal scroll.
    static let pointsPerSecond: CGFloat = 8
    /// Volume steps per point of vertical scroll.
    static let pointsPerVolumeStep: CGFloat = 6

    let model: PlayerModel
    private(set) var displayLayer = AVSampleBufferDisplayLayer()
    var onDoubleClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    private var pendingClick: Task<Void, Never>?
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// A fresh display layer for a new engine, replacing the previous one. A layer's renderer
    /// can belong to one synchronizer at a time, so layers are not reused across engines.
    func prepareDisplayLayer() -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        displayLayer.removeFromSuperlayer()
        displayLayer = layer
        configure(layer)
        return layer
    }

    private func configure(_ layer: AVSampleBufferDisplayLayer) {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        layer.frame = bounds
        self.layer?.addSublayer(layer)
    }

    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
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
            window.performDrag(with: event)
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

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Scroll: horizontal seeks (scrubs, then exact at the end), vertical sets the volume.

    override func scrollWheel(with event: NSEvent) {
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
