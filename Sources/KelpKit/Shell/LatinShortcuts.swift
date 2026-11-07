import AppKit
import Carbon.HIToolbox

/// ⌘-shortcuts on a non-Latin layout (Russian, Greek, Hebrew…): a ⌘ key that comes in with a non-Latin letter goes on
/// as the letter that key types on the user's Latin layout — ⌘Ц is ⌘W, ⌘С is ⌘C — so menus, the terminal's own
/// bindings and text views all see the shortcut they know, like in most Mac apps.
@MainActor
enum LatinShortcuts {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.contains(.command), let typed = e.charactersIgnoringModifiers,
                typed.unicodeScalars.contains(where: isLetterOfAnotherScript), let latin = latin(e),
                let t = NSEvent.keyEvent(
                    with: .keyDown, location: e.locationInWindow, modifierFlags: e.modifierFlags,
                    timestamp: e.timestamp,
                    windowNumber: e.windowNumber, context: nil, characters: latin, charactersIgnoringModifiers: latin,
                    isARepeat: e.isARepeat, keyCode: e.keyCode)
            else { return e }
            return t
        }
    }

    /// ⌘Ц yes; ⌘↓ no: arrows and other function keys come as private-use characters (NSUpArrowFunctionKey…).
    static func isLetterOfAnotherScript(_ c: Unicode.Scalar) -> Bool {
        !c.isASCII && !(0xF700...0xF8FF).contains(c.value)
    }

    /// The character this key types on the current ASCII-capable layout (shift kept, other modifiers dropped).
    static func latin(_ e: NSEvent) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let shift = e.modifierFlags.contains(.shift) ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(
                layout, e.keyCode, UInt16(kUCKeyActionDisplay), shift, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length) : nil
        }
    }
}
