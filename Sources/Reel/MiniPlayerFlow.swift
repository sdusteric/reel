import AppKit
import ReelUI

/// What happens around the mini player (mini player design section 6): fullscreen first, Close
/// pauses and leaves Reel in the background, Back to Window and the Dock bring the window back,
/// a failure card or a closed file leaves at once. The window is reached through `WindowOps`, so
/// tests drive this without a window.
@MainActor
final class MiniPlayerFlow {
    struct WindowOps {
        var isFullscreen: () -> Bool
        var exitFullscreen: () -> Void
        var toggleFullscreen: () -> Void
        /// The window's video area in screen points.
        var videoRect: () -> CGRect
        var aspect: () -> CGFloat
        /// Fades the window out over the duration, then orders it out.
        var hide: (TimeInterval) -> Void
        /// Orders the window in: in front and active, or behind without activating Reel.
        var show: (_ activate: Bool) -> Void
    }

    private let model: PlayerModel
    private let controller: MiniPlayerController
    private let window: WindowOps
    private let reduceMotion: () -> Bool
    private var pendingEnter = false

    var isActive: Bool { controller.isActive }

    init(
        model: PlayerModel,
        controller: MiniPlayerController,
        window: WindowOps,
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.model = model
        self.controller = controller
        self.window = window
        self.reduceMotion = reduceMotion
        controller.onLeaveRequest = { [weak self] kind in self?.leave(kind) }
    }

    /// The controller button, the menu and Ctrl+Cmd+P (`true` enters).
    func request(_ wanted: Bool) {
        if wanted { enter() } else { leave(.backToWindow) }
    }

    private func enter() {
        guard model.hasMedia, !controller.isActive else { return }
        if window.isFullscreen() {
            pendingEnter = true
            window.exitFullscreen()
            return
        }
        controller.enter(from: window.videoRect(), aspect: window.aspect())
        window.hide(reduceMotion() ? MotionTiming.miniPlayerReducedFade : MotionTiming.miniPlayerChromeOut)
    }

    func windowDidExitFullScreen() {
        guard pendingEnter else { return }
        pendingEnter = false
        enter()
    }

    func leave(_ kind: LeaveKind, then next: (() -> Void)? = nil) {
        guard controller.isActive else {
            next?()
            return
        }
        if kind == .close { model.pause() }
        let activate = kind == .backToWindow
        let window = window
        controller.leave(to: window.videoRect(), beforeSwap: { window.show(activate) }) { next?() }
    }

    /// The file closed or the window is closing: no move, and Reel stays where it is.
    func leaveAtOnce() {
        guard controller.isActive else { return }
        let window = window
        controller.leave(to: .zero, animated: false, beforeSwap: { window.show(false) }) {}
    }

    /// Fullscreen keys while the mini player is up: back to the window, then fullscreen.
    func requestFullscreen() {
        guard controller.isActive else {
            window.toggleFullscreen()
            return
        }
        let window = window
        leave(.backToWindow) { window.toggleFullscreen() }
    }

    func mediaOpened(aspect: CGFloat) {
        guard controller.isActive else { return }
        controller.resize(aspect: aspect)
    }

    /// A failure card (9.14) shows in the window, which comes back without taking focus.
    func problemChanged() {
        guard model.problem != nil, controller.isActive else { return }
        let window = window
        controller.leave(to: window.videoRect(), beforeSwap: { window.show(false) }) {}
    }

    /// A click on Reel's Dock icon; true when it brought the window back.
    func reopen() -> Bool {
        guard controller.isActive else { return false }
        leave(.backToWindow)
        return true
    }
}
