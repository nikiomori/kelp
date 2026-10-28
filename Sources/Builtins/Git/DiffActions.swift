import AppKit
import Core
import KelpKit

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
    /// Throwing a hunk away can't be taken back, so a sheet says what goes (an alert of the window, not of the app).
    @objc func discardHunk(_ b: NSButton) {
        guard let wid = worktreeId, let window = view.window, let (path, h, shown) = hunk(b) else { return }
        let lines = shown.lines, file = (path as NSString).lastPathComponent, header = shown.header, print = shown.fingerprint
        let added = lines.filter { $0.kind == .add }.count, removed = lines.filter { $0.kind == .del }.count
        let a = NSAlert()
        a.messageText = String(localized: "Discard this change?")
        a.informativeText = String(localized: "\(file) goes back to the committed lines here: \(added) added lines go, \(removed) removed lines come back. This can't be undone.")
        a.addButton(withTitle: String(localized: "Discard")).hasDestructiveAction = true
        a.addButton(withTitle: String(localized: "Cancel"))
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            Task {
                // The lines shown, not only the header: a line an agent rewrote in place since is never thrown away unseen.
                let m = GitDiscardHunk(id: wid, file: path, hunk: h, header: header, fingerprint: print)
                if let e = await app.tryCall(m).error { Banner.show(e, style: .error) }
                await self.load()
                app.watchAgain(.git, wid)   // Source Control and the badges now, not on the next file event
            }
        }
    }
    private func selectedFilePath() -> String? {
        let r = files.clickedRow >= 0 ? files.clickedRow : files.selectedRow
        return diffs.indices.contains(r) ? diffs[r].path : nil
    }
    @objc func stageFile() { fileOp { GitStage(id: $0, files: [$1]) } }
    @objc func unstageFile() { fileOp { GitUnstage(id: $0, files: [$1]) } }
    /// `make`: the method for the workspace's id and the selected file.
    private func fileOp<M: RPCMethod>(_ make: (String, String) -> M) {
        guard let wid = worktreeId, let p = selectedFilePath() else { return }
        let m = make(wid, p)
        Task { await app.call(m); await load() }
    }

    @objc func addComment() {
        guard let wid = worktreeId else { return }
        var lines: [(Int, String)] = []; var file: String?
        for r in table.selectedRowIndexes {
            guard case .diff(let d) = rows[r] else { continue }
            switch d {
            case .line(let f, let l): file = diffs[f].path; if let n = l.newLine ?? l.oldLine { lines.append((n, l.text)) }
            case .pair(let f, let l, let rr): file = diffs[f].path; if let x = rr ?? l, let n = x.newLine ?? x.oldLine { lines.append((n, x.text)) }
            default: break
            }
        }
        guard let file, let first = lines.first, let last = lines.last else { NSSound.beep(); return }
        Task {
            guard let text = await prompt(String(localized: "Comment on \(file):\(first.0)\(first.0 == last.0 ? "" : "-\(last.0)")"),
                                          String(localized: "Goes to the agent with the code quote.")), !text.isEmpty else { return }
            await app.call(CommentAdd(id: wid, file: file, start: first.0, end: last.0, quote: lines.map(\.1).joined(separator: "\n"), text: text))
            await load()
        }
    }

    @objc func setCommentState(_ m: NSMenuItem) {
        guard table.clickedRow >= 0, case .comment(let c) = rows[table.clickedRow] else { NSSound.beep(); return }
        let set = CommentSetState(id: c.id, state: m.representedObject as? String ?? "")
        Task { await app.call(set); await load() }
    }

    @objc func sendComments() {
        guard let wid = worktreeId else { return }
        guard comments.contains(where: { $0.state == .open }) else { status.stringValue = String(localized: "No open comments"); return }
        Task {
            guard let sid = await pickAgentSession(wid) else { return }
            let n = await app.call(CommentSend(id: wid, session: sid)) ?? 0
            status.stringValue = String(localized: "Sent \(n) comments to agent"); await load()
        }
    }

    /// The focused session if it is in this worktree, else ask.
    private func pickAgentSession(_ wid: String) async -> String? {
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
