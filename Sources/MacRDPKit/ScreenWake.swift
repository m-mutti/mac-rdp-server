import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac's displays awake while a client is connected, even with its
/// own screens turned off. While displays sleep, macOS puts off changes to
/// them: arranging stalls, and removed virtual displays linger and block new
/// ones with the same identity.
public final class ScreenWake {
    private var assertion = IOPMAssertionID(kIOPMNullAssertionID)

    /// Wakes the displays and keeps them from sleeping until `release()`.
    public init(reason: String) {
        Self.wake(reason: reason)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
    }

    deinit { release() }

    public func release() {
        guard assertion != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(kIOPMNullAssertionID)
    }

    /// Turns the screens on, as a key press at the Mac would. The activity is
    /// declared as local because it's the Mac's display that must power on.
    public static func wake(reason: String) {
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id)
    }

    public static var anyAsleep: Bool {
        VirtualDisplayManager.onlineDisplays().contains { CGDisplayIsAsleep($0) != 0 }
    }

    /// Waits for the screens to come on, then for macOS to finish the display
    /// changes waking causes. Returns whether any screen was asleep.
    @discardableResult
    public static func waitUntilAwake(timeout: Duration = .seconds(3)) async -> Bool {
        guard anyAsleep else { return false }
        let deadline = ContinuousClock.now + timeout
        while anyAsleep, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(500))
        return true
    }
}
