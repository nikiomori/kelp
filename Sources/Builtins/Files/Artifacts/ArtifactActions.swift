import AppKit
import Core
import DesignKit
import KelpKit
@preconcurrency import UserNotifications   // its content isn't marked Sendable
import WorkbenchKit

/// What the user does to a page as a whole, from the Artifacts panel's menu and its bar's ⋯: give it a name of their
/// own, or move its folder to the Trash (from where Finder puts it back).
@MainActor
enum ArtifactActions {
    /// Asks for the page's new name; `page` is its file.
    static func rename(_ app: AppModel, page: String, title: String) {
        Task {
            let typed = await prompt(
                String(localized: "Rename Page"), String(localized: "The name the panel and the tab show."),
                initial: title, action: String(localized: "Rename"))
            guard let typed, typed != title else { return }
            await app.call(ArtifactRename(path: page, title: typed))
        }
    }

    /// Moves the page's folder to the Trash, and closes its tab.
    static func trash(_ app: AppModel, page: String) {
        let folder = (page as NSString).deletingLastPathComponent
        Task {
            guard let moved = await app.call(FilesTrash(paths: [folder])) else { return }
            if let error = moved.error { return Banner.show(error, style: .error) }
            app.workbench.closeTab(uri: TabURI.file(page))
        }
    }
}

extension ArtifactActions {
    /// Opens a page: its file in a tab, or its page on a service in the user's browser, which is signed in to it and
    /// Kelp's tabs aren't. Only https opens, because the record may come from a cloned repository (`Artifacts.record`
    /// refuses any other scheme too).
    static func open(_ app: AppModel, _ item: ArtifactItem) {
        guard item.url != nil else { return app.workbench.open(item.target) }
        if let url = URL(string: item.target), url.scheme == "https" { PreviewLinks.openOutside(url) }
    }

    /// What Artifacts Overview adds to a page's menu: pin it, and move it to its archive or back.
    struct Keeping {
        var pinned: Bool, archived: Bool
        var pin: @MainActor () -> Void, archive: @MainActor () -> Void
    }

    /// A page's menu, the same in the Artifacts panel and Artifacts Overview: open it, look at it, the chat that made
    /// it; its name, its link or its file; then what takes it out of sight. `earlier` are the pages of the same title
    /// (the panel's folded rows), and `keeping` is the overview's own items.
    static func addItems(
        to menu: NSMenu, _ app: AppModel, _ item: ArtifactItem, open: @escaping @MainActor (ArtifactItem) -> Void,
        quickLook: @escaping @MainActor () -> Void, earlier: [ArtifactItem] = [], keeping: Keeping? = nil
    ) {
        menu.add(item.url == nil ? String(localized: "Open") : String(localized: "Open in Browser")) { open(item) }
        if item.preview != nil { menu.add(String(localized: "Quick Look"), quickLook) }
        if !earlier.isEmpty {
            let versions = NSMenu()
            for old in earlier {
                let when = Date(timeIntervalSince1970: old.modified ?? old.created)
                versions.add(when.formatted(date: .abbreviated, time: .shortened)) { open(old) }
            }
            menu.addItem(withTitle: String(localized: "Earlier Versions"), action: nil, keyEquivalent: "").submenu =
                versions
        }
        if let session = item.session.flatMap(app.session), session.status != .exited {
            menu.add(String(localized: "Show the Chat That Made It")) { app.workbench.focus(session: session.id) }
        }
        menu.addItem(.separator())
        if let keeping { menu.add(keeping.pinned ? String(localized: "Unpin") : String(localized: "Pin"), keeping.pin) }
        if item.url == nil {
            menu.add(String(localized: "Rename…")) { rename(app, page: item.target, title: item.title) }
            if keeping != nil { addExport(to: menu, app, item) }
        }
        if let link = item.url {
            menu.add(String(localized: "Copy Link")) { copyText(link) }
        } else {
            WorkspaceActions.addLocate(to: menu, path: item.target)
        }
        guard keeping != nil || item.url == nil else { return }
        menu.addItem(.separator())
        if let keeping {
            menu.add(
                keeping.archived ? String(localized: "Move Out of Archive") : String(localized: "Move to Archive"),
                keeping.archive)
        }
        if item.url == nil { menu.add(String(localized: "Move to Trash")) { trash(app, page: item.target) } }
    }

    /// Export ›, with what the page's own ⋯ exports. The page opens beside to be drawn, and is written where the user
    /// chose (`Builtins.exportPage`).
    private static func addExport(to menu: NSMenu, _ app: AppModel, _ item: ArtifactItem) {
        let page: MarkdownTab.Page
        switch Artifacts.Kind(rawValue: item.type) {
        case .design, .dashboard: page = .canvas
        case .slides: page = .slides
        case .doc, .review, .proof: page = .markdown
        default: return   // a motion page exports a video, from its own bar
        }
        let formats = NSMenu()
        for format in PageExport.formats(for: page) {
            formats.add(format.title(page)) {
                Task {
                    let name = URL(fileURLWithPath: item.target).deletingLastPathComponent().lastPathComponent
                    guard let (to, editable) = await MarkdownTab.askWhere(format, name: name) else { return }
                    Builtins.exportPage(
                        app,
                        [
                            "path": .string(item.target), "format": .string(format.rawValue), "to": .string(to.path),
                            "editable": .bool(editable)
                        ])
                }
            }
        }
        menu.add(String(localized: "Export"), submenu: formats)
    }
}

extension ArtifactActions {
    /// Whether the agent is writing the page: it was saved in the last two minutes and its chat is working.
    static func writing(_ item: ArtifactItem, _ app: AppModel) -> Bool {
        guard let modified = item.modified, app.session(item.session ?? "")?.status == .working else { return false }
        return Date().timeIntervalSince1970 - modified < 120
    }

    /// A page's second line in a list, only when there's something to say: the agent is writing the page, the marks
    /// to check or with the agent, or how much of a review is answered.
    static func note(_ item: ArtifactItem, _ app: AppModel) -> (text: String, waits: Bool)? {
        if writing(item, app), let session = item.session.flatMap(app.session) {
            return (String(localized: "\(app.catalog.name(session.agent)) is writing"), false)
        }
        if let marks = item.marks, marks.check > 0 { return (String(localized: "To check: \(marks.check)"), true) }
        if let marks = item.marks, marks.sent > 0 {
            let who = item.session.flatMap(app.session).map { app.catalog.name($0.agent) }
            return (
                who.map { String(localized: "With \($0): \(marks.sent)") } ?? String(localized: "Sent: \(marks.sent)"),
                false
            )
        }
        guard let points = item.points, points > 0 else { return nil }
        let answered = item.answered ?? 0
        return (String(localized: "\(answered) of \(points) answered"), answered < points)
    }
}

/// Which pages the user has seen: opened from a list or shown in a tab. It is one list in the window's state for the
/// panel and the overview alike, at most the 500 latest. Until anything was listed nothing counts as new, so the first
/// list doesn't light up every page.
@MainActor
enum ArtifactSeen {
    static let key = "artifacts.seen"

    static func started(_ app: AppModel) -> Bool { app.uiState[key] != nil }
    static func isNew(_ item: ArtifactItem, _ app: AppModel) -> Bool {
        started(app) && !app.uiState.strings(key).contains(item.target)
    }

    /// Adds `targets` to the seen pages. Returns whether the list changed.
    static func mark(_ targets: [String], _ app: AppModel) async -> Bool {
        var list = app.uiState.strings(key)
        let added = targets.filter { !list.contains($0) }
        guard !added.isEmpty || !started(app) else { return false }
        list = Array((list + added).suffix(500))
        _ = await app.uiState.save(key, .array(list.map { .string($0) }))
        return true
    }
}

extension ArtifactsPanel {
    /// What the filter finds a page by: its title, its kind and the agent that made it ("slides", "Codex").
    func words(_ item: ArtifactItem, _ project: String?) -> String {
        let kind = Artifacts.Kind(rawValue: item.type).map(ArtifactStart.title) ?? item.type
        let agent = item.session.flatMap(app.session)?.agent.map { app.catalog.name($0) } ?? ""
        return [title(item, project), kind, item.type, agent].joined(separator: " ")
    }
}

extension ArtifactBar {
    /// Marks came back from the agent while Kelp isn't in front: a notification says the page is ready, and how many
    /// marks wait to be checked (with Kelp in front, the Mark count and the check bar say it).
    func tellChecks(was: Int, now: Int) {
        guard now > was, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = item?.title ?? (path as NSString).lastPathComponent
        content.body = String(localized: "Ready to check: the agent answered marks (\(now))")
        Notifications.notifyUser(app, "artifact-check:" + path, content)
    }
}

extension ArtifactBar {
    /// ⋯ › Keyboard Shortcuts: what the keys do on a page, a canvas or a motion page, in a popover from ⋯, since
    /// none of them shows on the page.
    func showKeys() {
        let content = NSViewController()
        content.view = keysView()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: more.bounds, of: more, preferredEdge: .minY)
    }

    /// The keys, by where they work.
    func keysView() -> NSView {
        var sections: [(String, [(String, String)])] = [
            (
                String(localized: "Page"),
                [
                    ("⌥⌘1 ⌥⌘2 ⌥⌘3", String(localized: "View, Mark, Edit")), ("⌃⌘← ⌃⌘→", String(localized: "Versions")),
                    ("⌘F", String(localized: "Find"))
                ]
            ),
            (
                String(localized: "Canvas"),
                [
                    ("⌘+ ⌘−", String(localized: "Zoom")), ("⌘9", String(localized: "Fit")),
                    ("⇧2", String(localized: "Zoom to the Chosen Element")),
                    (String(localized: "Space-drag"), String(localized: "Move Around"))
                ]
            ),
            (
                String(localized: "Edit"),
                [
                    (String(localized: "⇧-click"), String(localized: "Add to the Chosen")),
                    ("← → ↑ ↓", String(localized: "Move (⇧ by 10)")), ("⌘C ⌘V", String(localized: "Copy and Paste")),
                    ("⌘D", String(localized: "Duplicate")), ("⌫", String(localized: "Delete")),
                    ("⎋", String(localized: "Choose Nothing")), ("⌘Z", String(localized: "Undo"))
                ]
            ),
            (
                String(localized: "Layers"),
                [
                    ("↑ ↓", String(localized: "Parent, Inside")), ("⇥", String(localized: "Next")),
                    (String(localized: "Double-click"), String(localized: "Rename"))
                ]
            )
        ]
        if markdown.page == .motion {
            sections.append(
                (
                    String(localized: "Video"),
                    [
                        (String(localized: "Space"), String(localized: "Play or Pause")),
                        ("S", String(localized: "Split at Playhead")), ("[ ]", String(localized: "Trim to Playhead")),
                        ("I O", String(localized: "Set the Work Area")), ("K", String(localized: "Add Keyframe"))
                    ]
                ))
        }
        // One grid, so the keys line up in one column; a section's title spans both.
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = Metrics.gapTight
        grid.columnSpacing = Metrics.gapWide
        for (title, rows) in sections {
            let heading = grid.addRow(with: [
                NSTextField.label(title, font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
            ])
            heading.mergeCells(in: NSRange(location: 0, length: 2))
            heading.topPadding = grid.numberOfRows == 1 ? 0 : Metrics.gapWide
            for (keys, what) in rows {
                grid.addRow(with: [
                    NSTextField.label(keys, font: .uiDigits(TextSize.row), color: .secondaryLabelColor),
                    NSTextField.label(what, font: .ui(TextSize.row))
                ])
            }
        }
        let box = NSView()
        let m = Metrics.inset
        box.pin(grid, inset: NSEdgeInsets(top: m, left: m, bottom: m, right: m))
        box.frame.size = NSSize(width: Metrics.popoverWidth, height: box.fittingSize.height)
        return box
    }
}
