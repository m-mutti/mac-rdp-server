import CoreGraphics

/// How the Windows keyboard's modifier keys act on the Mac.
public enum ModifierStyle: String, Sendable, CaseIterable {
    /// Same as plugging a PC keyboard into a Mac: Windows key = Command,
    /// Alt = Option, Ctrl = Control.
    case mac
    /// Keep Windows muscle memory: Ctrl = Command (Ctrl+C copies, Ctrl+Tab
    /// switches tabs), Windows key = Control, Alt = Option.
    case windowsShortcuts
}

/// Maps RDP keyboard events (PC/AT set 1 scancodes, MS-RDPBCGR 2.2.8.1.1.3.1.1.1)
/// to macOS virtual key codes (Carbon `kVK_*`).
public enum KeyMap {
    public static func macKeyCode(scancode: UInt8, extended: Bool, style: ModifierStyle) -> CGKeyCode? {
        guard let code = extended ? extendedKeys[scancode] : standardKeys[scancode] else { return nil }
        guard style == .windowsShortcuts else { return code }
        switch code {
        case Mac.control: return Mac.command
        case Mac.rightControl: return Mac.rightCommand
        case Mac.command: return Mac.control
        case Mac.rightCommand: return Mac.rightControl
        default: return code
        }
    }

    /// Modifier keys and the event flag each one holds down.
    public static let modifierFlags: [CGKeyCode: CGEventFlags] = [
        Mac.command: .maskCommand, Mac.rightCommand: .maskCommand,
        Mac.shift: .maskShift, Mac.rightShift: .maskShift,
        Mac.option: .maskAlternate, Mac.rightOption: .maskAlternate,
        Mac.control: .maskControl, Mac.rightControl: .maskControl,
    ]

    public static let capsLock: CGKeyCode = 0x39

    /// Flags a Mac keyboard sets on some keys by itself: fn on the arrows,
    /// the navigation keys and F-keys, numeric pad on the arrows and keypad.
    /// macOS's own shortcuts include them (Mission Control is ⌃ fn ↑), so
    /// injected keys need them to match.
    public static func intrinsicFlags(for code: CGKeyCode) -> CGEventFlags {
        if arrows.contains(code) { return [.maskSecondaryFn, .maskNumericPad] }
        if functionKeys.contains(code) { return .maskSecondaryFn }
        if keypad.contains(code) { return .maskNumericPad }
        return []
    }

    private static let arrows: Set<CGKeyCode> = [0x7B, 0x7C, 0x7D, 0x7E]
    /// F1-F20, then Help, Home, Page Up, Forward Delete, End, Page Down.
    private static let functionKeys: Set<CGKeyCode> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        0x72, 0x73, 0x74, 0x75, 0x77, 0x79,
    ]
    /// Keypad 0-9, then . * + Clear / Enter - = and the JIS keypad comma.
    private static let keypad: Set<CGKeyCode> = [
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C,
        0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51, 0x5F,
    ]

    enum Mac {
        static let command: CGKeyCode = 0x37
        static let rightCommand: CGKeyCode = 0x36
        static let shift: CGKeyCode = 0x38
        static let rightShift: CGKeyCode = 0x3C
        static let option: CGKeyCode = 0x3A
        static let rightOption: CGKeyCode = 0x3D
        static let control: CGKeyCode = 0x3B
        static let rightControl: CGKeyCode = 0x3E
    }

    private static let standardKeys: [UInt8: CGKeyCode] = [
        0x01: 0x35, // Esc
        0x02: 0x12, 0x03: 0x13, 0x04: 0x14, 0x05: 0x15, 0x06: 0x17, // 1-5
        0x07: 0x16, 0x08: 0x1A, 0x09: 0x1C, 0x0A: 0x19, 0x0B: 0x1D, // 6-0
        0x0C: 0x1B, 0x0D: 0x18, // - =
        0x0E: 0x33, // Backspace
        0x0F: 0x30, // Tab
        0x10: 0x0C, 0x11: 0x0D, 0x12: 0x0E, 0x13: 0x0F, 0x14: 0x11, // Q W E R T
        0x15: 0x10, 0x16: 0x20, 0x17: 0x22, 0x18: 0x1F, 0x19: 0x23, // Y U I O P
        0x1A: 0x21, 0x1B: 0x1E, // [ ]
        0x1C: 0x24, // Enter
        0x1D: Mac.control,
        0x1E: 0x00, 0x1F: 0x01, 0x20: 0x02, 0x21: 0x03, 0x22: 0x05, // A S D F G
        0x23: 0x04, 0x24: 0x26, 0x25: 0x28, 0x26: 0x25, // H J K L
        0x27: 0x29, 0x28: 0x27, 0x29: 0x32, // ; ' `
        0x2A: Mac.shift,
        0x2B: 0x2A, // backslash
        0x2C: 0x06, 0x2D: 0x07, 0x2E: 0x08, 0x2F: 0x09, 0x30: 0x0B, // Z X C V B
        0x31: 0x2D, 0x32: 0x2E, // N M
        0x33: 0x2B, 0x34: 0x2F, 0x35: 0x2C, // , . /
        0x36: Mac.rightShift,
        0x37: 0x43, // keypad *
        0x38: Mac.option, // left Alt
        0x39: 0x31, // Space
        0x3A: capsLock,
        0x3B: 0x7A, 0x3C: 0x78, 0x3D: 0x63, 0x3E: 0x76, 0x3F: 0x60, // F1-F5
        0x40: 0x61, 0x41: 0x62, 0x42: 0x64, 0x43: 0x65, 0x44: 0x6D, // F6-F10
        0x45: 0x47, // Num Lock -> keypad Clear (same position)
        0x46: 0x6B, // Scroll Lock -> F14 (macOS brightness down)
        0x47: 0x59, 0x48: 0x5B, 0x49: 0x5C, 0x4A: 0x4E, // keypad 7 8 9 -
        0x4B: 0x56, 0x4C: 0x57, 0x4D: 0x58, 0x4E: 0x45, // keypad 4 5 6 +
        0x4F: 0x53, 0x50: 0x54, 0x51: 0x55, // keypad 1 2 3
        0x52: 0x52, 0x53: 0x41, // keypad 0 .
        0x56: 0x0A, // ISO key left of Z
        0x57: 0x67, 0x58: 0x6F, // F11 F12
        0x59: 0x51, // keypad =
        0x64: 0x69, 0x65: 0x6B, 0x66: 0x71, 0x67: 0x6A, // F13-F16
        0x68: 0x40, 0x69: 0x4F, 0x6A: 0x50, 0x6B: 0x5A, // F17-F20
        0x70: 0x68, // JIS Kana
        0x73: 0x5E, // JIS Ro (underscore)
        0x7B: 0x66, // JIS Muhenkan -> Eisu
        0x7D: 0x5D, // JIS Yen
        0x7E: 0x5F, // keypad comma
    ]

    private static let extendedKeys: [UInt8: CGKeyCode] = [
        0x1C: 0x4C, // keypad Enter
        0x1D: Mac.rightControl,
        0x35: 0x4B, // keypad /
        0x37: 0x69, // Print Screen -> F13
        0x38: Mac.rightOption, // right Alt / AltGr
        0x47: 0x73, // Home
        0x48: 0x7E, // Up
        0x49: 0x74, // Page Up
        0x4B: 0x7B, // Left
        0x4D: 0x7C, // Right
        0x4F: 0x77, // End
        0x50: 0x7D, // Down
        0x51: 0x79, // Page Down
        0x52: 0x72, // Insert -> Help (same position on Apple extended keyboards)
        0x53: 0x75, // Delete -> Forward Delete
        0x5B: Mac.command, // left Windows
        0x5C: Mac.rightCommand, // right Windows
    ]
}
