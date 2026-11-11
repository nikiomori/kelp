import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

/// The one place a `KeySpec`'s modifiers meet AppKit's flags (menu items, key events).
extension KeySpec.Modifiers {
    private static let appKit: [(Self, NSEvent.ModifierFlags)] = [
        (.control, .control), (.option, .option), (.shift, .shift), (.command, .command)
    ]
    /// The shortcut modifiers among `flags`; caps lock, fn and the like are dropped.
    init(_ flags: NSEvent.ModifierFlags) { self.init(Self.appKit.filter { flags.contains($0.1) }.map(\.0)) }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(Self.appKit.filter { contains($0.0) }.map(\.1)) }
}

/// Settings › Keyboard: any menu command's shortcut, set by pressing it. The menu is built with Kelp's defaults and
/// then the overrides in settings.json are laid over it: `"keys": {"editor.saveAll": "opt+cmd+s"}` ("" = none).
/// Kelp's commands go by their id; the menu's other items (Copy, Minimize, the agents in New Tab) by their English path.
@MainActor
enum KeyBindings {
    struct Entry: Identifiable {
        let id: String
        let menu: String
        let title: String
        var key: KeySpec?
        let defaultKey: KeySpec?
    }

    /// Each item's default, recorded every time the menu is built (always with the defaults).
    private static var defaults: [String: KeySpec?] = [:]
    private static let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    static func overrides(_ settings: SettingsStore) -> [String: String] {
        guard case .object(let keys)? = settings[SettingKeys.keys] else { return [:] }
        return keys.compactMapValues(\.string)
    }

    /// Names every item and applies the overrides. Runs while the titles are English.
    static func apply(to menu: NSMenu, _ settings: SettingsStore) {
        let over = overrides(settings)
        func walk(_ level: NSMenu, _ path: [String]) {
            for item in level.items where !item.isSeparatorItem {
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu { walk(submenu, path + [item.title]) }
                    continue
                }
                guard let action = item.action else { continue }
                // A command's item goes by the command id, the others by their English path ("Edit › Copy").
                let command = action == #selector(AppDelegate.runCommand(_:)),
                    name = item.identifier?.rawValue ?? item.title
                // English: the same in every language
                let id = command ? name : (path + [item.title]).joined(separator: " › ")
                item.identifier = NSUserInterfaceItemIdentifier(id)
                defaults[id] =
                    item.keyEquivalent.isEmpty
                    ? KeySpec?.none : KeySpec(key: item.keyEquivalent, mods: .init(item.keyEquivalentModifierMask))
                guard let spec = over[id] else { continue }
                let shortcut = spec.isEmpty ? nil : KeySpec(spec)
                item.keyEquivalent = shortcut?.key ?? ""
                item.keyEquivalentModifierMask = shortcut?.mods.flags ?? []
            }
        }
        walk(menu, [])
    }

    /// macOS's own app-menu commands (About, Hide, Hide Others, Show All, Quit): System Settings › Keyboard rebinds those.
    private static let systemActions: Set<Selector> = [
        #selector(NSApplication.orderFrontStandardAboutPanel(_:)), #selector(NSApplication.hide(_:)),
        #selector(NSApplication.hideOtherApplications(_:)), #selector(NSApplication.unhideAllApplications(_:)),
        #selector(NSApplication.terminate(_:))
    ]

    static func entries() -> [Entry] {
        var out: [Entry] = []
        func walk(_ level: NSMenu, _ path: [String]) {
            for item in level.items where !item.isSeparatorItem {
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu {
                        walk(submenu, path + [item.identifier?.rawValue ?? item.title])
                    }
                    continue
                }
                guard let id = item.identifier?.rawValue, defaults.keys.contains(id),
                    !(item.action.map(systemActions.contains) ?? false)
                else { continue }
                let key =
                    item.keyEquivalent.isEmpty
                    ? nil : KeySpec(key: item.keyEquivalent, mods: .init(item.keyEquivalentModifierMask))
                out.append(
                    Entry(
                        id: id, menu: path.map(loc).joined(separator: " › "), title: item.title,
                        key: key, defaultKey: defaults[id] ?? nil))
            }
        }
        NSApp.mainMenu.map { walk($0, []) }
        return out
    }

    static func matches(_ entry: Entry, _ query: String) -> Bool {
        let needle = query.lowercased()
        return needle.isEmpty
            || [entry.id, entry.menu, entry.title, entry.key.map(display) ?? ""].contains {
                $0.lowercased().contains(needle)
            }
    }

    /// nil: back to Kelp's default; a key with no key text: no shortcut.
    static func set(_ id: String, _ key: KeySpec?, in settings: SettingsStore) {
        var keys = overrides(settings)
        if let key { keys[id] = key.key.isEmpty ? "" : key.description } else { keys[id] = nil }
        settings.set(SettingKeys.keys, keys.isEmpty ? nil : .object(keys.mapValues { .string($0) }))
    }

    /// "⇧⌘K", as menus show it.
    static func display(_ key: KeySpec) -> String {
        var text = ""
        if key.mods.contains(.control) { text += "⌃" }
        if key.mods.contains(.option) { text += "⌥" }
        if key.mods.contains(.shift) { text += "⇧" }
        if key.mods.contains(.command) { text += "⌘" }
        let named: [String: String] = [
            "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\r": "↩", "\t": "⇥",
            " ": String(localized: "Space"),
            "\u{1b}": "⎋", "\u{8}": "⌫", "\u{7f}": "⌫"
        ]
        return text + (named[key.key] ?? key.key.uppercased())
    }

    /// What else answers to this combination: another of Kelp's commands, or macOS (which gets it first).
    static func conflict(_ key: KeySpec, keyCode: UInt16?, except id: String) -> String? {
        let norm = KeySpec(key: key.key.lowercased(), mods: key.mods)
        if let other = entries().first(where: {
            $0.id != id && $0.key.map { KeySpec(key: $0.key.lowercased(), mods: $0.mods) } == norm
        }) {
            let name = "\(other.menu) › \(other.title)"
            return String(localized: "Also the shortcut for \(name).")
        }
        if let code = keyCode, let name = system[SystemKey(code: code, mods: key.mods.flags.rawValue)] {
            return String(
                localized:
                    "macOS uses this for \(name), so Kelp won't see it (System Settings › Keyboard › Keyboard Shortcuts)."
            )
        }
        return nil
    }

    struct SystemKey: Hashable {
        var code: UInt16
        var mods: UInt
    }
    /// The enabled shortcuts in System Settings › Keyboard Shortcuts (Spotlight, Mission Control, input sources…).
    static let system: [SystemKey: String] = {
        let names: [Int: String] = [
            7: String(localized: "moving focus to the menu bar"), 8: String(localized: "moving focus to the Dock"),
            9: String(localized: "moving focus to the active window"),
            27: String(localized: "moving focus to the next window"), 28: String(localized: "a screenshot"),
            29: String(localized: "a screenshot to the clipboard"),
            30: String(localized: "a screenshot of an area"),
            31: String(localized: "an area screenshot to the clipboard"),
            32: "Mission Control",
            33: String(localized: "application windows"), 36: String(localized: "Show Desktop"),
            52: String(localized: "Dock hiding"),
            60: String(localized: "the previous input source"),
            61: String(localized: "the next input source"), 64: "Spotlight",
            65: String(localized: "Finder search"), 79: String(localized: "moving a space left"),
            81: String(localized: "moving a space right"), 98: String(localized: "the Help menu"),
            160: "Launchpad", 175: String(localized: "Do Not Disturb"),
            184: String(localized: "screenshot options"), 190: String(localized: "Quick Note")
        ]
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        else { return [:] }
        var out: [SystemKey: String] = [:]
        for (id, value) in all {
            guard let hotKey = value as? [String: Any],
                (hotKey["enabled"] as? Bool) == true || (hotKey["enabled"] as? Int) == 1,
                let parameters = (hotKey["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3,
                parameters[1] != 65535
            else { continue }
            out[SystemKey(code: UInt16(parameters[1]), mods: UInt(parameters[2]) & mask.rawValue)] =
                names[Int(id) ?? -1] ?? String(localized: "a system shortcut")
        }
        return out
    }()
}

/// The Keyboard page: every command, its shortcut, click to record a new one. Menus start folded but the first, what you
/// changed above them; Settings' own search lists what it finds by menu (`query`), so the page has no second search field.
struct KeyboardSettings: View {
    var query = ""
    @Environment(AppModel.self) private var app
    @State private var entries: [KeyBindings.Entry] = []
    @State private var recording: String?
    @State private var warning: [String: String] = [:]
    @State private var monitor: Any?
    @State private var open: Set<String> = []

    var body: some View {
        Group {
            if query.isEmpty {
                page
            } else {
                ForEach(groups, id: \.0) { menu, items in
                    Section("\(String(localized: "Keyboard")) › \(menu)") { ForEach(items) { e in row(e) } }
                }
            }
        }
        .onAppear {
            entries = KeyBindings.entries()
            // The first menu open, so "click a shortcut" has shortcuts to click.
            if open.isEmpty, let first = entries.first?.menu { open = [first] }
        }
        .onDisappear { stop() }
    }

    @ViewBuilder private var page: some View {
        Section {
            LabeledContent {
                Button("Restore Defaults…") { restore() }.disabled(KeyBindings.overrides(app.settings).isEmpty)
            } label: {
                Text("Click a shortcut, then press the new keys.")
                Text("⌫ removes it, Esc keeps it.")
            }
        }
        let changed = entries.filter { KeyBindings.overrides(app.settings)[$0.id] != nil }
        if !changed.isEmpty { Section("Changed by you") { ForEach(changed) { e in row(e) } } }
        Section("Menus") {
            ForEach(groups, id: \.0) { menu, items in
                fold(menu, count: items.count)
                if open.contains(menu) { ForEach(items) { e in row(e) } }
            }
        }
    }

    /// A menu's line, folding its shortcuts under it. A row of the form's own height: a DisclosureGroup in a grouped form
    /// stood each folded menu half again as tall as a row.
    private func fold(_ menu: String, count: Int) -> some View {
        let shown = open.contains(menu)
        return Button {
            withAnimation(Motion.reduced ? nil : .easeOut(duration: Motion.fast)) {
                if shown { open.remove(menu) } else { open.insert(menu) }
            }
        } label: {
            HStack(spacing: Metrics.gap) {
                Image(systemName: "chevron.right").font(.symbol(Metrics.iconTiny)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(shown ? 90 : 0))
                Text(menu)
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle(flush: true))
        .accessibilityValue(shown ? Text("Expanded") : Text("Collapsed"))
    }

    private func restore() {
        Task {
            guard
                await confirm(
                    String(localized: "Restore every shortcut to Kelp's default?"),
                    detail: String(localized: "The shortcuts you set are lost."),
                    action: String(localized: "Restore Defaults"))
            else { return }
            app.settings.set(SettingKeys.keys, nil)
            later()
        }
    }

    private var groups: [(String, [KeyBindings.Entry])] {
        let shown = entries.filter { KeyBindings.matches($0, query) }
        var order: [String] = [], by: [String: [KeyBindings.Entry]] = [:]
        for entry in shown {
            if by[entry.menu] == nil { order.append(entry.menu) }
            by[entry.menu, default: []].append(entry)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    @ViewBuilder private func row(_ entry: KeyBindings.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.title)
                Spacer()
                if KeyBindings.overrides(app.settings)[entry.id] != nil {
                    Button("Default") {
                        KeyBindings.set(entry.id, nil, in: app.settings)
                        warning[entry.id] = nil
                        later()
                    }.buttonStyle(.link).font(.ui(TextSize.caption))
                        .help(
                            entry.defaultKey.map { String(localized: "Kelp's default: \(KeyBindings.display($0))") }
                                ?? String(localized: "Kelp's default: none"))
                }
                // The keys as text at the row's end, greying in under the pointer; outlined while it takes new ones. A grey
                // plate on every row, "—" ones too, was a column of empty boxes.
                Button {
                    record(entry.id)
                } label: {
                    Text(
                        recording == entry.id
                            ? String(localized: "Type shortcut…") : entry.key.map(KeyBindings.display) ?? "—"
                    ).monospacedDigit()
                }
                .buttonStyle(PointerButtonStyle())
                .overlay {
                    if recording == entry.id {
                        RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous).strokeBorder(
                            Color.accentColor)
                    }
                }
                .foregroundStyle(
                    recording == entry.id
                        ? Color.accentColor : entry.key == nil ? Color(nsColor: .tertiaryLabelColor) : .secondary)
            }
            if let message = warning[entry.id] {
                Text(message).font(.ui(TextSize.caption)).foregroundStyle(Color.textOrange)
            }
        }
    }

    private func record(_ id: String) {
        stop()
        recording = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
            let chars = ev.charactersIgnoringModifiers ?? ""
            switch ev.keyCode {
            case 53 where mods.isEmpty: stop()   // Esc: keep it
            case 51 where mods.isEmpty:   // ⌫: none
                KeyBindings.set(id, .init(key: "", mods: []), in: app.settings)
                warning[id] = nil
                stop()
                later()
            default:
                let fKey = (0xF704...0xF70F).contains(chars.unicodeScalars.first?.value ?? 0)
                guard !mods.subtracting(.shift).isEmpty || fKey else {
                    NSSound.beep()
                    return nil
                }   // a plain letter would type
                let key = KeySpec(
                    key: mods.contains(.shift) && chars.count == 1 ? chars.uppercased() : chars, mods: .init(mods))
                warning[id] = KeyBindings.conflict(key, keyCode: ev.keyCode, except: id)
                KeyBindings.set(id, key, in: app.settings)
                stop()
                later()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    /// The menu is rebuilt from the setting a moment later; read it back then.
    private func later() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { entries = KeyBindings.entries() } }
}
