import AppKit
import Core
import DesignKit
import Foundation
import TestSupport
import Testing

@testable import BuiltinActivity
@testable import BuiltinDatabases
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinIssues
@testable import BuiltinTasks
@testable import KelpApp
@testable import KelpKit

/// An inspector list's rows stand on the panel's grid: they start where the header's first item does, a row's trailing
/// text ends as far in from the right edge, and its trailing icon button where a bar's last one does.
@MainActor private func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
/// How far `view`'s content stands from `root`'s left and right edges.
@MainActor private func edges(_ view: NSView, in root: NSView) -> (left: CGFloat, right: CGFloat) {
    let frame = view.convert(view.alignmentRect(forFrame: view.bounds), to: root)
    return (frame.minX, root.bounds.width - frame.maxX)
}
/// How far `view`'s content ends from the right of what `list` shows: the panel's edge, or a scroller that always
/// shows (as on a Mac set to show them, or with a mouse), which takes its width from the list.
@MainActor private func endInset(_ view: NSView, in list: NSTableView) -> CGFloat {
    list.visibleRect.maxX - view.convert(view.alignmentRect(forFrame: view.bounds), to: list).maxX
}
/// Where the panel's header starts its first item.
@MainActor private func headerStart(_ root: NSView) throws -> CGFloat {
    let bar = try #require(all(root).compactMap { $0 as? Bar }.first)
    return edges(try #require(bar.stack.arrangedSubviews.first { !$0.isHidden }), in: root).left
}
@MainActor private func field(_ cell: NSView, _ text: String) throws -> NSTextField {
    try #require(all(cell).compactMap { $0 as? NSTextField }.first { $0.stringValue == text })
}
@MainActor private func sized(_ vc: NSViewController, in rig: AppRig) {
    rig.show(vc, 300, 500)
    vc.view.window?.setContentSize(NSSize(width: 300, height: 500))   // a panel's own fitting size is narrower
}

@MainActor private final class OneRow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 1 }
    func tableView(_ table: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? { NSTableCellView() }
}

extension AppOfItsOwn {
    /// A panel's list hands its cell the whole row, so what a cell puts at the inset stands at the panel's inset.
    @Test func aPanelListsCellIsAsWideAsItsRow() throws {
        let table = NSTableView(), rows = OneRow()
        let scroll = table.plainList("x")
        table.dataSource = rows
        table.delegate = rows
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        table.reloadData()
        scroll.layoutSubtreeIfNeeded()
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(cell.frame.minX == 0 && cell.frame.width == table.rect(ofRow: 0).width, "\(cell.frame)")
    }

    /// Files: a folder's triangle starts under the search field, a file's letter ends as far in on the right, and the
    /// tree still nests: a folder's child is one step in, and every icon stands clear of the triangles.
    @Test func filesRowsStandOnThePanelsGrid() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        try FileManager.default.createDirectory(atPath: rig.repo + "/sub", withIntermediateDirectories: true)
        try rig.write("sub/g.txt", "g\n")
        try rig.write("f.txt", "b\n")
        let panel = FilesPanel(app: rig.app)
        sized(panel, in: rig)
        panel.viewWillAppear()
        let outline = panel.outline, root = panel.view
        @MainActor func cell(_ row: Int) -> FileRowCell? {
            guard row < outline.numberOfRows else { return nil }   // a row past the end throws, which ends every test
            return outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileRowCell
        }
        @MainActor func letter(_ row: Int) -> String? {
            cell(row).flatMap { cell in all(cell).compactMap { ($0 as? NSTextField)?.stringValue }.last }
        }
        try #require(try await waitFor { outline.numberOfRows == 2 && letter(1) == "M" })
        outline.expandItem(outline.item(atRow: 0))
        try #require(try await waitFor { outline.numberOfRows == 3 })
        root.window?.layoutIfNeeded()
        let start = try headerStart(root)
        let triangle = outline.convert(outline.frameOfOutlineCell(atRow: 0), to: root)
        #expect(triangle.minX == start)
        let file = try #require(cell(2)), child = try #require(cell(1)), folder = try #require(cell(0))
        #expect(endInset(try field(file, "M"), in: outline) == start)
        #expect(child.frame.minX - folder.frame.minX == outline.indentationPerLevel)
        for row in [folder, child, file] {
            #expect(edges(try #require(row.imageView), in: root).left >= triangle.maxX)
        }
    }

    /// Activity: a session's icon starts under the header's figures, and its Stop ends where a bar's last button does.
    @Test func activityRowsStandOnThePanelsGrid() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        defer { rig.app.latest(ActivityEvent.self).byKey[""] = nil }
        var session = Session(cwd: "/", command: "x", agent: "shell", status: .working)
        session.worktreeId = rig.workspace.id
        rig.app.sessions = [session]
        let vc = ActivityController(app: rig.app)
        sized(vc, in: rig)
        let table = try #require(all(vc.view).compactMap { $0 as? NSTableView }.first)
        rig.app.land(ActivityEvent(usage: [.init(session: session.id, cpu: 1, memory: 1000, processes: 2)]))
        try #require(try await waitFor { table.numberOfRows == 1 })
        vc.view.window?.layoutIfNeeded()
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSStackView)
        let views = cell.arrangedSubviews
        #expect(edges(try #require(views.first), in: vc.view).left == (try headerStart(vc.view)))
        let stop = try #require(views.last as? IconButton)
        #expect(endInset(stop, in: table) == Metrics.insetTrailing)
    }

    /// Source Control: a section's chevron starts under the branch, and a file's letter ends as far in on the right.
    @Test func sourceControlRowsStandOnThePanelsGrid() async throws {
        let rig = try await AppRig(files: ["kept.txt": "a\n"])
        defer { rig.done() }
        try rig.write("kept.txt", "b\n")
        let vc = SourceControlController(app: rig.app)
        sized(vc, in: rig)
        vc.followWatches()
        let outline = try #require(all(vc.view).compactMap { $0 as? NSOutlineView }.first)
        @MainActor func cells() -> [NSView] {
            (0..<outline.numberOfRows).compactMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) }
        }
        try #require(try await waitFor { cells().contains { ($0 as? FileCell)?.path == "kept.txt" } })
        vc.view.window?.layoutIfNeeded()
        let start = Metrics.inset   // where the branch chip puts its glyph (its hover fill reaches further out)
        let section = try #require(cells().first { $0 is SectionCell })
        let chevron = try #require(all(section).first { $0 is NSImageView })
        #expect(edges(chevron, in: vc.view).left == start)
        let file = try #require(cells().first { ($0 as? FileCell)?.path == "kept.txt" })
        #expect(endInset(try field(file, "M"), in: outline) == start)
    }

    /// A CI line's time ends at the inset, as a row's text does.
    @Test func aCILinesTimeEndsAtTheInset() throws {
        let cell = CIRow.line(
            CIRunLook.mark("completed", "success"), "build", font: .ui(TextSize.row), color: .labelColor, right: "2m"
        ).cell
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        cell.layoutSubtreeIfNeeded()
        #expect(edges(try field(cell, "2m"), in: cell).right == Metrics.inset)
    }

    /// A card moves its rows' content in by as much on the right as on the left: a group's count ends as far in as its
    /// folder starts, and a database's last button ends that much further in than a plain row's.
    @Test func aDatabaseCardsRowsStandAsFarInOnBothSides() throws {
        let rows = DatabasePanelRows(panel: DatabasesPanel(app: AppModel(builtins: [])))
        @MainActor func laidOut(_ row: NSView) -> [NSView] {
            row.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            row.layoutSubtreeIfNeeded()
            return (row as? NSStackView)?.arrangedSubviews.filter { !$0.isHidden } ?? []
        }
        let group = laidOut(rows.group("Work", count: 3, open: true)), groupRow = try #require(group.first?.superview)
        let start = edges(try #require(group.first), in: groupRow).left
        #expect(edges(try #require(group.last), in: groupRow).right == start)
        let database = rows.database(DatabaseInfo(name: "app_dev", engine: .postgres), library: false, health: nil)
        let button = try #require(laidOut(database).last as? IconButton)
        #expect(edges(button, in: database).right - Metrics.insetTrailing == start - Metrics.inset)
    }

    /// A task's word ends at the inset, as a row's text does; under the pointer its ⋯ ends where a bar's last button does.
    @Test func aTasksTrailingWordAndButtonStandOnTheGrid() throws {
        let page = TaskPage(
            path: "/p/doc.md", slug: "tasks", title: "Tasks",
            tasks: [TaskLine(id: "a", text: "Squeeze", proposed: true)], isList: true)
        let row = try #require(TaskViews.rows([("kelp", [page])], session: { _ in nil }).first)
        let cell = TaskCell(BareApp().app, row, place: "Inbox")
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        cell.layoutSubtreeIfNeeded()
        #expect(edges(try field(cell, row.word(nil)), in: cell).right == Metrics.inset)
        let enter = try #require(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
        cell.mouseEntered(with: enter)
        cell.layoutSubtreeIfNeeded()
        let more = try #require(all(cell).compactMap { $0 as? IconButton }.last { !$0.isHidden })
        #expect(edges(more, in: cell).right == Metrics.insetTrailing)
    }
}
