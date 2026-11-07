import AppKit
import Core
import EditorKit
import Foundation
import Testing

@testable import BuiltinFiles
@testable import KelpKit

@Test func aReplacementSaysWhatEachLineBecomes() throws {
    var o = FindOptions()
    o.regex = true
    let plan = try ReplaceInText.plan("let a1 = 1\n  use(a2)\n", query: "a(\\d)", options: o, template: "b$1")
    #expect(plan.map(\.line) == [1, 2])
    #expect(plan[1].before == "use(a2)" && plan[1].after == "use(b2)")
    #expect(ReplaceInText.applying([plan[1]], to: "let a1 = 1\n  use(a2)\n") == "let a1 = 1\n  use(b2)\n")
    #expect(ReplaceInText.applying(plan, to: "let a1 = 1\n  use(a2)\n") == "let b1 = 1\n  use(b2)\n")
    #expect(throws: (any Error).self) { try ReplaceInText.plan("x", query: "(", options: o, template: "") }
    // In any order, with text around and between in more than one alphabet, a replacement longer or empty.
    let text = "ä a1 🌊 a22 a3 end", many = try ReplaceInText.plan(text, query: "a(\\d+)", options: o, template: "[$1]")
    #expect(ReplaceInText.applying(many.reversed(), to: text) == "ä [1] 🌊 [22] [3] end")
    let gone = try ReplaceInText.plan(text, query: "a\\d+ ?", options: o, template: "")
    #expect(ReplaceInText.applying(gone, to: text) == "ä 🌊 end")
}

extension AppOfItsOwn {
    /// What's chosen is written; a file changed since it was read is left alone.
    @Test func replacingWritesWhatsChosenAndNothingOverALaterChange() async throws {
        let rig = try await AppRig(files: ["a.txt": "old old\n", "b.txt": "old\n"])
        defer { rig.done() }
        let a = rig.workspace.path + "/a.txt", b = rig.workspace.path + "/b.txt", o = FindOptions()
        func file(_ p: String, _ only: Set<Int>?) async throws -> ReplaceFile {
            let r = try #require(await rig.app.call(FilesRead(path: p)))
            let plan = try ReplaceInText.plan(r.text, query: "old", options: o, template: "new")
            return ReplaceFile(
                path: p, name: (p as NSString).lastPathComponent, text: r.text, stamp: r.stamp, matches: plan,
                chosen: only ?? Set(plan.indices))
        }
        let first = try await file(a, [1]), second = try await file(b, nil)
        try "changed\n".write(toFile: b, atomically: true, encoding: .utf8)
        await FilesPanel.write([first, second], app: rig.app)
        #expect(try String(contentsOfFile: a, encoding: .utf8) == "old new\n")
        #expect(try String(contentsOfFile: b, encoding: .utf8) == "changed\n")
    }
}

/// A rename across files is all or none: one that changed since it was read stops it, the files written go back, and the
/// one an agent edited keeps the agent's text. Undo never writes over a newer version either.
@MainActor @Test func aRefusedWriteIsNothingWrittenAndUndoKeepsNewerText() async throws {
    let rig = try await AppRig(files: ["a.txt": "a\n", "b.txt": "b\n"])
    defer { rig.done() }
    let a = rig.repo + "/a.txt", b = rig.repo + "/b.txt"
    let ra = try #require(await rig.app.call(FilesRead(path: a))),
        rb = try #require(await rig.app.call(FilesRead(path: b)))
    try rig.write("b.txt", "agent\n")   // another size: another stamp
    let r = await FileBatch.writeAll([(a, ra.text, "A\n", ra.stamp), (b, rb.text, "B\n", rb.stamp)], app: rig.app)
    guard case .failure(let refused) = r else {
        Issue.record("a refused write counted as written")
        return
    }
    #expect(refused.path == b && refused.stuck.isEmpty)
    #expect(
        try String(contentsOfFile: a, encoding: .utf8) == "a\n"
            && String(contentsOfFile: b, encoding: .utf8) == "agent\n")

    let fresh = try #require(await rig.app.call(FilesRead(path: b)))
    guard case .success(let done) = await FileBatch.writeAll([(b, fresh.text, "B\n", fresh.stamp)], app: rig.app) else {
        Issue.record("not written")
        return
    }
    try rig.write("b.txt", "agent again\n")
    #expect(await FileBatch.undo(done, app: rig.app) == [b])
    #expect(try String(contentsOfFile: b, encoding: .utf8) == "agent again\n")
}
