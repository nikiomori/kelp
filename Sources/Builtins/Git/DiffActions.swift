import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Staging, discarding and commenting on what the diff shows.
extension DiffViewController {
    // MARK: actions
    /// The hunk a button stands for, found by what identifies it (file and "@@" header) when it's clicked, because
    /// indices go stale as soon as the diff reloads.
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
            // Source Control and the badges update now, not on the next file event.
            app.watchAgain(.git, app.gitKey(wid))
        }
    }
    /// Discards a hunk at once; the banner's Undo brings it back.
    @objc func discardHunk(_ button: NSButton) {
        guard let wid = worktreeId, let (path, _, shown) = hunk(button) else { return }
        Task {
            // The lines shown are sent, not only the header, so a line an agent rewrote in place since is never thrown
            // away unseen.
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === reviewPop.menu { return reviewItems(menu) }
        if menu === files.menu { fileMenu(menu, row: files.clickedRow) } else { lineMenu(menu, row: table.clickedRow) }
    }

    /// Offers Stage or Unstage, depending on how the file stands. A commit's or a turn's diff has nothing to stage.
    func fileMenu(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        let live = single?.commit == nil && sourcePicked.isLive
        guard live, let wid = worktreeId, diffs.indices.contains(row) else { return }
        let path = diffs[row].path
        guard let change = changes.first(where: { $0.path == path }) else { return }
        if change.unstaged || !change.staged {
            menu.add(String(localized: "Stage")) { [weak self] in self?.fileOp(GitStage(id: wid, files: [path])) }
        }
        if change.staged {
            menu.add(String(localized: "Unstage")) { [weak self] in self?.fileOp(GitUnstage(id: wid, files: [path])) }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Open File")) { [weak self] in self?.openLine(path, nil) }
        menu.add(String(localized: "Copy Path")) {
            copyText(path)
        }
    }
    func openLine(_ path: String, _ line: Int?) {
        guard let root = app.worktree(worktreeId)?.path else { return }
        app.workbench.open(TabURI.file(root + "/" + path, line: line))
    }
    private func fileOp<M: RPCMethod>(_ method: M) {
        Task {
            await app.call(method)
            await load()
        }
    }

    /// The menu of a row: a comment's next state, or what can be done with a line of the diff. The other rows have no
    /// menu.
    func lineMenu(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        guard rows.indices.contains(row) else { return }
        if let (path, line) = shownLine(row) { return lineItems(menu, row, path, line) }
        guard case .comment(let comment) = rows[row] else { return }
        func state(_ title: String, _ s: String) { menu.add(title) { [weak self] in self?.setComment(comment.id, s) } }
        if comment.state != .resolved { state(String(localized: "Mark Resolved"), "resolved") }
        if comment.state != .open { state(String(localized: "Reopen"), "open") }
    }

    /// Gives the selected lines a comment card under them (`DiffDraft`).
    @objc func addComment() {
        guard worktreeId != nil else { return }
        openDraft()
    }

    /// The file and the line a row of the diff shows, taking the new side's line when it has both.
    func shownLine(_ row: Int) -> (String, DiffLine)? {
        guard case .diff(let diffRow) = rows[row] else { return nil }
        switch diffRow {
        case .line(let file, let line): return (diffs[file].path, line)
        case .pair(let file, let removed, let added): return (added ?? removed).map { (diffs[file].path, $0) }
        default: return nil
        }
    }
    private func lineItems(_ menu: NSMenu, _ row: Int, _ path: String, _ line: DiffLine) {
        menu.add(String(localized: "Add Comment…")) { [weak self] in
            guard let self else { return }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
            addComment()
        }
        if let number = line.newLine {
            menu.add(String(localized: "Open File at Line")) { [weak self] in self?.openLine(path, number) }
        }
        menu.add(String(localized: "Copy Line")) {
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

    /// The agent that findings go to (`FileActions.pickAgent`). It is never a reviewer, because findings go to the
    /// agent that wrote the code.
    func pickAgentSession(_ wid: String) async -> String? {
        guard !FileActions(app).agents(in: wid).isEmpty else {
            status.stringValue = String(localized: "No running agent in this worktree")
            return nil
        }
        return await FileActions(app).pickAgent(in: wid)?.id
    }
}
