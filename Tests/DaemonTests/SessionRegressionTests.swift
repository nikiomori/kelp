import Agents
import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

// Sessions' input and lifecycle, kept apart from RegressionTests.swift by size.

/// What the program read first as one line (`GOT[…]`), the screen's wrapping undone.
private func submitted(_ screen: String) -> String {
    let rest =
        screen.replacingOccurrences(of: "\n", with: "").split(separator: "GOT[", maxSplits: 1).dropFirst().first ?? ""
    return String(rest.prefix { $0 != "]" })
}

/// A draft (an issue's brief) to a program that takes no pastes isn't submitted line by line: it arrives as one line,
/// still waiting for Return.
@Test func aDraftToAPlainProgramIsNotSubmittedLineByLine() async throws {
    let plain = AgentManifest(
        id: "plain", name: "Plain", command: "/bin/bash",
        args: ["-c", #"echo ready; read -r l; echo "GOT[$l]"; sleep 30"#, "x"])
    let w = try await world(agents: [plain])
    defer { w.d.stop() }
    let r = try await w.c.call(
        "task.fromIssue",
        .obj([
            "repoId": .string(w.repo.id), "ref": "#8", "title": "Two lines", "body": "first\nsecond", "agent": "plain"
        ]))
    let s = try #require(r["session"]).decode(Session.self)
    func screen() async throws -> String {
        (try await w.c.call("session.read", .obj(["id": .string(s.id)]))).string ?? ""
    }
    #expect(try await waitFor(10) { try await screen().contains("second") })   // typed
    w.c.notify("session.write", .obj(["id": .string(s.id), "base64": .string(Data("\r".utf8).base64EncodedString())]))   // the user's Return
    #expect(try await waitFor(10) { try await screen().contains("GOT[") })
    let shown = try await screen()
    // One line, the framed title and body in it: submitted early it'd end at the title.
    let got = submitted(shown)
    #expect(got.contains("Two lines") && got.contains("first second") && got.hasSuffix("(Issue: )"), "\(shown)")
}

/// Text sent while an unread draft sits in the input box waits behind it: its Enter would submit the draft (an issue's
/// text, someone else's words) without the user reading it. Once the user acts on the draft, it goes in.
@Test func aSendDoesntSubmitAnUnreadDraft() async throws {
    let reader = #"echo ready; while read -r l; do echo "GOT[$l]"; done"#
    let plain = AgentManifest(id: "plain2", name: "Plain", command: "/bin/bash", args: ["-c", reader, "x"])
    let w = try await world(agents: [plain])
    defer { w.d.stop() }
    let r = try await w.c.call(
        "task.fromIssue",
        .obj(["repoId": .string(w.repo.id), "ref": "#9", "title": "Brief", "body": "rm -rf", "agent": "plain2"]))
    let s = try #require(r["session"]).decode(Session.self)
    func screen() async throws -> String {
        (try await w.c.call("session.read", .obj(["id": .string(s.id)]))).string ?? ""
    }
    #expect(try await waitFor(10) { try await screen().contains("rm -rf") })   // the draft, typed
    _ = try await w.c.call("session.send", .obj(["id": .string(s.id), "text": "and also this"]))   // `kelp send`, with Enter
    let ls = try #require(w.d.sessions.existing(s.id))
    for _ in 0..<3 {
        await withCheckedContinuation { c in ls.inOrder { c.resume() } }
        ls.tick()
    }   // ticks that could deliver it
    #expect(!(try await screen()).contains("GOT["))   // nothing submitted
    w.c.notify("session.write", .obj(["id": .string(s.id), "base64": .string(Data("\r".utf8).base64EncodedString())]))   // the user sends it
    #expect(try await waitFor(10) { try await screen().contains("GOT[and also this]") })
    let got = submitted(try await screen())   // the draft first, then what waited behind it
    #expect(got.contains("Brief") && got.contains("rm -rf") && got.hasSuffix("(Issue: )"))   // the draft, as one line, after the user's Return
}

/// Opening a paused session doesn't wait for another session that takes its time to stop (an agent ignoring the
/// hangup gets 2 s before SIGKILL): each session has its own wake lock.
@Test func openingASessionDoesntWaitForAnotherToStop() async throws {
    let stubborn = AgentManifest(
        id: "stubborn2", name: "Stubborn", command: "/bin/bash",
        args: ["-c", "trap 'echo STOPPING' TERM; trap '' HUP; echo up; while :; do sleep 0.1; done", "x"],
        resumeArgs: ["--resume"])
    let sleepy = AgentManifest(
        id: "sleepy3", name: "Sleepy", command: "/bin/zsh", args: ["-c", "echo up; sleep 30", "x"],
        resumeArgs: ["--resume"])
    let w = try await world(agents: [stubborn, sleepy])
    defer { w.d.stop() }
    let slow = try await workspace(w, "slow"), other = try await workspace(w, "other")
    let a: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(slow.id), "agent": "stubborn2"]), as: Session.self)
    let b: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(other.id), "agent": "sleepy3"]), as: Session.self)
    #expect(
        try await waitFor(10) {
            (try await w.c.call("session.read", .obj(["id": .string(a.id)]))).string?.contains("up") == true
        })
    _ = try await w.c.call("worktree.archive", .obj(["id": .string(other.id)]))   // b paused
    _ = try await w.c.call("worktree.unarchive", .obj(["id": .string(other.id)]))
    let la = try #require(w.d.sessions.existing(a.id))
    let archiving = Task { try await w.c.call("worktree.archive", .obj(["id": .string(slow.id)])) }   // ~2 s: a ignores SIGTERM
    #expect(try await waitFor(10) { String(decoding: la.tail(4000), as: UTF8.self).contains("STOPPING") })   // under way, its lock held
    _ = try await w.c.call("session.attach", .obj(["id": .string(b.id)]))   // wakes b
    #expect(kill(a.pid, 0) == 0)   // a still stopping: b's wake didn't wait for it
    _ = try await archiving.value
    #expect(kill(a.pid, 0) != 0)
}

/// .kelp.yaml written on Windows (CRLF) reads like any other: each key on its own line, no "\r" in a command.
@Test func aKelpYamlWithCRLFLineEndingsReadsLineByLine() {
    let c = RepoConfig.parse("setup: npm ci\r\nrun: npm start\r\ntabs: claude, shell\r\n")
    #expect(c.setup == "npm ci" && c.tabs == ["claude", "shell"])
    #expect(c.scripts == [RepoConfig.Script(name: "run", command: "npm start")])
}

/// A woken session still follows the topic its agent sets (Claude Code's terminal title), as one that was never paused.
@Test func aWokenSessionStillFollowsItsAgentsTopic() async throws {
    let script = #"echo up; sleep 1.5; printf '\033]0;* Fixing the login bug\007'; sleep 30"#
    let titled = AgentManifest(
        id: "titled", name: "Titled", command: "/bin/bash", args: ["-c", script, "x"], resumeArgs: ["--resume"])
    let w = try await world(agents: [titled])
    defer { w.d.stop() }
    let wt = try await workspace(w, "topics")
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "titled"]), as: Session.self)
    _ = try await w.c.call("worktree.archive", .obj(["id": .string(wt.id)]))   // paused before it named its topic
    _ = try await w.c.call("worktree.unarchive", .obj(["id": .string(wt.id)]))
    _ = try await w.c.call("session.attach", .obj(["id": .string(s.id)]))   // woken: it runs again and names it
    #expect(
        try await waitFor(10) {
            try await w.c.call("session.list", as: [Session].self).first { $0.id == s.id }?.title
                == "Fixing the login bug"
        })
}

/// The hidden usage probe never answers a question its copy of the agent asks (trust this folder? use the project's new
/// MCP servers?): it presses nothing and gives up, where /usage and Enter would have picked the default, "Yes".
@Test func theUsageProbePressesNothingOnAQuestion() throws {
    for question in [
        #"Do you trust the files in this folder?\n\xe2\x9d\xaf 1. Yes, proceed\n  2. No, exit\n"#,
        #"New MCP server found in .mcp.json: tools\n\xe2\x9d\xaf 1. Use this and all future MCP servers\n  2. Continue without\n"#
    ] {
        let pressed = tmp().path + "-pressed"
        let script = "stty -icanon -echo; printf '\(question)'; IFS= read -rsn1 k && touch \(pressed); sleep 30"
        let probe = AgentUsage.PlanProbe(
            agent: "claude", command: "claude", every: 600, ready: { $0.contains("❯") },
            shown: { $0.contains("% used") }, parse: { _ in [] })
        let (readings, _) = AgentUsage.probe(probe, argv: ["/bin/bash", "-c", script], cwd: NSTemporaryDirectory())
        #expect(readings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pressed), "a key reached: \(question)")
    }
}

/// Stopping the daemon (a restart, an update) ends whole trees — a job in a process group of its own, an agent that
/// ignores the hangup — and a resumable agent is recorded as paused, so opening it later resumes it once.
@Test func stoppingTheDaemonEndsWholeTreesAndKeepsAgentsResumable() async throws {
    let stubborn = AgentManifest(
        id: "stubborn4", name: "Stubborn", command: "/bin/bash",
        args: ["-c", "trap '' HUP TERM; echo up; while :; do sleep 0.1; done", "x"], resumeArgs: ["--resume"])
    let w = try await world(agents: [stubborn])
    let wt = try await workspace(w, "stop")
    let a: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "stubborn4"]), as: Session.self)
    let pidFile = tmp().path + "-job.pid"
    let script = "set -m; (trap '' HUP TERM; while :; do sleep 0.1; done) & echo $! > \(pidFile); echo started; wait"
    _ = try await w.c.call(
        "session.create",
        .obj(["worktreeId": .string(wt.id), "command": .string("/bin/bash -c " + IDE.shellWord(script))]))
    #expect(try await waitFor(10) { FileManager.default.fileExists(atPath: pidFile) })
    #expect(
        try await waitFor(10) {
            (try await w.c.call("session.read", .obj(["id": .string(a.id)]))).string?.contains("up") == true
        })
    let job = try #require(
        pid_t((try String(contentsOfFile: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer {
        kill(job, SIGKILL)
        kill(a.pid, SIGKILL)
    }   // whatever happens, not left behind
    w.d.stop()
    #expect(kill(job, 0) != 0 && kill(a.pid, 0) != 0)
    #expect(try w.d.store.session(a.id)?.status == .paused)
}

/// What's stopped is waited for until it's gone, not for a fixed while: SIGKILL comes from a timer, which a busy
/// machine runs late, and a program still there when its workspace goes would write into a folder being removed.
@Test func waitingForProgramsEndsWhenTheyAreGone() throws {
    let late = Process()   // ends by itself after waitGone's old 3 s, as a SIGKILL's late timer would end it
    late.executableURL = URL(fileURLWithPath: "/bin/sleep")
    late.arguments = ["3.5"]
    try late.run()
    Sessions.waitGone([late.processIdentifier])
    #expect(kill(late.processIdentifier, 0) != 0)
}

/// Text sent to a session that is still starting waits until it's ready, however it came to be starting (just created,
/// or woken by someone else a moment before): typed at once, a program that flushes its input on startup loses it.
@Test func textForAStartingSessionWaitsUntilItIsReady() async throws {
    // It prints until the flush is done: a fixed quiet spell (and perl's start, slow on a busy runner) came out longer
    // than the second and a half after which a program counts as started.
    let script =
        "(while :; do echo booting; sleep 0.3; done) & sleep 1; perl -MPOSIX -e 'tcflush(0, POSIX::TCIFLUSH)'; kill $!; echo ready; read -r line; echo GOT:$line; sleep 30"
    let slow = AgentManifest(
        id: "slow2", name: "Slow", command: "/bin/bash", args: ["-c", script, "x"], resumeArgs: ["--resume"])
    let w = try await world(agents: [slow])
    defer { w.d.stop() }
    let wt = try await workspace(w, "starting")
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "slow2"]), as: Session.self)
    #expect(
        try await waitFor(10) {
            (try await w.c.call("session.read", .obj(["id": .string(s.id)]))).string?.contains("booting") == true
        })
    _ = try await w.c.call("session.send", .obj(["id": .string(s.id), "text": "hello"]))   // running, but still booting
    // Up to 25 s: a program that never goes quiet counts as started then (the Thread Sanitizer's run is that slow).
    #expect(
        try await waitFor(40) {
            (try await w.c.call("session.read", .obj(["id": .string(s.id)]))).string?.contains("GOT:hello") == true
        })
}

/// Text sent while the agent asks a question (trust this folder? use the project's new MCP servers?) waits: its Enter
/// would pick the default, usually "Yes". Here the agent is up and quiet before it asks, so the send isn't held back
/// as "still starting"; only the question holds it.
@Test func aSendNeverAnswersAQuestionOnScreen() async throws {
    let script =
        "echo starting; sleep 5; stty -icanon -echo; "
        + #"printf 'Do you trust the files in this folder?\n\xe2\x9d\xaf 1. Yes, proceed\n  2. No, exit\n'; "#
        + #"r=NOT-ANSWERED; while IFS= read -rsn1 -t 4 k; do if [[ -z "$k" ]]; then r=ANSWERED-BY-ENTER; break; fi; done; "#
        + #"echo $r; stty icanon echo; printf '❯ '; exec cat"#   // then its input box, as Claude Code draws it
    let asker = AgentManifest(id: "asker", name: "Asker", command: "/bin/bash", args: ["-c", script, "x"])
    let w = try await world(agents: [asker])
    defer { w.d.stop() }
    let wt = try await workspace(w, "asks")
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "asker"]), as: Session.self)
    func screen() async throws -> String {
        (try await w.c.call("session.read", .obj(["id": .string(s.id)]))).string ?? ""
    }
    #expect(try await waitFor(15) { try await screen().contains("Do you trust") })
    _ = try await w.c.call("session.send", .obj(["id": .string(s.id), "text": "hello"]))   // `kelp send`, review comments: with Enter
    #expect(
        try await waitFor(15) {
            let t = try await screen()
            return t.contains("NOT-ANSWERED") || t.contains("ANSWERED-BY-ENTER")
        })
    #expect(try await screen().contains("NOT-ANSWERED"))
    w.c.notify("session.write", .obj(["id": .string(s.id), "base64": .string(Data("2".utf8).base64EncodedString())]))   // the user answers
    #expect(try await waitFor(10) { try await screen().contains("hello") })   // and then it goes in
}

/// An agent's own auto-answer (a manifest's "press Enter to continue") is pressed a moment after the question draws; if
/// the user typed meanwhile, it isn't pressed at all (it would land in their text, or answer whatever came next).
@Test func anAutoAnswerIsntPressedOnceTheUserTyped() async throws {
    // Asks, then reports every key that comes: the user's, and a late Enter if there is one.
    let script =
        #"stty -icanon -echo; echo 'Press Enter to continue'; "#
        + #"while IFS= read -rsn1 -t 3 k; do if [[ -z "$k" ]]; then echo KEY-ENTER; else echo "KEY-$k"; fi; done; echo QUIET; sleep 30"#
    let m = AgentManifest(
        id: "asks2", name: "Asks", command: "/bin/bash", args: ["-c", script, "x"],
        autoAnswers: [AgentManifest.AutoAnswer(pattern: "Press Enter to continue", input: "\r", after: 5)])
    let w = try await world(agents: [m])
    defer { w.d.stop() }
    let wt = try await workspace(w, "typed")
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "asks2"]), as: Session.self)
    func screen() async throws -> String {
        (try await w.c.call("session.read", .obj(["id": .string(s.id)]))).string ?? ""
    }
    // The user comes well within the 5 s the answer waits (not a race with a busy machine).
    #expect(try await waitFor(10) { try await screen().contains("Press Enter") })
    w.c.notify("session.write", .obj(["id": .string(s.id), "base64": .string(Data("x".utf8).base64EncodedString())]))   // the user, at once
    #expect(try await waitFor(15) { try await screen().contains("QUIET") })
    let shown = try await screen()
    #expect(shown.contains("KEY-x") && !shown.contains("KEY-ENTER"), "\(shown)")
}

/// Which projects language servers and formatters may run in is the user's say in Kelp's window: another program on the
/// socket (an agent, a repository's script) can't record it; the window can.
@Test func onlyKelpsWindowTrustsAProjectForLanguageServers() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let set = RPCRequest(
        id: 1, method: "state.set", params: .obj(["key": "lsp.trusted", "value": .array([.string(w.repo.path)])]))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    p.arguments = ["-U", w.root.appendingPathComponent("kelp.sock").path]
    let input = Pipe(), out = Pipe()
    p.standardInput = input
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    try input.fileHandleForWriting.write(contentsOf: Wire.line(set))
    let reply = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
    p.terminate()
    #expect(reply.contains("Only Kelp's window"), "\(reply)")
    #expect(try await w.c.call("state.get", .obj(["prefix": "lsp."]))["lsp.trusted"] == nil)
    // The window (this process) sends it as UIState does: a notification, applied in order.
    w.c.notify("state.set", .obj(["key": "lsp.trusted", "value": .array([.string(w.repo.path)])]))
    #expect(
        try await waitFor(5) {
            try await w.c.call("state.get", .obj(["prefix": "lsp."]))["lsp.trusted"]?.array?.count == 1
        })
}

/// A cloned repository whose HEAD names a branch that reads as an option (refs/heads/--output=<file>) can't make git
/// write that file: Kelp takes no such name as a base or current branch, and the agent-config check that runs at every
/// agent start refuses a base like it rather than handing it to `git diff`.
@Test func aBranchNameThatReadsAsAnOptionNeverReachesGit() async throws {
    let victim = tmp().path + "-victim.txt"
    try "keep me\n".write(toFile: victim, atomically: true, encoding: .utf8)
    let evil = "--output=" + victim
    let origin = try makeRepo()
    let sha = try Git.run(["rev-parse", "HEAD"], cwd: origin).trimmingCharacters(in: .whitespacesAndNewlines)
    try Git.run(["update-ref", "refs/heads/" + evil, sha], cwd: origin)
    try Git.run(["symbolic-ref", "HEAD", "refs/heads/" + evil], cwd: origin)
    let clone = tmp().path
    try Git.run(["clone", "-q", "--", origin, clone], cwd: "/tmp")
    #expect(Git.defaultBranch(repo: clone) != "--output=" + victim && !Git.defaultBranch(repo: clone).hasPrefix("-"))
    #expect(throws: GitError.self) { try Git.currentBranch(clone) }
    #expect(AgentConfig.changed(clone, base: evil, remotes: .none))   // refused: asked, not compared
    let w = try await world()
    defer { w.d.stop() }
    let repo: Repo = try await w.c.call("repo.add", .obj(["path": .string(clone)]), as: Repo.self)
    #expect(!repo.baseBranch.hasPrefix("-"))
    _ = try await w.c.call("worktree.list", as: [Worktree].self)
    #expect(try String(contentsOfFile: victim, encoding: .utf8) == "keep me\n")
}

/// Esc / ⌃C stop a turn also once the agent turned on the kitty keyboard protocol (Claude Code does): the keys arrive as
/// CSI u, and the session stayed "working" after the user stopped it.
@Test func stopKeysAreSeenInKittyKeyboardMode() {
    for k in ["\u{1B}", "\u{03}", "\u{1B}[27u", "\u{1B}[99;5u", "\u{1B}[1089::99;5u"] {
        #expect(LiveSession.isStopKey(Data(k.utf8)), "\(k.debugDescription)")
    }
    for k in ["\u{1B}[A", "\u{1B}[99u", "\u{1B}[199;5u", "\u{1B}[27;2u", "q"] {
        #expect(!LiveSession.isStopKey(Data(k.utf8)), "\(k.debugDescription)")
    }
}

/// An agent whose hooks Kelp couldn't wire (the user set the variable to a folder of their own) has its screen read:
/// it would otherwise sit at idle for good. One whose hooks are wired doesn't.
@Test func unwiredHooksLeaveTheScreenRead() async throws {
    let script = "echo ready; read -r; while :; do echo working on the next step; sleep 0.2; done"
    var own = AgentManifest(
        id: "own", name: "Own", command: "/bin/bash", args: ["-c", script],
        hooks: .pluginDir(env: "KELP_TEST_HOOKS_DIR"))
    own.env = ["KELP_TEST_HOOKS_DIR": tmp().path]
    let wired = AgentManifest(
        id: "wired", name: "Wired", command: "/bin/bash", args: ["-c", script],
        hooks: .pluginDir(env: "KELP_TEST_HOOKS_DIR"))
    let w = try await world(agents: [own, wired])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    var ids: [String: String] = [:]
    // The wired one first: its screen has said as much as the other's by the time that one works.
    for agent in ["wired", "own"] {
        let s: Session = try await w.c.call(
            "session.create", .obj(["worktreeId": .string(wt.id), "agent": .string(agent)]), as: Session.self)
        #expect(
            try await waitFor(10) {
                (try await w.c.call("session.read", .obj(["id": .string(s.id)]))).string?.contains("ready") == true
            })
        w.c.notify(
            "session.write", .obj(["id": .string(s.id), "base64": .string(Data("go\r".utf8).base64EncodedString())]))
        ids[agent] = s.id
    }
    #expect(try await waitFor(10) { w.d.sessions.existing(ids["own"] ?? "")?.snapshot.status == .working })
    #expect(w.d.sessions.existing(ids["wired"] ?? "")?.snapshot.status == .idle)
}
