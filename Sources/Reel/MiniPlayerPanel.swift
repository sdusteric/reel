import AppKit
import ReelCore
import ReelUI
import SwiftUI

/// The floating mini player (mini player design section 3). Non-activating, so a click on it
/// never takes focus from the app in front; titled with a hidden title bar for the system's edge
/// resizing, corners and shadow; not movable by the system, because Reel moves it to snap.
final class MiniPlayerPanel: NSPanel {
    /// Read by `canBecomeKey`: the keys of section 10 reach the panel only while Reel is active.
    var isAppActive: () -> Bool = { NSApp.isActive }

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: true
        )
        title = "Mini Player"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(type)?.isHidden = true
        }
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        // Nothing in the panel asks to become key, so it must not wait to be asked.
        becomesKeyOnlyIfNeeded = false
        backgroundColor = .black
        tabbingMode = .disallowed
    }

    override var canBecomeKey: Bool { isAppActive() }
    override var canBecomeMain: Bool { false }
}

/// Holds the video surface inside a SwiftUI scene. SwiftUI owns the slot; the mini player
/// controller moves the surface between the window's slot and the panel's, so SwiftUI never
/// tears down a view that is showing in the other window.
final class SurfaceSlotView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { true }

    func host(_ view: NSView) {
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }
}

/// Puts a slot into a SwiftUI scene.
struct SurfaceSlot: NSViewRepresentable {
    let view: SurfaceSlotView

    func makeNSView(context: Context) -> SurfaceSlotView { view }
    func updateNSView(_ nsView: SurfaceSlotView, context: Context) {}
}

/// The first click on an inactive panel acts at once (pause, close) instead of only focusing it.
final class MiniHostingView: NSHostingView<MiniPlayerView<SurfaceSlot>> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's content: the SwiftUI overlay over the slot, and the pointer tracking that feeds the
/// mini player's chrome while another app is in front (`.activeAlways`).
final class MiniPlayerContentView: NSView {
    let model: PlayerModel
    let slot = SurfaceSlotView()
    private var hosting: MiniHostingView?
    /// The window controller: the keys of section 10 act on the mini player while Reel is active.
    weak var commandTarget: (any PlayerCommandTarget)?
    /// A pinch: the factor since the last event.
    var onMagnify: ((CGFloat) -> Void)?

    init(model: PlayerModel, actions: MiniPlayerActions) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let slot = slot
        let hosting = MiniHostingView(rootView: MiniPlayerView(model: model, actions: actions) { SurfaceSlot(view: slot) })
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        self.hosting = hosting
        setAccessibilityLabel("Mini Player")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        hosting?.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        model.miniChrome.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        model.miniChrome.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        model.miniChrome.pointerExited()
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        guard let commandTarget, KeyHandling.handle(event, map: .standard, model: model, target: commandTarget) else {
            super.keyDown(with: event)
            return
        }
    }
}
