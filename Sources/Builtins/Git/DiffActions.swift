import AppKit
import Core
import KelpKit
import WorkbenchKit

/// Staging, discarding and commenting on what the diff shows.
extension DiffViewController {
    // MARK: actions
    /// The hunk a button stands for, by what identifies it (file and "@@" header), read when it's clicked: indices go
    /// stale as soon as the diff reloads.
    private func hunk(_ b: NSButton) -> (path: String, index: Int, hunk: Hunk)? {
        let f = b.tag / 10000, h = b.tag % 10000
        guard diffs.indices.contains(f), diffs[f].hunks.indices.contains(h) else { return nil }
        return (diffs[f].path, h, diffs[f].hunks[h])
    }

    @objc func hunkAction(_ b: NSButton) {
        guard let wid = worktreeId, let (path, i, h) = hunk(b) else { return }
        let staged = hunksStaged(b.tag / 10000) == true
        Task {
            await app.call(GitHunk(id: wid, file: path, hunk: i, reverse: staged, header: h.header, fingerprint: h.fingerprint))
            await load()
            app.watchAgain(.git, wid)   // Source Control and the badges now, not on the next file event
        }
    }
    /// A hunk goes at once: the banner's Undo brings it back.
    @objc func discardHunk(_ b: NSButton) {
        guard let wid = worktreeId, let (path, h, shown) = hunk(b) else { return }
        let file = (path as NSString).lastPathComponent
        Task {
            // The lines shown, not only the header: a line an agent rewrote in place since is never thrown away unseen.
            let m = GitDiscardHunk(id: wid, file: path, hunk: h, header: shown.header, fingerprint: shown.fingerprint)
            if let e = await app.tryCall(m).error { Banner.show(e, style: .error) } else {
                app.offerUndoDiscard(String(localized: "Discarded a change in \(file)"), worktree: wid) { await self.load() }
            }
            fadesNextLoad = true
            await load()
            app.watchAgain(.git, wid)   // Source Control and the badges now, not on the next file event
        }
    }
    // MARK: menus

    func menuNeedsUpdate(_ m: NSMenu) {
        if m === files.menu { fileMenu(m, row: files.clickedRow) } else { lineMenu(m, row: table.clickedRow) }
    }

    /// Stage or Unstage as the file stands; a commit's or a turn's diff has nothing to stage.
    func fileMenu(_ m: NSMenu, row: Int) {
        m.removeAllItems()
        let live = single?.commit == nil && (0...2).contains(source.indexOfSelectedItem)
        guard live, let wid = worktreeId, diffs.indices.contains(row) else { return }
        let path = diffs[row].path
        guard let c = changes.first(where: { $0.path == path }) else { return }
        if c.unstaged || !c.staged { m.add(String(localized: "Stage")) { [weak self] in self?.fileOp(GitStage(id: wid, files: [path])) } }
        if c.staged { m.add(String(localized: "Unstage")) { [weak self] in self?.fileOp(GitUnstage(id: wid, files: [path])) } }
        m.addItem(.separator())
        m.add(String(localized: "Open File")) { [weak self] in self?.openLine(path, nil) }
        m.add(String(localized: "Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
    }
    func openLine(_ path: String, _ line: Int?) {
        guard let root = app.worktree(worktreeId)?.path else { return }
        app.workbench.open(TabURI.file(root + "/" + path, line: line))
    }
    private func fileOp<M: RPCMethod>(_ m: M) { Task { await app.call(m); await load() } }

    /// A comment's next state; a line of the diff, what can be done with a line; the other rows have no menu.
    func lineMenu(_ m: NSMenu, row: Int) {
        m.removeAllItems()
        guard rows.indices.contains(row) else { return }
        if let (path, line) = shownLine(row) { return lineItems(m, row, path, line) }
        guard case .comment(let c) = rows[row] else { return }
        func state(_ title: String, _ s: String) { m.add(title) { [weak self] in self?.setComment(c.id, s) } }
        if c.state != .resolved { state(String(localized: "Mark Resolved"), "resolved") }
        if c.state != .open { state(String(localized: "Reopen"), "open") }
    }

    /// The selected lines get a comment card under them (`DiffDraft`).
    @objc func addComment() {
        guard worktreeId != nil else { return }
        openDraft()
    }

    /// The file and the line a row of the diff shows, the new side's when it has both.
    func shownLine(_ row: Int) -> (String, DiffLine)? {
        guard case .diff(let d) = rows[row] else { return nil }
        switch d {
        case .line(let f, let l): return (diffs[f].path, l)
        case .pair(let f, let l, let r): return (r ?? l).map { (diffs[f].path, $0) }
        default: return nil
        }
    }
    private func lineItems(_ m: NSMenu, _ row: Int, _ path: String, _ line: DiffLine) {
        m.add(String(localized: "Add Comment…")) { [weak self] in
            guard let self else { return }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
            addComment()
        }
        if let n = line.newLine {
            m.add(String(localized: "Open File at Line")) { [weak self] in self?.openLine(path, n) }
        }
        m.add(String(localized: "Copy Line")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line.text, forType: .string) }
    }
    private func setComment(_ id: String, _ state: String) {
        let set = CommentSetState(id: id, state: state)
        Task { await app.call(set); await load() }
    }

    /// The focused session if it is in this worktree, else ask.
    func pickAgentSession(_ wid: String) async -> String? {
        let live = app.sessions.filter { $0.worktreeId == wid && $0.status != .exited }
        if let cur = app.workbench.focusedSession, live.contains(where: { $0.id == cur }) { return cur }
        if live.count == 1 { return live[0].id }
        guard !live.isEmpty else { status.stringValue = String(localized: "No running agent in this worktree"); return nil }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        for s in live { pop.addItem(withTitle: "\(s.agent ?? "shell") [\(s.id.prefix(6))]"); pop.lastItem?.representedObject = s.id }
        let a = NSAlert()
        a.messageText = String(localized: "Send to which agent?")
        a.accessoryView = pop
        a.addButton(withTitle: String(localized: "Send")); a.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(a) == .alertFirstButtonReturn ? pop.selectedItem?.representedObject as? String : nil
    }
}

extension AppModel {
    /// After a discard: a banner whose Undo puts it back while the daemon keeps it (a minute; the banner stays 10 s).
    func offerUndoDiscard(_ text: String, worktree wid: String, then reload: @escaping @MainActor () async -> Void = {}) {
        Banner.show(text, action: (String(localized: "Undo"), { [self] in
            Task {
                if await call(GitUndoDiscard(id: wid)) != nil { await reload() }
                watchAgain(.git, wid)   // Source Control and the badges now, not on the next file event
            }
        }))
    }
}
