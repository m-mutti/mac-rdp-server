import CoreGraphics
import Darwin
import Foundation

/// Turning the Mac's own screens off and on. A screen turned off stays off
/// even after the process that did it exits (macOS shows a stand-in display
/// instead), so `ScreenGuard` covers for this process dying first.
enum PhysicalScreens {
    typealias SetEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    /// CGSConfigureDisplayEnabled, which turns a screen off without unplugging
    /// it. It's private, so it's looked up at run time in case macOS drops it.
    static let setEnabled: SetEnabled? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetEnabled.self)
    }()

    /// Turns screens back on for the rest of the login session.
    static func turnOn(_ ids: [CGDirectDisplayID]) {
        guard !ids.isEmpty, let setEnabled else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for id in ids { _ = setEnabled(config, id, true) }
        CGCompleteDisplayConfiguration(config, .forSession)
    }
}

/// A helper process that turns the Mac's screens back on if this process
/// dies while they're off. It outlives a crash because macOS doesn't take
/// child processes down with their parent.
public final class ScreenGuard {
    /// The command line the helper runs as: `mac-rdp-server restore-screens <pid> <display>...`.
    public static let command = "restore-screens"
    private let process = Process()

    init?(screens: [CGDirectDisplayID]) {
        guard let executable = Bundle.main.executablePath else { return nil }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [Self.command, String(getpid())] + screens.map { String($0) }
        do { try process.run() } catch { return nil }
    }

    /// The screens are back on; the helper can go.
    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// Runs the helper: waits for the process that started it to exit, then
    /// turns the screens back on.
    public static func run(_ arguments: [String]) -> Never {
        guard let parent = arguments.first.flatMap({ pid_t($0) }) else { exit(2) }
        let screens = arguments.dropFirst().compactMap { CGDirectDisplayID($0) }
        let exited = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        exited.setEventHandler {
            PhysicalScreens.turnOn(screens)
            exit(0)
        }
        exited.resume()
        // The parent may have exited before the watch began.
        if kill(parent, 0) != 0 {
            PhysicalScreens.turnOn(screens)
            exit(0)
        }
        withExtendedLifetime(exited) { dispatchMain() }
    }
}
