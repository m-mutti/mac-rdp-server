import CoreGraphics

/// Input decoded from RDP fast-path / slow-path input flags (MS-RDPBCGR 2.2.8.1.1.3.1.1).
public enum RDPInputEvent: Equatable, Sendable {
    case key(scancode: UInt8, extended: Bool, down: Bool)
    /// A UTF-16 code unit typed as text (IME, emoji, on-screen keyboard).
    case text(UInt16, down: Bool)
    case move(CGPoint)
    case button(InputInjector.MouseButton, down: Bool, at: CGPoint)
    /// Windows wheel units, 120 per notch; positive is up / right.
    case wheel(vertical: Int, horizontal: Int)

    enum Flag {
        static let keyExtended: UInt16 = 0x0100
        static let keyExtended1: UInt16 = 0x0200
        static let keyRelease: UInt16 = 0x8000

        static let wheel: UInt16 = 0x0200
        static let hWheel: UInt16 = 0x0400
        static let rotationMask: UInt16 = 0x01FF
        static let move: UInt16 = 0x0800
        static let down: UInt16 = 0x8000
        static let button1: UInt16 = 0x1000
        static let button2: UInt16 = 0x2000
        static let button3: UInt16 = 0x4000
        static let xButton1: UInt16 = 0x0001
        static let xButton2: UInt16 = 0x0002
    }

    public static func keyboard(flags: UInt16, scancode: UInt8) -> RDPInputEvent? {
        // EXTENDED1 only accompanies Pause/Break, whose scancode would
        // otherwise alias Left Ctrl.
        guard flags & Flag.keyExtended1 == 0 else { return nil }
        return .key(scancode: scancode, extended: flags & Flag.keyExtended != 0,
                    down: flags & Flag.keyRelease == 0)
    }

    public static func unicode(flags: UInt16, code: UInt16) -> RDPInputEvent {
        .text(code, down: flags & Flag.keyRelease == 0)
    }

    public static func mouse(flags: UInt16, x: UInt16, y: UInt16) -> [RDPInputEvent] {
        // Wheel events carry a 9-bit two's complement rotation; their
        // coordinates are meaningless.
        if flags & (Flag.wheel | Flag.hWheel) != 0 {
            var rotation = Int(flags & Flag.rotationMask)
            if rotation & 0x100 != 0 { rotation -= 0x200 }
            return flags & Flag.hWheel != 0
                ? [.wheel(vertical: 0, horizontal: rotation)]
                : [.wheel(vertical: rotation, horizontal: 0)]
        }
        let point = CGPoint(x: Int(x), y: Int(y))
        var events: [RDPInputEvent] = []
        if flags & Flag.move != 0 { events.append(.move(point)) }
        let down = flags & Flag.down != 0
        let buttons: [(UInt16, InputInjector.MouseButton)] = [
            (Flag.button1, .left), (Flag.button2, .right), (Flag.button3, .middle),
        ]
        for (bit, button) in buttons where flags & bit != 0 {
            events.append(.button(button, down: down, at: point))
        }
        return events
    }

    public static func extendedMouse(flags: UInt16, x: UInt16, y: UInt16) -> [RDPInputEvent] {
        let point = CGPoint(x: Int(x), y: Int(y))
        let down = flags & Flag.down != 0
        var events: [RDPInputEvent] = []
        if flags & Flag.xButton1 != 0 { events.append(.button(.back, down: down, at: point)) }
        if flags & Flag.xButton2 != 0 { events.append(.button(.forward, down: down, at: point)) }
        return events
    }
}

extension InputInjector {
    public func apply(_ event: RDPInputEvent) {
        switch event {
        case let .key(scancode, extended, down):
            key(scancode: scancode, extended: extended, down: down)
        case let .text(code, down):
            unicode(code, down: down)
        case let .move(point):
            mouseMove(to: point)
        case let .button(button, down, point):
            mouseButton(button, down: down, at: point)
        case let .wheel(vertical, horizontal):
            scroll(vertical: vertical, horizontal: horizontal)
        }
    }
}
