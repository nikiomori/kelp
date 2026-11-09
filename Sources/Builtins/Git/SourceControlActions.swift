import AppKit
import Core
import KelpKit

/// What the rows and buttons do: stage, commit, sync, branches, and the context menu.
extension SourceControlController {
    // MARK: actions

    /// `make`: the method, given the workspace's id.
    func run<M: RPCMethod>(done: String? = nil, _ make: (String) -> M) {
        guard let wid = worktreeId else { return }
        let method = make(wid), op = (method as? GitRemoteOp)?.op
        if op != nil, busy {   // the menu's Pull and Push too: a second one would race the first
            NSSound.beep()
            return
        }
        begin(
            wid,
            syncing: op.map { op in
                (
                    op == "push"
                        ? String(localized: "Pushing…")
                        : op == "pull" ? String(localized: "Pulling…") : String(localized: "Fetching…"),
                    op == "push", op == "pull"
                )
            })
        Task {
            let result = await app.tryCall(method)
            end(wid, syncing: op != nil)
            if let error = result.error {
                // A rejected push or a pull that stopped on conflicts is work for the agent; other failures just say why.
                if op == "push" {
                    GitFix(app).offer(error, recipe: "fixPush", worktree: wid)
                } else if op == "pull", error.lowercased().contains("conflict") {
                    GitFix(app).offer(
                        error, recipe: "resolveConflicts", worktree: wid,
                        vars: [
                            "base": String(localized: "the remote branch"),
                            "files": String(localized: "see git status")
                        ])
                } else {
                    Banner.show(error, style: .error)
                }
            }
            if op != nil {
                finish(done ?? String(localized: "Fetched"), ok: result.error == nil, quiet: done == nil, in: wid)
            } else if result.error == nil, let done {
                Banner.show(done)
            }
            reloadAll()
        }
    }

    private func stage(_ files: [FileChange], _ on: Bool) {
        let paths = files.map(\.path)
        noteChanges()
        if on { run { GitStage(id: $0, files: paths) } } else { run { GitUnstage(id: $0, files: paths) } }
    }

    private func discard(_ files: [FileChange]) {
        guard !files.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let name = (files[0].path as NSString).lastPathComponent
        if files.count == 1, files[0].untracked {
            alert.messageText = String(localized: "Delete “\(name)”?")
            alert.informativeText = String(
                localized:
                    "Git doesn't track this file: Undo puts it back for a minute, and a project on this Mac keeps it in the Trash."
            )
            alert.addButton(withTitle: String(localized: "Delete File")).hasDestructiveAction = true
        } else {
            alert.messageText =
                files.count == 1
                ? String(localized: "Discard changes in “\(name)”?")
                : String(localized: "Discard all \(files.count) changes?")
            alert.informativeText =
                String(localized: "You can undo it for a minute.")
                + (files.contains(where: \.untracked) ? String(localized: " Untracked files go to the Trash.") : "")
            alert.addButton(
                withTitle: files.count == 1
                    ? String(localized: "Discard Changes") : String(localized: "Discard \(files.count) Changes")
            )
            .hasDestructiveAction = true
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        let wid = worktreeId   // the folder the files were picked in, whatever is shown once the sheet is answered
        Task {
            guard await runSheet(alert) == .alertFirstButtonReturn, let wid else { return }
            noteChanges()
            fadeRows(Set(files.map(\.path)))
            let undo = UUID().uuidString
            if await app.call(GitDiscard(id: wid, files: files.map(\.path), undo: undo)) != nil {
                let done =
                    files.count == 1
                    ? String(localized: "Discarded changes in \(name)")
                    : String(localized: "Discarded \(files.count) changes")
                UndoDiscard.offer(app, done, worktree: wid, undo: undo)
            }
            reloadAll()
        }
    }

    func sectionActions(_ s: Section, _ n: Node) -> [RowAction] {
        let files = n.files
        switch s {
        case .merge: return [RowAction("plus", "Stage All (Mark Resolved)") { [weak self] in self?.stage(files, true) }]
        case .staged: return [RowAction("minus", "Unstage All") { [weak self] in self?.stage(files, false) }]
        case .changes:
            return [
                RowAction("arrow.uturn.backward", "Discard All Changes…") { [weak self] in self?.discard(files) },
                RowAction("plus", "Stage All Changes") { [weak self] in self?.stage(files, true) }
            ]
        case .graph:
            return [RowAction("arrow.clockwise", "Refresh") { [weak self] in Task { await self?.loadGraph() } }]
        }
    }

    func fileActions(_ file: FileChange, _ section: Section) -> [RowAction] {
        var actions = [RowAction("doc", "Open File") { [weak self] in self?.openFile(file) }]
        switch section {
        case .staged:
            actions.append(RowAction("minus", "Unstage Changes") { [weak self] in self?.stage([file], false) })
        case .changes:
            actions.append(
                RowAction("arrow.uturn.backward", "Discard Changes…") { [weak self] in self?.discard([file]) })
            actions.append(RowAction("plus", "Stage Changes") { [weak self] in self?.stage([file], true) })
        case .merge:
            actions.append(RowAction("plus", "Stage (Mark Resolved)") { [weak self] in self?.stage([file], true) })
        case .graph: break
        }
        return actions
    }

    /// An action of `wid` started: one that talks to the remote says so (`syncing`), one that stages only holds the buttons.
    func begin(_ wid: String, syncing: GitWork.Sync? = nil) {
        var state = work[wid] ?? GitWork()
        state.running += 1
        state.syncing = syncing ?? state.syncing
        work[wid] = state
        if wid == worktreeId { showWork() }
    }

    /// A step of `wid`'s sync.
    func nowSyncing(_ wid: String, _ syncing: GitWork.Sync) {
        work[wid]?.syncing = syncing
        if wid == worktreeId { showWork() }
    }

    /// One action ended, and with it what `syncing` said if it was the one saying it: a stage ending doesn't end a push.
    func end(_ wid: String, syncing ended: Bool) {
        guard var state = work[wid] else { return }
        state.running -= 1
        if ended { state.syncing = nil }
        work[wid] = state.running > 0 ? state : nil
        if wid == worktreeId { showWork() }
    }

    /// `wid`'s message went in as a commit: its text is over, wherever it's being kept.
    private func sent(_ wid: String) {
        guard wid == worktreeId else {
            drafts[wid] = nil
            return
        }
        message.string = ""
        messageChanged()
        clearing = true
    }

    @objc func commitPressed() { commit(push: false, amend: false) }

    func commit(push: Bool, amend: Bool) {
        let text = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wid = worktreeId, !busy, !changes.isEmpty || amend else {
            NSSound.beep()
            return
        }
        // No message yet: a page to write it on, as in VS Code (amending starts from the last commit's message).
        guard !text.isEmpty else {
            let last = amend ? commits.first { $0.hash.hasPrefix(info?.head ?? "\u{0}") }?.subject : nil
            app.workbench.open(CommitMessageTab.uri(wid, push: push, amend: amend, message: last))
            return
        }
        begin(wid, syncing: push ? (String(localized: "Pushing…"), true, false) : nil)
        Task {
            let result = await GitCommit.run(app, wid, message: text, push: push, amend: amend)
            if result.committed { sent(wid) }
            end(wid, syncing: push)
            finish(
                push ? String(localized: "Pushed") : String(localized: "Committed"),
                ok: push ? result.pushed : result.committed,
                quiet: !push, in: wid)
            reloadAll()
        }
    }

    @objc func sync() {
        guard let info, !busy else { return }
        if info.upstream == nil {
            run(done: String(localized: "Published \(info.current ?? "HEAD")")) { GitRemoteOp(id: $0, op: "push") }
            return
        }
        guard let wid = worktreeId else { return }
        let ahead = (info.ahead ?? 0) > 0, title = String(localized: "Syncing…")
        begin(wid, syncing: (title, false, true))
        Task {
            var ok = await app.call(GitRemoteOp(id: wid, op: "pull")) != nil
            if ok, ahead {
                nowSyncing(wid, (title, true, false))
                ok = await app.call(GitRemoteOp(id: wid, op: "push")) != nil
            }
            end(wid, syncing: true)
            finish(String(localized: "Synced"), ok: ok, quiet: true, in: wid)
            reloadAll()
        }
    }

    func pullPressed() { run(done: String(localized: "Pulled")) { GitRemoteOp(id: $0, op: "pull") } }
    func fetchPressed() { run { GitRemoteOp(id: $0, op: "fetch") } }
    /// Push, or publish a branch with no upstream.
    func pushPressed() {
        if info?.upstream == nil {
            sync()
            return
        }
        run(done: String(localized: "Pushed")) { GitRemoteOp(id: $0, op: "push") }
    }

    @objc func branchMenu() {
        guard let info else { return }
        let menu = NSMenu()
        for branch in info.local {
            let item = menu.add(branch) { [weak self] in self?.run { GitSwitch(id: $0, branch: branch) } }
            item.state = branch == info.current ? .on : .off
        }
        if !info.remote.isEmpty {
            let sub = NSMenu()
            for branch in info.remote {
                sub.add(branch) { [weak self] in self?.run { GitSwitch(id: $0, branch: branch, remote: true) } }
            }
            menu.addItem(.separator())
            let remoteItem = menu.addItem(
                withTitle: String(localized: "Remote Branches"), action: nil, keyEquivalent: "")
            remoteItem.submenu = sub
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Create Branch…")) { [weak self] in
            Task {
                guard
                    let name = await prompt(
                        String(localized: "Create Branch"),
                        String(localized: "Starts from \(info.current ?? "HEAD") and switches to it.")),
                    !name.isEmpty
                else { return }
                self?.run { GitSwitch(id: $0, branch: name, create: true) }
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: branchButton.bounds.height + 4), in: branchButton)
    }

    func showMoreMenu() {
        let app = self.app
        guard let wid = worktreeId else { return }
        let menu = NSMenu()
        menu.add(String(localized: "Pull")) { [weak self] in
            self?.run(done: String(localized: "Pulled")) { GitRemoteOp(id: $0, op: "pull") }
        }
        menu.add(String(localized: "Push")) { [weak self] in
            self?.run(done: String(localized: "Pushed")) { GitRemoteOp(id: $0, op: "push") }
        }
        menu.add(String(localized: "Fetch")) { [weak self] in self?.run { GitRemoteOp(id: $0, op: "fetch") } }
        menu.add(String(localized: "Refresh")) { [weak self] in self?.reloadAll() }
        menu.addItem(.separator())
        menu.add(String(localized: "Stash Changes")) { [weak self] in
            self?.run(done: String(localized: "Changes stashed")) { GitStash(id: $0) }
        }
        menu.add(String(localized: "Pop Stash")) { [weak self] in self?.run { GitStash(id: $0, pop: true) } }
        menu.addItem(.separator())
        menu.add(String(localized: "Open All Changes")) { app.workbench.open(DiffTab.uri(wid)) }
        menu.add(String(localized: "Create Pull Request…")) { PRActions(app).create(worktree: wid) }
        if let worktree = app.worktree(wid), let repo = app.repo(worktree.repoId), worktree.path != repo.path {
            menu.add(String(localized: "Merge into \(repo.baseBranch)…")) { [weak self] in self?.mergeIntoBase() }
        }
        let anchor: NSView = moreButton ?? view
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    /// A workspace on its own branch (worktree) into the project's base branch.
    private func mergeIntoBase() {
        guard let wid = worktreeId else { return }
        Task {
            guard let outcome = await app.call(GitMerge(id: wid)) else { return }
            if outcome.merged {
                Banner.show(String(localized: "Merged"))
                // The base moved in the project's own folder: its git and this branch's are read again now.
                let project = app.worktree(wid).flatMap { worktree in
                    app.worktrees.first { $0.repoId == worktree.repoId && $0.path == app.repo(worktree.repoId)?.path }
                }
                for id in [wid, project?.id].compactMap({ $0 }) { app.watchAgain(.git, id) }
                return
            }
            let files = outcome.conflicts
            let alert = NSAlert()
            alert.messageText = String(localized: "Merge Conflicts")
            alert.alertStyle = .warning
            alert.informativeText =
                files.joined(separator: "\n") + String(localized: "\n\nThe merge was aborted; nothing changed.")
            alert.addButton(withTitle: String(localized: "OK"))
            if FileActions(app).targetAgent != nil {
                alert.addButton(withTitle: String(localized: "Ask Agent to Resolve"))
            }
            if await runSheet(alert) == .alertSecondButtonReturn, let worktree = app.worktree(wid),
                let repo = app.repo(worktree.repoId)
            {
                GitFix(app).send(
                    "resolveConflicts", worktree: wid,
                    vars: ["base": repo.baseBranch, "files": files.joined(separator: ", ")])
            }
        }
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let app = self.app
        menu.removeAllItems()
        let list = menu === graphOutline.menu ? graphOutline : outline
        guard let node = list.item(atRow: list.clickedRow) as? Node else { return }
        switch node.kind {
        case .file(let file, let section):
            if section != .merge {
                menu.add(String(localized: "Open Changes")) { [weak self] in self?.open(file, section) }
            }
            menu.add(String(localized: "Open File")) { [weak self] in self?.openFile(file) }
            menu.addItem(.separator())
            let acts = Array(fileActions(file, section).dropFirst()), discard = section == .changes ? acts.first : nil
            for a in acts.dropFirst(discard == nil ? 0 : 1) { menu.add(a.title) { a.run() } }
            if let root = app.worktree(worktreeId)?.path {
                menu.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(root + "/" + file.path) }
            }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy Path")) {
                copyText(file.path)
            }
            if let discard {
                menu.addItem(.separator())
                menu.add(discard.title) { discard.run() }
            }
        case .section(let section) where section != .graph:
            // What its row's hover buttons do, with what throws work away last.
            if section != .merge, let wid = worktreeId {
                menu.add(String(localized: "Open All Changes")) { app.workbench.open(DiffTab.uri(wid)) }
            }
            let acts = Array(sectionActions(section, node).reversed())
            for (i, a) in acts.enumerated() {
                if i == acts.count - 1, acts.count > 1 { menu.addItem(.separator()) }
                menu.add(a.title) { a.run() }
            }
        case .commit(let index):
            let commit = commits[index]
            let wid = worktreeId
            menu.add(String(localized: "Open in Browser")) {
                Task {
                    guard let found = await app.call(GitWebPages(worktreeId: wid)),
                        let url = (found?.commitURL(commit.hash)).flatMap(URL.init)
                    else { return }
                    PreviewLinks.openOutside(url)
                }
            }
            menu.add(String(localized: "Send to Agent")) {
                FileActions(app).sendToAgent(text: "commit \(commit.hash.prefix(10)) (\(commit.subject))")
            }
            menu.addItem(.separator())
            let copies = NSMenu()
            copies.add(String(localized: "Hash")) {
                copyText(commit.hash)
            }
            copies.add(String(localized: "Message")) {
                copyText(commit.subject)
            }
            menu.setSubmenu(
                copies, for: menu.addItem(withTitle: String(localized: "Copy"), action: nil, keyEquivalent: ""))
        case .commitFile(let hash, let fileChange):
            menu.add(String(localized: "Open Changes")) { [weak self] in
                if let worktree = self?.worktreeId {
                    app.workbench.open(DiffTab.uri(worktree, file: fileChange.path, commit: hash))
                }
            }
            menu.add(String(localized: "Open File")) { [weak self] in self?.openFile(fileChange) }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy Path")) {
                copyText(fileChange.path)
            }
        default: break
        }
    }
}
