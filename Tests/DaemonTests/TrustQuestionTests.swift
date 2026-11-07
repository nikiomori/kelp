import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// The user moving through "trust this folder?" with the arrows hasn't answered it: text waiting to go in still waits,
/// instead of its Enter picking the option the cursor reached (Claude Code's "No, exit" with pre-approved permissions).
@Test func anArrowInAQuestionDoesntAnswerIt() async throws {
    let script =
        "echo starting; sleep 5; stty -icanon -echo; "   // Claude Code's, with no numbers to read a menu by
        + #"printf 'Is this a project you created or one you trust?\n\xe2\x9d\xaf No, exit\n  Yes, I trust this folder\n'; "#
        + #"r=NOT-ANSWERED; while IFS= read -rsn1 -t 4 k; do if [[ -z "$k" ]]; then r=ANSWERED-BY-ENTER; break; fi; done; "#
        + #"echo $r; sleep 30"#
    let asker = AgentManifest(id: "asker", name: "Asker", command: "/bin/bash", args: ["-c", script, "x"])
    let w = try await world(agents: [asker])
    defer { w.d.stop() }
    let wt = try await workspace(w, "arrows")
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "asker"]), as: Session.self)
    func screen() async throws -> String {
        (try await w.c.call("session.read", .obj(["id": .string(s.id)]))).string ?? ""
    }
    #expect(try await waitFor(15) { try await screen().contains("one you trust") })
    _ = try await w.c.call("session.send", .obj(["id": .string(s.id), "text": "hello"]))
    w.c.notify(
        "session.write", .obj(["id": .string(s.id), "base64": .string(Data("\u{1B}[B".utf8).base64EncodedString())]))   // ↓
    #expect(
        try await waitFor(15) {
            let t = try await screen()
            return t.contains("NOT-ANSWERED") || t.contains("ANSWERED-BY-ENTER")
        })
    #expect(try await screen().contains("NOT-ANSWERED"))
}
