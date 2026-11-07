import Agents
import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

// Projects, history and agents' own folders: kept apart from DaemonTests.swift by size.

/// The Run menu's commands come from .kelp.yaml and run only after Trust; editing the file asks again.
@Test func projectScriptsNeedTrust() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let path = try makeRepo()
    try "test: touch TESTED\nscript.hello: echo hi\n".write(
        toFile: path + "/.kelp.yaml", atomically: true, encoding: .utf8)
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(path)]), as: Repo.self)
    let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    let id = JSONValue.obj(["worktreeId": .string(w.id)])
    let list = try await c.call("scripts.list", id)
    #expect(
        list["trusted"]?.bool == false
            && list["scripts"]?.array?.compactMap { $0["name"]?.string } == ["test", "hello"])
    await #expect(throws: (any Error).self) {
        try await c.call("scripts.run", .obj(["worktreeId": .string(w.id), "name": "test"]))
    }
    _ = try await trustAsShown(c, id["worktreeId"] ?? .null)
    _ = try await c.call("scripts.run", .obj(["worktreeId": .string(w.id), "name": "test"]))
    #expect(try await waitFor { FileManager.default.fileExists(atPath: w.path + "/TESTED") })
    try "test: false\n".write(toFile: path + "/.kelp.yaml", atomically: true, encoding: .utf8)
    #expect(try await c.call("scripts.list", id)["trusted"]?.bool == false)
}

@Test func namingFromPrompt() {
    #expect(Naming.slug("Add a dark-mode toggle to the Settings screen!") == "add-dark-mode-toggle-settings")
    #expect(Naming.title("short") == "Short")
    #expect(
        Naming.title("посмотри ресерч http://localhost:8765/p и предложи как улучшить подсказки")
            == "Посмотри ресерч и предложи как…")
}

/// A project on another machine: git, the file list, a file and a session all happen "there" (an ssh stand-in that
/// runs the command locally), while Kelp keeps only a placeholder folder.
@Test func remoteProjectOverSSH() async throws {
    _ = localSSH
    let (d, c, root) = try daemon()
    defer { d.stop() }
    #expect(d.remotes.ssh == localSSH)
    let there = try makeRepo()
    try "changed\n".write(toFile: there + "/a.txt", atomically: true, encoding: .utf8)
    // The folder browser: the repository is listed and marked; a missing folder says so.
    let listed = try await c.call(RemoteListFolders(host: "box", path: (there as NSString).deletingLastPathComponent))
    #expect(listed.folders.contains(.init(name: (there as NSString).lastPathComponent, git: true)) && !listed.repo)
    #expect(try await c.call(RemoteListFolders(host: "box", path: there)).repo)
    await #expect(throws: (any Error).self) { try await c.call(RemoteListFolders(host: "box", path: "/nope/nothing")) }
    // A folder that isn't a repository opens only with init, which makes it one.
    let loose = tmp().path
    try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: loose + "/a.txt", contents: Data())
    await #expect(throws: (any Error).self) {
        try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(loose)]))
    }
    _ = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(loose), "init": true]))
    #expect(FileManager.default.fileExists(atPath: loose + "/.git"))
    let repo: Repo = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(there)]), as: Repo.self)
    #expect(
        repo.path.hasPrefix(root.path + "/remote/box/") && !FileManager.default.fileExists(atPath: repo.path + "/a.txt")
    )
    let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    let status = try await c.call("git.status", .obj(["id": .string(w.id)]), as: [FileChange].self)
    #expect(status.map(\.path) == ["a.txt"])
    // An untracked file there shows with its text (read on the host, not from the marker folder here).
    try "brand new\n".write(toFile: there + "/new.txt", atomically: true, encoding: .utf8)
    let diffs = try await c.call("git.diff", .obj(["id": .string(w.id), "source": "unstaged"]), as: [FileDiff].self)
    #expect(diffs.first { $0.path == "new.txt" }?.hunks.first?.lines.map(\.text) == ["brand new"])
    try FileManager.default.removeItem(atPath: there + "/new.txt")
    // A path that climbs out of the project's folder isn't read on the host.
    try "outside\n".write(
        toFile: (there as NSString).deletingLastPathComponent + "/outside.txt", atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) {
        _ = try await c.call("files.readRemote", .obj(["path": .string(repo.path + "/../outside.txt")]))
    }
    // gh / glab would run in the local marker folder (and its git walk up to ~): refused, said plainly.
    do {
        _ = try await c.call("github.prs", .obj(["worktreeId": .string(w.id)]))
        Issue.record("ran gh for a remote project")
    } catch { #expect("\(error)".contains("remote projects")) }
    #expect(try await c.call("github.branchPR", .obj(["worktreeId": .string(w.id)])) == .null)
    #expect(try await c.call("files.list", .obj(["id": .string(w.id)]), as: [String].self).contains("a.txt"))
    #expect(try await c.call("files.readRemote", .obj(["path": .string(repo.path + "/a.txt")])).string == "changed\n")
    // Saving writes it there; an edit there since it was read comes back instead, and nothing is written over it.
    let save = { (text: String, base: String) in
        try await c.call(
            "files.writeRemote",
            .obj(["path": .string(repo.path + "/a.txt"), "text": .string(text), "base": .string(base)]))
    }
    #expect(try await save("mine\n", "changed\n") == .null)
    #expect(try String(contentsOfFile: there + "/a.txt", encoding: .utf8) == "mine\n")
    #expect(try await save("again\n", "changed\n") == .obj(["changed": "mine\n"]))
    #expect(try String(contentsOfFile: there + "/a.txt", encoding: .utf8) == "mine\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: there).allSatisfy { !$0.contains(".kelp-") })
    try "changed\n".write(toFile: there + "/a.txt", atomically: true, encoding: .utf8)
    // Adding it again is the same project; a folder that isn't there says so.
    #expect(
        try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(there)]), as: Repo.self).id == repo.id)
    await #expect(throws: (any Error).self) {
        try await c.call("repo.addRemote", .obj(["host": "box", "path": "/nope/nothing"]))
    }

    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": "pwd -P"]), as: Session.self)
    let real = URL(fileURLWithPath: there).resolvingSymlinksInPath().path
    #expect(
        try await waitFor(10) {
            (try await c.call("session.read", .obj(["id": .string(s.id)])).string ?? "").contains(real)
        })
    // A command line runs in sh on the host, not in this Mac's zsh; cwd (the project's folder) picks the host for another workspace's tab.
    let ssh = try d.sessions.setup.launchArgv(
        ["/bin/zsh", "-lc", "claude update"], cwd: repo.path, manifest: .custom("claude update"))
    #expect(ssh.last?.hasSuffix(IDE.shellWord("'sh' '-c' 'claude update'")) == true)
    let other: Session = try await c.call(
        "session.create", .obj(["cwd": .string(repo.path), "command": "pwd -P"]), as: Session.self)
    #expect(
        try await waitFor(10) {
            (try await c.call("session.read", .obj(["id": .string(other.id)])).string ?? "").contains(real)
        })
}

/// A finished turn moves the agent's plan read up to half a minute away; it never puts a sooner one off.
@Test func turnEndBringsPlanReadForward() throws {
    let d = try Daemon(root: tmp())
    let every = try #require(AgentUsage.planProbes.first { $0.agent == "claude" }).every
    d.agentUsage.plans.withLock { $0["claude"] = .init(at: Date()) }
    d.agentUsage.planUsed("claude")
    let due = try #require(d.agentUsage.plans.withLock { $0 }["claude"]?.at).addingTimeInterval(every)
        .timeIntervalSinceNow
    #expect(due > 25 && due <= 30)
    // Read a moment ago: turns ending in a row wait for the gap, and asking twice doesn't shorten it.
    d.agentUsage.plans.withLock { $0["claude"] = .init(at: Date(), readAt: Date()) }
    d.agentUsage.planUsed("claude")
    d.agentUsage.planUsed("claude")
    let gap = try #require(d.agentUsage.plans.withLock { $0 }["claude"]?.at).addingTimeInterval(every)
        .timeIntervalSinceNow
    #expect(gap > AgentUsage.planGap - 5 && gap <= AgentUsage.planGap)
    // A failing probe keeps to its own wait.
    d.agentUsage.plans.withLock { $0["claude"] = .init(at: Date(), fails: 2) }
    let waiting = try #require(d.agentUsage.plans.withLock { $0 }["claude"]?.at)
    d.agentUsage.planUsed("claude")
    #expect(d.agentUsage.plans.withLock { $0 }["claude"]?.at == waiting)
    d.agentUsage.plans.withLock { $0["claude"]?.at = .distantPast }
    #expect(d.agentUsage.plans.withLock { $0 }["claude"]?.at == .distantPast)
}

/// Twice as many stuck git / gh calls as there are cores still leave the daemon answering (they don't hold the cooperative pool).
@Test func blockingCallsLeaveTheDaemonAnswering() async throws {
    let d = try Daemon(root: tmp())
    let n = ProcessInfo.processInfo.activeProcessorCount * 2
    let entered = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0),
        answered = DispatchSemaphore(value: 0)
    let stuck = (0..<n).map { _ in
        Task {
            try await d.offload {
                entered.signal()
                gate.wait()
            }
        }
    }
    let started = signals(entered, n, by: .now() + 20)   // generous: this proves the daemon answers, not how fast, and a loaded machine starts threads slowly
    let ping = Task {
        let r = try await d.handle("ping", .null, conn: -1)
        answered.signal()
        return r
    }
    let answeredInTime = signals(answered, 1, by: .now() + 20) == 1   // a daemon whose pool is held would never answer, so this still fails when it should
    for _ in 0..<n { gate.signal() }
    for t in stuck { try await t.value }
    #expect(started == n && answeredInTime)
    #expect(try await ping.value.string == "pong")
}

/// History and usage answer from the agents' folders (empty, then one conversation), now off the cooperative pool.
@Test func historyAndUsageFromAgentFolders() async throws {
    let d = try Daemon(root: tmp()), home = tmp()
    d.agentUsage.agentHomes.withLock {
        $0 = (home.appendingPathComponent("projects"), home.appendingPathComponent("sessions"))
    }
    #expect(try await d.handle("history.list", .null, conn: -1) == .array([]))
    let dir = home.appendingPathComponent("projects/-work-app"), now = ISO8601DateFormatter().string(from: Date())
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try [
        #"{"type":"user","sessionId":"s1","cwd":"/work/app","timestamp":"\#(now)","message":{"role":"user","content":"Fix the parser"}}"#,
        #"{"type":"assistant","cwd":"/work/app","timestamp":"\#(now)","message":{"model":"m","usage":{"input_tokens":3,"output_tokens":5}}}"#
    ]
    .joined(separator: "\n").appending("\n").write(
        to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    let list = try await d.handle("history.list", .obj(["cwd": "/work/app"]), conn: -1)
    #expect(list.array?.map { $0["title"]?.string } == ["Fix the parser"])
    let report = try await d.handle("usage.report", .obj(["days": 1]), conn: -1)
    #expect(report["models"]?.array?.first?["tokens"]?.int == 8)
    await #expect(throws: RPCError.invalidParams("session required")) {
        try await d.handle("history.resume", .null, conn: -1)
    }
}

/// A typed call and the same request written by hand (the CLI, an older app) get the same answer.
@Test func typedAndUntypedCallsAgree() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    _ = try await c.call(StateSet(key: "sidebar.order", value: .array(["a"])))
    #expect(try await c.call(StateGet(key: "sidebar.order")) == .array(["a"]))
    #expect(try await c.call("state.get", .obj(["key": "sidebar.order"])) == .array(["a"]))
    _ = try await c.call("state.set", .obj(["key": "layout/w1", "value": 1]))
    #expect(try await c.call(StateGet(prefix: "")) == .obj(["sidebar.order": .array(["a"]), "layout/w1": 1]))
    _ = try await c.call(StateSet(key: "sidebar.order", value: nil))
    #expect(try await c.call("state.get", .obj(["prefix": ""])) == .obj(["layout/w1": 1]))

    let info = try await c.call(DaemonInfo())
    #expect(info.pid == Int(getpid()) && info.liveSessions == 0 && info.binaryMTime == Daemon.binaryMTime)
    #expect(try await c.call("daemon.info") == .from(info))
    #expect(try await c.call(SessionContextWindow(id: "nope")) == nil)
    #expect(try await c.call(SessionContextParts(id: "nope")) == nil)
    await #expect(throws: RPCError.invalidParams("missing title")) {
        try await c.call("session.rename", .obj(["id": "x"]))
    }
}

/// How many of `n` signals came by the deadline. Blocks this thread on purpose: with a broken offload the cooperative
/// pool is full, and a test that awaited would hang instead of failing.
private func signals(_ s: DispatchSemaphore, _ n: Int, by deadline: DispatchTime) -> Int {
    (0..<n).filter { _ in s.wait(timeout: deadline) == .success }.count
}

@Test func agentTopicNamesSessionAndWorkspace() async throws {
    // Like Claude Code: its own name in the title first, then the conversation's topic.
    let (d, c, _, repo) = try await world(agents: [
        AgentManifest(
            id: "topical", name: "Topical", command: "/bin/zsh",
            args: ["-c", #"printf '\e]0;✳ Topical\a'; sleep 1; printf '\e]0;✳ Ревью и оценка приложения\a'; sleep 30"#])
    ])
    defer { d.stop() }
    let ws = try await c.call("workspace.create", .obj(["repoId": .string(repo.id)]))
    let wid = try #require(ws["id"]?.string)
    let s: Session = try await c.call(
        "session.create",
        .obj([
            "worktreeId": .string(wid), "agent": "topical",
            "prompt": "сделай ревью приложения и дай ему оценку по десятибалльной шкале"
        ]), as: Session.self)
    #expect(
        try await waitFor(10) {
            try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.title
                == "Ревью и оценка приложения"
        })
    #expect(
        try await waitFor(5) {
            try await c.call("worktree.list", as: [Worktree].self).first { $0.id == wid }?.note
                == "Ревью и оценка приложения"
        })
}
