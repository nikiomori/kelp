import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Shows who last changed the line at the caret, in a menu at the caret. The menu names the agent's turn (with its
/// prompt), the commit, or nobody yet, and then offers the change itself and the chat it came from.
extension FileTab {
    /// The workspace of the project that holds the file, and the file's path in it; nil when no project holds it.
    var inProject: (worktree: String, file: String)? {
        ChangeBars.project(of: path, in: app.worktrees).map { ($0.worktree.id, $0.file) }
    }

    func showLineOrigin() {
        guard let (wid, file) = inProject, let line = editor?.cursor?.line else { return }
        Task { [weak self, app] in
            guard let found = await app.call(GitLineOrigin(worktreeId: wid, file: file, line: line)) else { return }
            guard let self, let editor else { return }
            editor.popUpAtCursor(lineOriginMenu(found, worktree: wid, file: file))
        }
    }

    func lineOriginMenu(_ origin: GitLineOrigin.Origin?, worktree wid: String, file: String) -> NSMenu {
        let app = self.app, menu = NSMenu()
        func note(_ text: String) {
            menu.addItem(withTitle: text, action: nil, keyEquivalent: "").isEnabled = false
        }
        let when = { (date: Date) in date.formatted(date: .abbreviated, time: .shortened) }
        if let origin, let commit = origin.commit {
            if let turn = origin.turn {
                note(String(localized: "Changed by \(origin.author), \(when(turn.at))"))
                note("“\(Self.short(turn.prompt))”")
            } else {
                note(String(localized: "Committed by \(origin.author), \(when(origin.date))"))
                note(Self.short(origin.summary))
            }
            menu.addItem(.separator())
            menu.add(String(localized: "Show Changes")) {
                app.workbench.open(TabURI.diff(wid, file: file, commit: commit))
            }
            if let session = origin.turn?.session, app.session(session) != nil {
                menu.add(String(localized: "Show Chat")) { app.workbench.open(TabURI.session(session)) }
            }
        } else if origin != nil {
            note(String(localized: "Not committed yet, and no agent’s turn changed it"))
            menu.addItem(.separator())
            menu.add(String(localized: "Show Changes")) { app.workbench.open(TabURI.diff(wid, file: file)) }
        } else {
            note(String(localized: "Git doesn’t track this line"))
        }
        return menu
    }

    private static func short(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 60 ? line.prefix(59) + "…" : line
    }
}
