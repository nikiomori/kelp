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
        content.body = String(localized: "Ready to check: \(now) marks came back")
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
