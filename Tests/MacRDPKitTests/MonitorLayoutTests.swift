import CoreGraphics
import Testing
@testable import MacRDPKit

struct MonitorLayoutTests {
    // A laptop-style desk: secondary 1920x1080 to the LEFT of a 4K primary at 150%.
    let desk = [
        MonitorSpec(x: 0, y: 0, width: 3840, height: 2160, isPrimary: true, scalePercent: 150),
        MonitorSpec(x: -1920, y: 540, width: 1920, height: 1080, scalePercent: 100),
    ]

    @Test func normalizesToDesktopSpace() throws {
        let layout = try MonitorLayout(desk)
        #expect(layout.monitors[0].frame == CGRect(x: 1920, y: 0, width: 3840, height: 2160))
        #expect(layout.monitors[1].frame == CGRect(x: 0, y: 540, width: 1920, height: 1080))
        #expect(layout.primaryIndex == 0)
        #expect(layout.desktopSize == (5760, 2160))
    }

    @Test func hitTestingFallsBackToNearestMonitor() throws {
        let layout = try MonitorLayout(desk)
        #expect(layout.monitorIndex(at: CGPoint(x: 100, y: 600)) == 1)
        #expect(layout.monitorIndex(at: CGPoint(x: 2000, y: 100)) == 0)
        // Above the left monitor is empty space; nearest is the left monitor.
        #expect(layout.monitorIndex(at: CGPoint(x: 100, y: 10)) == 1)
    }

    @Test func matchClientScalingMirrorsWindowsScale() throws {
        let layout = try MonitorLayout(desk)
        #expect(layout.displayMode(for: 0, policy: .matchClient)
                == VirtualDisplayMode(pointWidth: 2560, pointHeight: 1440, hiDPI: true))
        #expect(layout.displayMode(for: 1, policy: .matchClient)
                == VirtualDisplayMode(pointWidth: 1920, pointHeight: 1080, hiDPI: false))
        #expect(layout.displayMode(for: 0, policy: .native)
                == VirtualDisplayMode(pointWidth: 3840, pointHeight: 2160, hiDPI: false))
    }

    @Test func primaryBecomesMacMainDisplay() throws {
        let layout = try MonitorLayout(desk)
        let origins = layout.macOrigins(policy: .native)
        #expect(origins[0] == .zero)
        #expect(origins[1] == CGPoint(x: -1920, y: 540))
    }

    @Test func rejectsNonsenseLayouts() {
        #expect(throws: MonitorLayout.Invalid.empty) { try MonitorLayout([]) }
        #expect(throws: MonitorLayout.Invalid.badSize(index: 0)) {
            try MonitorLayout([MonitorSpec(x: 0, y: 0, width: 10, height: 10)])
        }
        #expect(throws: MonitorLayout.Invalid.tooLarge) {
            try MonitorLayout((0..<5).map { MonitorSpec(x: $0 * 8000, y: 0, width: 8000, height: 1000) })
        }
    }
}

struct KeyMapTests {
    @Test func lettersAndNavigation() {
        #expect(KeyMap.macKeyCode(scancode: 0x1E, extended: false, style: .mac) == 0x00) // A
        #expect(KeyMap.macKeyCode(scancode: 0x48, extended: true, style: .mac) == 0x7E) // Up
        #expect(KeyMap.macKeyCode(scancode: 0x48, extended: false, style: .mac) == 0x5B) // keypad 8
        #expect(KeyMap.macKeyCode(scancode: 0x53, extended: true, style: .mac) == 0x75) // Delete
        #expect(KeyMap.macKeyCode(scancode: 0xFF, extended: false, style: .mac) == nil)
    }

    @Test func modifierStyles() {
        let ctrl: UInt8 = 0x1D, win: UInt8 = 0x5B, alt: UInt8 = 0x38
        #expect(KeyMap.macKeyCode(scancode: win, extended: true, style: .mac) == KeyMap.Mac.command)
        #expect(KeyMap.macKeyCode(scancode: ctrl, extended: false, style: .mac) == KeyMap.Mac.control)
        #expect(KeyMap.macKeyCode(scancode: ctrl, extended: false, style: .windowsShortcuts) == KeyMap.Mac.command)
        #expect(KeyMap.macKeyCode(scancode: win, extended: true, style: .windowsShortcuts) == KeyMap.Mac.control)
        #expect(KeyMap.macKeyCode(scancode: alt, extended: false, style: .windowsShortcuts) == KeyMap.Mac.option)
    }
}
