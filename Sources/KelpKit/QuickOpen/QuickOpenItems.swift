import AppKit
import Core
import DesignKit
import WorkbenchKit

@MainActor
extension QuickOpen {
    func collect() {
        let app = self.app
        var items: [Item] = []
        if !commandsOnly {
            collectRecents()
            if let editor = app.workbench.editor {
                let root = app.worktree(app.workbench.workspaceId)?.path
                for (uri, title) in editor.openTabs where TabURI.scheme(uri) != "session" {
                    let (icon, detail) = Self.place(uri, root: root)
                    items.append(
                        Item(
                            kind: "Tab", icon: icon, title: title, detail: detail,
                            action: { app.workbench.open(uri) }, split: { app.workbench.open(uri, split: .right) },
                            image: TabURI.scheme(uri) == "file" ? app.fileIcons.image(title) : nil))
                }
            }
            for w in app.worktrees where !w.archived && app.groupName(w) != nil {
                let repo = app.projectName(w.repoId) ?? ""
                items.append(
                    Item(
                        kind: "Group", icon: "arrow.triangle.branch", title: w.displayName,
                        detail: "\(repo) · \(w.branch)",
                        action: { app.workbench.show(workspace: w.id) }))
            }
            for host in app.remoteHosts {
                let projects = app.projects(onServer: host).compactMap { app.projectName($0.id) }
                items.append(
                    Item(
                        kind: "Server", icon: "server.rack", title: host, detail: projects.joined(separator: ", "),
                        action: { app.workbench.openServer(host) }))
            }
            for s in app.sessions where s.status != .exited && s.startedBy == nil {
                let wt = app.worktree(s.worktreeId)
                items.append(
                    Item(
                        kind: s.isTerminal ? "Terminal" : "Agent", icon: "terminal",
                        title: app.catalog.displayName(s),
                        detail: [
                            s.statusWords, shortAgo(s.statusAt ?? s.createdAt),
                            app.groupName(wt) ?? app.projectName(wt?.repoId) ?? ""
                        ]
                        .joined(separator: " · "),
                        action: { app.workbench.focus(session: s.id) },
                        split: { app.workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId) },
                        session: s))
            }
            filesLoad?.cancel()
            if let wid = app.workbench.workspaceId, let root = app.worktree(wid)?.path {
                if files.root != root { files = Files() }
                // Use the files the Files panel was last told while it's watching, or else list them now.
                let pushed = app.latest(FilesEvent.self, wid)?.paths, known = files
                filesLoad = Task {
                    var paths = pushed ?? []
                    // If the list fails, a banner says why there are none.
                    if pushed == nil { paths = await app.call(FilesList(id: wid)) ?? [] }
                    let listed = paths
                    let fuzzy =
                        known.paths == listed
                        ? known.fuzzy : await Task.detached { listed.map(ProjectFiles.FuzzyPath.init) }.value
                    // Stop if the files were listed again meanwhile, or a setting's choices are on screen.
                    guard !Task.isCancelled, choosing == nil else { return }
                    files = Files(root: root, paths: listed, fuzzy: fuzzy)
                    filter()
                }
            }
        }
        // Commands come after what's open, so the empty field without agents to list starts with tabs and workspaces,
        // not the Kelp menu. The commands are every enabled menu item with an action. The app menu's items name no
        // menu, because "Kelp" beside each said nothing.
        // Extension commands are in the menus (Tools) already. Services ("Convert Text to Chinese"…) aren't listed.
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        for (i, path) in NSApp.mainMenu?.leaves() ?? [] {
            guard let action = i.action, !i.isHidden, !i.title.isEmpty else { continue }
            // Take only what the menu would offer now: something handles it and it's enabled (Run File needs a
            // file…).
            guard let target = NSApp.target(forAction: action, to: i.target, from: i),
                (target as? NSMenuItemValidation)?.validateMenuItem(i) ?? true
            else { continue }
            // No icon unless the menu item has one, because the same ⌘ on every row said nothing.
            let detail = path.filter { $0.submenu !== appMenu }.map(\.title).joined(separator: " › ")
            items.append(
                Item(
                    kind: "Command", icon: "", title: i.title, detail: detail,
                    action: { NSApp.sendAction(action, to: i.target, from: i) },
                    image: i.image, key: i.keyEquivalent.isEmpty ? "" : Self.shortcut(i)))
        }
        // Every setting is listed. One with choices (Color Theme…) lists them here, and the others open their page.
        for section in app.extensions.all.settings {
            for spec in section.specs {
                let title = "\(loc(section.title)): \(loc(spec.title))", choices = self.choices(spec)
                guard !choices.isEmpty else {
                    items.append(
                        Item(
                            kind: "Setting", icon: section.icon, title: title, detail: loc(spec.description ?? ""),
                            action: { SettingsWindow.show(app, section: section.id) }))
                    continue
                }
                let now = app.settings.value(spec.key)
                items.append(
                    Item(
                        kind: "Setting", icon: section.icon, title: title, detail: loc(spec.description ?? ""),
                        action: { [weak self] in self?.pick(section, spec) },
                        value: choices.first { $0.0 == now }?.1 ?? ""))
            }
        }
        all = items
    }

    /// Returns the item for the file at `index` in `files`.
    func fileItem(_ index: Int) -> Item {
        let app = self.app, path = files.paths[index], full = files.root + "/" + path
        return Item(
            kind: "File", icon: "doc", title: (path as NSString).lastPathComponent, detail: path,
            action: { app.workbench.open(TabURI.file(full)) },
            split: { app.workbench.open(TabURI.file(full), split: .right) })
    }

    /// Returns a tab's icon and where the tab is, in words. That is a file's path in its workspace (from ~ when outside
    /// it), a page's address, or "changes", and never the tab's own `diff:` or `file:` address.
    static func place(_ uri: String, root: String?) -> (icon: String, detail: String) {
        switch TabURI.scheme(uri) {
        case "file":
            let path = TabURI.filePath(uri).path
            if let root, let inRoot = Paths.relative(path, to: root) { return ("doc", inRoot) }
            return ("doc", (path as NSString).abbreviatingWithTildeInPath)
        case "diff": return ("plus.forwardslash.minus", String(localized: "Changes"))
        case "http", "https": return ("safari", URL(string: uri)?.host() ?? uri)
        default: return ("square.on.square", "")
        }
    }

    /// Collects the agents to get back to: asking or failed first, then finished and unseen, then the latest others.
    /// After them come the workspaces visited last. The first six get ⌘1–⌘6.
    func collectRecents() {
        let app = self.app
        let model = app
        let queue = AttentionQueue(app).sessions
        let rest = model.sessions.filter { s in s.isChat && s.status != .exited && !queue.contains { $0.id == s.id } }
            .sorted { ($0.statusAt ?? $0.createdAt) > ($1.statusAt ?? $1.createdAt) }
        var out = (queue + rest).prefix(6).map { s -> Item in
            let worktree = model.worktree(s.worktreeId)
            return Item(
                kind: s.statusWords, icon: "terminal", title: app.catalog.displayName(s),
                detail: [model.groupName(worktree), model.projectName(worktree?.repoId)].compactMap { $0 }.joined(
                    separator: " · "),
                action: { app.workbench.focus(session: s.id) },
                split: { app.workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId) },
                session: s)
        }
        var seen: Set<String> = []   // lists each workspace once, at its last visit
        for id in app.workbench.history.visits.reversed()
        where id != app.workbench.workspaceId && seen.insert(id).inserted {
            guard let worktree = model.worktree(id) else { continue }
            out.append(
                Item(
                    kind: "Group", icon: "arrow.triangle.branch",
                    title: model.groupName(worktree) ?? model.projectName(worktree.repoId) ?? worktree.displayName,
                    detail: model.projectName(worktree.repoId) ?? "",
                    action: { app.workbench.show(workspace: worktree.id) }))
            if out.count >= 10 { break }
        }
        recents = out
    }
}
