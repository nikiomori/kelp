import Agents
import Core
import Foundation
import Testing

@testable import Daemon

// The agent rules' table (`whoMayDoWhat`), for a question a hook raised: who may type into it, and what ends it.

/// A session's own program can't un-say its permission question and then answer it: "working" said by hand (a hook, a
/// report), the menu pushed out of the last bytes of the screen, then a Return. The dialog a hook counted stays a
/// question until what answers it: here, its tools' batch.
@Test func aSessionCantUnsayItsQuestionAndAnswerIt() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "feat/x")
    let menu = #"/bin/sh -c 'printf "Allow npm test?\r\n\xe2\x9d\xaf 1. Yes\r\n  2. No\r\n"; cat'"#
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "command": .string(menu)]), as: Session.self)
    let ls = try #require(w.d.sessions.existing(s.id))
    _ = ls.update { $0.agent = "claude" }
    w.d.sessions.publish(ls)
    #expect(try await waitFor { try w.d.sessions.store.session(s.id)?.agent == "claude" })
    var other = Session(worktreeId: wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    other.agent = "claude"
    try w.d.sessions.store.save(other)
    let own = Caller.session(s.id), enter = SessionWrite(id: s.id, text: "\r")

    _ = try await w.c.call(SessionHook(id: s.id, event: "waiting", hookName: "PermissionRequest"))
    #expect(try await waitFor { ls.snapshot.status == .waiting })
    // (a) it says it works, by a hook and by a report: both its own to send.
    try expectRows(
        w.d,
        [
            (own, SessionHook(id: s.id, event: "working"), true, "a session reports for itself"),
            (own, SessionReport(id: s.id, state: "working"), true, "by `kelp report` too"),
            (.session(other.id), SessionHook(id: s.id, event: "working"), false, "not for another"),
            (own, enter, false, "it doesn't type into its own question")
        ])
    _ = try await w.c.call(SessionHook(id: s.id, event: "working"))
    _ = try await w.c.call(SessionReport(id: s.id, state: "working"))
    #expect(try await waitFor { ls.snapshot.status == .working })
    // (b) the menu leaves the last 1500 bytes of the screen.
    for _ in 0..<5 { _ = try await w.c.call(SessionWrite(id: s.id, text: String(repeating: "x", count: 500) + "\n")) }
    _ = try await w.c.call(SessionWrite(id: s.id, text: "flood-end\n"))
    #expect(try await waitFor(10) { try await w.c.call(SessionRead(id: s.id, bytes: 200)).contains("flood-end") })
    // (c) its Return is still refused, a send's too; so is anyone's it started for.
    #expect(ls.asksSomething)
    try expectRows(
        w.d,
        [
            (own, enter, false, "said working by itself, its question is still the user's"),
            (own, SessionSend(id: s.id, text: "go"), false, "nor sent into"),
            (.user, enter, true, "the user answers it")
        ])
    // Its tools' batch ran: it was answered, and typing into it is the agent's again.
    _ = try await w.c.call(SessionHook(id: s.id, event: "command", hookName: "PostToolBatch"))
    #expect(try await waitFor { !ls.asksSomething })
    try expectRows(w.d, [(own, enter, true, "answered, it types into its own session")])
}

/// What ends a dialog a hook counted: a key typed in the terminal, Kelp's Allow or Deny through the hook, the batch of
/// its tools, the turn's end. A prompt's "working" doesn't; AskUserQuestion's own result ends that question only.
@Test func aCountedDialogEndsWithItsAnswer() throws {
    var s = LiveSession.State(
        record: Session(cwd: "/", command: "claude", agent: "claude"),
        manifest: AgentManifest(
            id: "claude", name: "Claude Code", command: "claude", hooks: .settingsFlag("--settings")),
        logSize: 0, callbacks: .init(), trail: .init(history: tmp(), session: "s"))
    s.hook(.waiting, asker: "")
    s.hook(.working)
    #expect(s.asked)
    #expect(s.answeredOne() && !s.asked)

    s.hook(.waiting, question: true)
    s.hook(.working)
    #expect(s.asked)
    s.hook(.working, answered: true)
    #expect(!s.asked)

    s.hook(.waiting, asker: "")
    s.hook(.waiting, question: true)
    s.hook(.working, answered: true)
    #expect(s.asked)   // the permission dialog is still open
    s.tool("PostToolBatch", agent: nil)
    #expect(!s.asked)
}
