import Foundation

// A machine's keyboard: characters and key names as US key codes, for typing into its screen from the Mac's side.

extension VMs {
    /// A character → its key code on a US keyboard and whether it takes Shift: what a machine's screen types from the Mac's
    /// side. Nil: no key for it (`kelp vm type` pastes such text instead).
    public static func usKey(_ char: Character) -> (code: UInt16, shift: Bool)? {
        if let code = keyCodes[String(char)], char.isASCII, !char.isUppercase { return (code, false) }
        if char.isUppercase, char.isASCII, let code = keyCodes[char.lowercased()] { return (code, true) }
        if let base = shifted[char], let code = keyCodes[String(base)] { return (code, true) }
        return nil
    }

    /// Key names and characters → US key codes (`kelp vm key cmd+shift+t`).
    public static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\n": 36, "l": 37, "j": 38, "'": 39,
        "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "forwarddelete": 117, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101,
        "f10": 109, "f11": 103, "f12": 111
    ]
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-",
        "+": "=",
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
    ]
}
