import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Staging, discarding and commenting on what the diff shows.
extension DiffViewController {
    // MARK: actions
    /// The hunk a button stands for, by what identifies it (file and "@@" header), read when it's clicked: indices go
    /// stale as soon as the diff reloads.
    private func hunk(_ button: NSButton) -> (path: String, index: Int, hunk: Hunk)? {
        let fileIndex = button.tag / 10000, hunkIndex = button.tag % 10000
        guard diffs.indices.contains(fileIndex), diffs[fileIndex].hunks.indices.contains(hunkIndex) else { return nil }
        return (diffs[fileIndex].path, hunkIndex, diffs[fileIndex].hunks[hunkIndex])
    }

    @objc func hunkAction(_ button: NSButton) {
        guard let wid = worktreeId, let (path, i, h) = hunk(button) else { return }
        let staged = hunksStaged(button.tag / 10000) == true
        Task {
            await app.call(
                GitHunk(id: wid, file: path, hunk: i, reverse: staged, header: h.header, fingerprint: h.fingerprint))
            await load()
            app.watchAgain(.git, wid)   // Source Control and the badges now, not on the next file event
        }
    }
    /// A hunk goes at once: the banner's Undo brings it back.
    @objc func discardHunk(_ button: NSButton) {
        guard let wid = worktreeId, let (path, _, shown) = hunk(button) else { return }
        Task {
            // The lines shown, not only the header: a line an agent rewrote in place since is never thrown away unseen.
            await discardWithUndo(
                app,
                {
                    GitDiscardHunk(
                        id: wid, file: path, hunk: 0, header: shown.header, fingerprint: shown.fingerprint, undo: $0)
                },
                saying: String(localized: "Discarded a change in \((path as NSString).lastPathComponent)"),
                worktree: wid
            ) { await self.load() }
            fadesNextLoad = true
            await load()
        }
    }
    // MARK: menus

    func menuNeedsUpdate(_ m: NSMenu) {
        if m === reviewPop.menu { return reviewItems(m) }
        if m === files.menu { fileMenu(m, row: files.clickedRow) } else { lineMenu(m, row: table.clickedRow) }
    }

    /// Stage or Unstage as the file stands; a commit's or a turn's diff has nothing to stage.
    func fileMenu(_ m: NSMenu, row: Int) {
        m.removeAllItems()
        let live = single?.commit == nil && (0...2).contains(source.indexOfSelectedItem)
        guard live, let wid = worktreeId, diffs.indices.contains(row) else { return }
        let path = diffs[row].path
        guard let change = changes.first(where: { $0.path == path }) else { return }
        if change.unstaged || !change.staged {
            m.add(String(localized: "Stage")) { [weak self] in self?.fileOp(GitStage(id: wid, files: [path])) }
        }
        if change.staged {
            m.add(String(localized: "Unstage")) { [weak self] in self?.fileOp(GitUnstage(id: wid, files: [path])) }
        }
        m.addItem(.separator())
        m.add(String(localized: "Open File")) { [weak self] in self?.openLine(path, nil) }
        m.add(String(localized: "Copy Path")) {
            copyText(path)
        }
    }
    func openLine(_ path: String, _ line: Int?) {
        guard let root = app.worktree(worktreeId)?.path else { return }
        app.workbench.open(TabURI.file(root + "/" + path, line: line))
    }
    private func fileOp<M: RPCMethod>(_ m: M) {
        Task {
            await app.call(m)
            await load()
        }
    }

    /// A comment's next state; a line of the diff, what can be done with a line; the other rows have no menu.
    func lineMenu(_ m: NSMenu, row: Int) {
        m.removeAllItems()
        guard rows.indices.contains(row) else { return }
        if let (path, line) = shownLine(row) { return lineItems(m, row, path, line) }
        guard case .comment(let comment) = rows[row] else { return }
        func state(_ title: String, _ s: String) { m.add(title) { [weak self] in self?.setComment(comment.id, s) } }
        if comment.state != .resolved { state(String(localized: "Mark Resolved"), "resolved") }
        if comment.state != .open { state(String(localized: "Reopen"), "open") }
    }

    /// The selected lines get a comment card under them (`DiffDraft`).
    @objc func addComment() {
        guard worktreeId != nil else { return }
        openDraft()
    }

    /// The file and the line a row of the diff shows, the new side's when it has both.
    func shownLine(_ row: Int) -> (String, DiffLine)? {
        guard case .diff(let diffRow) = rows[row] else { return nil }
        switch diffRow {
        case .line(let file, let line): return (diffs[file].path, line)
        case .pair(let file, let removed, let added): return (added ?? removed).map { (diffs[file].path, $0) }
        default: return nil
        }
    }
    private func lineItems(_ m: NSMenu, _ row: Int, _ path: String, _ line: DiffLine) {
        m.add(String(localized: "Add Comment…")) { [weak self] in
            guard let self else { return }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
            addComment()
        }
        if let number = line.newLine {
            m.add(String(localized: "Open File at Line")) { [weak self] in self?.openLine(path, number) }
        }
        m.add(String(localized: "Copy Line")) {
            copyText(line.text)
        }
    }
    private func setComment(_ id: String, _ state: String) {
        let set = CommentSetState(id: id, state: state)
        Task {
            await app.call(set)
            await load()
        }
    }

    /// The focused session if it is in this worktree, else ask.
    func pickAgentSession(_ wid: String) async -> String? {
        // Not a reviewer: findings go to the agent that wrote the code.
        let reviewers = Set(app.catalog.all.map { Self.reviewTitle($0.name) })
        let live = app.sessions.filter {   // agents only: a terminal would run the message's lines
            $0.worktreeId == wid && $0.status != .exited && $0.id != reviewer && !reviewers.contains($0.title)
                && $0.isAgent
        }
        if let cur = app.workbench.focusedSession, live.contains(where: { $0.id == cur }) { return cur }
        if live.count == 1 { return live[0].id }
        guard !live.isEmpty else {
            status.stringValue = String(localized: "No running agent in this worktree")
            return nil
        }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        for session in live {
            pop.addItem(withTitle: "\(session.agent ?? "shell") [\(session.id.prefix(6))]")
            pop.lastItem?.representedObject = session.id
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Send to which agent?")
        alert.accessoryView = pop
        alert.addButton(withTitle: String(localized: "Send"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(alert) == .alertFirstButtonReturn ? pop.selectedItem?.representedObject as? String : nil
    }
}
