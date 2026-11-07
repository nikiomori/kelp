import Foundation
import Testing
import Core
@testable import Daemon

// What an agent's program may do (`Daemon.allow`): each test is a session whose script talks to the socket as an agent's
// program would, marked an agent's.

private struct Rig { let d: Daemon, c: RPCClient, repo: Repo, wt: Worktree }
private func rig() async throws -> Rig {
    let w = try await world()
    return Rig(d: w.d, c: w.c, repo: w.repo, wt: try await workspace(w, "feat/x"))
}
private func session(_ r: Rig, _ command: String) async throws -> Session {
    try await r.c.call("session.create", .obj(["worktreeId": .string(r.wt.id), "command": .string(command)]), as: Session.self)
}
private func sessions(_ r: Rig) async throws -> [Session] { try await r.c.call("session.list", as: [Session].self) }

/// A program an agent runs types into, stops and answers for only the sessions that agent started, and never answers an
/// agent's question: one approved `kelp` call doesn't reach every other agent. The user's own terminals, and callers outside
/// every session, drive any.
@Test func anAgentActsOnlyOnTheSessionsItStarted() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let other = try await session(r, "cat")
    let call = #"r() { zsocket $KELP_SOCKET; print -u $REPLY "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"; "#
        + #"read -u $REPLY line; print -r -- "$1 $line"; exec {REPLY}>&-; }"#
    let send = #"r session.send "{\"id\":\"$1\",\"text\":\"hi\",\"enter\":false}""#
    // `kelp attach`: the stream's line, then what it types.
    let attach = #"a() { zsocket $KELP_SOCKET; print -u $REPLY "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.stream\",\"params\":{\"id\":\"$1\"}}"; "#
        + #"print -u $REPLY typed; read -t 3 -u $REPLY line; print -r -- "stream $line"; exec {REPLY}>&-; }"#
    let script = "zmodload zsh/net/socket; \(call); \(attach); s() { \(send); }; read kid; s \(other.id); s $kid; "
        + #"r session.restart "{\"id\":\"\#(other.id)\"}"; a \#(other.id); "#
        + #"r comment.send "{\"id\":\"\#(r.wt.id)\",\"session\":\"\#(other.id)\"}"; "#
        + #"r ui.browser "{\"action\":\"info\",\"worktreeId\":\"elsewhere\"}"; "#
        + #"r comment.add "{\"id\":\"\#(r.wt.id)\",\"file\":\"a.txt\",\"text\":\"x\",\"session\":\"\#(other.id)\"}"; "#
        + #"r session.continueAt "{\"id\":\"\#(other.id)\"}"; r ports.stop "{\"worktreeId\":\"elsewhere\",\"pid\":1}"; "#
        + #"r worktree.remove "{\"id\":\"\#(r.wt.id)\"}"; r repo.remove "{\"id\":\"\#(r.wt.repoId)\"}"; "#
        + #"r session.choose "{\"id\":\"$kid\",\"answer\":\"allow\"}"; cat"#
    let me = try await session(r, "/bin/zsh -c '\(script)'")
    let ls = try #require(r.d.sessions.existing(me.id))
    _ = ls.update { $0.agent = "claude" }
    r.d.sessions.publish(ls)
    #expect(try await waitFor { try r.d.sessions.store.session(me.id)?.agent == "claude" })
    let kid = try await r.c.call("session.create", .obj(["worktreeId": .string(r.wt.id), "command": "cat", "parent": .string(me.id)]), as: Session.self)
    #expect(kid.startedBy == me.id)
    _ = try await r.c.call(SessionWrite(id: me.id, text: kid.id + "\n"))   // this test process is in no session
    #expect(try await waitFor(10) { try await r.c.call(SessionRead(id: me.id)).contains("user's to answer") })
    let out = try await r.c.call(SessionRead(id: me.id))
    #expect(out.contains("acts only on its own session"))
    #expect(out.contains(#/session\.restart [^\n]*acts only on its own session/#))
    #expect(out.contains(#/comment\.send [^\n]*acts only on its own session/#))
    #expect(out.contains(#/comment\.add [^\n]*speaks only for itself/#))   // a comment signed as another agent
    #expect(out.contains(#/session\.continueAt [^\n]*acts only on its own session/#))   // "continue" typed later
    #expect(out.contains(#/ports\.stop [^\n]*only in its own workspace/#))
    // Removing the workspace would end `other`, which this agent didn't start; a project is the user's to remove.
    #expect(out.contains(#/worktree\.remove [^\n]*ends only its own sessions/#) && out.contains(#/repo\.remove [^\n]*Only the user removes a project/#))
    #expect(out.contains(#/ui\.browser [^\n]*only in its own workspace/#))   // another workspace's tabs may carry a login   // comments typed, with Enter, into another agent
    #expect(out.contains(#/stream kelp: An agent acts only/#))
    #expect(try await waitFor { try await r.c.call(SessionRead(id: kid.id)).contains("hi") })
    let seen = try await r.c.call(SessionRead(id: other.id))
    #expect(!seen.contains("hi") && !seen.contains("typed"))
    #expect(try await sessions(r).first { $0.id == other.id }?.status != .exited)   // not restarted
}

/// What an agent starts is its own whatever it sends: the daemon takes the parent from the caller's process, so it can't
/// name another agent as its child's parent (whose reports would reach that agent with Enter), and a session it starts
/// with `--outlive` is still its own (`origin`), not a terminal free of every rule. Any session a call names counts, a read
/// too; and what the app or a routine would start for nobody isn't an agent's to ask for.
@Test func anAgentCantStartSessionsOutsideItsOwnLine() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let other = try await session(r, "cat")
    let away = try await r.c.call(WorktreeCreate(repoId: r.repo.id, branch: "away", setup: false)).worktree
    let call = #"r() { zsocket $KELP_SOCKET; print -u $REPLY "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}"; "#
        + #"read -u $REPLY line; print -r -- "<$1> $line"; exec {REPLY}>&-; }"#
    let wt = r.wt.id, o = other.id
    let script = "zmodload zsh/net/socket; \(call); read go; "
        + #"r parent session.create "{\"worktreeId\":\"\#(wt)\",\"agent\":\"claude\",\"parent\":\"\#(o)\"}"; "#
        + #"r outlive session.create "{\"worktreeId\":\"\#(wt)\",\"command\":\"cat\"}"; "#
        + #"r read session.read "{\"id\":\"\#(o)\"}"; r markRead session.markRead "{\"id\":\"\#(o)\"}"; "#
        + #"r close ui.command "{\"id\":\"editor.closeTab\"}"; r term ui.open "{\"uri\":\"terminal:?cmd=true\"}"; "#
        + #"r new ui.command "{\"id\":\"agents.new\",\"args\":{\"agent\":\"shell\"}}"; r pane ui.command "{\"id\":\"view.nextPane\"}"; "#
        + #"r shot ui.command "{\"id\":\"window.shot\"}"; r fake ui.command "{\"id\":\"view.anExtensions\"}"; "#
        + #"r routine routine.delete "{\"id\":\"x\"}"; r away session.create "{\"worktreeId\":\"\#(away.id)\",\"command\":\"cat\"}";"#
        + #"r archive worktree.archive "{\"id\":\"\#(away.id)\"}"; r forget repo.remove "{\"id\":\"\#(r.repo.id)\"}"; "#
        + #"r clear repo.removeWorktrees "{\"id\":\"\#(r.repo.id)\",\"paths\":[]}"; "#
        + #"r upper ui.open "{\"uri\":\"TERMINAL:?cmd=true\"}"; r peek ui.open "{\"uri\":\"session:\#(o)\"}"; "#
        + #"r look ui.open "{\"uri\":\"file:///tmp\",\"worktreeId\":\"\#(away.id)\"}"; "#
        + #"r phone settings.set "{\"key\":\"phone.url\",\"value\":\"https://x.example\"}"; "#
        + #"r font settings.set "{\"key\":\"editor.fontSize\",\"value\":13}"; "#
        + #"r pull git.remote "{\"id\":\"\#(wt)\",\"op\":\"pull\"}"; r folder settings.set "{\"key\":\"worktrees.folder\",\"value\":\"/tmp\"}"; "#
        + #"r commit git.commit "{\"id\":\"\#(wt)\",\"message\":\"x\"}"; r run run.start "{\"worktreeId\":\"\#(away.id)\",\"id\":\"x\"}"; "#
        + #"r drop worktree.remove "{\"id\":\"\#(wt)\",\"dropCommits\":true}"; cat"#
    let me = try await session(r, "/bin/zsh -c '\(script)'")
    for id in [me.id, other.id] {
        let ls = try #require(r.d.sessions.existing(id))
        _ = ls.update { $0.agent = "claude" }
        r.d.sessions.publish(ls)
        #expect(try await waitFor { try r.d.sessions.store.session(id)?.agent == "claude" })
    }
    _ = try await r.c.call(SessionWrite(id: me.id, text: "go\n"))
    #expect(try await waitFor(10) { try await r.c.call(SessionRead(id: me.id)).contains("<drop>") })
    // A line each: "\r\n" is one Character, which `[^\n]` would match, running one line's check into the next.
    let out = try await r.c.call(SessionRead(id: me.id)).replacingOccurrences(of: "\r\n", with: "\n")
    for refused in ["parent", "read", "markRead"] { #expect(out.contains(try Regex("<\(refused)> [^\n]*acts only on its own session")), "\(refused)") }
    #expect(out.contains(#/<close> [^\n]*is the user's to run/#) && out.contains(#/<term> [^\n]*kelp session new/#))
    #expect(out.contains(#/<new> [^\n]*is the user's to run/#) && !out.contains(#/<pane> [^<]*is the user's to run/#))
    // `kelp shot` from the extensions skill goes through; an extension's command named like a view doesn't.
    #expect(!out.contains(#/<shot> [^<]*is the user's to run/#) && out.contains(#/<fake> [^\n]*is the user's to run/#))
    #expect(out.contains(#/<routine> [^\n]*routine is the user's/#) && out.contains(#/<drop> [^\n]*Only the user removes/#))
    #expect(out.contains(#/<away> [^\n]*works only in its own workspace/#) && out.contains(#/<archive> [^\n]*works only in its own workspace/#))
    #expect(out.contains(#/<forget> [^\n]*Only the user removes a project/#) && out.contains(#/<clear> [^\n]*Only the user clears/#))
    #expect(out.contains(#/<commit> [^\n]*“git\.commit” is the user's/#) && out.contains(#/<run> [^\n]*“run\.start” is the user's/#))
    // The app reads a scheme in any case; a session's tab is its screen; a file in another workspace switches there.
    #expect(out.contains(#/<upper> [^\n]*kelp session new/#) && out.contains(#/<peek> [^\n]*acts only on its own session/#))
    #expect(out.contains(#/<look> [^\n]*works only in its own workspace/#))
    #expect(out.contains(#/<phone> [^\n]*the user's/#) && !out.contains(#/<font> [^<]*error/#))
    #expect(out.contains(#/<pull> [^\n]*pull is the user's/#) && out.contains(#/<folder> [^\n]*the user's to set/#))
    #expect(try !r.d.sessions.works(me.id, in: away.id))
    var made = away; made.madeBy = me.id   // as `worktree.create` from its terminal does: kept in the store, past a restart
    try r.d.sessions.store.save(made)
    #expect(try r.d.sessions.works(me.id, in: away.id))
    #expect(try r.d.sessions.store.sessions().filter { $0.parent == other.id } == [])
    let outlived = try #require(try r.d.sessions.store.sessions().first { $0.id != me.id && $0.origin == me.id })
    #expect(outlived.parent == nil && outlived.startedBy == nil)   // still not its child, nor on its line
    #expect(try r.d.sessions.store.lineage(outlived.id).contains { $0.id == me.id })
}

/// What the daemon runs itself (an extension's command or event, a git hook) answers no question, nor does a program an
/// agent forked away from its tree (it asks only once launchd is its parent): that one still has the agent's terminal.
@Test func kelpdsOwnProgramsAndForkedAwayOnesAnswerNoQuestion() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let other = try await session(r, "cat")
    let call = #"r() { zsocket $KELP_SOCKET; print -u $REPLY "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}"; "#
        + #"read -u $REPLY line; print -r -- "<$1> $line"; exec {REPLY}>&-; }"#
    let choose = #"session.choose "{\"id\":\"\#(other.id)\",\"answer\":\"allow\"}""#
    let ran = try await r.c.call(ProcessRun(argv: ["/bin/zsh", "-c", "zmodload zsh/net/socket; \(call); r kelpd \(choose)"],
                                            cwd: nil, stdin: nil, timeLimit: 20, extensionId: nil))
    #expect(ran.stdout.contains(#/<kelpd> [^\n]*has no session to act for/#), "\(ran.stdout) \(ran.stderr)")
    let me = try await session(r, "/bin/zsh -c 'zmodload zsh/net/socket zsh/system; \(call); read go; ( { until (( sysparams[ppid] == 1 )); do sleep 0.05; done; r forked \(choose); } & ); cat'")
    let ls = try #require(r.d.sessions.existing(me.id))
    _ = ls.update { $0.agent = "claude" }
    r.d.sessions.publish(ls)
    #expect(try await waitFor { try r.d.sessions.store.session(me.id)?.agent == "claude" })
    _ = try await r.c.call(SessionWrite(id: me.id, text: "go\n"))
    #expect(try await waitFor(10) { try await r.c.call(SessionRead(id: me.id)).contains("<forked>") })
    #expect(try await r.c.call(SessionRead(id: me.id)).replacingOccurrences(of: "\r\n", with: "\n").contains(#/<forked> [^\n]*the user's to answer/#))
}

/// What agents may call is a list of methods the daemon answers (a stale name would hide a renamed method's door).
@Test func theAgentsListNamesMethodsThatExist() {
    #expect(AgentRules.methods.subtracting(Daemon.methods.keys) == [])
}

/// The sessions a call names are found wherever they sit in its params (a struct, a list of them, an optional), and
/// free-form JSON in it names none.
@Test func aSessionNamedDeepInACallIsFound() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await session(r, "cat"), t = try await session(r, "cat")
    struct Inner { var session: String?; var count = 3 }
    struct Call { var top = "x"; var inner: [Inner]; var args: JSONValue }
    let found = try r.d.sessions.named(by: Call(inner: [Inner(session: s.id)], args: .obj(["id": .string(t.id)])))
    #expect(found == [s.id])
    #expect(throws: RPCError.self) { try r.d.sessions.named(by: [[[[[[[[s.id]]]]]]]]) }   // too deep to tell: refused
}

/// An agent's program types no key into an agent that asks a question, its own included: "1⏎" would approve it.
@Test func anAgentDoesntTypeIntoAQuestion() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let call = #"r() { zsocket $KELP_SOCKET; print -u $REPLY "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}"; "#
        + #"read -u $REPLY line; print -r -- "<$1> $line"; exec {REPLY}>&-; }"#
    let write = #"r write session.write "{\"id\":\"$KELP_SESSION\",\"base64\":\"MQ0=\"}""#
    let go = r.wt.path + "/go"   // not typed: a key from the user would end the question
    let me = try await session(r, "/bin/zsh -c 'zmodload zsh/net/socket; \(call); until [[ -e \(go) ]]; do sleep 0.1; done; \(write); cat'")
    let ls = try #require(r.d.sessions.existing(me.id))
    _ = ls.update { $0.agent = "claude" }
    r.d.sessions.publish(ls)
    #expect(try await waitFor { try r.d.sessions.store.session(me.id)?.agent == "claude" })
    _ = try await r.c.call(SessionReport(id: me.id, state: "blocked", message: "Allow rm?"))   // as its hook says: it stands
    #expect(try await waitFor { try r.d.sessions.store.session(me.id)?.status == .waiting })
    FileManager.default.createFile(atPath: go, contents: nil)
    #expect(try await waitFor(10) { try await r.c.call(SessionRead(id: me.id)).contains("<write>") })
    #expect(try await r.c.call(SessionRead(id: me.id)).replacingOccurrences(of: "\r\n", with: "\n").contains(#/<write> [^\n]*asks a question/#))
}

/// A restart keeps what an agent started its own (its commands, what came from its terminal); a session whose line
/// breaks off (the one it came from is gone) is held to an agent's rules.
@Test func aRestartedAgentKeepsWhatItStarted() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let a = try await session(r, "cat"), cmd = try await session(r, "cat"), term = try await session(r, "cat")
    func set(_ id: String, _ f: @escaping @Sendable (inout Session) -> Void) throws {
        let ls = try #require(r.d.sessions.existing(id))
        _ = ls.update(f)
        r.d.sessions.publish(ls)
    }
    try set(cmd.id) { [a] in $0.startedBy = a.id }
    try set(term.id) { [a] in $0.origin = a.id }
    #expect(try await waitFor { try r.d.sessions.store.session(term.id)?.origin == a.id && r.d.sessions.store.session(cmd.id)?.startedBy == a.id })
    let a2: Session = try await r.c.call("session.restart", .obj(["id": .string(a.id)]), as: Session.self)
    #expect(try await waitFor { try r.d.sessions.store.session(cmd.id)?.startedBy == a2.id })
    #expect(try await waitFor { try r.d.sessions.store.session(term.id)?.origin == a2.id })
    #expect(try r.d.sessions.store.lineage(term.id).map(\.id) == [term.id, a2.id])
    #expect(try !r.d.sessions.store.forAnAgent(term.id))
    try set(term.id) { $0.origin = UUID().uuidString }
    #expect(try await waitFor { try r.d.sessions.store.forAnAgent(term.id) })
}

/// A program gone before it was looked at (it connected and ended, a child keeping the connection) isn't taken for the
/// user: `unknown`, held to an agent's rules but for a status report. The daemon's own process is the user's.
@Test func aProgramGoneBeforeItsLookedAtIsNoUser() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run(); p.waitUntilExit()
    #expect(r.d.sessions.callers.session(running: p.processIdentifier) == .unknown)
    #expect(r.d.sessions.callers.session(running: getpid()) == .user)
}

/// One Kelp couldn't place (gone as it connected, its connection handed on) speaks for no session: no report, no
/// hook, no wait on a question. A hook waiting for its answer is found as it connects, so it's never this.
@Test func aCallerKelpCantPlaceSpeaksForNoSession() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let other = try await session(r, "cat")
    for id in 0..<64 { r.d.clients.connection(id)?.owner.withLock { $0 = .unknown } }
    await #expect(throws: (any Error).self) { _ = try await r.c.call(SessionHook(id: other.id, event: "done", at: ProcessInfo.processInfo.systemUptime)) }
    await #expect(throws: (any Error).self) { _ = try await r.c.call(SessionReport(id: other.id, state: "error", message: "do this")) }
    #expect(r.d.sessions.existing(other.id)?.snapshot.summary != "do this")
    await #expect(throws: (any Error).self) { _ = try await r.c.call(SessionPermissionWait(id: other.id), timeout: 5) }   // refused at once, not after a wait
}

/// Who may do what by `Caller`, asked of `allow` itself (no terminal in between): one with no session of its own reports
/// for none and is held to an agent's rules; the user isn't.
@Test func whatEachKindOfCallerMayDo() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let other = try await session(r, "cat")
    let phone = SettingsSet(key: "phone.url", value: .string("https://x.example")), font = SettingsSet(key: "editor.fontSize", value: .int(13))
    for c in [Caller.kelpd, .unknown, .detached] {
        #expect(throws: (any Error).self, "\(c)") { try r.d.allow(phone, conn: 0, caller: c) }
        #expect(throws: (any Error).self, "\(c)") { try r.d.allow(SessionKill(id: other.id), conn: 0, caller: c) }
        #expect(throws: Never.self, "\(c)") { try r.d.allow(font, conn: 0, caller: c) }
    }
    #expect(throws: (any Error).self) { try r.d.allow(SessionReport(id: other.id, state: "done"), conn: 0, caller: .detached) }
    #expect(throws: (any Error).self) { try r.d.allow(SessionReport(id: other.id, state: "done"), conn: 0, caller: .unknown) }
    #expect(throws: Never.self) { try r.d.allow(SessionReport(id: other.id, state: "done"), conn: 0, caller: .session(other.id)) }
    #expect(throws: Never.self) { try r.d.allow(phone, conn: 0, caller: .user) }
    #expect(throws: Never.self) { try r.d.allow(SessionKill(id: other.id), conn: 0, caller: .user) }
}

/// A program that forked away from its parent and its terminal (a double fork with `setsid`, what an agent does to pass
/// for the user) is `detached`: held to an agent's rules, not the user's.
@Test func aProgramForkedAwayFromItsTerminalIsNoUser() async throws {
    let r = try await rig(); defer { r.d.stop() }
    r.d.sessions.callers.strict.withLock { $0 = true }   // as a kelpd leading its own process session is
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("detached-\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: out) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = ["-MPOSIX", "-e", "fork && exit; setsid; fork && exit; open(F, '>', $ARGV[0]); print F $$; close F; sleep 10", out.path]
    try p.run(); p.waitUntilExit()
    #expect(try await waitFor(5) { (try? String(contentsOf: out, encoding: .utf8)).flatMap { Int32($0) } != nil })
    let pid = try #require(Int32(String(contentsOf: out, encoding: .utf8)))
    defer { kill(pid, SIGTERM) }
    #expect(try await waitFor(5) { Subprocess.parent(pid) == 1 })
    #expect(r.d.sessions.callers.session(running: pid) == .detached)
}

/// A program in a tmux pane is whoever is attached to that tmux session: nobody, and it's no user (what `tmux new -d`
/// from an agent gives). A session of the default server's, named for this test, and ended by it.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tmux")))
func aTmuxPaneNobodysAttachedToIsNoUser() async throws {
    let r = try await rig(); defer { r.d.stop() }
    r.d.sessions.callers.strict.withLock { $0 = true }
    let tmux = try LoginPath.resolve("tmux"), name = "kelp-probe-\(UUID().uuidString.prefix(6))", env = ["PATH": "/usr/bin:/bin"]
    _ = try await Subprocess.run([tmux, "new-session", "-d", "-s", name, "sleep 30"], cwd: "/", env: env, timeLimit: 5)
    let out = try await Subprocess.run([tmux, "list-panes", "-t", "=" + name, "-F", "#{pane_pid}"], cwd: "/", env: env, timeLimit: 5)
    let pid = pid_t(String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(pid.map { r.d.sessions.callers.session(running: $0) } == .detached)
    _ = try await Subprocess.run([tmux, "kill-session", "-t", "=" + name], cwd: "/", env: env, timeLimit: 5)
}

/// What makes a caller the user's: an ancestor of another account (root's `login`, `sshd`), which an agent can't start,
/// or an app's program; not one of the user's own plain programs, nor Kelp's own (`kelp` sits in Kelp's bundle).
@Test func whatCameFromTheUsersLoginTellsTheUser() throws {
    let root = try Subprocess.run(["/usr/bin/pgrep", "-U", "0", "-x", "syslogd"], cwd: "/", env: [:], timeLimit: 5)
    let pid = try #require(pid_t(String(decoding: root.stdout, as: UTF8.self).split(separator: "\n").first ?? ""))
    #expect(Callers.cameFromTheUser(pid))   // another account's
    let plain = Process()
    plain.executableURL = URL(fileURLWithPath: "/bin/sleep")
    plain.arguments = ["5"]
    try plain.run()
    defer { plain.terminate() }
    #expect(!Callers.cameFromTheUser(plain.processIdentifier))   // the user's own plain program
}

/// A program that forked away and is itself in a bundle (as `kelp` is, in Kelp.app) is no app the user started: only
/// what it came from counts.
@Test func aForkedAwayProgramInABundleIsNoUser() async throws {
    let r = try await rig(); defer { r.d.stop() }
    r.d.sessions.callers.strict.withLock { $0 = true }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString.prefix(6))")
    let bin = dir.appendingPathComponent("Fake.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // A program of its own (a copy of a system one is killed outside the system's folders): it waits, then ends.
    let c = dir.appendingPathComponent("wait.c")
    try "#include <unistd.h>\nint main(void) { sleep(10); return 0; }\n".write(to: c, atomically: true, encoding: .utf8)
    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    cc.arguments = ["-o", bin.appendingPathComponent("sleep").path, c.path]
    try cc.run(); cc.waitUntilExit()
    try #require(cc.terminationStatus == 0)
    let out = dir.appendingPathComponent("pid")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = ["-MPOSIX", "-e", "fork && exit; setsid; fork && exit; open(F, '>', $ARGV[0]); print F $$; close F; exec $ARGV[1]",
                   out.path, bin.appendingPathComponent("sleep").path]
    try p.run(); p.waitUntilExit()
    #expect(try await waitFor(5) { (try? String(contentsOf: out, encoding: .utf8)).flatMap { Int32($0) } != nil })
    let pid = try #require(Int32(String(contentsOf: out, encoding: .utf8)))
    defer { kill(pid, SIGTERM) }
    #expect(try await waitFor(5) { Unix.executable(pid)?.contains(".app/Contents/MacOS/") == true })
    #expect(r.d.sessions.callers.session(running: pid) == .detached)
}

/// A tmux pane's caller from who's attached: a Kelp terminal's session outweighs the user's own client; the user's
/// counts for the pane they're shown only; nobody attached is nobody's.
@Test func aTmuxPanesCallerIsWhoIsAttached() {
    #expect(Callers.tmuxDecision([.user, .session("A")], shown: true) == .session("A"))
    #expect(Callers.tmuxDecision([.session("T")], shown: false) == nil)   // the user's terminal: the shown pane only
    #expect(Callers.tmuxDecision([.session("T"), .session("A")], shown: false) { $0 == "A" } == .session("A"))   // an agent's: any
    #expect(Callers.tmuxDecision([.session("T")], shown: false, underAgent: true) == .session("T"))   // a typed agent there, shown or not
    #expect(Callers.tmuxDecision([.user, .typedAgent("T")], shown: true) == .typedAgent("T"))   // a typed agent attached outweighs the user
    #expect(Callers.tmuxDecision([.user], shown: true) == .user)
    #expect(Callers.tmuxDecision([.user], shown: false) == nil)
    #expect(Callers.tmuxDecision([], shown: true) == nil)
    #expect(Callers.tmuxSocket(["tmux", "-L", "work", "new", "-s", "x"]) == ["-L", "work"])
    #expect(Callers.tmuxSocket(["tmux", "new"]) == [])
}

/// A process's own arguments, read back as it was started (what a tmux server's socket is told by).
@Test func aProcessesArgumentsAreReadBack() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["7"]
    try p.run()
    defer { p.terminate() }
    #expect(Subprocess.arguments(p.processIdentifier) == ["/bin/sleep", "7"])
}

/// The socket a tmux server was started on is read from tmux's own options only: not from its command's.
@Test func aTmuxServersSocketIsReadFromItsOwnOptions() {
    #expect(Callers.tmuxSocket(["tmux", "-Lwork", "new"]) == ["-L", "work"])
    #expect(Callers.tmuxSocket(["tmux", "-u", "-S", "/tmp/s", "new"]) == ["-S", "/tmp/s"])
    #expect(Callers.tmuxSocket(["tmux", "-f", "/x.conf", "-L", "a", "new"]) == ["-L", "a"])
    #expect(Callers.tmuxSocket(["tmux", "new", "-s", "x", "ssh", "-L", "8080:h:80", "host"]) == [])
}

/// A program run under an agent the user typed into a plain terminal by hand is that agent's, held to its rules as
/// that terminal's: by the name the agent was run as, or the script its interpreter runs (`node …/codex`). The shell's
/// own programs beside it stay the user's.
@Test func anAgentTypedIntoAPlainTerminalIsHeldToItsRules() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ta-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let codex = dir.appendingPathComponent("codex"), out = dir.appendingPathComponent("pids")
    // `claude` and `python3`: a shell by those names (a link's name is the name it runs as), and `codex` a script it runs.
    for name in ["claude", "python3"] { try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent(name).path, withDestinationPath: "/bin/zsh") }
    try "sleep 30 & echo $! >> \(out.path); wait\n".write(to: codex, atomically: true, encoding: .utf8)
    let script = "\(dir.path)/claude -c 'sleep 30 & echo \\$! >> \(out.path); wait' & "
        + "\(dir.path)/python3 \(codex.path) & "
        + "sleep 30 & echo \\$! >> \(out.path); wait"
    let term = try await session(r, "exec /bin/zsh -c \"\(script)\"")
    #expect(try await waitFor(10) { (try? String(contentsOf: out, encoding: .utf8))?.split(separator: "\n").count == 3 })
    let pids = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").compactMap { pid_t($0) }
    let seen = pids.map { r.d.sessions.callers.session(running: $0) }
    #expect(seen.filter { $0 == .typedAgent(term.id) }.count == 2, "\(seen)")
    #expect(seen.contains(.session(term.id)), "\(seen)")   // the shell's own
}

/// What an agent typed into a terminal by hand starts is held to its rules too, and stays that agent's to drive: its
/// line goes on to the terminal it was typed into.
@Test func whatATypedAgentStartsIsHeldToItsRules() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let term = try await session(r, "cat")
    var started = Session(worktreeId: r.wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    started.origin = Caller.typedAgent(term.id).origin
    try r.d.sessions.store.save(started)
    #expect(try !r.d.sessions.store.forAnAgent(term.id))   // the terminal itself: the user's, but for what runs under the agent
    #expect(try r.d.sessions.store.forAnAgent(started.id))
    #expect(try r.d.sessions.store.lineage(started.id).contains { $0.id == term.id })
    #expect(throws: Never.self) { try r.d.allow(SessionKill(id: started.id), conn: 0, caller: .typedAgent(term.id)) }
    // What the user started from that terminal themselves isn't the agent's.
    var theirs = Session(worktreeId: r.wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    theirs.origin = term.id
    try r.d.sessions.store.save(theirs)
    #expect(throws: (any Error).self) { try r.d.allow(SessionKill(id: theirs.id), conn: 0, caller: .typedAgent(term.id)) }
}

/// A job left behind in a terminal (`&`, its line cut at launchd, the terminal still its) is held to an agent's rules
/// as that terminal's typed agent: who left it, the user or an agent typed in and gone since, can't be told. And a typed
/// agent doesn't type into its own terminal (its own question would be answered so).
@Test func aJobLeftInATerminalIsHeldToAnAgentsRules() async throws {
    let r = try await rig(); defer { r.d.stop() }
    r.d.sessions.callers.strict.withLock { $0 = true }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tj-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("pid")
    let term = try await session(r, "exec /bin/zsh -f -i")
    _ = try await r.c.call(SessionWrite(id: term.id, text: "(sleep 30 & echo $! > \(out.path))\n"))
    #expect(try await waitFor(10) { (try? String(contentsOf: out, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } != nil })
    let job = try #require(pid_t(String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(job, SIGTERM) }
    #expect(try await waitFor(5) { Subprocess.parent(job) == 1 })
    #expect(r.d.sessions.callers.session(running: job) == .typedAgent(term.id))
    #expect(throws: (any Error).self) { try r.d.allow(SessionWrite(id: term.id, text: "1\r"), conn: 0, caller: .typedAgent(term.id)) }
    #expect(throws: Never.self) { try r.d.allow(SessionWrite(id: term.id, text: "1\r"), conn: 0, caller: .session(term.id)) }
}

/// Who may do what, as one table (the model `Daemon.allow` keeps): the user drives anything; a terminal of the user's
/// is the user; an agent typed into it may name it (a child's parent, its own reports, reading it) but neither types into
/// it nor acts on it, and reaches only what it started there, not what the user started from it; a caller with no
/// session of its own (detached, kelpd's, unknown) is held to an agent's rules and speaks for none.
@Test func whoMayDoWhat() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let term = try await session(r, "cat")   // the user's terminal
    var mine = Session(worktreeId: r.wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])   // what an agent typed into it started
    mine.origin = Caller.typedAgent(term.id).origin
    var theirs = Session(worktreeId: r.wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])   // what the user started from it
    theirs.origin = term.id
    try r.d.sessions.store.save(mine)
    try r.d.sessions.store.save(theirs)
    let phone = SettingsSet(key: "phone.url", value: .string("https://x.example")), font = SettingsSet(key: "editor.fontSize", value: .int(13))
    let child = SessionCreate(worktreeId: r.wt.id, command: "cat", parent: term.id)
    var made = Worktree(repoId: r.repo.id, branch: "made", path: "/tmp/made"), userMade = Worktree(repoId: r.repo.id, branch: "um", path: "/tmp/um")
    made.madeBy = Caller.typedAgent(term.id).origin   // a workspace the typed agent made
    userMade.madeBy = term.id   // one the user made from that terminal
    try r.d.sessions.store.save(made)
    try r.d.sessions.store.save(userMade)
    let elsewhere = Worktree(repoId: r.repo.id, branch: "o", path: "/tmp/o")   // nobody's of theirs
    try r.d.sessions.store.save(elsewhere)
    let otherProject = Repo(name: "o", path: "/tmp/other-project")   // a project of the user's it doesn't work in
    try r.d.sessions.store.save(otherProject)
    try r.d.sessions.store.save(Worktree(repoId: otherProject.id, branch: "main", path: "/tmp/other-project"))
    let typed = Caller.typedAgent(term.id)
    // The workspaces a call names are found in any field, as its sessions are: no method has to remember to say.
    #expect(try r.d.sessions.workspaces(namedBy: SessionCreate(worktreeId: elsewhere.id, command: "cat", parent: mine.id)) == [elsewhere.id])
    #expect(AgentRules.reads.contains(GitStatus.name) && !AgentRules.reads.contains(WorktreeNote.name))
    // Who counts as an agent's in a tmux pane is who `allow` holds to an agent's rules: the same table.
    #expect(!r.d.sessions.callers.heldAsAgent(term.id) && !r.d.sessions.callers.heldAsAgent(theirs.id))
    #expect(r.d.sessions.callers.heldAsAgent(mine.id))
    let table: [(Caller, any Answered, Bool, String)] = [
        (.user, SessionKill(id: term.id), true, "the user ends any"),
        (.user, phone, true, "the user sets their own settings"),
        (.session(term.id), SessionWrite(id: theirs.id, text: "x"), true, "the user's terminal is the user"),
        (.session(term.id), phone, true, "the user's terminal sets the user's settings"),
        (typed, child, true, "a typed agent starts a session from its terminal"),
        (typed, SessionReport(id: term.id, state: "working"), true, "a typed agent reports for its terminal"),
        (typed, SessionRead(id: term.id), true, "a typed agent reads its terminal"),
        (typed, UIOpen(uri: "session:" + term.id), true, "and opens its tab"),
        (typed, UIOpen(uri: "session:" + theirs.id), false, "not another's the user started"),
        (typed, SessionTurnUndo(id: mine.id, turn: "t"), false, "nor undoes a turn (the user's edits since go too)"),
        (typed, SessionWrite(id: term.id, text: "1\r"), false, "a typed agent doesn't type into its terminal"),
        (typed, SessionSend(id: term.id, text: "1"), false, "nor send into it"),
        (typed, SessionKill(id: term.id), false, "nor end it"),
        (typed, SessionWrite(id: mine.id, text: "x"), true, "a typed agent drives what it started"),
        (typed, SessionKill(id: theirs.id), false, "not what the user started from that terminal"),
        (typed, phone, false, "nor the user's settings"),
        (typed, CommentAdd(id: r.wt.id, file: "a", start: 1, end: 1, quote: nil, text: "x"), false, "a comment of no session would read as the user's"),
        (.detached, CommentAdd(id: r.wt.id, file: "a", start: 1, end: 1, quote: nil, text: "x"), false, "from nowhere, the same"),
        (.user, CommentAdd(id: r.wt.id, file: "a", start: 1, end: 1, quote: nil, text: "x"), true, "the window's is the user's"),
        (.session(mine.id), CommentAdd(id: r.wt.id, file: "a", text: "x", session: mine.id), true, "an agent's own, signed, in its workspace"),
        (.session(mine.id), CommentAdd(id: elsewhere.id, file: "a", text: "x", session: mine.id), false, "not in another's"),
        (.session(mine.id), CommentSend(id: r.wt.id, session: term.id), false, "nor sent to a session it didn't start"),
        (typed, SessionRename(id: term.id, title: "x"), false, "nor rename the user's terminal"),
        (typed, font, true, "a look it may set"),
        (typed, WorktreeNote(id: made.id, note: "x"), true, "a typed agent works in a workspace it made"),
        (typed, WorktreeNote(id: userMade.id, note: "x"), false, "not in one the user made from its terminal"),
        (.session(mine.id), WorktreeNote(id: elsewhere.id, note: "x"), false, "what acts is held to its own workspaces"),
        (.session(mine.id), GitStatus(id: elsewhere.id), true, "what only reads may look at any"),
        (.session(mine.id), WorktreeCreate(repoId: r.repo.id, branch: "n"), true, "a workspace in its own project"),
        (.session(mine.id), WorktreeCreate(repoId: otherProject.id, branch: "n"), false, "not in another project"),
        (.session(mine.id), WorkspaceCreate(repoId: otherProject.id), false, "nor a group there"),
        (.session(mine.id), WorkspaceCreate(repoId: r.repo.id), true, "a group in its own"),
        (.detached, WorktreeCreate(repoId: r.repo.id, branch: "n"), false, "what works in no workspace makes none (a git hook, a launchd job)"),
        (.detached, font, true, "a detached caller is held to an agent's rules: a look it may set"),
        (.detached, phone, false, "the user's settings it may not"),
        (.detached, SessionKill(id: term.id), false, "nor end the user's terminal"),
        (.kelpd, SessionReport(id: term.id, state: "done"), false, "kelpd's program speaks for no session"),
        (.unknown, SessionReport(id: term.id, state: "done"), false, "nor does one gone as it connected")
    ]
    for (caller, m, allowed, why) in table {
        // A refusal is the rules' (`RPCError.refused`), not any error: a missing record or a store's would pass for one.
        var refused = false
        do { try r.d.allow(m, conn: 0, caller: caller) } catch let e as RPCError where e.isRefusal { refused = true } catch {
            Issue.record("\(why): not a refusal but \(error)")
        }
        #expect(refused != allowed, "\(why): \(caller), \(type(of: m).name)")
    }
}

/// `kelp attach` from an agent's program types where `session send` may, key by key: a session it started that asks a
/// question meanwhile gets none of it (a `(sleep 60; printf 1) | kelp attach` would answer it), and the attach ends.
@Test func anAgentsAttachStopsTypingOnceTheSessionAsks() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let attach = #"zsocket $KELP_SOCKET; print -u $REPLY "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.stream\",\"params\":{\"id\":\"$kid\"}}"; "#
        + #"print -u $REPLY first; read go; print -u $REPLY second; while read -t 1 -u $REPLY line; do print -r -- "stream $line"; done; "#
        + #"read more; trap "" PIPE; print -u $REPLY $more 2>/dev/null; print sent; cat"#
    let me = try await session(r, "/bin/zsh -c 'zmodload zsh/net/socket; read kid; \(attach)'")
    let ls = try #require(r.d.sessions.existing(me.id))
    _ = ls.update { $0.agent = "claude" }
    r.d.sessions.publish(ls)
    #expect(try await waitFor { try r.d.sessions.store.session(me.id)?.agent == "claude" })
    let kid = try await r.c.call("session.create", .obj(["worktreeId": .string(r.wt.id), "command": "cat", "parent": .string(me.id)]), as: Session.self)
    _ = try await r.c.call(SessionWrite(id: me.id, text: kid.id + "\n"))
    #expect(try await waitFor(10) { try await r.c.call(SessionRead(id: kid.id)).contains("first") })   // its own child: typed
    let child = try #require(r.d.sessions.existing(kid.id))
    _ = child.update { $0.status = .waiting }
    _ = try await r.c.call(SessionWrite(id: me.id, text: "go\n"))
    #expect(try await waitFor(10) { try await r.c.call(SessionRead(id: me.id)).contains("stream kelp: That session asks a question") })
    #expect(try await !r.c.call(SessionRead(id: kid.id)).contains("second"))
    // The attach is over: what it would type after the answer doesn't join what it typed before.
    _ = child.update { $0.status = .working }
    _ = try await r.c.call(SessionWrite(id: me.id, text: "third\n"))
    #expect(try await waitFor(10) { try await r.c.call(SessionRead(id: me.id)).contains("sent") })   // it tried
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(try await !r.c.call(SessionRead(id: kid.id)).contains("third"))
}

/// A question on screen that no hook said ("trust this folder?", a numbered menu) is one too: an agent's keys don't go
/// into it, whatever its status says. Trusting a folder turns its hooks and servers on: the user's answer.
@Test func anAgentDoesntTypeIntoAMenuOnScreen() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let menu = try await session(r, "/bin/sh -c 'printf \"Do you trust this folder?\\r\\n\\xe2\\x9d\\xaf 1. Yes, proceed\\r\\n  2. No, exit\\r\\n\"; cat'")
    #expect(try await waitFor(10) { try r.d.sessions.existing(menu.id)?.asksSomething == true })
    #expect(try r.d.sessions.existing(menu.id)?.snapshot.status != .waiting)   // asked by no hook
    var refusal = ""
    do { try r.d.allow(SessionWrite(id: menu.id, text: "\r"), conn: 0, caller: .detached) } catch let e as RPCError where e.isRefusal {
        refusal = e.message
    }
    #expect(refusal.contains("asks a question"))
    // Nor sent, by any door: a send's Enter would answer it too (review comments are a send).
    for m in [SessionSend(id: menu.id, text: "go"), CommentSend(id: r.wt.id, session: menu.id)] as [any Answered] {
        refusal = ""
        do { try r.d.allow(m, conn: 0, caller: .detached) } catch let e as RPCError where e.isRefusal { refusal = e.message }
        #expect(refusal.contains("asks a question"), "\(type(of: m).name)")
    }
}
