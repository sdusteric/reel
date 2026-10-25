import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Keeps the display awake while a video plays (design section 9.1): one
/// `PreventUserIdleDisplaySleep` assertion, taken on play and released on pause, close and quit.
/// With it goes a `ProcessInfo` activity (`.userInitiated`), so App Nap leaves playback alone and
/// takes over again while paused (section 7.9). The assertion already keeps the display awake.
///
/// Headless engines (tests, reelctl) create it disabled, so they never hold an assertion.
public final class DisplaySleep: Sendable {
    public static let reason = "Reel is playing video"

    private struct Held {
        var assertion: IOPMAssertionID?
        var activity: (any NSObjectProtocol)?
    }

    public let isEnabled: Bool
    private let held = Mutex(Held())

    public init(enabled: Bool) {
        isEnabled = enabled
    }

    deinit {
        allowSleep()
    }

    /// True while this object holds an assertion.
    public var isPreventingSleep: Bool { held.withLock { $0.assertion != nil } }

    /// True while this object holds the App Nap activity.
    public var holdsActivity: Bool { held.withLock { $0.activity != nil } }

    /// Takes the assertion and the activity if they are not held yet. Returns false when
    /// disabled or the assertion was refused.
    @discardableResult
    public func preventSleep() -> Bool {
        guard isEnabled else { return false }
        return held.withLock { current in
            if current.activity == nil {
                current.activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: DisplaySleep.reason)
            }
            if current.assertion != nil { return true }
            var identifier = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                DisplaySleep.reason as CFString,
                &identifier
            )
            guard status == kIOReturnSuccess else { return false }
            current.assertion = identifier
            return true
        }
    }

    /// Releases the assertion and the activity if held.
    public func allowSleep() {
        held.withLock { current in
            if let activity = current.activity {
                ProcessInfo.processInfo.endActivity(activity)
                current.activity = nil
            }
            guard let identifier = current.assertion else { return }
            IOPMAssertionRelease(identifier)
            current.assertion = nil
        }
    }
}
