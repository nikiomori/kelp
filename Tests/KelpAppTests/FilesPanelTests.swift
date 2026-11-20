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
        #expect(try await waitFor { there(a) })
        #expect(there(a) && !there(b))
        undo.redo()
        #expect(try await waitFor { there(b) })
        #expect(there(b) && !there(a))

        #expect(await panel.trash({ [b] }, undo: "Move to Trash").value.count == 1)
        #expect(!there(b))
        undo.undo()
        #expect(try await waitFor { there(b) })

        _ = await panel.move({ [FileMove(from: rig.repo + "/none.txt", to: rig.repo + "/other.txt")] }, undo: "Nothing")
            .value
        #expect(try await waitFor { undo.undoActionName != "Nothing" })
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
        // The rename's step is still there to undo: one ⌘Z took it too if it isn't, whenever its file comes back.
        #expect(undo.undoActionName == "Rename")
        #expect(try await waitFor { there("c.txt") })
        #expect(there("b.txt") && !there("a.txt"))
        undo.undo()
        #expect(try await waitFor { there("a.txt") && !there("b.txt") })   // and it is the rename's
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
        #expect(try await waitFor { FileManager.default.fileExists(atPath: copy) })
        #expect(try String(contentsOfFile: copy, encoding: .utf8) == "from Finder\n")
        undo.undo()
        #expect(try await waitFor { !FileManager.default.fileExists(atPath: copy) })
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
        #expect(try await waitFor { names() == ["f.txt"] })
        #expect(names() == ["f.txt"])
        try rig.write("g.txt", "new\n")
        #expect(try await waitFor { names() == ["f.txt", "g.txt"] })
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
        #expect(try await waitFor { names() == ["build", ".gitignore", "f.txt"] })
        let build = try #require(panel.outline.item(atRow: 0) as? FileNode)
        #expect(build.ignored && build.children?.isEmpty == true)
        panel.outline.expandItem(build)
        #expect(try await waitFor { names().contains("a.o") })
        #expect(names() == ["build", "a.o", ".gitignore", "f.txt"])
        #expect(await panel.create(in: rig.repo + "/build", undo: "New File").value == rig.repo + "/build/untitled")
        panel.reloadTree()
        #expect(try await waitFor { names().contains("untitled") })
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
        #expect(try await waitFor { panel.outline.numberOfRows != 0 })
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
        #expect(try await waitFor { FileManager.default.fileExists(atPath: rig.repo + "/untitled") })
        #expect(!FileManager.default.fileExists(atPath: rig.repo + "/sub/untitled"))
    }
}

/// A file an agent adds goes into the tree where it belongs: the folders around it are the same nodes, still open, the
/// rows already there keep their cells and the selection stays. Building the whole tree again for each push took tens
/// of milliseconds per change in a big repository, on the main thread.
extension AppOfItsOwn {
    @Test func aFileAddedGoesIntoTheTreeAsItIs() async throws {
        let rig = try await AppRig(files: ["top.txt": "t\n"])
        defer { rig.done() }
        try FileManager.default.createDirectory(atPath: rig.repo + "/sub", withIntermediateDirectories: true)
        try rig.write("sub/a.txt", "a\n")
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        panel.viewWillAppear()
        @MainActor func row(_ path: String) -> Int? {
            (0..<panel.outline.numberOfRows).first { (panel.outline.item(atRow: $0) as? FileNode)?.path == path }
        }
        #expect(try await waitFor { row("sub") != nil })
        let subRow = try #require(row("sub"))
        let sub = try #require(panel.outline.item(atRow: subRow) as? FileNode)
        panel.outline.expandItem(sub)
        let top = try #require(row("top.txt"))
        panel.outline.selectRowIndexes([top], byExtendingSelection: false)
        panel.view.window?.layoutIfNeeded()   // the rows on show have their cells
        let cell = panel.outline.view(atColumn: 0, row: top, makeIfNecessary: true)
        try rig.write("sub/b.txt", "b\n")
        #expect(try await waitFor { row("sub/b.txt") != nil })
        #expect(row("sub").map { panel.outline.item(atRow: $0) as? FileNode } == sub)
        #expect(panel.outline.isItemExpanded(sub) && row("sub/b.txt") == (row("sub/a.txt") ?? 0) + 1)
        #expect(panel.outline.selectedRow == row("top.txt"))
        #expect(row("top.txt").flatMap { panel.outline.view(atColumn: 0, row: $0, makeIfNecessary: false) } === cell)
        // Worked out off the main actor: the listing isn't in the tree when `listed` returns, it is once that's done.
        let shown = try #require(panel.shownPaths)
        let task = panel.listed(FilesEvent(worktree: rig.workspace.id, paths: shown.0 + ["z.txt"], ignored: shown.1))
        #expect(task != nil && row("z.txt") == nil)
        await task?.value
        #expect(row("z.txt") != nil)
        panel.viewDidDisappear()
    }
}

/// A few paths in or out patch the tree in order, each where its folder sorts it, and say which rows moved; a file
/// that became a folder, or a listing changed as a whole, builds it again.
@Test func aListingPatchesTheTreeOrBuildsItAgain() throws {
    var nodes = FileNode.tree(["src/b.swift", "src/d.swift", "old/x.txt", "README"])
    let src = try #require(nodes.first { $0.name == "src" })
    let edits = try #require(
        FileNode.patch(&nodes, added: ["src/c.swift", "new/y.txt"], removed: ["old/x.txt"]))
    #expect(nodes.map(\.name) == ["new", "src", "README"] && nodes[1] === src)
    #expect(src.children?.map(\.name) == ["b.swift", "c.swift", "d.swift"])
    #expect(
        edits.map { "\($0.parent?.name ?? "/") \($0.index) \($0.inserted)" } == [
            "old 0 false", "/ 0 false",   // the file, then its folder left empty
            "src 1 true", "/ 0 true"   // a new folder comes in with its file in it
        ])
    #expect(FileNode.patch(&nodes, added: ["README/z"], removed: []) == nil && nodes.count == 3)
    func kind(_ update: TreeUpdate) -> String {
        switch update {
        case .same: "same"
        case .patch(let added, let removed): "patch +\(added) -\(removed)"
        case .tree: "tree"
        }
    }
    let paths = ["a", "b"], many = (0...FileNode.mostPatched).map { "f\($0)" }
    #expect(kind(FileNode.update(was: (paths, []), paths: paths, ignored: [], opened: [:])) == "same")
    #expect(
        kind(FileNode.update(was: (paths, []), paths: ["b", "c"], ignored: [], opened: [:]))
            == "patch +[\"c\"] -[\"a\"]")
    #expect(kind(FileNode.update(was: (paths, []), paths: many, ignored: [], opened: [:])) == "tree")   // a checkout
    #expect(kind(FileNode.update(was: (paths, []), paths: ["b", "c"], ignored: ["x/"], opened: [:])) == "tree")
    #expect(kind(FileNode.update(was: nil, paths: paths, ignored: [], opened: [:])) == "tree")
}

@MainActor @Test func problemsListTheProjectsErrorsFirst() {
    let warning = CodeProblem(line: 1, column: 0, endLine: 1, endColumn: 1, isError: false, message: "unused")
    let error = CodeProblem(line: 9, column: 0, endLine: 9, endColumn: 1, isError: true, message: "wrong")
    let found = FilesPanel.problems(
        in: ["/p/a.swift": [warning], "/p/b.swift": [error], "/other/c.swift": [error]], root: "/p")
    #expect(found.map(\.match.path) == ["b.swift", "a.swift"])
    #expect(found.map(\.match.line) == [10, 2])
    // The sign is drawn from isError, not typed into the text.
    #expect(found.map(\.match.text) == ["wrong", "unused"] && found.map(\.isError) == [true, false])
}
