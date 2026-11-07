import AppKit
import Core
import WorkbenchKit

// MARK: tmux

extension QuickOpen {
    /// File › Attach to tmux Session, the "+" menu: the sessions tmux has on this workspace's machine, the last used first.
    /// Typing filters them by name, and a name that isn't one starts that session. Each opens as a terminal attached to it.
    package func showTmux() {
        guard let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        if panel == nil { build() }
        stopChoosing()
        filesLoad?.cancel()
        prSearch?.cancel()
        tmuxLoad?.cancel()
        commandsOnly = false
        recents = []
        all = []
        tmux = []
        field.placeholderString = String(localized: "Attach to a tmux session, or type a name for a new one")
        keys.stringValue = String(localized: "↑↓ Select    ↩ Attach    ⇧↩ Attach in a Split")
        field.stringValue = ""
        filter()
        present()
        tmuxLoad = Task {
            let found = await app.call(TmuxList(worktreeId: wid)) ?? []
            guard !Task.isCancelled, tmux != nil else { return }
            tmux = found
            filter()
        }
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
