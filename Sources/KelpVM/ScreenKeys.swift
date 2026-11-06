import AppKit
import Virtualization
import Core

/// Typing into a macOS machine's screen from the Mac's side: key events handed to its VZVirtualMachineView, which sends
/// them to the machine's keyboard. No permission inside the machine is needed for it (Kelp Guest's Accessibility is),
/// so it types the password that Privacy & Security asks for before Kelp Guest may do anything. A US keyboard's keys.
@MainActor
enum ScreenKeys {
    /// A character → its key code on a US keyboard, and whether it takes Shift.
    static func key(_ c: Character) -> (code: UInt16, shift: Bool)? {
        let plain: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\n": 36, "l": 37, "j": 38, "'": 39, "k": 40,
            ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
            "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
        ]
        if let code = plain[c] { return (code, false) }
        if c.isUppercase, let code = plain[Character(c.lowercased())] { return (code, true) }
        if let base = shifted[c], let code = plain[base] { return (code, true) }
        return nil
    }

    /// Types `text` into `view`, a key at a time, then answers `done` (an error for a character it has no key for).
    static func type(_ text: String, into view: VZVirtualMachineView, done: @escaping (String?) -> Void) {
        let keys = text.map { ($0, key($0)) }
        if let bad = keys.first(where: { $0.1 == nil }) { return done("No key for \"\(bad.0)\" on a US keyboard.") }
        let window = view.window
        window?.makeFirstResponder(view)
        // A real left Shift's flags: the device bit (NX_DEVICELSHIFTKEYMASK) is what the machine's keyboard reads, not .shift.
        let leftShift = NSEvent.ModifierFlags(rawValue: 0x20102), idle = NSEvent.ModifierFlags(rawValue: 0x100)
        func event(_ type: NSEvent.EventType, _ code: UInt16, _ c: Character, shift: Bool) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? leftShift : idle, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window?.windowNumber ?? 0, context: nil, characters: c == "\n" ? "\r" : String(c),
                             charactersIgnoringModifiers: c == "\n" ? "\r" : String(c).lowercased(), isARepeat: false, keyCode: code)
        }
        // One event every 15 ms, Shift as keys of its own around its letter: the machine's keyboard reads each as it comes,
        // and a Shift sent in the same moment as its letter didn't reach it (nor did a first key sent with the focus).
        var events: [NSEvent] = []
        for (c, k) in keys {
            guard let k else { continue }
            if k.shift, let e = event(.flagsChanged, 56, c, shift: true) { events.append(e) }
            if let e = event(.keyDown, k.code, c, shift: k.shift) { events.append(e) }
            if let e = event(.keyUp, k.code, c, shift: k.shift) { events.append(e) }
            if k.shift, let e = event(.flagsChanged, 56, c, shift: false) { events.append(e) }
        }
        func next(_ i: Int) {
            guard i < events.count else { return done(nil) }
            let e = events[i]
            switch e.type {   // to the view itself: the window sends keys only while it's key, and kelp-vm may not be active
            case .flagsChanged: view.flagsChanged(with: e)
            case .keyDown: view.keyDown(with: e)
            default: view.keyUp(with: e)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { MainActor.assumeIsolated { next(i + 1) } }   // the main queue
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { next(0) } }   // the main queue
    }
}
