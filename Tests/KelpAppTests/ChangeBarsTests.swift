import AppKit
import Core
import Foundation
import Testing
import TestSupport
@testable import EditorKit
import WorkbenchKit
@testable import KelpKit
@testable import BuiltinFiles

extension OneAtATime {
    /// A file an agent changed shows what differs from HEAD; a commit clears it. Nothing else is asked of the tab.
    @Test func aChangedFileShowsItsBarsUntilItsCommitted() async throws {
        let rig = try await AppRig(files: ["a.txt": "1\n2\n3\n4\n5\n"]); defer { rig.done() }
        _ = NSApplication.shared
        rig.app.worktrees = [rig.workspace]
        let path = rig.workspace.path + "/a.txt"
        try "1\n2 changed\n3\nnew\n4\n".write(toFile: path, atomically: true, encoding: .utf8)
        let tab = FileTab(uri: TabURI.file(path), app: rig.app)
        await tab.loading?.value
        let e = try #require(tab.editor)
        #expect(try await waitFor(4) { !(e.changeMarks.isEmpty) })
        #expect(e.changeMarks.map(\.kind) == [.changed, .added, .removed])
        #expect(e.changeMarks.map(\.line) == [1, 3, 5])
    }
}

@MainActor @Test func theHunkToStageIsTheOneOverTheSameLines() {
    func hunk(_ start: Int, _ line: Int) -> Hunk {
        Hunk(header: "@@ \(start)", oldStart: start, newStart: start, lines: [DiffLine(kind: .add, text: "x", newLine: line)])
    }
    #expect(ChangeBars.counterpart(of: hunk(1, 5), in: [hunk(90, 90), hunk(3, 5)])?.newStart == 3)
    #expect(ChangeBars.counterpart(of: hunk(1, 5), in: [hunk(90, 90)]) == nil)
}

@MainActor @Test func typingKeepsTheBarsBesideTheirLines() {
    let e = CodeEditor(text: "a\nb\nc\nd\n", url: URL(fileURLWithPath: "/t.txt"))
    e.changeMarks = [.init(kind: .added, line: 2, count: 1, hunk: 0)]
    e.textView.insertText("x\ny\n", replacementRange: NSRange(location: 0, length: 0))
    #expect(e.changeMarks.first?.line == 4)
    e.textView.insertText("", replacementRange: NSRange(location: 0, length: 4))
    #expect(e.changeMarks.first?.line == 2)
}

@MainActor @Test func aChangesCardIsAsBigAsItsLines() {
    let many = (0..<40).map { DiffLine(kind: .add, text: "line \($0)", newLine: $0 + 1) }
    let small = ChangeCard(shown: Hunk(header: "", oldStart: 1, newStart: 1, lines: Array(many.prefix(1))), actions: [])
    let big = ChangeCard(shown: Hunk(header: "", oldStart: 1, newStart: 1, lines: many), actions: [])
    _ = small.view
    _ = big.view
    #expect(small.preferredContentSize.height > 0 && small.preferredContentSize.width > 0)
    #expect(big.preferredContentSize.height > small.preferredContentSize.height * 5)   // 24 lines and a "more", not 40
}

@MainActor @Test func problemsLandOnTheirTextAndF8GoesRoundThem() {
    let e = CodeEditor(text: "one\ntwo three\nfour\n", url: URL(fileURLWithPath: "/t.txt"))
    e.problems = [.init(line: 1, column: 4, endLine: 1, endColumn: 9, isError: true, message: "bad"),
                  .init(line: 2, column: 0, endLine: 2, endColumn: 0, isError: false, message: "a point")]
    #expect(e.textView.problemMarks.map(\.range) == [NSRange(location: 8, length: 5), NSRange(location: 14, length: 1)])
    e.goToProblem(forward: true)
    #expect(e.textView.selectedRange().location == 8)
    #expect(e.problemAtCursor?.message == "bad")
    e.goToProblem(forward: true)
    #expect(e.textView.selectedRange().location == 14)
    e.goToProblem(forward: true)
    #expect(e.textView.selectedRange().location == 8)   // round again
    e.goToProblem(forward: false)
    #expect(e.textView.selectedRange().location == 14)
}

/// /var is /private/var: a file opened through the link is still its project's, the innermost one, with its path inside it.
@MainActor @Test func aFileThroughASymlinkFindsItsProject() throws {
    let real = try #require(Paths.real(NSTemporaryDirectory())) + "/kelp-project-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: real + "/sub/src", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: real) }
    let link = real.replacingOccurrences(of: "/private/var/", with: "/var/")
    let outer = Worktree(id: "a", repoId: "r", branch: "main", path: real)
    let inner = Worktree(id: "b", repoId: "r", branch: "x", path: real + "/sub")
    #expect(link != real)
    #expect(ChangeBars.project(of: link + "/sub/src/a.swift", in: [outer, inner]).map { [$0.worktree.id, $0.file] } == ["b", "src/a.swift"])
    #expect(ChangeBars.project(of: link + "/top.swift", in: [inner, outer]).map { [$0.worktree.id, $0.file] } == ["a", "top.swift"])
    #expect(ChangeBars.project(of: "/elsewhere/a.swift", in: [outer, inner]) == nil)
}
