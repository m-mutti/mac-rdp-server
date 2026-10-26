import AppKit
import SwiftUI

/// Shows SwiftUI views in ordinary windows. A menu bar app has no Dock icon,
/// so each window is brought forward explicitly.
@MainActor
final class WindowPresenter {
    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(_ id: String, title: String, @ViewBuilder content: () -> Content) {
        if let window = windows[id] {
            bringForward(window)
            return
        }
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        windows[id] = window
        bringForward(window)
    }

    func close(_ id: String) {
        windows.removeValue(forKey: id)?.close()
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
