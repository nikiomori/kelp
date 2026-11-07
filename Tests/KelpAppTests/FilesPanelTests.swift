import AppKit
import Core
import Foundation
import TestSupport
import Testing

@testable import BuiltinActivity
@testable import BuiltinAgents
@testable import BuiltinBrowser
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinIssues
@testable import KelpApp
@testable import KelpKit

/// Files moved in the Files panel (by the daemon, `files.move`) come back with ⌘Z and go again with ⇧⌘Z: an agent's
/// folder isn't left half-moved. A trashed file comes back from the Trash; an operation that did nothing leaves no step.
extension AppOfItsOwn {
    @Test func aMoveInTheFilesPanelIsUndone() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        try FileManager.default.createDirectory(atPath: rig.repo + "/sub", withIntermediateDirectories: true)
        try rig.write("a.txt", "x")
        let a = rig.repo + "/a.txt", b = rig.repo + "/sub/a.txt"
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        let undo = try #require(panel.undoManager)
        func there(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
        #expect(await panel.move({ [FileMove(from: a, to: b)] }, undo: "Move").value.count == 1)
        #expect(there(b) && !there(a))
        undo.undo()
        #expect(try await waitFor(5) { there(a) })
        #expect(there(a) && !there(b))
        undo.redo()
        #expect(try await waitFor(5) { there(b) })
        #expect(there(b) && !there(a))

        #expect(await panel.trash({ [b] }, undo: "Move to Trash").value.count == 1)
        #expect(!there(b))
        undo.undo()
        #expect(try await waitFor(5) { there(b) })
        #expect(there(b))

        _ = await panel.move({ [FileMove(from: rig.repo + "/none.txt", to: rig.repo + "/other.txt")] }, undo: "Nothing")
            .value
        #expect(try await waitFor(5) { undo.undoActionName != "Nothing" })
        #expect(undo.undoActionName == "Move")   // it failed: ⌘Z undoes the step before it
    }

    /// Each operation is one step: a rename (registered once its edit ends, after an await) and a trash after it come
    /// back with two ⌘Z, not one. They once shared a step, and one ⌘Z undid both at once (the rename's undo racing the
    /// file back from the Trash).
    @Test func oneUndoIsOneOperation() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        try rig.write("a.txt", "a")
        try rig.write("c.txt", "c")
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        let undo = try #require(panel.undoManager)
        func there(_ name: String) -> Bool { FileManager.default.fileExists(atPath: rig.repo + "/" + name) }
        let renamed = panel.move({ [FileMove(from: rig.repo + "/a.txt", to: rig.repo + "/b.txt")] }, undo: "Rename")
        #expect(undo.groupingLevel == 0)   // its step closed (no event around it to close it): the next can't join it
        _ = await renamed.value
        _ = await panel.trash({ [rig.repo + "/c.txt"] }, undo: "Move to Trash").value
        undo.undo()
        #expect(try await waitFor(4) { there("c.txt") })
        // A rename undone with it would be back too by now: nothing says it isn't coming.
        try await Task.sleep(for: .milliseconds(200))
        #expect(there("c.txt") && there("b.txt") && !there("a.txt"))
        #expect(undo.undoActionName == "Rename")
    }

    /// A file dropped from Finder is copied in under Finder's "name copy" when the name is taken, and ⌘Z puts the copy in
    /// the Trash; New File makes "untitled", then "untitled 2".
    @Test func filesCopiedInAndMadeTakeFreeNames() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        let undo = try #require(panel.undoManager)
        let outside = rig.root.appendingPathComponent("f.txt").path
        try "from Finder\n".write(toFile: outside, atomically: true, encoding: .utf8)
        panel.copy([outside], into: rig.repo, undo: "Copy")
        let copy = rig.repo + "/f copy.txt"
        #expect(try await waitFor(4) { FileManager.default.fileExists(atPath: copy) })
        #expect(try String(contentsOfFile: copy, encoding: .utf8) == "from Finder\n")
        undo.undo()
        #expect(try await waitFor(4) { !(FileManager.default.fileExists(atPath: copy)) })
        #expect(
            !FileManager.default.fileExists(atPath: copy) && FileManager.default.fileExists(atPath: rig.repo + "/f.txt")
        )
        #expect(await panel.create(in: rig.repo, undo: "New File").value == rig.repo + "/untitled")
        #expect(await panel.create(in: rig.repo, undo: "New File").value == rig.repo + "/untitled 2")
    }

    /// The tree is what the daemon pushes (`WatchTopic.files`): a file an agent adds shows up without the panel asking.
    @Test func theFilesTreeFollowsWhatsPushed() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        panel.viewWillAppear()   // the window is never on screen: as if it were
        @MainActor func names() -> [String] {
            (0..<panel.outline.numberOfRows).compactMap { (panel.outline.item(atRow: $0) as? FileNode)?.name }
        }
        #expect(try await waitFor(4) { !(names() != ["f.txt"]) })
        #expect(names() == ["f.txt"])
        try rig.write("g.txt", "new\n")
        #expect(try await waitFor(5) { !(names() != ["f.txt", "g.txt"]) })
        #expect(names() == ["f.txt", "g.txt"])
        panel.viewDidDisappear()
    }

    /// What git ignores shows too, its folders closed: one opened is read then, and read again after an operation of the
    /// panel's in it (New File), which nothing pushes.
    @Test func ignoredFilesShowAndAnOpenOneFollowsOperations() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        try FileManager.default.createDirectory(atPath: rig.repo + "/build", withIntermediateDirectories: true)
        try rig.write(".gitignore", "build/\n")
        try rig.write("build/a.o", "x")
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        panel.viewWillAppear()
        @MainActor func names() -> [String] {
            (0..<panel.outline.numberOfRows).compactMap { (panel.outline.item(atRow: $0) as? FileNode)?.name }
        }
        #expect(try await waitFor(5) { names() == ["build", ".gitignore", "f.txt"] })
        let build = try #require(panel.outline.item(atRow: 0) as? FileNode)
        #expect(build.ignored && build.children?.isEmpty == true)
        panel.outline.expandItem(build)
        #expect(try await waitFor(5) { names().contains("a.o") })
        #expect(names() == ["build", "a.o", ".gitignore", "f.txt"])
        #expect(await panel.create(in: rig.repo + "/build", undo: "New File").value == rig.repo + "/build/untitled")
        panel.reloadTree()
        #expect(try await waitFor(5) { names().contains("untitled") })
        #expect(names() == ["build", "a.o", "untitled", ".gitignore", "f.txt"])
        panel.viewDidDisappear()
    }
}

/// A right-click on the empty space under the tree is about the project's folder, not about the row that happens to be
/// selected: nothing in its menu reaches that row, and a new file lands at the top.
extension AppOfItsOwn {
    @Test func theEmptySpaceUnderTheTreeLeavesTheSelectedFileAlone() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        try FileManager.default.createDirectory(atPath: rig.repo + "/sub", withIntermediateDirectories: true)
        try rig.write("sub/a.txt", "x")
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        panel.worktree = rig.workspace
        panel.reloadTree()
        #expect(try await waitFor(4) { !(panel.outline.numberOfRows == 0) })
        panel.outline.expandItem(nil, expandChildren: true)
        let file = (0..<panel.outline.numberOfRows).first {
            (panel.outline.item(atRow: $0) as? FileNode)?.path == "sub/a.txt"
        }
        panel.outline.selectRowIndexes([try #require(file)], byExtendingSelection: false)

        let onRow = NSMenu(), onNothing = NSMenu()
        panel.fill(onRow, row: try #require(file))
        panel.fill(onNothing, row: -1)
        #expect(onRow.items.map(\.title).contains("Move to Trash"))
        #expect(!onRow.items.map(\.title).contains("New File"))   // that's a folder's
        let folder = NSMenu()
        panel.fill(
            folder,
            row: panel.outline.row(
                forItem: panel.outline.parent(forItem: panel.outline.item(atRow: try #require(file)))))
        #expect(folder.items.map(\.title).first == "New File")
        #expect(folder.items.map(\.title).contains("Move to Trash"))
        #expect(!onNothing.items.map(\.title).contains("Move to Trash"))
        #expect(!onNothing.items.map(\.title).contains("Rename"))
        #expect(!onNothing.items.map(\.title).contains("Send to Agent"))

        let new = try #require(onNothing.items.first { $0.title == "New File" })
        onNothing.performActionForItem(at: onNothing.index(of: new))
        #expect(try await waitFor(4) { FileManager.default.fileExists(atPath: rig.repo + "/untitled") })
        #expect(FileManager.default.fileExists(atPath: rig.repo + "/untitled"))
        #expect(!FileManager.default.fileExists(atPath: rig.repo + "/sub/untitled"))
    }
}

@MainActor @Test func problemsListTheProjectsErrorsFirst() {
    let warning = CodeProblem(line: 1, column: 0, endLine: 1, endColumn: 1, isError: false, message: "unused")
    let error = CodeProblem(line: 9, column: 0, endLine: 9, endColumn: 1, isError: true, message: "wrong")
    let found = FilesPanel.problems(
        in: ["/p/a.swift": [warning], "/p/b.swift": [error], "/other/c.swift": [error]], root: "/p")
    #expect(found.map(\.path) == ["b.swift", "a.swift"])
    #expect(found.map(\.line) == [10, 2])
    #expect(found[0].text == "✕ wrong" && found[1].text == "⚠ unused")
}
