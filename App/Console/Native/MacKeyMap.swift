import Carbon.HIToolbox

/// macOS virtual key codes → PC XT set-1 scancodes, by key *position*.
/// 0xE0-prefixed keys are `0x100 | code`, the spice-glib convention.
enum MacKeyMap {
    static let escape: UInt32 = 0x01
    static let backspace: UInt32 = 0x0E
    static let leftControl: UInt32 = 0x1D
    static let leftShift: UInt32 = 0x2A
    static let leftAlt: UInt32 = 0x38
    static let delete: UInt32 = 0x153

    /// F1…F12.
    static func function(_ n: Int) -> UInt32? {
        switch n {
        case 1...10: return UInt32(0x3B + n - 1)
        case 11: return 0x57
        case 12: return 0x58
        default: return nil
        }
    }

    static func scancode(forKeyCode keyCode: UInt16) -> UInt32? { table[Int(keyCode)] }

    private static let table: [Int: UInt32] = [
        kVK_ANSI_A: 0x1E, kVK_ANSI_S: 0x1F, kVK_ANSI_D: 0x20, kVK_ANSI_F: 0x21, kVK_ANSI_H: 0x23, kVK_ANSI_G: 0x22,
        kVK_ANSI_Z: 0x2C, kVK_ANSI_X: 0x2D, kVK_ANSI_C: 0x2E, kVK_ANSI_V: 0x2F, kVK_ISO_Section: 0x56, kVK_ANSI_B: 0x30,
        kVK_ANSI_Q: 0x10, kVK_ANSI_W: 0x11, kVK_ANSI_E: 0x12, kVK_ANSI_R: 0x13, kVK_ANSI_Y: 0x15, kVK_ANSI_T: 0x14,
        kVK_ANSI_1: 0x02, kVK_ANSI_2: 0x03, kVK_ANSI_3: 0x04, kVK_ANSI_4: 0x05, kVK_ANSI_6: 0x07, kVK_ANSI_5: 0x06,
        kVK_ANSI_Equal: 0x0D, kVK_ANSI_9: 0x0A, kVK_ANSI_7: 0x08, kVK_ANSI_Minus: 0x0C, kVK_ANSI_8: 0x09, kVK_ANSI_0: 0x0B,
        kVK_ANSI_RightBracket: 0x1B, kVK_ANSI_O: 0x18, kVK_ANSI_U: 0x16, kVK_ANSI_LeftBracket: 0x1A, kVK_ANSI_I: 0x17,
        kVK_ANSI_P: 0x19, kVK_Return: 0x1C, kVK_ANSI_L: 0x26, kVK_ANSI_J: 0x24, kVK_ANSI_Quote: 0x28, kVK_ANSI_K: 0x25,
        kVK_ANSI_Semicolon: 0x27, kVK_ANSI_Backslash: 0x2B, kVK_ANSI_Comma: 0x33, kVK_ANSI_Slash: 0x35, kVK_ANSI_N: 0x31,
        kVK_ANSI_M: 0x32, kVK_ANSI_Period: 0x34, kVK_Tab: 0x0F, kVK_Space: 0x39, kVK_ANSI_Grave: 0x29,
        kVK_Delete: 0x0E, kVK_Escape: 0x01,
        // Modifiers. Command ↔ Windows key.
        kVK_RightCommand: 0x15C, kVK_Command: 0x15B, kVK_Shift: 0x2A, kVK_CapsLock: 0x3A, kVK_Option: 0x38,
        kVK_Control: 0x1D, kVK_RightShift: 0x36, kVK_RightOption: 0x138, kVK_RightControl: 0x11D,
        // Keypad.
        kVK_ANSI_KeypadDecimal: 0x53, kVK_ANSI_KeypadMultiply: 0x37, kVK_ANSI_KeypadPlus: 0x4E, kVK_ANSI_KeypadClear: 0x45,
        kVK_ANSI_KeypadDivide: 0x135, kVK_ANSI_KeypadEnter: 0x11C, kVK_ANSI_KeypadMinus: 0x4A,
        kVK_ANSI_Keypad0: 0x52, kVK_ANSI_Keypad1: 0x4F, kVK_ANSI_Keypad2: 0x50, kVK_ANSI_Keypad3: 0x51, kVK_ANSI_Keypad4: 0x4B,
        kVK_ANSI_Keypad5: 0x4C, kVK_ANSI_Keypad6: 0x4D, kVK_ANSI_Keypad7: 0x47, kVK_ANSI_Keypad8: 0x48, kVK_ANSI_Keypad9: 0x49,
        // Function row.
        kVK_F1: 0x3B, kVK_F2: 0x3C, kVK_F3: 0x3D, kVK_F4: 0x3E, kVK_F5: 0x3F, kVK_F6: 0x40, kVK_F7: 0x41, kVK_F8: 0x42,
        kVK_F9: 0x43, kVK_F10: 0x44, kVK_F11: 0x57, kVK_F12: 0x58, kVK_F13: 0x137, kVK_F14: 0x46,
        // Navigation.
        kVK_Help: 0x152, kVK_Home: 0x147, kVK_PageUp: 0x149, kVK_ForwardDelete: 0x153, kVK_End: 0x14F, kVK_PageDown: 0x151,
        kVK_LeftArrow: 0x14B, kVK_RightArrow: 0x14D, kVK_DownArrow: 0x150, kVK_UpArrow: 0x148,
    ]

    /// US-layout character → (scancode, needs shift), for paste-as-keystrokes.
    static func stroke(for ch: Character) -> (scancode: UInt32, shift: Bool)? {
        if let s = plain[ch] { return (s, false) }
        if let s = shifted[ch] { return (s, true) }
        if ch.isLetter, ch.isASCII, let s = plain[Character(ch.lowercased())] { return (s, ch.isUppercase) }
        return nil
    }

    private static let plain: [Character: UInt32] = {
        var m: [Character: UInt32] = [
            "`": 0x29, "-": 0x0C, "=": 0x0D, "[": 0x1A, "]": 0x1B, "\\": 0x2B, ";": 0x27, "'": 0x28, ",": 0x33, ".": 0x34,
            "/": 0x35, " ": 0x39, "\n": 0x1C, "\t": 0x0F,
        ]
        for (i, c) in "1234567890".enumerated() { m[c] = UInt32(0x02 + i) }
        for (c, s) in zip("qwertyuiop", 0x10...) { m[c] = UInt32(s) }
        for (c, s) in zip("asdfghjkl", 0x1E...) { m[c] = UInt32(s) }
        for (c, s) in zip("zxcvbnm", 0x2C...) { m[c] = UInt32(s) }
        return m
    }()

    private static let shifted: [Character: UInt32] = {
        var m: [Character: UInt32] = [
            "~": 0x29, "_": 0x0C, "+": 0x0D, "{": 0x1A, "}": 0x1B, "|": 0x2B, ":": 0x27, "\"": 0x28, "<": 0x33, ">": 0x34, "?": 0x35,
        ]
        for (i, c) in "!@#$%^&*()".enumerated() { m[c] = UInt32(0x02 + i) }
        return m
    }()
}
