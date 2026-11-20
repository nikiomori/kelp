// The sync popover's actions: sync, commit, switch branch, and the keys of its message field.
import AppKit
import Core
import DesignKit
import KelpKit

extension SyncPopover: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        let hinted = hint.isHidden
        showChanges()
        if hint.isHidden != hinted { root.crossfade() }   // the hint comes and goes in place
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) || sel == Selector(("noop:")),
            let event = NSApp.currentEvent, event.keyCode == 36 || event.keyCode == 76,
            event.modifierFlags.contains(.command)
        else { return false }
        if commit.isEnabled { commitAll(thenPush: true) }
        return true
    }
}

extension SyncPopover {
    // MARK: actions

    func sync(_ ops: [GitRemoteOp.Step]) {
        guard GitSync.state(app).running[wid] == nil else { return }
        let before = app.latest(GitEvent.self, folder)?.branches
        let ahead = before?.ahead ?? 0, behind = before?.behind ?? 0
        let published = before?.upstream != nil, branch = before?.current ?? "HEAD"
        result = nil
        Task {
            let error = await GitSync.run(app, wid, ops)
            listKey = ""   // reads the lists and the fetch time again, even when no count moved
            if let error {
                failed(error, ops: ops)
            } else if ops.contains(.push) {
                let text =
                    !published
                    ? String(localized: "Published \(branch).")
                    : ahead == 1
                        ? String(localized: "Pushed 1 commit.") : String(localized: "Pushed \(max(ahead, 1)) commits.")
                result = (text, false, false)
            } else if ops.contains(.pull) {
                result = (
                    behind == 1
                        ? String(localized: "Pulled 1 commit.") : String(localized: "Pulled \(behind) commits."), false,
                    false
                )
            }
            update()
        }
    }

    /// A pull that stopped on conflicts is work for the agent (and for Source Control). Any other failure says why,
    /// here.
    private func failed(_ error: String, ops: [GitRemoteOp.Step]) {
        guard ops.contains(.pull), error.lowercased().contains("conflict") else {
            result = (Self.summary(error), true, GitSync.isRejected(error))
            return
        }
        popover?.performClose(nil)
        GitFix(app).offer(
            error, recipe: "resolveConflicts", worktree: wid,
            vars: ["base": String(localized: "the remote branch"), "files": String(localized: "see git status")])
        app.workbench.showPanel("git.changes")
    }

    /// Git's message cut to a few lines: the pieces of a long push or pull report that say why.
    private static func summary(_ error: String) -> String {
        if GitSync.isRejected(error) {
            return String(localized: "Push rejected: the remote has commits this branch doesn’t. Pull first.")
        }
        let lines = error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty
        }
        let useful = lines.filter { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
        return (useful.isEmpty ? lines : useful).prefix(3).joined(separator: "\n")
            .replacingOccurrences(of: "fatal: ", with: "").replacingOccurrences(of: "error: ", with: "")
    }

    @objc func commitPressed() { commitAll(thenPush: false) }

    /// ⌘⏎ in the field commits, then pushes (or publishes) what's now ahead.
    private func commitAll(thenPush: Bool) {
        let text = message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.isEnabled, !text.isEmpty else { return }
        committing = true
        update()
        Task {
            defer {
                committing = false
                app.watchAgain(.git, folder)
                update()
            }
            // This is Source Control's commit, the one way to commit: what's staged, else every change. A failure
            // offers a fix.
            guard await GitCommit.run(app, wid, message: text, push: false, amend: false).committed else { return }
            message.stringValue = ""
            if thenPush {
                committing = false
                sync([.push])
            }
        }
    }

    /// The menu of local branches to switch to, and a new one. The remote branches are in Source Control.
    @objc func switchMenu() {
        guard let info = app.latest(GitEvent.self, folder)?.branches else { return }
        let menu = NSMenu(), wid = wid
        menu.addBranches(info) { [weak self] branch, create in
            self?.switchBranch(GitSwitch(id: wid, branch: branch, create: create ? true : nil))
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: name.bounds.height + 4), in: name)
    }

    private func switchBranch(_ request: GitSwitch) {
        Task {
            await app.call(request)
            app.watchAgain(.git, folder)   // updates the chip now, not on the next file event
        }
    }
}

@MainActor
extension NSMenu {
    /// The local branches to switch to, the current one ticked, then `more` (Source Control's remote branches) and
    /// Create Branch…, which asks for the new branch's name. `pick` gets the branch, and true for one to create.
    func addBranches(
        _ info: BranchInfo, more: (NSMenu) -> Void = { _ in }, pick: @escaping @MainActor (String, Bool) -> Void
    ) {
        for branch in info.local { add(branch) { pick(branch, false) }.state = branch == info.current ? .on : .off }
        more(self)
        addItem(.separator())
        add(String(localized: "Create Branch…")) {
            Task {
                let starts = String(localized: "Starts from \(info.current ?? "HEAD") and switches to it.")
                guard let name = await prompt(String(localized: "Create Branch"), starts), !name.isEmpty else { return }
                pick(name, true)
            }
        }
    }
}
