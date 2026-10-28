import AppKit
import Core
import WorkbenchKit

@MainActor
extension QuickOpen {
    func collect() {
        let app = self.app
        var items: [Item] = []
        if !commandsOnly {
            collectRecents()
            if let e = app.workbench.editor {
                for (uri, title) in e.openTabs where TabURI.scheme(uri) != "session" {
                    items.append(Item(kind: "Tab", icon: "square.on.square", title: title,
                                      detail: TabURI.scheme(uri) == "file" ? TabURI.filePath(uri).path : uri,
                                      action: { app.workbench.open(uri) }, split: { app.workbench.open(uri, split: .right) }))
                }
            }
            for w in app.worktrees where !w.archived {
                let repo = app.projectName(w.repoId) ?? ""
                items.append(Item(kind: "Workspace", icon: "arrow.triangle.branch", title: w.displayName, detail: "\(repo) · \(w.branch)",
                                  action: { app.workbench.show(workspace: w.id) }))
            }
            for s in app.sessions where s.status != .exited {
                let wt = app.worktree(s.worktreeId)
                items.append(Item(kind: "Agent", icon: "terminal", title: app.catalog.displayName(s),
                                  detail: "\(s.status.words) · \(shortAgo(s.statusAt ?? s.createdAt)) · \(wt?.displayName ?? "")",
                                  action: { app.workbench.focus(session: s.id) },
                                  split: { app.workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId) },
                                  session: s))
            }
            filesLoad?.cancel()
            if let wid = app.workbench.workspaceId, let root = app.worktree(wid)?.path {
                filesLoad = Task {
                    let files = await app.call(FilesList(id: wid)) ?? []   // why there are none, if it failed
                    let fuzzy = await Task.detached { files.map(ProjectFiles.FuzzyPath.init) }.value
                    // Listed again meanwhile (its own load adds them), or a setting's choices are on screen.
                    guard !Task.isCancelled, choosing == nil else { return }
                    all += zip(files, fuzzy).map { f, z in Item(kind: "File", icon: "doc", title: (f as NSString).lastPathComponent, detail: f,
                                                               action: { app.workbench.open(TabURI.file(root + "/" + f)) },
                                                               split: { app.workbench.open(TabURI.file(root + "/" + f), split: .right) }, fuzzy: z) }
                    filter()
                }
            }
        }
        // After what's open: the empty field without agents to list starts with tabs and workspaces, not the Kelp menu.
        // Commands: every enabled menu item with an action.
        func walk(_ m: NSMenu, path: String) {
            for i in m.items {
                if let s = i.submenu {
                    // Not the system's Services ("Convert Text to Chinese"…): other apps' actions, not Kelp's commands.
                    if s !== NSApp.servicesMenu { walk(s, path: path.isEmpty ? i.title : path + " › " + i.title) }
                    continue
                }
                guard let a = i.action, !i.isSeparatorItem, !i.isHidden, !i.title.isEmpty else { continue }
                // Only what the menu would offer now: someone handles it and it's enabled (Run File needs a file…).
                guard let t = NSApp.target(forAction: a, to: i.target, from: i), (t as? NSMenuItemValidation)?.validateMenuItem(i) ?? true else { continue }
                // No icon unless the menu item has one: the same ⌘ on every row said nothing.
                items.append(Item(kind: "Command", icon: "", title: i.title, detail: path, action: { NSApp.sendAction(a, to: i.target, from: i) },
                                  image: i.image, key: i.keyEquivalent.isEmpty ? "" : Self.shortcut(i)))
            }
        }
        if let m = NSApp.mainMenu { walk(m, path: "") }   // extension commands are in the menus (Tools) already
        // Every setting: one with choices (Color Theme…) lists them here, the others open their page.
        for section in app.extensions.all.settings {
            for spec in section.specs {
                let title = "\(loc(section.title)): \(loc(spec.title))", choices = self.choices(spec)
                guard !choices.isEmpty else {
                    items.append(Item(kind: "Setting", icon: section.icon, title: title, detail: loc(spec.description ?? ""),
                                      action: { SettingsWindow.show(app, section: section.id) }))
                    continue
                }
                let now = app.settings.value(spec.key)
                items.append(Item(kind: "Setting", icon: section.icon, title: title, detail: loc(spec.description ?? ""),
                                  action: { [weak self] in self?.pick(section, spec) },
                                  value: choices.first { $0.0 == now }?.1 ?? ""))
            }
        }
        all = items
    }

    /// Agents to get back to: asking or failed first, then finished and unseen, then the latest others; then the
    /// workspaces visited last. The first six get ⌘1–⌘6.
    func collectRecents() {
        let app = self.app
        let m = app
        let queue = AttentionQueue(app).sessions
        let rest = m.sessions.filter { s in s.agent != "shell" && s.status != .exited && !queue.contains { $0.id == s.id } }
            .sorted { ($0.statusAt ?? $0.createdAt) > ($1.statusAt ?? $1.createdAt) }
        var out = (queue + rest).prefix(6).map { s -> Item in
            let w = m.worktree(s.worktreeId)
            return Item(kind: s.status.words, icon: "terminal", title: app.catalog.displayName(s),
                        detail: [w?.displayName, m.projectName(w?.repoId)].compactMap { $0 }.joined(separator: " · "),
                        action: { app.workbench.focus(session: s.id) },
                        split: { app.workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId) },
                        session: s)
        }
        var seen: Set<String> = []   // each workspace once, at its last visit
        for id in app.workbench.history.visits.reversed() where id != app.workbench.workspaceId && seen.insert(id).inserted {
            guard let w = m.worktree(id) else { continue }
            out.append(Item(kind: "Workspace", icon: "arrow.triangle.branch", title: w.displayName,
                            detail: m.projectName(w.repoId) ?? "", action: { app.workbench.show(workspace: w.id) }))
            if out.count >= 10 { break }
        }
        recents = out
    }
}
