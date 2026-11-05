import AppKit
import Core
import WorkbenchKit

@MainActor
package struct WorkspaceActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    private static let editors = [("VS Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92"), ("Windsurf", "com.exafunction.windsurf"),
                                  ("Zed", "dev.zed.Zed"), ("Sublime Text", "com.sublimetext.4"), ("Xcode", "com.apple.dt.Xcode"),
                                  ("Fork", "com.DanPristupov.Fork"), ("Tower", "com.fournova.Tower3"), ("GitHub Desktop", "com.github.GitHubClient"),
                                  ("Terminal", "com.apple.Terminal"), ("iTerm", "com.googlecode.iterm2"), ("Warp", "dev.warp.Warp-Stable")]
    /// Terminals and git clients get a folder: Terminal would run a file as a script.
    private static let folderOnly: Set = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.DanPristupov.Fork",
                                          "com.fournova.Tower3", "com.github.GitHubClient"]

    static var installedEditors: [(name: String, bundle: String, app: URL)] {
        editors.compactMap { n, b in NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { (n, b, $0) } }
    }

    static func open(_ path: String, in bundle: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { NSSound.beep(); return }
        var p = path, dir: ObjCBool = false
        if folderOnly.contains(bundle), FileManager.default.fileExists(atPath: p, isDirectory: &dir), !dir.boolValue {
            p = (p as NSString).deletingLastPathComponent
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: p)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// "Open in VS Code"… for whatever editors this Mac has, like "Open With" in Finder.
    static func addOpenIn(to menu: NSMenu, path: @escaping @MainActor () -> String?, prefix: String = String(localized: "Open in ")) {
        for e in installedEditors {
            let i = menu.add(prefix + e.name) {
                guard let p = path() else { NSSound.beep(); return }
                open(p, in: e.bundle)
            }
            i.image = NSWorkspace.shared.icon(forFile: e.app.path).resized(16)
        }
    }
    static func addOpenIn(to menu: NSMenu, path: String) { addOpenIn(to: menu, path: { path }) }

    /// Where a thing is, the same items everywhere: Reveal in Finder, Open In ›, and Copy Path, or Copy › when `copies`
    /// has more than the path to offer.
    package static func addLocate(to menu: NSMenu, path: String, copies: [(title: String, run: @MainActor @Sendable () -> Void)] = []) {
        menu.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        let editors = NSMenu()
        addOpenIn(to: editors, path: { path }, prefix: "")
        if !editors.items.isEmpty { menu.setSubmenu(editors, for: menu.addItem(withTitle: String(localized: "Open In"), action: nil, keyEquivalent: "")) }
        let copyPath: @MainActor () -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        guard !copies.isEmpty else { menu.add(String(localized: "Copy Path"), copyPath); return }
        let list = NSMenu()
        list.add(String(localized: "Path"), copyPath)
        for c in copies { list.add(c.title, c.run) }
        menu.setSubmenu(list, for: menu.addItem(withTitle: String(localized: "Copy"), action: nil, keyEquivalent: ""))
    }

    /// The file in the focused tab, else the workspace's folder (Xcode's "Show in Finder" works on the selection).
    func revealCurrent() {
        if let u = app.workbench.editor?.focusedContent?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]); return }
        guard let w = app.worktree(app.workbench.workspaceId) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)])
    }

    /// What exists only in a branch's folder: nothing about it may go without being asked.
    private struct Work {
        var dirty: Bool, commits: Int
        var isAny: Bool { dirty || commits > 0 }
        var words: [String] {
            (dirty ? [String(localized: "It has uncommitted changes that will be lost.")] : [])
                + (commits > 0 ? [String(localized: "\(commits) commits on this branch aren't on any other branch or remote and will be lost.")] : [])
        }
    }

    /// Nil: can't tell (its folder is gone, say).
    private func work(on id: String) async -> Work? {
        guard let d = await app.quiet(WorktreeDirty(id: id)), let c = await app.quiet(WorktreeUnmerged(id: id)) else { return nil }
        return Work(dirty: d, commits: c)
    }

    func delete(_ w: Worktree) {
        Task {
            let work = Work(dirty: await app.call(WorktreeDirty(id: w.id)) ?? false, commits: await app.call(WorktreeUnmerged(id: w.id)) ?? 0)
            let a = NSAlert(); a.messageText = String(localized: "Delete “\(w.displayName)” and its branch?")
            a.informativeText = (work.isAny ? work.words.joined(separator: " ")
                : String(localized: "The checkout and branch \(w.branch) are removed. Running agents stop."))
                + app.sessions.childrenWords(of: app.sessions.filter { $0.worktreeId == w.id }.map(\.id))
            a.addButton(withTitle: work.isAny ? String(localized: "Delete and Lose Changes") : String(localized: "Delete Folder and Branch"))
                .hasDestructiveAction = true
            a.addButton(withTitle: String(localized: "Cancel")); a.alertStyle = work.isAny ? .critical : .warning
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            await discard(w, work)
        }
    }

    private func discard(_ w: Worktree, _ work: Work) async {
        guard await UnsavedChanges.confirm(closing: [w.id], in: app) else { return }
        if app.workbench.workspaceId == w.id, let main = app.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id }) {
            app.workbench.show(workspace: main.id)
        }
        await app.call(WorktreeRemove(id: w.id, force: work.dirty, dropCommits: work.commits > 0))
    }

    /// The project's other git worktrees with nothing uncommitted (agents leave them in `.claude/worktrees`), after one
    /// question; git itself keeps any that changed meanwhile. Kelp's own workspaces aren't among them.
    func removeCleanWorktrees(_ r: Repo) {
        Task {
            guard let all = await app.call(RepoWorktreeSizes(id: r.id)) else { return }
            let clean = all.filter(\.removable), a = NSAlert()
            guard !clean.isEmpty else {
                a.messageText = String(localized: "No clean worktrees in “\(r.name)”")
                a.informativeText = all.isEmpty ? String(localized: "The project has no other git worktrees.")
                    : String(localized: "Each of its \(all.count) worktrees has uncommitted changes, is locked or is in use in Kelp.")
                _ = await runSheet(a); return
            }
            let size = WorktreeSizes.size(clean.reduce(0) { $0 + $1.bytes })
            a.messageText = clean.count == 1 ? String(localized: "Remove the clean worktree “\(WorktreeSizes.name(clean[0].path, root: r.path))” (\(size))?")
                : String(localized: "Remove \(clean.count) clean worktrees (\(size))?")
            let names = clean.prefix(10).map { "\(WorktreeSizes.name($0.path, root: r.path))  \(WorktreeSizes.size($0.bytes))" }
            a.informativeText = (clean.count > 1 ? names.joined(separator: "\n") + (clean.count > 10 ? "\n…" : "") + "\n\n" : "")
                + String(localized: """
                    Nothing uncommitted is lost: git removes only clean worktrees. A branch goes too if its commits are on another branch. \
                    Ignored files (builds, copied .env) go with the folder.
                    """)
            a.addButton(withTitle: clean.count == 1 ? String(localized: "Remove Worktree") : String(localized: "Remove \(clean.count) Worktrees"))
                .hasDestructiveAction = true
            a.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(a) == .alertFirstButtonReturn,
                  let res = await app.call(RepoRemoveWorktrees(id: r.id, paths: clean.map(\.path))) else { return }
            let freed = WorktreeSizes.size(clean.filter { res.removed.contains($0.path) }.reduce(0) { $0 + $1.bytes })
            if let why = res.kept.values.first {
                Banner.show(String(localized: "Removed \(res.removed.count), kept \(res.kept.count): \(why)"), style: .error)
            } else { Banner.show(String(localized: "Removed \(res.removed.count) worktrees, \(freed) freed")) }
        }
    }

    /// A group: its agents end, the project's files stay. Asks only when agents are running there. One on a branch goes with
    /// its folder and branch, and first asks if they hold the only copy of something. A project's own screen stays.
    func close(_ w: Worktree) {
        guard let r = app.repo(w.repoId), w.id != mainWorkspace(of: r, among: app.workspaces(of: r))?.id else { NSSound.beep(); return }
        let open = app.sessions.filter { $0.worktreeId == w.id && $0.status != .exited }
        let running = open.filter { $0.status != .paused }, paused = open.count - running.count
        Task {
            if w.path != r.path, let work = await work(on: w.id), work.isAny { await closeKeeping(w, work); return }
            if !open.isEmpty {
                let a = NSAlert(); a.messageText = String(localized: "Close “\(w.displayName)”?")
                a.informativeText = pausedGo(paused) + (running.isEmpty ? String(localized: "Files in the project are not touched.")
                    : running.count == 1 ? String(localized: "1 running agent stops. Files in the project are not touched.")
                    : String(localized: "\(running.count) running agents stop. Files in the project are not touched."))
                a.addButton(withTitle: running.isEmpty ? String(localized: "Close") : running.count == 1 ? String(localized: "Stop Agent and Close")
                    : String(localized: "Stop \(running.count) Agents and Close")).hasDestructiveAction = true
                a.addButton(withTitle: String(localized: "Cancel"))
                guard await runSheet(a) == .alertFirstButtonReturn else { return }
            }
            guard await UnsavedChanges.confirm(closing: [w.id], in: app) else { return }
            if app.workbench.workspaceId == w.id, let other = app.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id }) {
                app.workbench.show(workspace: other.id)
            }
            // Refused (an agent wrote something at the last moment): back to what's still there.
            if await app.call(WorktreeRemove(id: w.id)) == nil { app.workbench.show(workspace: w.id) }
            await app.refresh()
        }
    }

    /// Closing takes a paused agent's tab and its history too: it can't be opened from Kelp again.
    private func pausedGo(_ n: Int) -> String {
        n == 0 ? "" : (n == 1 ? String(localized: "1 paused agent closes for good. ") : String(localized: "\(n) paused agents close for good. "))
    }

    /// A branch with work of its own: kept unless told otherwise, as it can't be got back.
    private func closeKeeping(_ w: Worktree, _ work: Work) async {
        let a = NSAlert(); a.messageText = String(localized: "“\(w.displayName)” has work that's nowhere else")
        a.informativeText = (work.words + [String(localized: "Archive keeps it, agents paused, until Window › Archived Groups brings it back.")])
            .joined(separator: " ")
        a.addButton(withTitle: String(localized: "Archive"))
        a.addButton(withTitle: String(localized: "Delete and Lose Changes")).hasDestructiveAction = true
        a.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        switch await runSheet(a) {
        case .alertFirstButtonReturn: archive(w)
        case .alertSecondButtonReturn: await discard(w, work)
        default: break
        }
    }

    /// The project's folder was moved or renamed: pick it again; its workspaces follow.
    func relocate(_ r: Repo) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = String(localized: "Where is “\(r.name)” now?"); p.prompt = String(localized: "Choose")
        p.directoryURL = URL(fileURLWithPath: (r.path as NSString).deletingLastPathComponent)
        let chosen = { (resp: NSApplication.ModalResponse) in
            guard resp == .OK, let u = p.url else { return }
            Task { if await app.call(RepoRelocate(id: r.id, path: u.path)) != nil { await app.refresh() } }
        }
        if let w = NSApp.mainWindow { p.beginSheetModal(for: w, completionHandler: chosen) } else { p.begin(completionHandler: chosen) }
    }

    /// Chats off to a group of their own, named after the first. Their agents go on where they are.
    func newGroup(from chats: [String]) async {
        guard let first = chats.first.flatMap(app.session), let w = app.worktree(first.worktreeId),
              let made = await app.call(WorkspaceCreate(repoId: w.repoId)) else { return }
        await app.call(WorktreeNote(id: made.id, note: app.catalog.displayName(first)))
        await move(chats, to: made.id)
    }

    func move(_ chats: [String], to id: String) async {
        let from = Set(chats.compactMap { app.session($0)?.worktreeId }).subtracting([id])
        for s in chats { await app.call(SessionMove(id: s, worktreeId: id)) }
        await app.refresh()
        if let s = chats.first { app.workbench.focus(session: s) }
        for w in from { app.workbench.window?.editors.chatsLeft(w) }
    }

    /// Its last tab was closed: its row goes too, with nothing to ask. One on a branch with work of its own stays, and says
    /// so: nothing there is decided by closing a tab. `ended`: that tab's session, still on its way out.
    func closeEmpty(_ id: String, ended: String?) {
        // Its children end with it, a moment later: they have no tab, and nothing would come back to close this.
        var ending = Set([ended].compactMap { $0 })
        while case let more = Set(app.sessions.filter { $0.parent.map(ending.contains) == true }.map(\.id)).subtracting(ending), !more.isEmpty {
            ending.formUnion(more)
        }
        guard let w = app.worktree(id), let r = app.repo(w.repoId),
              !app.sessions.contains(where: { $0.worktreeId == id && !ending.contains($0.id) && $0.status != .exited }),
              let next = WorkspaceClosing.afterLastTab(of: w, rows: app.workspaces(of: r), repos: app.repos) else { return }
        Task {
            if w.path != r.path {
                guard let work = await work(on: id) else { return }
                if work.isAny {
                    Banner.show(String(localized: "“\(w.displayName)” stays: its work is only on \(w.branch). ⇧⌘W closes it."))
                    return
                }
            }
            if app.workbench.workspaceId == id { app.workbench.show(workspace: next.id) }
            await app.workbench.keepClosedTabs(of: w, on: next)
            // The agent that just ended may have left something after all: then it stays, as above.
            if await app.call(WorktreeRemove(id: id)) == nil { app.workbench.show(workspace: id) }
            await app.refresh()
        }
    }

    /// Several at once (sidebar multi-selection): one question; each project keeps at least one workspace.
    /// Workspaces close; one on its own branch goes if nothing is only there, else it's archived (nothing is lost).
    func close(_ ws: [Worktree]) {
        let m = app
        let plan = WorkspaceClosing(picked: ws, open: m.worktrees.filter { !$0.archived }, repos: m.repos), closing = plan.ids
        guard !closing.isEmpty else { NSSound.beep(); return }
        let open = m.sessions.filter { s in s.worktreeId.map(closing.contains) == true && s.status != .exited }
        let running = open.filter { $0.status != .paused }
        let a = NSAlert()
        let name = ws.first { $0.id == closing[0] }?.displayName ?? ""
        a.messageText = closing.count == 1 ? String(localized: "Close “\(name)”?") : String(localized: "Close \(closing.count) groups?")
        a.informativeText = pausedGo(open.count - running.count)
            + (running.isEmpty ? "" : running.count == 1 ? String(localized: "1 running session stops. ")
                : String(localized: "\(running.count) running sessions stop. "))
            + String(localized: "Files in the projects are not touched.") + (plan.keptSome ? " " + String(localized: "A project's own chats stay.") : "")
        let close = a.addButton(withTitle: running.isEmpty ? String(localized: "Close")
            : running.count == 1 ? String(localized: "Stop 1 Session and Close") : String(localized: "Stop \(running.count) Sessions and Close"))
        close.hasDestructiveAction = !open.isEmpty; a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn, await UnsavedChanges.confirm(closing: closing, in: app) else { return }
            if let id = app.workbench.workspaceId, closing.contains(id),
               let other = m.worktrees.first(where: { !$0.archived && !closing.contains($0.id) }) { app.workbench.show(workspace: other.id) }
            for id in plan.remove { await m.call(WorktreeRemove(id: id)) }
            for id in plan.archive {
                if await work(on: id)?.isAny == false { await m.call(WorktreeRemove(id: id)) } else { await m.call(WorktreeArchive(id: id)) }
            }
            await m.refresh()
        }
    }

    /// Out of the sidebar, nothing lost: its agents pause and its tabs stay until it comes back (Window › Archived Workspaces).
    func archive(_ w: Worktree) {
        Task {
            guard await UnsavedChanges.confirm(closing: [w.id], in: app) else { return }
            if app.workbench.workspaceId == w.id,
               let other = app.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id && !$0.archived }) { app.workbench.show(workspace: other.id) }
            if await app.call(WorktreeArchive(id: w.id)) != nil {
                await app.refresh()
                Banner.show(String(localized: "“\(w.displayName)” archived. Window › Archived Groups brings it back."))
            }
        }
    }

    func unarchive(_ id: String) {
        Task {
            await app.call(WorktreeUnarchive(id: id))
            await app.refresh()
            app.workbench.show(workspace: id)
        }
    }

    func removeProject(_ r: Repo) {
        let a = NSAlert()
        a.messageText = String(localized: "Remove “\(app.projectName(r.id) ?? r.name)” from Kelp?")
        let branches = app.worktrees.filter { $0.repoId == r.id && $0.path != r.path }
        a.informativeText = [String(localized: "Its agents stop, and its chats and routines leave Kelp for good."),
                             branches.isEmpty ? nil : String(localized: "Folders of its branch groups stay on disk, and Kelp no longer lists them."),
                             String(localized: "The repository on disk is not touched.")].compactMap { $0 }.joined(separator: " ")
        a.addButton(withTitle: String(localized: "Remove")).hasDestructiveAction = true
        a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn,
                  await UnsavedChanges.confirm(closing: app.worktrees.filter { $0.repoId == r.id }.map(\.id), in: app) else { return }
            await app.call(RepoRemove(id: r.id))
        }
    }
}
