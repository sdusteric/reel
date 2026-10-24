import Foundation
import Observation
import SwiftUI

/// The shared `chromeVisible` state of the traffic lights, title and controller (design 9.2).
///
/// Shown on pointer movement of 2 pt or more, on playback keys and always while paused. Hidden
/// 2.5 s after the last input while playing, but never while the pointer is over the controller
/// or a drag is in progress. Time comes from an injected clock so tests need no waiting.
@Observable
public final class ChromeVisibility {
    public static let autoHideDelay: TimeInterval = 2.5
    public static let pointerThreshold: CGFloat = 2
    public static let fadeInDuration: TimeInterval = 0.22
    public static let fadeOutDuration: TimeInterval = 0.35
    public static let reducedMotionDuration: TimeInterval = 0.1

    public private(set) var isVisible = true

    public private(set) var isPlaying = false
    public private(set) var isPointerOverController = false
    public private(set) var isDragging = false
    /// The last input that keeps the chrome up, on the injected clock.
    public private(set) var lastInputAt: TimeInterval

    /// Called on every visibility change with the new value.
    @ObservationIgnored public var onChange: ((Bool) -> Void)?

    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastPointer: CGPoint?

    /// - Parameters:
    ///   - now: a monotonic clock in seconds.
    ///   - sleep: how the auto-hide timer waits. Tests pass one that never returns and call
    ///     `evaluate()` after moving their clock.
    public init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.now = now
        self.sleep = sleep
        lastInputAt = now()
    }

    /// When the chrome will hide if nothing else happens; nil while it is pinned visible or hidden.
    public var hideDeadline: TimeInterval? {
        guard isVisible, canAutoHide else { return nil }
        return lastInputAt + ChromeVisibility.autoHideDelay
    }

    private var canAutoHide: Bool { isPlaying && !isPointerOverController && !isDragging }

    // MARK: Inputs

    /// Pointer moved inside the window. Movement under 2 pt is ignored (trackpad jitter).
    public func pointerMoved(to point: CGPoint) {
        defer { lastPointer = point }
        if let lastPointer, hypot(point.x - lastPointer.x, point.y - lastPointer.y) < ChromeVisibility.pointerThreshold {
            return
        }
        registerInput()
    }

    /// The pointer left the window: forget the position so re-entry shows the chrome.
    public func pointerExited() {
        lastPointer = nil
        isPointerOverController = false
        reschedule()
    }

    /// A key that changes playback: show for the auto-hide period.
    public func playbackKeyPressed() {
        registerInput()
    }

    public func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if !playing {
            show()
        } else {
            lastInputAt = now()
        }
        reschedule()
    }

    public func setPointerOverController(_ over: Bool) {
        guard over != isPointerOverController else { return }
        isPointerOverController = over
        if over { show() } else { lastInputAt = now() }
        reschedule()
    }

    public func setDragging(_ dragging: Bool) {
        guard dragging != isDragging else { return }
        isDragging = dragging
        if dragging { show() } else { lastInputAt = now() }
        reschedule()
    }

    /// Applies the auto-hide rule at the current clock reading.
    public func evaluate() {
        if let deadline = hideDeadline, now() >= deadline {
            setVisible(false)
        }
        if !isVisible, !canAutoHide {
            setVisible(true)
        }
    }

    /// Stops the timer (window closing).
    public func invalidate() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Animation

    /// The fade for a change to `visible`: 0.22 s ease-out in, 0.35 s ease-in out, or 0.1 s
    /// opacity only with Reduce Motion.
    public static func animation(visible: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .linear(duration: reducedMotionDuration) }
        return visible ? .easeOut(duration: fadeInDuration) : .easeIn(duration: fadeOutDuration)
    }

    public static func duration(visible: Bool, reduceMotion: Bool) -> TimeInterval {
        if reduceMotion { return reducedMotionDuration }
        return visible ? fadeInDuration : fadeOutDuration
    }

    // MARK: Private

    private func registerInput() {
        lastInputAt = now()
        show()
        reschedule()
    }

    private func show() {
        setVisible(true)
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        onChange?(visible)
    }

    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard let deadline = hideDeadline else { return }
        let wait = max(0, deadline - now())
        timer = Task { [weak self, sleep] in
            await sleep(wait)
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }
}
