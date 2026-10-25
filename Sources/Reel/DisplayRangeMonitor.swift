import AppKit
import ReelCore
import ReelEngine
import ReelUI

/// A cancellable delayed call on the main actor.
@MainActor
final class ScheduledAction {
    private var onCancel: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        onCancel = cancel
    }

    func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// When delayed work runs. The app uses dispatch timers with 10% leeway (D60); tests advance a
/// fake clock by hand.
@MainActor
protocol AppScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction
}

/// Main-queue dispatch timers with `EnergyPolicy.leeway` so the system can coalesce wakeups.
@MainActor
final class MainQueueScheduler: AppScheduling {
    static let shared = MainQueueScheduler()

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let leeway = Int((EnergyPolicy.leeway(forInterval: seconds) * 1_000).rounded())
        timer.schedule(deadline: .now() + max(seconds, 0), repeating: .never, leeway: .milliseconds(max(leeway, 1)))
        timer.setEventHandler {
            timer.cancel()
            MainActor.assumeIsolated { action() }
        }
        timer.resume()
        return ScheduledAction { timer.cancel() }
    }
}

/// The EDR state of the window's screen for the tag and Video Info (section 7.7, D54). Read when
/// the window changes screen and when screen parameters change; the current headroom is polled at
/// 2 Hz only while Video Info is open. It never touches the display layer: the plan's layer
/// depends on the content and the setting only.
@MainActor
final class DisplayRangeMonitor {
    /// Seconds between current-headroom reads while Video Info is open.
    static let pollInterval: TimeInterval = 0.5

    /// What the window's screen reports now; nil without a screen.
    typealias ScreenReader = @MainActor () -> DisplayCapabilities?

    private let read: ScreenReader
    private let scheduler: any AppScheduling
    private let onChange: (DisplayCapabilities) -> Void
    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter
    private var poll: ScheduledAction?
    private(set) var current: DisplayCapabilities?
    /// How many times the screen was read (tests).
    private(set) var reads = 0

    /// `window` filters the screen-change notification; nil takes any (tests post their own).
    init(
        window: NSWindow?,
        read: @escaping ScreenReader,
        center: NotificationCenter = .default,
        scheduler: any AppScheduling = MainQueueScheduler.shared,
        onChange: @escaping (DisplayCapabilities) -> Void
    ) {
        self.read = read
        self.center = center
        self.scheduler = scheduler
        self.onChange = onChange
        let changed: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: changed))
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: changed
        ))
        refresh()
    }

    /// The real reader for `window`'s screen (or the main screen before it has one).
    static func screenReader(for window: NSWindow?) -> ScreenReader {
        { [weak window] in
            guard let screen = window?.screen ?? NSScreen.main else { return nil }
            return capabilities(of: screen)
        }
    }

    static func capabilities(of screen: NSScreen) -> DisplayCapabilities {
        let reference = Double(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
        return DisplayCapabilities(
            name: screen.localizedName,
            potentialHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
            currentHeadroom: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
            referenceHeadroom: reference > 0 ? reference : nil
        )
    }

    /// Reads the screen now and reports a change.
    func refresh() {
        reads += 1
        guard let display = read(), display != current else { return }
        current = display
        onChange(display)
    }

    /// Video Info opened or closed: poll the current headroom at 2 Hz only while it is open.
    func setPolling(_ polling: Bool) {
        guard polling != isPolling else { return }
        if polling {
            refresh()
            schedulePoll()
        } else {
            poll?.cancel()
            poll = nil
        }
    }

    var isPolling: Bool { poll != nil }

    private func schedulePoll() {
        poll = scheduler.schedule(after: DisplayRangeMonitor.pollInterval) { [weak self] in
            guard let self, self.poll != nil else { return }
            self.refresh()
            self.schedulePoll()
        }
    }

    func stop() {
        setPolling(false)
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}
