import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Keeps the display awake while a video plays (design section 9.1): one
/// `PreventUserIdleDisplaySleep` assertion, taken on play and released on pause, close and quit.
///
/// Headless engines (tests, reelctl) create it disabled, so they never hold an assertion.
public final class DisplaySleep: Sendable {
    public static let reason = "Reel is playing video"

    public let isEnabled: Bool
    private let assertion = Mutex<IOPMAssertionID?>(nil)

    public init(enabled: Bool) {
        isEnabled = enabled
    }

    deinit {
        allowSleep()
    }

    /// True while this object holds an assertion.
    public var isPreventingSleep: Bool { assertion.withLock { $0 != nil } }

    /// Takes the assertion if it is not held yet. Returns false when disabled or refused.
    @discardableResult
    public func preventSleep() -> Bool {
        guard isEnabled else { return false }
        return assertion.withLock { current in
            if current != nil { return true }
            var identifier = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                DisplaySleep.reason as CFString,
                &identifier
            )
            guard status == kIOReturnSuccess else { return false }
            current = identifier
            return true
        }
    }

    /// Releases the assertion if held.
    public func allowSleep() {
        assertion.withLock { current in
            guard let identifier = current else { return }
            IOPMAssertionRelease(identifier)
            current = nil
        }
    }
}
