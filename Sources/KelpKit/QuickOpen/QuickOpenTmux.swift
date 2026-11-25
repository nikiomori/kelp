import AppKit
import Core
import DesignKit
import WorkbenchKit

// MARK: tmux and built-ins' lists

extension QuickOpen {
    /// Lists the sessions tmux has on this workspace's machine, the last used first (File › Attach to tmux Session, and
    /// the "+" menu). Typing filters them by name, and a name that matches none starts that session. Each opens as a
    /// terminal attached to it.
    func showTmux() {
        guard let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        let app = self.app
        let load = Task { await app.call(TmuxList(worktreeId: wid)) ?? [] }
        // The rows wait for tmux's answer, so ↩ (which waits on `scoring`) attaches to what is listed, and the "new
        // session" row doesn't move down when the sessions come in. Over ssh that can take a while: it's named at once.
        showOwn(
            String(localized: "Attach to a tmux session, or type a name for a new one"),
            keys: String(localized: "↑↓ Select    ↩ Attach    ⇧↩ Attach in a Split")
        ) { [weak self] in
            let found = await load.value
            return self?.tmuxItems(found, $0) ?? []
        }
        tmuxLoad = load
        setRows([], grouped: false, heading: String(localized: "Reading the tmux sessions…"))
    }

    /// Shows a built-in's list where the palette shows (Open Database). `rows` makes the rows from what's typed.
    func showList(_ placeholder: String, keys: String, rows: @escaping @MainActor (String) async -> [QuickItem]) {
        showOwn(placeholder, keys: keys) { typed in
            await rows(typed).map { row in
                Item(
                    kind: "", icon: row.icon, title: row.title, detail: row.detail, action: row.open, split: row.split,
                    image: row.image, accessory: row.accessory)
            }
        }
    }

    /// Shows the palette's panel listing `rows` instead of its own items.
    private func showOwn(_ placeholder: String, keys: String, rows: @escaping @MainActor (String) async -> [Item]) {
        if panel == nil { build() }
        stopChoosing()
        filesLoad?.cancel()
        prefixedLoad?.cancel()
        tmuxLoad?.cancel()
        commandsOnly = false
        recents = []
        all = []
        own = rows
        field.placeholderString = placeholder
        self.keys.stringValue = keys
        field.scope = nil
        field.stringValue = ""
        filter()
        present()
    }

    /// Returns the tmux sessions matching what is typed, an exact name first. After them comes a new session with that
    /// name, or with the project's name.
    func tmuxItems(_ sessions: [Tmux.Session], _ q: String) -> [Item] {
        func item(_ name: String, icon: String, detail: String) -> Item {
            let app = self.app
            let uri = TabURI.terminal(["tmux": name])
            return Item(
                kind: "tmux", icon: icon, title: name, detail: detail, action: { app.workbench.runURI(uri) },
                split: { app.workbench.runURI(uri, split: .right) })
        }
        // Kelp's own sessions (terminal.tmux) are terminals already and end with their tab, so they aren't offered.
        let found = sessions.filter { !Tmux.isOwn($0.name) }.compactMap { s -> (Item, Int)? in
            guard let score = s.name == q ? 1000 : Self.wordScore(s.name, q) else { return nil }
            let detail = [
                s.windows == 1 ? String(localized: "1 window") : String(localized: "\(s.windows) windows"),
                s.attached > 0 ? String(localized: "attached") : nil, shortAgo(s.activity)
            ].compactMap { $0 }.joined(separator: " · ")
            return (item(s.name, icon: "terminal", detail: detail), score)
        }.sorted { $0.1 > $1.1 }.map(\.0)
        var new = Tmux.name(q)
        if new.isEmpty {   // use the project's name, numbered while tmux has a session by that name
            let worktree = app.worktree(app.workbench.workspaceId)
            let base = Tmux.name(app.repo(worktree?.repoId)?.name ?? "kelp").lowercased().replacingOccurrences(
                of: " ", with: "-")
            new = base
            var number = 2
            while sessions.contains(where: { $0.name == new }) {
                new = "\(base)-\(number)"
                number += 1
            }
        }
        guard !sessions.contains(where: { $0.name == new }) else { return found }
        return found + [item(new, icon: "plus", detail: String(localized: "New tmux session"))]
    }
}

/// A row of a built-in's list in Open Quickly (`Workbench.showList`).
package struct QuickItem {
    let title: String, detail: String, icon: String, image: NSImage?
    /// Grey words at the row's end ("3 more matches").
    let note: String
    /// The title is machine text (a line a terminal printed), set in the monospaced face.
    let mono: Bool
    /// A view at the row's end, such as a database's stage.
    let accessory: (@MainActor () -> NSView?)?
    let open: () -> Void, split: (() -> Void)?

    package init(
        _ title: String, detail: String, icon: String = "", image: NSImage? = nil, note: String = "",
        mono: Bool = false, accessory: (@MainActor () -> NSView?)? = nil, open: @escaping () -> Void,
        split: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.image = image
        self.note = note
        self.mono = mono
        self.accessory = accessory
        self.open = open
        self.split = split
    }
}

/// A built-in's rows for whatever is typed in ⌘P, under `heading` (English, shown translated) after ⌘P's own matches.
/// The rows are asked for again on every key; an empty list shows no heading.
package struct QuickSection {
    let heading: String
    let rows: @MainActor (_ typed: String) async -> [QuickItem]
    package init(_ heading: String, rows: @escaping @MainActor (_ typed: String) async -> [QuickItem]) {
        self.heading = heading
        self.rows = rows
    }
}

/// The palette's window. ⌘1–⌘6 pick from the agents it lists before the main menu sees them (there they select tabs).
final class QuickPanel: NSPanel {
    var onNumber: ((Int) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
            let number = Int(event.charactersIgnoringModifiers ?? ""),
            (1...6).contains(number), onNumber?(number) == true
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
