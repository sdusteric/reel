import AppKit
import CoreGraphics
import ReelCore
import ReelUI

/// A display as the mini player sees it; `id` is the display's UUID, stored in `state.json`.
struct ScreenInfo: Equatable {
    let id: String
    let visibleFrame: CGRect
    let isMain: Bool

    static func current() -> [ScreenInfo] {
        let main = NSScreen.main
        return NSScreen.screens.map { ScreenInfo(id: $0.reelID, visibleFrame: $0.visibleFrame, isMain: $0 == main) }
    }
}

extension NSScreen {
    /// The display's UUID string, stable across launches and arrangement changes.
    var reelID: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) else { return localizedName }
        return text as String
    }
}

/// How the mini player was asked to close: Back to Window activates Reel, Close pauses and
/// leaves Reel in the background.
enum LeaveKind: Equatable {
    case backToWindow, close
}

/// A drag on the picture in the mini player. `moved` carries the translation since `began`, in
/// screen points; `ended` the pointer's velocity in points per second.
enum DragPhase: Equatable {
    case began
    case moved(CGVector)
    case ended(velocity: CGVector)
}

/// The enter and leave move; tests record it and complete it by hand.
@MainActor
protocol PanelAnimating: AnyObject {
    func move(_ window: NSWindow, to frame: CGRect, duration: TimeInterval, completion: @escaping () -> Void)
    func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval, completion: @escaping () -> Void)
}

/// `NSAnimationContext` on the window frame (the layer resizes with it) and on its alpha.
@MainActor
final class AppKitPanelAnimator: PanelAnimating {
    func move(_ window: NSWindow, to frame: CGRect, duration: TimeInterval, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = MotionTiming.miniPlayerMoveTimingFunction
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            completion()
        }
    }

    func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = alpha > window.alphaValue ? MotionCurve.easeOut.timingFunction : MotionCurve.easeIn.timingFunction
            window.animator().alphaValue = alpha
        } completionHandler: {
            completion()
        }
    }
}

/// Moves the panel to its corner after a drag. Tests set the frame at once.
@MainActor
protocol PanelSnapping: AnyObject {
    func snap(_ window: NSWindow, to frame: CGRect, velocity: CGVector, completion: @escaping () -> Void)
    func stop()
}

/// The snap of mini player design section 8 row 2: the panel's origin follows `SnapSpring`, driven
/// by a display link that runs only until the spring settles.
@MainActor
final class SpringSnapper: NSObject, PanelSnapping {
    private var link: CADisplayLink?
    private weak var window: NSWindow?
    private var from = CGPoint.zero
    private var target = CGRect.zero
    private var started: CFTimeInterval = 0
    private var spring = SnapSpring(reduceMotion: false)
    private var initialVelocity = 0.0
    private var distance = 0.0
    private var completion: (() -> Void)?

    func snap(_ window: NSWindow, to frame: CGRect, velocity: CGVector, completion: @escaping () -> Void) {
        stop()
        from = window.frame.origin
        target = frame
        let dx = Double(frame.minX - from.x), dy = Double(frame.minY - from.y)
        distance = (dx * dx + dy * dy).squareRoot()
        guard distance > SnapSpring.settledDistance, let view = window.contentView else {
            window.setFrame(frame, display: true)
            completion()
            return
        }
        // The release speed toward the corner, as a fraction of the distance per second.
        initialVelocity = (Double(velocity.dx) * dx + Double(velocity.dy) * dy) / (distance * distance)
        spring = SnapSpring(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        self.window = window
        self.completion = completion
        started = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        completion = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else {
            stop()
            return
        }
        let elapsed = CACurrentMediaTime() - started
        let progress = CGFloat(spring.progress(at: elapsed, initialVelocity: initialVelocity))
        window.setFrameOrigin(CGPoint(x: from.x + (target.minX - from.x) * progress, y: from.y + (target.minY - from.y) * progress))
        guard spring.isSettled(at: elapsed, initialVelocity: initialVelocity, distance: distance) else { return }
        window.setFrame(target, display: true)
        let done = completion
        stop()
        done?()
    }
}

/// Owns the mini player panel and hands the window's video surface to it and back (mini player
/// design sections 3 to 6). The engine is never touched: the surface keeps its layers.
@MainActor
final class MiniPlayerController: NSObject, NSWindowDelegate {
    private let model: PlayerModel
    private let surface: VideoSurfaceView
    private let home: SurfaceSlotView
    private let stateStore: StateStore
    private let screens: @MainActor () -> [ScreenInfo]
    private let show: @MainActor (NSPanel) -> Void
    private let snapper: any PanelSnapping
    private let animator: any PanelAnimating
    private let reduceMotion: @MainActor () -> Bool
    private let log: ReelLog
    /// Bumped by every enter and leave, so a move that was overtaken does nothing when it ends.
    private var generation = 0

    private(set) var panel: MiniPlayerPanel?
    private var content: MiniPlayerContentView?
    private var aspect: CGFloat = 16 / 9
    private var dragStart: CGPoint?
    private var windowDoubleClick: (() -> Void)?
    /// Close and Back to Window from the panel's buttons; the window controller decides what follows.
    var onLeaveRequest: ((LeaveKind) -> Void)?
    /// The panel's occlusion changed; while it is up, energy follows the panel (section 7.9).
    var onOcclusionChange: (() -> Void)?
    weak var commandTarget: (any PlayerCommandTarget)?
    /// Makes the panel key with the content as first responder while Reel is active, so the keys
    /// of section 10 reach it; tests record instead.
    var focus: @MainActor (NSPanel, NSView) -> Void = { panel, view in
        guard NSApp.isActive else { return }
        panel.makeKey()
        panel.makeFirstResponder(view)
    }
    /// The display the panel sits on now, to re-place it when displays change.
    private var currentScreenID: String?

    /// The window whose visibility decides whether video decodes: the panel while it is up.
    var occlusionWindow: NSWindow? { panel }

    var isActive: Bool { panel != nil }

    init(
        model: PlayerModel,
        surface: VideoSurfaceView,
        home: SurfaceSlotView,
        stateStore: StateStore,
        screens: @escaping @MainActor () -> [ScreenInfo] = ScreenInfo.current,
        show: @escaping @MainActor (NSPanel) -> Void = { $0.orderFrontRegardless() },
        snapper: any PanelSnapping = SpringSnapper(),
        animator: any PanelAnimating = AppKitPanelAnimator(),
        reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        log: ReelLog = .disabled
    ) {
        self.model = model
        self.surface = surface
        self.home = home
        self.stateStore = stateStore
        self.screens = screens
        self.show = show
        self.snapper = snapper
        self.animator = animator
        self.reduceMotion = reduceMotion
        self.log = log
    }

    // MARK: Placement

    private var placement: MiniPlayerPlacement { stateStore.state.miniPlayer }

    private var mainScreen: ScreenInfo {
        let list = screens()
        return list.first(where: \.isMain) ?? list.first ?? ScreenInfo(id: "", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), isMain: true)
    }

    /// The saved display if it is still connected, else the main one.
    private var savedScreen: ScreenInfo {
        let list = screens()
        let id = MiniPlayerGeometry.screen(saved: placement.screen, available: list.map(\.id), fallback: mainScreen.id)
        return list.first { $0.id == id } ?? mainScreen
    }

    /// The display holding most of `frame`, for snapping after a drag across displays.
    private func screen(containing frame: CGRect) -> ScreenInfo {
        let list = screens()
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = list.first(where: { $0.visibleFrame.contains(centre) }) { return hit }
        return list.min { distance(centre, $0.visibleFrame) < distance(centre, $1.visibleFrame) } ?? mainScreen
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    func targetFrame(aspect: CGFloat, on screen: ScreenInfo) -> CGRect {
        let size = MiniPlayerGeometry.size(aspect: aspect, boxScale: placement.boxScale, visible: screen.visibleFrame)
        return MiniPlayerGeometry.frame(size: size, corner: placement.corner, visible: screen.visibleFrame)
    }

    // MARK: Enter and leave

    /// The panel appears over the window's video area (`sourceRect`, screen points) holding the
    /// picture, then travels to its corner.
    func enter(from sourceRect: CGRect, aspect: CGFloat) {
        guard panel == nil else { return }
        generation += 1
        let current = generation
        self.aspect = aspect > 0 && aspect.isFinite ? aspect : 16 / 9
        // First use opens on the window's display (mini player design 4).
        let screen = placement.screen == nil && !sourceRect.isEmpty ? screen(containing: sourceRect) : savedScreen
        let frame = targetFrame(aspect: self.aspect, on: screen)
        let motion = MotionTiming.miniPlayerMove(reduceMotion: reduceMotion())
        let travels = motion.travels && !sourceRect.isEmpty
        let panel = MiniPlayerPanel(contentRect: frame)
        let actions = MiniPlayerActions(
            close: { [weak self] in self?.onLeaveRequest?(.close) },
            backToWindow: { [weak self] in self?.onLeaveRequest?(.backToWindow) }
        )
        let content = MiniPlayerContentView(model: model, actions: actions)
        content.commandTarget = commandTarget
        content.onMagnify = { [weak self] factor in self?.magnify(by: factor) }
        content.onMagnifyEnd = { [weak self] in self?.magnifyEnded() }
        panel.contentView = content
        panel.initialFirstResponder = content
        currentScreenID = screen.id
        applyLimits(to: panel, visible: screen.visibleFrame)
        // The limits would clamp the window-sized start of the move.
        if travels {
            panel.contentMinSize = NSSize(width: 1, height: 1)
            panel.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        panel.setFrame(travels ? sourceRect : frame, display: false)
        if !motion.travels { panel.alphaValue = 0 }
        panel.delegate = self
        content.layoutSubtreeIfNeeded()

        content.slot.host(surface)
        windowDoubleClick = surface.onDoubleClick
        surface.onDoubleClick = { [weak self] in self?.onLeaveRequest?(.backToWindow) }
        surface.onPanelDrag = { [weak self] phase in self?.drag(phase) }
        surface.mode = .mini

        self.panel = panel
        self.content = content
        model.miniChrome.pointerExited()
        model.setMiniPlayer(active: true)
        show(panel)
        focus(panel, content)
        let visible = screen.visibleFrame
        if travels {
            animator.move(panel, to: frame, duration: motion.duration) { [weak self, weak panel] in
                guard let self, let panel, self.generation == current else { return }
                self.applyLimits(to: panel, visible: visible)
            }
        } else if !motion.travels {
            animator.fade(panel, to: 1, duration: motion.duration) {}
        }
    }

    /// The panel travels back to the window's video area (`targetRect`), then `beforeSwap` orders
    /// the window in behind it, the surface goes home and the panel closes.
    /// `animated: false` swaps at once (the file or the window went away).
    func leave(to targetRect: CGRect, animated: Bool = true, beforeSwap: @escaping () -> Void = {}, completion: @escaping () -> Void) {
        guard let panel else {
            completion()
            return
        }
        generation += 1
        let current = generation
        snapper.stop()
        let motion = MotionTiming.miniPlayerMove(reduceMotion: reduceMotion())
        let finish = { [weak self] in
            guard let self, self.generation == current else { return }
            beforeSwap()
            self.swapHome(panel)
            completion()
        }
        if !animated {
            finish()
        } else if motion.travels, !targetRect.isEmpty {
            panel.contentMinSize = NSSize(width: 1, height: 1)
            panel.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            panel.contentAspectRatio = NSSize(width: 0, height: 0)
            animator.move(panel, to: targetRect, duration: motion.duration, completion: finish)
        } else if !motion.travels {
            animator.fade(panel, to: 0, duration: motion.duration, completion: finish)
        } else {
            finish()
        }
    }

    private func swapHome(_ panel: MiniPlayerPanel) {
        home.host(surface)
        surface.mode = .window
        surface.onDoubleClick = windowDoubleClick
        surface.onPanelDrag = nil
        windowDoubleClick = nil
        panel.delegate = nil
        panel.close()
        if self.panel === panel {
            self.panel = nil
            content = nil
        }
        model.setMiniPlayer(active: false)
    }

    private func applyLimits(to panel: NSPanel, visible: CGRect) {
        panel.contentAspectRatio = NSSize(width: aspect, height: 1)
        panel.contentMinSize = MiniPlayerGeometry.size(aspect: aspect, boxScale: .leastNonzeroMagnitude, visible: visible)
        panel.contentMaxSize = MiniPlayerGeometry.size(aspect: aspect, boxScale: .greatestFiniteMagnitude, visible: visible)
    }

    // MARK: Drag, pinch and resize

    func drag(_ phase: DragPhase) {
        guard let panel else { return }
        switch phase {
        case .began:
            snapper.stop()
            dragStart = panel.frame.origin
        case .moved(let translation):
            let start = dragStart ?? panel.frame.origin
            panel.setFrameOrigin(CGPoint(x: start.x + translation.dx, y: start.y + translation.dy))
        case .ended(let velocity):
            dragStart = nil
            let screen = screen(containing: panel.frame)
            let corner = MiniPlayerGeometry.corner(releasing: panel.frame, velocity: velocity, visible: screen.visibleFrame)
            // Onto another display the panel takes that display's box limits.
            let scale = MiniPlayerGeometry.boxScale(for: panel.frame.size, aspect: aspect)
            let size = MiniPlayerGeometry.size(aspect: aspect, boxScale: scale, visible: screen.visibleFrame)
            let target = MiniPlayerGeometry.frame(size: size, corner: corner, visible: screen.visibleFrame)
            currentScreenID = screen.id
            save { $0.corner = corner; $0.screen = screen.id }
            applyLimits(to: panel, visible: screen.visibleFrame)
            snapper.snap(panel, to: target, velocity: velocity) {}
        }
    }

    /// A pinch scales the panel about its corner, within the box limits.
    func magnify(by factor: CGFloat) {
        guard let panel, factor.isFinite, factor > 0 else { return }
        snapper.stop()
        let screen = screen(containing: panel.frame)
        let scale = MiniPlayerGeometry.boxScale(for: panel.frame.size, aspect: aspect) * Double(factor)
        let size = MiniPlayerGeometry.size(aspect: aspect, boxScale: scale, visible: screen.visibleFrame)
        panel.setFrame(MiniPlayerGeometry.frame(size: size, corner: placement.corner, visible: screen.visibleFrame), display: true)
    }

    /// The pinch ended: its box is saved once.
    func magnifyEnded() {
        guard let panel else { return }
        let stored = MiniPlayerGeometry.boxScale(for: panel.frame.size, aspect: aspect)
        save { $0.boxScale = stored }
    }

    /// A new video with another aspect keeps the corner and the box (mini player design 4).
    func resize(aspect newAspect: CGFloat) {
        guard let panel, newAspect.isFinite, newAspect > 0 else { return }
        snapper.stop()
        let current = generation
        aspect = newAspect
        let screen = screen(containing: panel.frame)
        let size = MiniPlayerGeometry.size(aspect: aspect, boxScale: placement.boxScale, visible: screen.visibleFrame)
        let target = MiniPlayerGeometry.frame(size: size, corner: placement.corner, visible: screen.visibleFrame)
        let duration = MotionTiming.windowResizeDuration(reduceMotion: reduceMotion())
        guard duration > 0 else {
            panel.setFrame(target, display: true)
            applyLimits(to: panel, visible: screen.visibleFrame)
            return
        }
        panel.contentAspectRatio = NSSize(width: 0, height: 0)
        panel.contentMinSize = NSSize(width: 1, height: 1)
        panel.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        animator.move(panel, to: target, duration: duration) { [weak self, weak panel] in
            guard let self, let panel, self.generation == current else { return }
            self.applyLimits(to: panel, visible: screen.visibleFrame)
        }
    }

    /// Displays were added, removed or rearranged, or a visible frame changed (Dock, resolution):
    /// the panel goes back to its corner on its display, or on the main display when its own is
    /// gone, without animation. AppKit may already have moved it, so its frame is not trusted.
    func screensChanged() {
        guard let panel else { return }
        let screen = screens().first { $0.id == currentScreenID } ?? mainScreen
        currentScreenID = screen.id
        let scale = MiniPlayerGeometry.boxScale(for: panel.frame.size, aspect: aspect)
        let size = MiniPlayerGeometry.size(aspect: aspect, boxScale: scale, visible: screen.visibleFrame)
        panel.setFrame(MiniPlayerGeometry.frame(size: size, corner: placement.corner, visible: screen.visibleFrame), display: true)
        applyLimits(to: panel, visible: screen.visibleFrame)
    }

    /// Reel became active (Cmd+Tab): the panel takes the keys.
    func appDidBecomeActive() {
        guard let panel, let content else { return }
        focus(panel, content)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        onOcclusionChange?()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        let stored = MiniPlayerGeometry.boxScale(for: panel.frame.size, aspect: aspect)
        save { $0.boxScale = stored }
        // Dragging the anchored edge moves the panel off its inset; it settles back.
        let screen = screen(containing: panel.frame)
        let target = MiniPlayerGeometry.frame(size: panel.frame.size, corner: placement.corner, visible: screen.visibleFrame)
        guard target != panel.frame else { return }
        snapper.snap(panel, to: target, velocity: .zero) {}
    }

    private func save(_ change: (inout MiniPlayerPlacement) -> Void) {
        do {
            try stateStore.update { change(&$0.miniPlayer) }
        } catch {
            log.error("mini player placement save failed: \(error)")
        }
    }
}
