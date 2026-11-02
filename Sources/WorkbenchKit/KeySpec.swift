/// A shortcut as commands, extension manifests and settings.json `keys` write it: "shift+cmd+k".
/// `key` is AppKit's key equivalent ("K" with shift, "\r", "\u{F700}" for up); the app maps `mods` to NSEvent's flags.
public struct KeySpec: Equatable, LosslessStringConvertible {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Self(rawValue: 1), option = Self(rawValue: 2), shift = Self(rawValue: 4), command = Self(rawValue: 8)
    }
    public var key: String
    public var mods: Modifiers

    public init(key: String, mods: Modifiers) { self.key = key; self.mods = mods }

    /// Keys a spec writes by name.
    private static let named = ["up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}", "return": "\r", "tab": "\t",
                                "space": " ", "esc": "\u{1b}", "delete": "\u{8}", "plus": "+", "f8": "\u{F70B}"]
    private static let names = Dictionary(uniqueKeysWithValues: named.map { ($1, $0) }).merging(["\u{7f}": "delete"]) { $1 }

    /// "cmd+shift+k", modifiers in any order ("command", "opt", "alt", "control" too). Nil without a key.
    public init?(_ s: String) {
        var mods: Modifiers = [], key = ""
        for part in s.lowercased().split(separator: "+") {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: key = Self.named[String(part)] ?? String(part)
            }
        }
        guard !key.isEmpty else { return nil }
        self.init(key: mods.contains(.shift) && key.count == 1 ? key.uppercased() : key, mods: mods)
    }

    /// "shift+cmd+k": modifiers in the order menus show them.
    public var description: String {
        let order: [(Modifiers, String)] = [(.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd")]
        return (order.filter { mods.contains($0.0) }.map(\.1) + [Self.names[key] ?? key.lowercased()]).joined(separator: "+")
    }
}
