import AppKit
import Foundation
import Testing
import Core
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

/// Files moved in the Files panel (by the daemon, `files.move`) come back with ⌘Z and go again with ⇧⌘Z: an agent's
/// folder isn't left half-moved. A trashed file comes back from the Trash; an operation that did nothing leaves no step.
extension AppOfItsOwn {
    @Test func aMoveInTheFilesPanelIsUndone() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        try FileManager.default.createDirectory(atPath: rig.repo + "/sub", withIntermediateDirectories: true)
        try rig.write("a.txt", "x")
        let a = rig.repo + "/a.txt", b = rig.repo + "/sub/a.txt"
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        let undo = try #require(panel.undoManager)
        func there(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
        func until(_ ok: () -> Bool) async throws { for _ in 0..<200 where !ok() { try await Task.sleep(for: .milliseconds(20)) } }
        #expect(await panel.move({ [FileMove(from: a, to: b)] }, undo: "Move").value.count == 1)
        #expect(there(b) && !there(a))
        undo.undo()
        try await until { there(a) }
        #expect(there(a) && !there(b))
        undo.redo()
        try await until { there(b) }
        #expect(there(b) && !there(a))

        #expect(await panel.trash({ [b] }, undo: "Move to Trash").value.count == 1)
        #expect(!there(b))
        undo.undo()
        try await until { there(b) }
        #expect(there(b))

        await panel.move({ [FileMove(from: rig.repo + "/none.txt", to: rig.repo + "/other.txt")] }, undo: "Nothing").value
        try await until { undo.undoActionName != "Nothing" }
        #expect(undo.undoActionName == "Move")   // it failed: ⌘Z undoes the step before it
    }

    /// Each operation is one step: a rename (registered once its edit ends, after an await) and a trash after it come
    /// back with two ⌘Z, not one. They once shared a step, and one ⌘Z undid both at once (the rename's undo racing the
    /// file back from the Trash).
    @Test func oneUndoIsOneOperation() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        try rig.write("a.txt", "a"); try rig.write("c.txt", "c")
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        let undo = try #require(panel.undoManager)
        func there(_ name: String) -> Bool { FileManager.default.fileExists(atPath: rig.repo + "/" + name) }
        let renamed = panel.move({ [FileMove(from: rig.repo + "/a.txt", to: rig.repo + "/b.txt")] }, undo: "Rename")
        #expect(undo.groupingLevel == 0)   // its step closed (no event around it to close it): the next can't join it
        await renamed.value
        await panel.trash({ [rig.repo + "/c.txt"] }, undo: "Move to Trash").value
        undo.undo()
        for _ in 0..<200 where !there("c.txt") { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(there("c.txt") && there("b.txt") && !there("a.txt"))
        #expect(undo.undoActionName == "Rename")
    }

    /// A file dropped from Finder is copied in under Finder's "name copy" when the name is taken, and ⌘Z puts the copy in
    /// the Trash; New File makes "untitled", then "untitled 2".
    @Test func filesCopiedInAndMadeTakeFreeNames() async throws {
        let rig = try await AppRig(); defer { rig.done() }
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        let undo = try #require(panel.undoManager)
        let outside = rig.root.appendingPathComponent("f.txt").path
        try "from Finder\n".write(toFile: outside, atomically: true, encoding: .utf8)
        panel.copy([outside], into: rig.repo, undo: "Copy")
        let copy = rig.repo + "/f copy.txt"
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: copy) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try String(contentsOfFile: copy, encoding: .utf8) == "from Finder\n")
        undo.undo()
        for _ in 0..<200 where FileManager.default.fileExists(atPath: copy) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!FileManager.default.fileExists(atPath: copy) && FileManager.default.fileExists(atPath: rig.repo + "/f.txt"))
        #expect(await panel.create(in: rig.repo, undo: "New File").value == rig.repo + "/untitled")
        #expect(await panel.create(in: rig.repo, undo: "New File").value == rig.repo + "/untitled 2")
    }

    /// The tree is what the daemon pushes (`WatchTopic.files`): a file an agent adds shows up without the panel asking.
    @Test func theFilesTreeFollowsWhatsPushed() async throws {
        let rig = try await AppRig(); defer { rig.done() }
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        panel.viewWillAppear()   // the window is never on screen: as if it were
        @MainActor func names() -> [String] { (0..<panel.outline.numberOfRows).compactMap { (panel.outline.item(atRow: $0) as? FileNode)?.name } }
        for _ in 0..<200 where names() != ["f.txt"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["f.txt"])
        try rig.write("g.txt", "new\n")
        for _ in 0..<250 where names() != ["f.txt", "g.txt"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["f.txt", "g.txt"])
        panel.viewDidDisappear()
    }

    /// What git ignores shows too, its folders closed: one opened is read then, and read again after an operation of the
    /// panel's in it (New File), which nothing pushes.
    @Test func ignoredFilesShowAndAnOpenOneFollowsOperations() async throws {
        let rig = try await AppRig(); defer { rig.done() }
        try FileManager.default.createDirectory(atPath: rig.repo + "/build", withIntermediateDirectories: true)
        try rig.write(".gitignore", "build/\n"); try rig.write("build/a.o", "x")
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        panel.viewWillAppear()
        @MainActor func names() -> [String] { (0..<panel.outline.numberOfRows).compactMap { (panel.outline.item(atRow: $0) as? FileNode)?.name } }
        func until(_ ok: () -> Bool) async throws { for _ in 0..<250 where !ok() { try await Task.sleep(for: .milliseconds(20)) } }
        try await until { names() == ["build", ".gitignore", "f.txt"] }
        let build = try #require(panel.outline.item(atRow: 0) as? FileNode)
        #expect(build.ignored && build.children?.isEmpty == true)
        panel.outline.expandItem(build)
        try await until { names().contains("a.o") }
        #expect(names() == ["build", "a.o", ".gitignore", "f.txt"])
        #expect(await panel.create(in: rig.repo + "/build", undo: "New File").value == rig.repo + "/build/untitled")
        panel.reloadTree()
        try await until { names().contains("untitled") }
        #expect(names() == ["build", "a.o", "untitled", ".gitignore", "f.txt"])
        panel.viewDidDisappear()
    }
}

/// A right-click on the empty space under the tree is about the project's folder, not about the row that happens to be
/// selected: nothing in its menu reaches that row, and a new file lands at the top.
extension AppOfItsOwn {
    @Test func theEmptySpaceUnderTheTreeLeavesTheSelectedFileAlone() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        try FileManager.default.createDirectory(atPath: rig.repo + "/sub", withIntermediateDirectories: true)
        try rig.write("sub/a.txt", "x")
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        panel.worktree = rig.workspace
        panel.reloadTree()
        for _ in 0..<200 where panel.outline.numberOfRows == 0 { try await Task.sleep(for: .milliseconds(20)) }
        panel.outline.expandItem(nil, expandChildren: true)
        let file = (0..<panel.outline.numberOfRows).first { (panel.outline.item(atRow: $0) as? FileNode)?.path == "sub/a.txt" }
        panel.outline.selectRowIndexes([try #require(file)], byExtendingSelection: false)

        let onRow = NSMenu(), onNothing = NSMenu()
        panel.fill(onRow, row: try #require(file))
        panel.fill(onNothing, row: -1)
        #expect(onRow.items.map(\.title).contains("Move to Trash"))
        #expect(!onNothing.items.map(\.title).contains("Move to Trash"))
        #expect(!onNothing.items.map(\.title).contains("Rename"))
        #expect(!onNothing.items.map(\.title).contains("Send to Agent"))

        let new = try #require(onNothing.items.first { $0.title == "New File" })
        new.target.map { _ = $0.perform(new.action, with: new) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: rig.repo + "/untitled") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: rig.repo + "/untitled"))
        #expect(!FileManager.default.fileExists(atPath: rig.repo + "/sub/untitled"))
    }
}
