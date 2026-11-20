// What can be done to a commit in the graph: its menu (right-click and the card's ⋯), the card's buttons, a double
// click or Return on its row, ⌘C, and the same as commands in ⇧⌘P.
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// A commit's actions, in the menu's order. The menu's groups end after `endsGroup`.
enum CommitAction: String, CaseIterable {
    case open, browser, agent, checkOut, branch, cherryPick, revert, copyHash, copyMessage

    var endsGroup: Bool { self == .agent || self == .revert }

    /// The menu's words. Cherry-Pick names the branch the commit goes into.
    func title(branch: String) -> String {
        switch self {
        case .open: String(localized: "Open Changes")
        case .browser: String(localized: "Open in Browser")
        case .agent: String(localized: "Send to Agent")
        case .checkOut: String(localized: "Check Out…")
        case .branch: String(localized: "Create Branch Here…")
        case .cherryPick: String(localized: "Cherry-Pick into \(branch)…")
        case .revert: String(localized: "Revert…")
        case .copyHash: String(localized: "Copy Hash")
        case .copyMessage: String(localized: "Copy Message")
        }
    }

    /// The command's title in ⇧⌘P, which acts on the commit selected in the graph.
    var command: String {
        switch self {
        case .open: "Git: Open Commit Changes"
        case .browser: "Git: Open Commit in Browser"
        case .agent: "Git: Send Commit to Agent"
        case .checkOut: "Git: Check Out Commit…"
        case .branch: "Git: Create Branch at Commit…"
        case .cherryPick: "Git: Cherry-Pick Commit…"
        case .revert: "Git: Revert Commit…"
        case .copyHash: "Git: Copy Commit Hash"
        case .copyMessage: "Git: Copy Commit Message"
        }
    }

    /// The key the menu shows: Return opens, ⌘C copies, both on the selected row.
    var key: (String, NSEvent.ModifierFlags)? {
        switch self {
        case .open: ("\r", [])
        case .copyHash: ("c", .command)
        default: nil
        }
    }
}

/// The graph's list: Return opens the selected commit's changes and ⌘C copies its hash, as the menu shows.
final class GraphOutline: NSOutlineView {
    var onReturn: (() -> Bool)?, onCopy: (() -> Bool)?
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.isDisjoint(with: [.command, .option, .control])
        if plain, [36, 76].contains(event.keyCode), onReturn?() == true { return }
        super.keyDown(with: event)
    }
    @objc func copy(_ sender: Any?) {
        if onCopy?() != true { NSSound.beep() }
    }
}

extension SourceControlController {
    /// The commit selected in the graph, for the keys and the commands.
    var selectedCommit: GraphCommit? {
        guard case .commit(let index)? = (graphOutline.item(atRow: graphOutline.selectedRow) as? Node)?.kind,
            commits.indices.contains(index)
        else { return nil }
        return commits[index]
    }

    /// Whether the commit is in the current branch's history, as far as the graph has read. The daemon refuses a
    /// cherry-pick of one the branch has beyond that.
    func inCurrentBranch(_ hash: String) -> Bool {
        guard let head = info?.head, !head.isEmpty, let start = commits.first(where: { $0.hash.hasPrefix(head) })
        else { return false }
        let parents = Dictionary(commits.map { ($0.hash, $0.parents) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = [], next = [start.hash]
        while let current = next.popLast() {
            if current == hash { return true }
            if seen.insert(current).inserted { next += parents[current] ?? [] }
        }
        return false
    }

    /// The commit's actions, in order, into `menu`. Cherry-Pick is left out for a commit the branch already has.
    func addCommitItems(_ commit: GraphCommit, to menu: NSMenu) {
        let has = inCurrentBranch(commit.hash), branch = info?.current ?? "HEAD"
        for action in CommitAction.allCases where action != .cherryPick || !has {
            let item = menu.add(action.title(branch: branch)) { [weak self] in self?.act(action, on: commit) }
            if let (key, modifiers) = action.key {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = modifiers
            }
            if action.endsGroup { menu.addItem(.separator()) }
        }
    }

    /// Whether the command can act: a commit is selected in the graph of the workspace on screen, and Cherry-Pick only
    /// for a commit the branch doesn't have.
    func canAct(_ action: CommitAction) -> Bool {
        guard worktreeId == app.workbench.workspaceId, let commit = selectedCommit else { return false }
        return action != .cherryPick || !inCurrentBranch(commit.hash)
    }

    func act(_ action: CommitAction, on commit: GraphCommit) {
        guard let wid = worktreeId else { return }
        let app = self.app, short = String(commit.hash.prefix(7))
        switch action {
        case .open: app.workbench.open(DiffTab.uri(wid, commit: commit.hash))
        case .browser:
            Task {
                guard let found = await app.call(GitWebPages(worktreeId: wid)),
                    let url = (found?.commitURL(commit.hash)).flatMap(URL.init)
                else { return }
                PreviewLinks.openOutside(url)
            }
        case .agent: FileActions(app).sendToAgent(text: "commit \(commit.hash.prefix(10)) (\(commit.subject))")
        case .checkOut: checkOut(commit)
        case .branch: createBranch(at: commit)
        case .cherryPick:
            let branch = info?.current ?? "HEAD"
            Task {
                guard
                    await confirm(
                        String(localized: "Cherry-pick \(short) into \(branch)?"),
                        detail: String(localized: "Its changes go onto \(branch) as a new commit."),
                        action: String(localized: "Cherry-Pick"))
                else { return }
                commitAct(.cherryPick, commit, in: wid)
            }
        case .revert:
            Task {
                guard
                    await confirm(
                        String(localized: "Revert \(short)?"),
                        detail: String(localized: "A new commit undoes its changes."),
                        action: String(localized: "Revert"))
                else { return }
                commitAct(.revert, commit, in: wid)
            }
        case .copyHash: copyText(commit.hash)
        case .copyMessage:
            // The whole message: the graph has the subject, and the body comes with the details.
            Task {
                let body = await app.quiet(GitCommitDetails(id: wid, commit: commit.hash))?.body ?? ""
                copyText(body.isEmpty ? commit.subject : commit.subject + "\n\n" + body)
            }
        }
    }

    /// Runs the daemon's side of an action once its sheet was answered, unless another workspace came on screen
    /// meanwhile. The panel reads git again after it, as after any git action.
    private func commitAct(_ op: GitCommitAct.Kind, _ commit: GraphCommit, in wid: String, branch: String? = nil) {
        guard wid == worktreeId else { return }
        run { GitCommitAct(worktreeId: $0, commit: commit.hash, op: op, branch: branch) }
    }

    /// Asks before HEAD leaves the branch, and offers a branch at the commit instead.
    private func checkOut(_ commit: GraphCommit) {
        guard let wid = worktreeId else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Check out \(String(commit.hash.prefix(7)))?")
        alert.informativeText = String(localized: "You’ll be on no branch.")
        alert.addButton(withTitle: String(localized: "Check Out"))
        alert.addButton(withTitle: String(localized: "Create Branch…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Task {
            switch await runSheet(alert) {
            case .alertFirstButtonReturn: commitAct(.checkout, commit, in: wid)
            case .alertSecondButtonReturn: createBranch(at: commit)
            default: break
            }
        }
    }

    /// Asks for the new branch's name, as the branch menu's Create Branch… does, then makes it at the commit.
    private func createBranch(at commit: GraphCommit) {
        guard let wid = worktreeId else { return }
        Task {
            let starts = String(localized: "Starts from \(String(commit.hash.prefix(7))) and switches to it.")
            guard let name = await prompt(String(localized: "Create Branch"), starts), !name.isEmpty else { return }
            commitAct(.branch, commit, in: wid, branch: name)
        }
    }

    /// The card's buttons.
    func cardAction(_ commit: GraphCommit, _ action: CommitCardView.Action) {
        switch action {
        case .open: act(.open, on: commit)
        case .checkOut: act(.checkOut, on: commit)
        case .menu(let button):
            let menu = NSMenu()
            addCommitItems(commit, to: menu)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    /// A double click or Return on a commit opens all of its changes in one tab.
    @objc func doubleClicked(_ outline: NSOutlineView) {
        guard case .commit(let index)? = (outline.item(atRow: outline.actedRow) as? Node)?.kind else { return }
        act(.open, on: commits[index])
    }

    /// Return and ⌘C on the selected commit; false when no commit is selected, so the key goes on.
    func followGraphKeys() {
        graphOutline.doubleAction = #selector(doubleClicked(_:))
        graphOutline.onReturn = { [weak self] in
            guard let self, let commit = selectedCommit else { return false }
            act(.open, on: commit)
            return true
        }
        graphOutline.onCopy = { [weak self] in
            guard let commit = self?.selectedCommit else { return false }
            copyText(commit.hash)
            return true
        }
    }
}
