import AppKit
import Core
import DesignKit

// MARK: tmux and built-ins' lists

extension QuickOpen {
    /// File › Attach to tmux Session, the "+" menu: the sessions tmux has on this workspace's machine, the last used first.
    /// Typing filters them by name, and a name that isn't one starts that session. Each opens as a terminal attached to it.
    func showTmux() {
        guard let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        showOwn(
            String(localized: "Attach to a tmux session, or type a name for a new one"),
            keys: String(localized: "↑↓ Select    ↩ Attach    ⇧↩ Attach in a Split")
        ) { [weak self] in self?.tmuxItems([], $0) ?? [] }
        tmuxLoad = Task {
            let found = await app.call(TmuxList(worktreeId: wid)) ?? []
            guard !Task.isCancelled, own != nil else { return }
            own = { [weak self] in self?.tmuxItems(found, $0) ?? [] }
            filter()
        }
    }

    /// A built-in's list where the palette shows (Open Database): `rows` makes its rows from what's typed.
    func showList(_ placeholder: String, keys: String, rows: @escaping @MainActor (String) async -> [QuickItem]) {
        showOwn(placeholder, keys: keys) { typed in
            await rows(typed).map { row in
                Item(
                    kind: "", icon: row.icon, title: row.title, detail: row.detail, action: row.open, split: row.split,
                    image: row.image, accessory: row.accessory)
            }
        }
    }

    /// The palette's panel listing `rows` instead of its own items.
    private func showOwn(_ placeholder: String, keys: String, rows: @escaping @MainActor (String) async -> [Item]) {
        if panel == nil { build() }
        stopChoosing()
        filesLoad?.cancel()
        prSearch?.cancel()
        pullRequests = nil
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

    /// The sessions matching what's typed, that exact name first; then a new session by that name, or by the project's.
    func tmuxItems(_ sessions: [Tmux.Session], _ q: String) -> [Item] {
        func item(_ name: String, icon: String, detail: String) -> Item {
            let app = self.app
            var components = URLComponents()
            components.scheme = "terminal"
            components.queryItems = [URLQueryItem(name: "tmux", value: name)]
            let uri = components.string ?? "terminal:"
            return Item(
                kind: "tmux", icon: icon, title: name, detail: detail, action: { app.workbench.runURI(uri) },
                split: { app.workbench.runURI(uri, split: .right) })
        }
        // Kelp's own (terminal.tmux) are terminals already, and end with their tab: not offered.
        let found = sessions.filter { !Tmux.isOwn($0.name) }.compactMap { s -> (Item, Int)? in
            guard let score = s.name == q ? 1000 : Self.wordScore(s.name, q) else { return nil }
            let detail = [
                s.windows == 1 ? String(localized: "1 window") : String(localized: "\(s.windows) windows"),
                s.attached > 0 ? String(localized: "attached") : nil, shortAgo(s.activity)
            ].compactMap { $0 }.joined(separator: " · ")
            return (item(s.name, icon: "terminal", detail: detail), score)
        }.sorted { $0.1 > $1.1 }.map(\.0)
        var new = Tmux.name(q)
        if new.isEmpty {   // the project's name, numbered while tmux has a session by it
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
    /// At the row's end, as a database's stage.
    let accessory: (@MainActor () -> NSView?)?
    let open: () -> Void, split: (() -> Void)?

    package init(
        _ title: String, detail: String, icon: String = "", image: NSImage? = nil,
        accessory: (@MainActor () -> NSView?)? = nil, open: @escaping () -> Void, split: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.image = image
        self.accessory = accessory
        self.open = open
        self.split = split
    }
}

/// The palette's window: ⌘1–⌘6 pick from the agents it lists before the main menu sees them (they select tabs there).
final class QuickPanel: NSPanel {
    var onNumber: ((Int) -> Bool)?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
            let number = Int(e.charactersIgnoringModifiers ?? ""),
            (1...6).contains(number), onNumber?(number) == true
        {
            return true
        }
        return super.performKeyEquivalent(with: e)
    }
}
