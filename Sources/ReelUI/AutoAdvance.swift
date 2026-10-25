import CoreGraphics
import Foundation
import Observation
import ReelCore

/// The end-of-episode countdown behind the next-episode card (design 9.8, D39, D49).
///
/// It runs 5 s from `begin`, stops while the pointer is over the card and starts the next file
/// when it reaches zero. Time comes from an injected clock so tests move it by hand and call
/// `tick()`; the app's timer calls `tick()` every 0.1 s.
@Observable
public final class AutoAdvance {
    public static let countdown: TimeInterval = 5
    public static let tickInterval: TimeInterval = 0.1

    /// The card is showing.
    public private(set) var isActive = false
    public private(set) var nextURL: URL?
    public private(set) var isHovered = false
    /// Seconds of countdown used up.
    public private(set) var elapsed: TimeInterval = 0
    /// A frame of the next file, when the app provided one.
    public internal(set) var thumbnail: CGImage?

    /// Starts the next file (countdown end, Play Now, Return, a click on the thumbnail).
    @ObservationIgnored public var onStart: ((URL) -> Void)?

    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void
    @ObservationIgnored private var runningSince: TimeInterval?
    @ObservationIgnored private var timer: Task<Void, Never>?

    public init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    public var remaining: TimeInterval { max(0, AutoAdvance.countdown - elapsed) }

    /// 0 at the start, 1 when the countdown is over.
    public var progress: Double { min(max(elapsed / AutoAdvance.countdown, 0), 1) }

    /// "in 3 s": whole seconds, rounded up, so it never shows "in 0 s" before the file starts.
    public var remainingLabel: String { "in \(Int(remaining.rounded(.up))) s" }

    /// "Northern Line S02E06".
    public var nextName: String {
        nextURL.map(EpisodeList.episodeName(for:)) ?? ""
    }

    /// Shows the card and starts counting. The pointer is not over the card yet.
    public func begin(next: URL) {
        stopTimer()
        nextURL = next
        thumbnail = nil
        isActive = true
        isHovered = false
        elapsed = 0
        runningSince = now()
        startTimer()
    }

    /// The pointer entered or left the card. Entering freezes the countdown where it is.
    public func setHovered(_ hovered: Bool) {
        guard isActive, hovered != isHovered else { return }
        bank()
        isHovered = hovered
        runningSince = hovered ? nil : now()
    }

    /// Moves the countdown to the clock and starts the next file when it is over.
    public func tick() {
        guard isActive else { return }
        bank()
        if elapsed >= AutoAdvance.countdown {
            fire()
        }
    }

    /// Cancel, Esc, a seek, a replay or a new file: remove the card and stay where we are.
    public func cancel() {
        guard isActive else { return }
        finish()
    }

    /// Play Now, Return and a click on the thumbnail.
    public func playNow() {
        guard isActive else { return }
        fire()
    }

    // MARK: Private

    private func fire() {
        let next = nextURL
        finish()
        if let next { onStart?(next) }
    }

    private func finish() {
        stopTimer()
        isActive = false
        isHovered = false
        runningSince = nil
        elapsed = 0
        thumbnail = nil
    }

    /// Adds the running time since the last tick to `elapsed`.
    private func bank() {
        guard let runningSince else { return }
        let current = now()
        elapsed = min(AutoAdvance.countdown, elapsed + max(0, current - runningSince))
        self.runningSince = current
    }

    private func startTimer() {
        let sleep = sleep
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(AutoAdvance.tickInterval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
