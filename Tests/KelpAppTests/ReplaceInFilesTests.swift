import AppKit
import Core
import Foundation
import Testing
import EditorKit
@testable import KelpKit
@testable import BuiltinFiles

@Test func aReplacementSaysWhatEachLineBecomes() throws {
    var o = FindOptions()
    o.regex = true
    let plan = try ReplaceInText.plan("let a1 = 1\n  use(a2)\n", query: "a(\\d)", options: o, template: "b$1")
    #expect(plan.map(\.line) == [1, 2])
    #expect(plan[1].before == "use(a2)" && plan[1].after == "use(b2)")
    #expect(ReplaceInText.applying([plan[1]], to: "let a1 = 1\n  use(a2)\n") == "let a1 = 1\n  use(b2)\n")
    #expect(ReplaceInText.applying(plan, to: "let a1 = 1\n  use(a2)\n") == "let b1 = 1\n  use(b2)\n")
    #expect(throws: (any Error).self) { try ReplaceInText.plan("x", query: "(", options: o, template: "") }
}

extension AppOfItsOwn {
    /// What's chosen is written; a file changed since it was read is left alone.
    @Test func replacingWritesWhatsChosenAndNothingOverALaterChange() async throws {
        let rig = try await AppRig(files: ["a.txt": "old old\n", "b.txt": "old\n"]); defer { rig.done() }
        let a = rig.workspace.path + "/a.txt", b = rig.workspace.path + "/b.txt", o = FindOptions()
        func file(_ p: String, _ only: Set<Int>?) async throws -> ReplaceFile {
            let r = try #require(await rig.app.call(FilesRead(path: p)))
            let plan = try ReplaceInText.plan(r.text, query: "old", options: o, template: "new")
            return ReplaceFile(path: p, name: (p as NSString).lastPathComponent, text: r.text, stamp: r.stamp, matches: plan, chosen: only ?? Set(plan.indices))
        }
        let first = try await file(a, [1]), second = try await file(b, nil)
        try "changed\n".write(toFile: b, atomically: true, encoding: .utf8)
        await FilesPanel.write([first, second], app: rig.app)
        #expect(try String(contentsOfFile: a, encoding: .utf8) == "old new\n")
        #expect(try String(contentsOfFile: b, encoding: .utf8) == "changed\n")
    }
}
