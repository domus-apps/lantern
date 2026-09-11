import AppKit
import Carbon.HIToolbox

/* One recordable shortcut: a Carbon-compatible key code + modifier mask,
   plus the key's display label captured at record time (deriving labels
   from key codes needs layout-aware translation; capturing is simpler). */
struct ShortcutSpec: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    /// ⌥⌘S — the default, free on a stock Mac.
    static let defaultCapture = ShortcutSpec(
        keyCode: UInt32(kVK_ANSI_S),
        carbonModifiers: UInt32(optionKey) | UInt32(cmdKey),
        keyLabel: "S")

    var displayString: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyLabel
    }

    /* For NSMenuItem: the key equivalent is a character, so only shortcuts
       whose label is a single character can be shown in the menu. */
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags)? {
        guard keyLabel.count == 1 else { return nil }
        var mask: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        return (keyLabel.lowercased(), mask)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    static func keyLabel(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}
