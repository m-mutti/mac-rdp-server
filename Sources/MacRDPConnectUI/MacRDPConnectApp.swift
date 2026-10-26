import AppKit
import SwiftUI

/// The menu bar app: runs the server and hosts onboarding and settings.
public struct MacRDPConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    /// Runs the app until it quits. `window` ("onboarding" or "settings")
    /// opens that window at launch.
    @MainActor
    public static func run(showing window: String?) -> Never {
        AppDelegate.initialWindow = window
        redirectOutputToLog()
        main()
        exit(0)
    }

    /// Without a terminal, server messages would be lost; keep them in the log file.
    private static func redirectOutputToLog() {
        let log = AppModel.logFile
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        freopen(log.path, "a", stdout)
        freopen(log.path, "a", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var initialWindow: String?
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch(showing: Self.initialWindow)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopServer()
    }
}
