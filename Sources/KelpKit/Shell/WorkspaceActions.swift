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
    package static func addOpenIn(to menu: NSMenu, path: @escaping @MainActor () -> String?, prefix: String = String(localized: "Open in ")) {
        for e in installedEditors {
            let i = menu.add(prefix + e.name) {
                guard let p = path() else { NSSound.beep(); return }
                open(p, in: e.bundle)
            }
            i.image = NSWorkspace.shared.icon(forFile: e.app.path).resized(16)
        }
    }
    static func addOpenIn(to menu: NSMenu, path: String) { addOpenIn(to: menu, path: { path }) }

    /// The file in the focused tab, else the workspace's folder (Xcode's "Show in Finder" works on the selection).
    func revealCurrent() {
        if let u = app.workbench.editor?.focusedContent?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]); return }
        guard let w = app.worktree(app.workbench.workspaceId) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)])
    }

    func delete(_ w: Worktree) {
        Task {
            let dirty = await app.call(WorktreeDirty(id: w.id)) ?? false
            let commits = await app.call(WorktreeUnmerged(id: w.id)) ?? 0
            let a = NSAlert(); a.messageText = String(localized: "Delete “\(w.displayName)” and its branch?")
            var lost: [String] = []
            if dirty { lost.append(String(localized: "It has uncommitted changes that will be lost.")) }
            if commits > 0 { lost.append(String(localized: "\(commits) commits on this branch aren't on any other branch or remote and will be lost.")) }
            a.informativeText = lost.isEmpty
                ? String(localized: "The checkout and branch \(w.branch) are removed. Running agents stop.") : lost.joined(separator: " ")
            a.addButton(withTitle: lost.isEmpty ? String(localized: "Delete Folder and Branch") : String(localized: "Delete and Lose Changes"))
                .hasDestructiveAction = true
            a.addButton(withTitle: String(localized: "Cancel")); a.alertStyle = lost.isEmpty ? .warning : .critical
            guard await runSheet(a) == .alertFirstButtonReturn, await UnsavedChanges.confirm(closing: [w.id], in: app) else { return }
            if app.workbench.workspaceId == w.id, let main = app.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id }) {
                app.workbench.show(workspace: main.id)
            }
            await app.call(WorktreeRemove(id: w.id, force: dirty, dropCommits: commits > 0))
        }
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

    /// A desk: its agents end, the folder stays. Asks only when agents are running there.
    func close(_ w: Worktree) {
        // The project's last workspace stays (removing the project is a separate, deliberate action).
        guard app.worktrees.filter({ $0.repoId == w.repoId && !$0.archived }).count > 1 else { NSSound.beep(); return }
        let running = app.sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.status != .hibernated }
        Task {
            if !running.isEmpty {
                let a = NSAlert(); a.messageText = String(localized: "Close “\(w.displayName)”?")
                a.informativeText = (running.count == 1 ? String(localized: "1 running agent stops. Files in the project are not touched.")
                    : String(localized: "\(running.count) running agents stop. Files in the project are not touched."))
                a.addButton(withTitle: running.count == 1 ? String(localized: "Stop Agent and Close")
                    : String(localized: "Stop \(running.count) Agents and Close")).hasDestructiveAction = true
                a.addButton(withTitle: String(localized: "Cancel"))
                guard await runSheet(a) == .alertFirstButtonReturn else { return }
            }
            guard await UnsavedChanges.confirm(closing: [w.id], in: app) else { return }
            if app.workbench.workspaceId == w.id, let other = app.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id }) {
                app.workbench.show(workspace: other.id)
            }
            await app.call(WorktreeRemove(id: w.id))
            await app.refresh()
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

    /// Its last tab was closed: its row goes too, with nothing to ask. `ended`: that tab's session, still on its way out.
    func closeEmpty(_ id: String, ended: String?) {
        guard let w = app.worktree(id), let r = app.repo(w.repoId),
              !app.sessions.contains(where: { $0.worktreeId == id && $0.id != ended && $0.status != .exited }),
              let next = WorkspaceClosing.afterLastTab(of: w, rows: app.workspaces(of: r), repos: app.repos) else { return }
        Task {
            if app.workbench.workspaceId == id { app.workbench.show(workspace: next.id) }
            await app.call(WorktreeRemove(id: id))
            await app.refresh()
        }
    }

    /// Several at once (sidebar multi-selection): one question; each project keeps at least one workspace.
    /// Desks close; workspaces on their own branch are archived (nothing is deleted).
    func close(_ ws: [Worktree]) {
        let m = app
        let plan = WorkspaceClosing(picked: ws, open: m.worktrees.filter { !$0.archived }, repos: m.repos), closing = plan.ids
        guard !closing.isEmpty else { NSSound.beep(); return }
        let running = m.sessions.filter { s in s.worktreeId.map(closing.contains) == true && s.status != .exited && s.status != .hibernated }
        let a = NSAlert()
        let name = ws.first { $0.id == closing[0] }?.displayName ?? ""
        a.messageText = closing.count == 1 ? String(localized: "Close “\(name)”?") : String(localized: "Close \(closing.count) groups?")
        a.informativeText = (running.isEmpty ? "" : running.count == 1 ? String(localized: "1 running session stops. ")
            : String(localized: "\(running.count) running sessions stop. "))
            + String(localized: "Files in the projects are not touched.") + (plan.keptSome ? " " + String(localized: "A project's own chats stay.") : "")
        let close = a.addButton(withTitle: running.isEmpty ? String(localized: "Close")
            : running.count == 1 ? String(localized: "Stop 1 Session and Close") : String(localized: "Stop \(running.count) Sessions and Close"))
        close.hasDestructiveAction = !running.isEmpty; a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn, await UnsavedChanges.confirm(closing: closing, in: app) else { return }
            if let id = app.workbench.workspaceId, closing.contains(id),
               let other = m.worktrees.first(where: { !$0.archived && !closing.contains($0.id) }) { app.workbench.show(workspace: other.id) }
            for id in plan.remove { await m.call(WorktreeRemove(id: id)) }
            for id in plan.archive { await m.call(WorktreeArchive(id: id)) }
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
        a.informativeText = String(localized: "The repository on disk is not touched.")
        a.addButton(withTitle: String(localized: "Remove")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn,
                  await UnsavedChanges.confirm(closing: app.worktrees.filter { $0.repoId == r.id }.map(\.id), in: app) else { return }
            await app.call(RepoRemove(id: r.id))
        }
    }
}
