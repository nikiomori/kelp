// Developer aids, debug builds: the keys KELP_TYPE sends, the hovers KELP_HOVER sends, and the snapshot's end.
import AppKit
import Core
import TerminalKit
import WebKit
import WorkbenchKit

#if DEBUG

    extension AppDelegate {
        static var hovered = false
        /// `{f2}`, `{shift+f12}`.
        static let functionKeys: [String: (char: String, code: UInt16)] = [
            "f2": ("\u{F705}", 120), "f8": ("\u{F70B}", 100), "f12": ("\u{F70F}", 111)
        ]
        /// Quits, and takes along the daemon the app started in a KELP_HOME of the snapshot's own: each one would stay behind.
        /// Never one under ~/.kelp*, a home someone lives in.
        func finishSnapshot() {
            let home = Paths.root.path
            guard getenv("KELP_HOME") != nil, !home.hasPrefix(NSHomeDirectory() + "/.kelp") else { exit(0) }
            Task {
                await app.quiet(DaemonShutdown())
                exit(0)
            }
        }

        static func hover(_ text: String, in root: NSView, window: NSWindow) {
            guard let label = root.allSubviews(of: NSTextField.self).first(where: { $0.stringValue == text }) else {
                print("HOVER no", text)
                return
            }
            var candidate: NSView? = label
            while let view = candidate, view.trackingAreas.isEmpty { candidate = view.superview }
            guard let target = candidate,
                let event = NSEvent.enterExitEvent(
                    with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
            else {
                print("HOVER nothing tracks", text)
                return
            }
            target.mouseEntered(with: event)
            print("HOVER", text, "→", type(of: target))
        }

        /// Dev aid: real key events through NSApp (menus, key equivalents, the terminal's keyDown/IME path).
        /// "echo hi\r" types text; "{cmd+t}" / "{cmd+\\}" press shortcuts; "{wait}" pauses a second (async UI); "{ok}" presses a sheet's default button.
        func typeKeys(_ spec: String) {
            let app = self.app
            let codes: [Character: UInt16] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
                "w": 13,
                "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25,
                "7": 26, "8": 28, "0": 29, "o": 31,
                "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49, "\r": 36, "-": 27,
                "=": 24, "\\": 42, "/": 44, "?": 44,
                // ЙЦУКЕН on the same keys, to press ⌘Ц the way a Russian layout sends it
                "й": 12, "ц": 13, "у": 14, "к": 15, "е": 17, "н": 16, "г": 32, "ш": 34, "щ": 31, "з": 35, "ф": 0,
                "ы": 1, "в": 2, "а": 3,
                "п": 5, "р": 4, "о": 38, "л": 40, "д": 37, "я": 6, "ч": 7, "с": 8, "м": 9, "и": 11, "т": 45, "ь": 46
            ]
            var events: [(String, NSEvent.ModifierFlags)] = []
            var rest = Substring(spec.replacingOccurrences(of: "\\r", with: "\r"))
            while let char = rest.first {
                if char == "{", let end = rest.firstIndex(of: "}") {
                    let combo = rest[rest.index(after: rest.startIndex)..<end].split(separator: "+")
                    var mods: NSEvent.ModifierFlags = []
                    for m in combo.dropLast() {
                        mods.insert(
                            ["cmd": .command, "shift": .shift, "opt": .option, "ctrl": .control][String(m)] ?? [])
                    }
                    var key = String(combo.last ?? "")
                    key =
                        [
                            "up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}", "tab": "\t",
                            "esc": "\u{1B}",
                            "delete": "\u{7F}", "space": " ", "return": "\r"
                        ][key] ?? Self.functionKeys[key]?.char ?? key
                    events.append((mods.contains(.shift) ? key.uppercased() : key, mods))
                    rest = rest[rest.index(after: end)...]
                } else {
                    events.append((String(char), []))
                    rest = rest.dropFirst()
                }
            }
            main.window?.makeKeyAndOrderFront(nil)
            app.workbench.editor?.focusSelected()
            var at = 0.3
            for (ch, mods) in events {
                if ch == "wait", mods.isEmpty {
                    at += 1
                    continue
                }
                at += 0.05
                if ch == "ok", mods.isEmpty {   // The sheet's default button: a window in the background doesn't get ↩ to it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) { [self] in
                        let sheet = main.window?.attachedSheet,
                            buttons = sheet?.contentView?.allSubviews(of: NSButton.self) ?? []
                        let chosen = buttons.first {
                            $0.keyEquivalent == "\r" || ($0.cell === sheet?.defaultButtonCell && $0.cell != nil)
                        }
                        chosen?.performClick(nil)
                    }
                    continue
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [self] in
                    let named: [String: UInt16] = [
                        "\u{F700}": 126, "\u{F701}": 125, "\u{F702}": 123, "\u{F703}": 124, "\t": 48, "\u{1B}": 53,
                        "\u{7F}": 51
                    ]
                    let function = Self.functionKeys.values.first { $0.char == ch }?.code
                    let code = function ?? named[ch] ?? (ch.count == 1 ? codes[Character(ch.lowercased())] ?? 0 : 0)
                    defer {
                        if !mods.isEmpty {
                            DispatchQueue.main.async {
                                let shown = app.worktree(app.workbench.workspaceId)?.displayName ?? "-"
                                print(
                                    "KEY", mods.rawValue, ch.unicodeScalars.map { String($0.value, radix: 16) }, "→",
                                    shown)
                            }
                        }
                    }
                    // In the background (launched from a shell) there's no key window, so menu items that go to the
                    // responder chain (Find…, Copy) are disabled: send their action along the window's chain instead.
                    if !NSApp.isActive, mods.contains(.command), let item = Self.menuItem(ch, mods), item.target == nil,
                        let action = item.action,
                        main.window?.firstResponder?.tryToPerform(action, with: item) == true
                    {
                        return
                    }
                    // As a keyboard's do.
                    let flags =
                        (123...126).contains(code)
                        ? mods.union([.numericPad, .function]) : function != nil ? mods.union(.function) : mods
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        guard
                            let event = NSEvent.keyEvent(
                                with: type, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: (NSApp.keyWindow ?? main.window)?.windowNumber ?? 0, context: nil,
                                characters: ch, charactersIgnoringModifiers: ch,
                                isARepeat: false, keyCode: code)
                        else { continue }
                        // Without a key window AppKit offers a shortcut to the menu only; a user's goes to the window's views first.
                        if type == .keyDown, !mods.isEmpty, NSApp.keyWindow == nil,
                            main.window?.performKeyEquivalent(with: event) == true
                        {
                            continue
                        }
                        NSApp.sendEvent(event)
                    }
                }
            }
        }
    }

#endif
