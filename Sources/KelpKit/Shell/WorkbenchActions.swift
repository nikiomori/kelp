import AppKit
import Core
import WorkbenchKit

/// Entry points everything uses to act on the window: open URIs, switch workspaces, focus agents.
@MainActor
extension Workbench {
    /// Every unsaved file in the app: the main window's loaded workspaces and the Scratch panel's.
    package var editedFiles: [SavableTab] { (window?.editors.editedFiles ?? []) + app.scratch.editedFiles }
    /// The editor area with the keyboard: the Scratch panel's while it's key, else the workspace on screen's.
    package var editor: EditorArea? { keyArea ?? window?.editors.current }
    /// An editor area that is a window's whole content (the Scratch panel) and has the keys.
    private var keyArea: EditorArea? { NSApp.keyWindow?.contentViewController as? EditorArea }

    package func show(workspace id: String) { show(workspace: id, remember: true) }

    private func show(workspace id: String, remember: Bool) {
        guard workspaceId != id || window?.editors.current == nil else { return }
        workspaceId = id
        if remember { history.visit(id) }
        window?.showWorkspace(id)
    }

    /// ⌃⌘← / ⌃⌘→: the workspace shown before / after this one (closed ones are skipped).
    func goBack(_ step: Int) {
        guard let i = visit(step) else { NSSound.beep(); return }
        show(workspace: history.go(to: i), remember: false)
    }

    /// Where Back (-1) / Forward (1) would go: nil when there's nothing that way (the title bar's arrows grey out).
    func visit(_ step: Int) -> Int? {
        history.target(step, current: workspaceId) { app.worktree($0) != nil }
    }

    package func open(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil, focus: Bool = true) {
        if let k = keyArea, workspace == nil || workspace == k.workspaceId { k.open(uri, split: split, focus: focus); return }
        if let workspace, workspace != workspaceId { show(workspace: workspace) }
        if workspaceId == nil, let first = app.worktrees.first { show(workspace: first.id) }
        window?.editors.current?.open(uri, split: split, focus: focus)
    }

    /// Restart: the new session takes the old one's tab in the workspace it belongs to, which may not be the one on screen
    /// (Restart from the sidebar).
    func replace(session old: String, with new: String, workspace: String?) {
        let o = TabURI.session(old), n = TabURI.session(new)
        if let k = keyArea, workspace == nil || workspace == k.workspaceId { k.replace(o, with: n); return }
        if let workspace, workspace != workspaceId { window?.editors.replaceInBackground(o, with: n, workspace: workspace); return }
        window?.editors.current?.replace(o, with: n)
    }

    package func focus(session id: String) {
        guard let s = app.session(id) else { return }
        if let k = keyArea, s.worktreeId == k.workspaceId { k.focus(session: id) } else {
            if let w = s.worktreeId, w != workspaceId { show(workspace: w) }
            window?.editors.current?.focus(session: id)
        }
        // Opening a finished agent is reading it; a question stays marked until it's answered (typing clears it).
        if s.unread, s.status == .done { Task { await app.call(SessionMarkRead(id: id)) } }
    }

    /// No notification for an agent whose tab the user is looking at.
    func isViewing(session id: String) -> Bool {
        window?.window?.isKeyWindow == true && editor?.layout.focusedGroup?.selectedTab?.uri == TabURI.session(id)
    }

    /// Workspaces in sidebar order (⌃1–9, ⌃⌘↑ / ↓).
    var workspacesInOrder: [Worktree] { app.projects.flatMap { app.workspaces(of: $0) } }

    func showWorkspace(offset: Int) {
        let all = workspacesInOrder
        guard !all.isEmpty else { NSSound.beep(); return }
        let i = all.firstIndex { $0.id == workspaceId }.map { ($0 + offset + all.count) % all.count } ?? 0
        show(workspace: all[i].id)
    }

    func showWorkspace(number n: Int) {
        let all = workspacesInOrder
        guard all.indices.contains(n - 1) else { NSSound.beep(); return }
        show(workspace: all[n - 1].id)
    }

    /// ⇧⌘U: the next agent that asked something or finished, wherever it is.
    package func showNextNeedingAttention() {
        let current = editor?.layout.focusedGroup?.selectedTab.map(\.uri).flatMap { TabURI.scheme($0) == "session" ? TabURI.body($0) : nil }
        guard let s = AttentionQueue(app).next(after: current) else { NSSound.beep(); return }
        focus(session: s.id)
    }

    package func closeTab(uri: String) {
        guard let e = [keyArea, window?.editors.current].compactMap({ $0 }).first(where: { $0.layout.tab(uri: uri) != nil }),
              let t = e.layout.tab(uri: uri) else { return }
        e.closeTab(t.id)
    }

    /// Takes a tab off the screen without closing what it shows: a run hidden in the Run menu keeps running.
    func hideTab(uri: String) {
        guard let e = [keyArea, window?.editors.current].compactMap({ $0 }).first(where: { $0.layout.tab(uri: uri) != nil }),
              let t = e.layout.tab(uri: uri) else { return }
        e.drop(t.id)
    }

    func addProject() {
        // A new folder made here is a new project (asked whether to `git init` it). Clone and SSH are their own commands.
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = String(localized: "Choose a project folder, or make a new one"); p.prompt = String(localized: "Add Project")
        let chosen = { [self] (r: NSApplication.ModalResponse) in
            guard r == .OK, let u = p.url else { return }
            addProject(path: u.path)
        }
        // A sheet on the window, not an app-modal panel that stops everything else.
        if let w = NSApp.mainWindow ?? NSApp.keyWindow { p.beginSheetModal(for: w, completionHandler: chosen) } else { p.begin(completionHandler: chosen) }
    }

    /// A folder dropped on the Dock icon or the sidebar, `open -a Kelp .`, or picked in Add Project: its project on screen
    /// (added first if it's new; a folder inside a repository adds the repository).
    func addProject(path: String) {
        Task {
            let m = app
            await m.waitForConnection()   // opened at launch
            guard let rid = await repoAdd(path, m)?.id else { return }
            await m.refresh()
            let ws = m.repo(rid).map(m.workspaces(of:)) ?? []
            if let w = ws.first(where: { $0.id == workspaceId }) ?? ws.first { show(workspace: w.id) }
        }
    }

    /// The folder's project; one outside any repository is asked about first: made one (`git init`) or added as it is.
    private func repoAdd(_ path: String, _ m: AppModel) async -> Repo? {
        do { return try await m.get(RepoAdd(path: path)) } catch let e as RPCError where e.code == RepoAdd.notARepository.code {
            let a = NSAlert()
            a.messageText = String(localized: "“\((path as NSString).lastPathComponent)” isn't a Git repository")
            a.informativeText = String(localized: "Initialize Git to see changes, diffs and branches here, or open the folder without it.")
            a.addButton(withTitle: String(localized: "Initialize Git"))
            a.addButton(withTitle: String(localized: "Open Without Git"))
            a.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
            switch await runSheet(a) {
            case .alertFirstButtonReturn: return await m.call(RepoAdd(path: path, init: true))
            case .alertSecondButtonReturn: return await m.call(RepoAdd(path: path, init: false))
            default: return nil
            }
        } catch {
            Banner.show(AppModel.message(error), style: .error); return nil
        }
    }

    /// Files and folders from Finder (dropped on the window or the Dock icon, `open -a Kelp <path>`): a folder becomes a
    /// project, a file opens as a tab (`open`: in that editor area, else wherever ⌘O would).
    package func open(files urls: [URL], with open: (@MainActor (String) -> Void)? = nil) {
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            if dir.boolValue { addProject(path: u.path) } else if let open { open(TabURI.file(u.path)) } else { self.open(TabURI.file(u.path)) }
        }
    }

    /// The files a drag carries (from Finder or the Files panel).
    static func files(_ s: NSDraggingInfo) -> [URL] {
        s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// New isolated workspace in the project on screen (or the first one).
    func newWorkspace(repo: String? = nil) {
        Task {
            // Right after launch the project list may not be in yet: ⌘N must not turn into "Add Project".
            let m = app
            await m.waitForConnection()
            guard let rid = repo ?? m.worktree(workspaceId)?.repoId ?? m.repos.first?.id else { addProject(); return }
            guard let id = await app.call(WorkspaceCreate(repoId: rid))?.id else { return }
            await app.refresh()
            show(workspace: id)
        }
    }
}

/// `kelp://` links (from a browser, a script, another app). Looking things up is free; adding a project asks first.
@MainActor
struct KelpLinks {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    func handle(_ url: URL) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "workspace" where app.worktree(id) != nil: app.workbench.show(workspace: id)
        case "session" where app.session(id) != nil: app.workbench.focus(session: id)
        case "open":
            guard let path = q.first(where: { $0.name == "path" })?.value.map({ ($0 as NSString).expandingTildeInPath }),
                  FileManager.default.fileExists(atPath: path) else {
                Banner.show(String(localized: "Kelp can't find the file in that link."), style: .error)
                return
            }
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &dir)
            if !dir.boolValue {
                let line = q.first { $0.name == "line" }?.value.flatMap(Int.init)
                let w = app.worktrees.filter { path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
                app.workbench.open(TabURI.file(path) + (line.map { "#L\($0)" } ?? ""), workspace: w?.id)
            } else if app.repos.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                app.workbench.addProject(path: path)   // already a project: just shows it
            } else {
                let a = NSAlert(); a.messageText = String(localized: "Add “\((path as NSString).lastPathComponent)” to Kelp?")
                a.informativeText = String(localized: "A link asked to open \(path) as a project.")
                a.addButton(withTitle: String(localized: "Add Project")); a.addButton(withTitle: String(localized: "Cancel"))
                Task { if await runSheet(a) == .alertFirstButtonReturn { app.workbench.addProject(path: path) } }
            }
        default: Banner.show(String(localized: "Kelp doesn't know the link \(url.absoluteString)."), style: .error)
        }
        NSApp.activate()
    }
}

/// IDE actions agents ask for through the daemon (`kelp open`, `kelp ui`). They never pull Kelp to the front or
/// switch the workspace on screen unless asked (`--focus`): a tab for another workspace waits there.
@MainActor
struct UIRequests {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    func handle(_ e: UIEvent) {
        switch e.action {
        case "open":
            guard let uri = e.uri else { return }
            let split = e.split.flatMap(SplitDirection.init(rawValue:))
            let focus = e.focus == true
            if let w = e.worktreeId, w != app.workbench.workspaceId, !focus, app.workbench.workspaceId != nil {
                app.workbench.window?.editors.openInBackground(uri, workspace: w)
                return
            }
            app.workbench.open(uri, split: split, workspace: e.worktreeId)
            if focus { NSApp.activate() }
        case "command":
            guard let id = e.id else { return }
            if id == "extensions.reload" { app.extensions.reload(); return }
            if id == "window.shot", let w = app.workbench.window?.window, let path = e.args?["path"]?.string {
                AppDelegate.snap(w, to: path); return
            }
            guard let c = app.extensions.command(id) else { Banner.show(String(localized: "Unknown command \(id)"), style: .error); return }
            if case .object(let args)? = e.args { c.run(args) } else { c.run([:]) }
        default: break
        }
    }
}

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
            a.addButton(withTitle: lost.isEmpty ? String(localized: "Delete Workspace and Branch") : String(localized: "Delete and Lose Changes"))
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
                    : String(localized: "Each of its \(all.count) worktrees has uncommitted changes, is locked or is a Kelp workspace.")
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

    /// Several at once (sidebar multi-selection): one question; each project keeps at least one workspace.
    /// Desks close; workspaces on their own branch are archived (nothing is deleted).
    func close(_ ws: [Worktree]) {
        let m = app
        let plan = WorkspaceClosing(picked: ws, open: m.worktrees.filter { !$0.archived }, repos: m.repos), closing = plan.ids
        guard !closing.isEmpty else { NSSound.beep(); return }
        let running = m.sessions.filter { s in s.worktreeId.map(closing.contains) == true && s.status != .exited && s.status != .hibernated }
        let a = NSAlert()
        a.messageText = closing.count == 1 ? String(localized: "Close 1 workspace?") : String(localized: "Close \(closing.count) workspaces?")
        a.informativeText = (running.isEmpty ? "" : running.count == 1 ? String(localized: "1 running session stops. ")
            : String(localized: "\(running.count) running sessions stop. "))
            + String(localized: "Files in the projects are not touched.") + (plan.keptSome ? " " + String(localized: "Each project keeps one workspace.") : "")
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
                Banner.show(String(localized: "“\(w.displayName)” archived. Window › Archived Workspaces brings it back."))
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

/// A file (or lines in it) handed to an agent or copied as a link.
@MainActor
package struct FileActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    /// "Sources/App.swift:12-30": workspace-relative, the way agents read a reference.
    func reference(_ path: String, lines: ClosedRange<Int>?) -> String {
        let root = app.worktree(app.workbench.workspaceId)?.path ?? ""
        let rel = !root.isEmpty && path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let l = lines.map { $0.count == 1 ? ":\($0.lowerBound)" : ":\($0.lowerBound)-\($0.upperBound)" } ?? ""
        return IDE.escapedPath(rel) + l
    }

    /// The agent the user was last with in this workspace (never a plain terminal).
    package var targetAgent: Session? {
        let m = app, wid = app.workbench.workspaceId
        if let s = app.workbench.focusedSession.flatMap(m.session), s.agent != "shell", s.worktreeId == wid, s.status != .exited { return s }
        return m.sessions.last { $0.worktreeId == wid && $0.agent != "shell" && $0.status != .exited }
    }

    /// Types the reference into the agent's prompt without pressing Return, and shows the agent.
    package func sendToAgent(_ path: String, lines: ClosedRange<Int>? = nil) {
        guard let s = targetAgent else {
            Banner.show(String(localized: "No agent in this workspace. Start one with ⌥⌘T, then send again."), style: .error)
            return
        }
        Task { await app.call(SessionSend(id: s.id, text: reference(path, lines: lines) + " ", enter: false)) }
        app.workbench.focus(session: s.id)
    }

    package func copyWebLink(_ path: String, lines: ClosedRange<Int>? = nil) {
        Task {
            guard let url = await app.call(GitWebURL(path: path, start: lines?.lowerBound, end: lines?.upperBound)) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
            Banner.show(String(localized: "Link copied"))
        }
    }

    package func copyReference(_ path: String, lines: ClosedRange<Int>?) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reference(path, lines: lines), forType: .string)
    }
}

/// A git step that failed for a reason an agent can fix (hooks, a rejected push, conflicts): the error banner
/// offers to hand it to the workspace's agent, with the error, as a prompt waiting for Return.
@MainActor
package struct GitFix {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    package func offer(_ error: String, recipe: String, worktree wid: String, vars: [String: String] = [:]) {
        guard FileActions(app).targetAgent != nil else { Banner.show(error, style: .error); return }
        Banner.show(error, style: .error, action: (String(localized: "Ask Agent to Fix"), {
            send(recipe, worktree: wid, vars: vars.merging(["error": error]) { a, _ in a })
        }))
    }

    package func send(_ recipe: String, worktree wid: String, vars: [String: String]) {
        guard let s = FileActions(app).targetAgent else { return }
        Task { if await type(recipe, worktree: wid, vars: vars, into: s.id) { app.workbench.focus(session: s.id) } }
    }

    /// The recipe typed into the session, not sent: other people's text (errors, CI logs, review comments) waits for Return.
    package func type(_ recipe: String, worktree wid: String, vars: [String: String], into sid: String) async -> Bool {
        guard let text = await app.call(RecipeRender(id: wid, name: recipe, vars: vars)) else { return false }
        await app.call(SessionSend(id: sid, text: text, enter: false))
        return true
    }
}

@MainActor
package struct PRActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    /// Pushes and opens a PR; title and body come from the branch's commits.
    package func create(worktree wid: String) {
        let a = NSAlert(); a.messageText = String(localized: "Create a pull request?")
        a.informativeText = String(localized: "Pushes \(app.worktree(wid)?.branch ?? "the branch") and opens a PR titled from its commits.")
        a.addButton(withTitle: String(localized: "Create")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            guard let url = await app.call(GitHubPRCreate(worktreeId: wid))?.url else { return }
            Banner.show(url.isEmpty ? String(localized: "Pull request created") : String(localized: "Pull request created: \(url)"))
            if let u = URL(string: url), !url.isEmpty { app.workbench.open(u.absoluteString) }
        }
    }
}
