import AppKit
import ApplicationServices
import CoreGraphics

/// Replays RDP input on the Mac as if it came from local hardware.
/// Requires the Accessibility permission.
@MainActor
public final class InputInjector {
    public enum MouseButton: Sendable {
        case left, right, middle, back, forward

        var cgButton: CGMouseButton {
            switch self {
            case .left: .left
            case .right: .right
            case .middle: .center
            case .back: CGMouseButton(rawValue: 3)!
            case .forward: CGMouseButton(rawValue: 4)!
            }
        }
    }

    public var modifierStyle: ModifierStyle
    /// Pixels to scroll per wheel notch (Windows reports 120 units per notch).
    public var scrollPixelsPerNotch: Double

    /// Maps an RDP desktop-space point to Mac global coordinates.
    private var toMac: (CGPoint) -> CGPoint = { $0 }
    private let source = CGEventSource(stateID: .hidSystemState)
    private var heldModifiers: [CGKeyCode: CGEventFlags] = [:]
    private var capsLockOn = false
    private var heldButtons: Set<CGMouseButton.RawValue> = []
    private var position = CGPoint.zero
    private var lastClick: (button: CGMouseButton, time: TimeInterval, point: CGPoint, count: Int64)?

    public init(modifierStyle: ModifierStyle = .mac, scrollPixelsPerNotch: Double = 40) {
        self.modifierStyle = modifierStyle
        self.scrollPixelsPerNotch = scrollPixelsPerNotch
        source?.localEventsSuppressionInterval = 0
    }

    nonisolated public static func isTrusted(prompt: Bool) -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt, which Swift 6 flags as a mutable global.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Points input at the current set of virtual displays.
    public func target(layout: MonitorLayout, monitors: [VirtualMonitor]) {
        let byIndex = Dictionary(uniqueKeysWithValues: monitors.map { ($0.index, $0) })
        toMac = { point in
            let i = layout.monitorIndex(at: point)
            let spec = layout.monitors[i]
            guard let bounds = byIndex[i]?.bounds, spec.width > 0, spec.height > 0 else { return point }
            let u = min(max((point.x - CGFloat(spec.x)) / CGFloat(spec.width), 0), 0.9999)
            let v = min(max((point.y - CGFloat(spec.y)) / CGFloat(spec.height), 0), 0.9999)
            return CGPoint(x: bounds.minX + u * bounds.width, y: bounds.minY + v * bounds.height)
        }
    }

    // MARK: Keyboard

    public func key(scancode: UInt8, extended: Bool, down: Bool) {
        guard let code = KeyMap.macKeyCode(scancode: scancode, extended: extended, style: modifierStyle),
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        else { return }

        if let flag = KeyMap.modifierFlags[code] {
            if down { heldModifiers[code] = flag } else { heldModifiers[code] = nil }
            event.type = .flagsChanged
        } else if code == KeyMap.capsLock {
            guard down else { return }
            capsLockOn.toggle()
            event.type = .flagsChanged
        }
        event.flags = currentFlags.union(KeyMap.intrinsicFlags(for: code))
        event.post(tap: .cghidEventTap)
    }

    /// Text the client sends as characters rather than keys (IME, on-screen keyboard).
    public func unicode(_ codeUnit: UInt16, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return }
        var unit = codeUnit
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        event.post(tap: .cghidEventTap)
    }

    /// Clears stuck keys and buttons, e.g. when the client loses focus or disconnects.
    public func releaseAll() {
        for code in heldModifiers.keys {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                event.type = .flagsChanged
                event.post(tap: .cghidEventTap)
            }
        }
        heldModifiers.removeAll()
        for raw in heldButtons {
            if let button = CGMouseButton(rawValue: raw) { post(button: button, down: false) }
        }
        heldButtons.removeAll()
    }

    private var currentFlags: CGEventFlags {
        var flags = heldModifiers.values.reduce(CGEventFlags()) { $0.union($1) }
        if capsLockOn { flags.insert(.maskAlphaShift) }
        return flags
    }

    // MARK: Mouse

    public func mouseMove(to desktopPoint: CGPoint) {
        position = toMac(desktopPoint)
        let (type, button) = dragState()
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: position, mouseButton: button) else { return }
        event.flags = currentFlags
        event.post(tap: .cghidEventTap)
    }

    public func mouseButton(_ button: MouseButton, down: Bool, at desktopPoint: CGPoint) {
        position = toMac(desktopPoint)
        let cg = button.cgButton
        if down { heldButtons.insert(cg.rawValue) } else { heldButtons.remove(cg.rawValue) }
        post(button: cg, down: down)
    }

    /// `vertical` / `horizontal` are in Windows wheel units (120 per notch,
    /// positive = up / right).
    public func scroll(vertical: Int, horizontal: Int) {
        let dy = Int32((Double(vertical) / 120 * scrollPixelsPerNotch).rounded())
        // macOS horizontal deltas are positive to the left.
        let dx = Int32((Double(-horizontal) / 120 * scrollPixelsPerNotch).rounded())
        guard dy != 0 || dx != 0,
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        event.flags = currentFlags
        event.post(tap: .cghidEventTap)
    }

    private func post(button: CGMouseButton, down: Bool) {
        let type: CGEventType = switch (button, down) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        case (_, true): .otherMouseDown
        case (_, false): .otherMouseUp
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: position, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount(button: button, down: down))
        event.flags = currentFlags
        event.post(tap: .cghidEventTap)
    }

    /// macOS only recognises double/triple clicks when events carry a click count.
    private func clickCount(button: CGMouseButton, down: Bool) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        if !down { return lastClick?.button == button ? lastClick!.count : 1 }
        var count: Int64 = 1
        if let last = lastClick, last.button == button,
           now - last.time <= NSEvent.doubleClickInterval,
           abs(last.point.x - position.x) <= 4, abs(last.point.y - position.y) <= 4 {
            count = last.count + 1
        }
        lastClick = (button, now, position, count)
        return count
    }

    private func dragState() -> (CGEventType, CGMouseButton) {
        if heldButtons.contains(CGMouseButton.left.rawValue) { return (.leftMouseDragged, .left) }
        if heldButtons.contains(CGMouseButton.right.rawValue) { return (.rightMouseDragged, .right) }
        if let other = heldButtons.first, let button = CGMouseButton(rawValue: other) {
            return (.otherMouseDragged, button)
        }
        return (.mouseMoved, .left)
    }
}
