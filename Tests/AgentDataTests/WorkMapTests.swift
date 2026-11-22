import Core
import Foundation
import Testing

@testable import AgentData

/// What a shell command reads, writes and reaches, as agents write commands.
@Test(
    arguments: [
        ("cat Sources/a.swift", [ShellTouches.Touch.read("Sources/a.swift", search: false)]),
        ("sed -n '1,80p' Sources/a.swift | head", [.read("Sources/a.swift", search: false)]),
        (
            "cd Sources && cat a.swift b.swift",
            [.read("Sources/a.swift", search: false), .read("Sources/b.swift", search: false)]
        ),
        ("rg -n 'func work' Sources/Core", [.read("Sources/Core", search: true)]),
        ("grep -rn foo .", [.read(".", search: true)]),
        ("rg foo", [.read(".", search: true)]),
        ("swift test 2>&1 | tail -5", []),
        ("echo hi > notes/out.txt", [.wrote("notes/out.txt")]),
        ("cat x.log >> /dev/null", [.read("x.log", search: false)]),
        ("cat > Sources/New.swift <<'EOF'\ncat secret.txt\nrm -rf /\nEOF\n", [.wrote("Sources/New.swift")]),
        ("sed -i '' 's/a/b/' Sources/a.swift", [.wrote("Sources/a.swift")]),
        ("mv old.txt new.txt", [.wrote("new.txt")]),
        ("curl -s http://127.0.0.1:8765/v1/models", [.site("127.0.0.1:8765", verb: "curl")]),
        ("curl 'https://ollama.com/library?q=x' -o /tmp/o.html", [.site("ollama.com", verb: "curl")]),
        ("gh pr view 53 --json title", [.remote("github.com", verb: "gh pr view")]),
        ("git push origin main", [.remote("", verb: "git push")]),
        ("wc -l Sources/Work/*.swift", [.read("Sources/Work", search: true)]),
        ("rg -n retry Sources/**/*.swift", [.read("Sources", search: true)]),
        ("kelp browser open https://example.com/a", [.site("example.com", verb: "kelp browser")]),
        ("kelp vm run ubuntu -- cat /etc/os-release", [.host("ubuntu", verb: "kelp vm run")]),
        ("git status", []),
        ("ssh niko@mini.local 'swift test'", [.host("mini.local", verb: "ssh")]),
        ("rsync -a dist/ host1:/srv/app", [.host("host1", verb: "rsync")]),
        ("brew install ollama", [.packages("Homebrew", verb: "brew install")]),
        ("FOO=1 npm install", [.packages("npm", verb: "npm install")]),
        ("swift package resolve", [.packages("SwiftPM", verb: "swift package resolve")]),
        ("python3 -c \"print('cat a.py')\"", []),
        ("(cd Vendor/Kit.xcframework && cat Info.plist)", [.read("Vendor/Kit.xcframework/Info.plist", search: false)]),
        (
            "find Sources Tests -name '*.swift' -exec sed -i '' 's|old|new|g' {} +",
            [.read("Sources", search: true), .read("Tests", search: true)]
        ),
        ("grep -rn foo $W 2 | awk '{print $1}'", [.read(".", search: true)]),
        ("rg -l 'x' Sources/a+b.swift", [.read("Sources/a+b.swift", search: false)]),
        ("sed -i '' -e 's|/ a probe.s terminal|/ a probe|g' Sources/x.swift", [.wrote("Sources/x.swift")]),
        ("cd $W && cat a.swift /etc/hosts", [.read("/etc/hosts", search: false)]),
        ("ls -la Sources/Daemon README.md", [.read("Sources/Daemon", search: true), .read("README.md", search: false)]),
        ("grep -rn -A 3 retry Sources", [.read("Sources", search: true)]),
        ("rg -t swift -g '*.md' retry Docs", [.read("Docs", search: true)]),
        ("jq .version package.json", [.read("package.json", search: false)]),
        ("cd $W && echo hi > notes.txt", [])
    ] as [(String, [ShellTouches.Touch])])
func aShellCommandSaysWhatItTouched(command: String, touches: [ShellTouches.Touch]) {
    #expect(ShellTouches.parse(command) == touches)
}

private func line(_ object: [String: Any]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
}
private func at(_ minute: Int, _ second: Int = 0) -> String {
    String(format: "2026-11-21T12:%02d:%02d.000Z", minute, second)
}
private func prompt(_ text: String, _ time: String) -> [String: Any] {
    ["type": "user", "timestamp": time, "cwd": "/p", "message": ["content": text]]
}
private func use(_ id: String, _ name: String, _ input: [String: Any], _ time: String, cwd: String = "/p") -> [String:
    Any]
{
    [
        "type": "assistant", "timestamp": time, "cwd": cwd,
        "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]
    ]
}
private func result(_ id: String, _ time: String, error: Bool = false, detail: [String: Any]? = nil) -> [String: Any] {
    var entry: [String: Any] = [
        "type": "user", "timestamp": time,
        "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": error, "content": "…"]]]
    ]
    if let detail { entry["toolUseResult"] = detail }
    return entry
}
private func log(_ entries: [[String: Any]]) -> WorkLog {
    var log = WorkLog()
    log.read(Data((entries.map(line).joined(separator: "\n") + "\n").utf8))
    return log
}

private var mainEntries: [[String: Any]] {
    [
        prompt("Fix the remote tests", at(6)),
        use("r1", "Read", ["file_path": "/p/Sources/Models.swift"], at(6, 1)), result("r1", at(6, 2)),
        use("r2", "Read", ["file_path": "/p/.claude/worktrees/fix/Sources/Models.swift"], at(6, 3)),
        result("r2", at(6, 4)),
        use("t1", "Task", ["subagent_type": "Explore", "description": "find readers"], at(6, 5)),
        use("b1", "Bash", ["command": "cat Sources/Hooks.swift && curl -s http://127.0.0.1:8765/x"], at(6, 6)),
        result("b1", at(6, 7)),
        use("e1", "Edit", ["file_path": "/p/Sources/Child.swift"], at(7)),
        result("e1", at(7, 1), detail: ["structuredPatch": [["lines": [" a", "-b", "+c", "+d"]]]]),
        use("b2", "Bash", ["command": "swift test"], at(7, 2)), result("b2", at(7, 9), error: true),
        use("g1", "Grep", ["pattern": "remote", "path": "/p/Sources/Daemon"], at(7, 10)),
        use("w1", "WebFetch", ["url": "https://code.claude.com/docs/hooks?token=x"], at(7, 11)),
        use("m1", "mcp__claude-in-chrome__navigate", ["url": "https://x"], at(7, 12)),
        use("o1", "Read", ["file_path": "/Users/me/projects/fixtures/a.json"], at(7, 13)),
        use("o2", "Read", ["file_path": "/private/tmp/shot.png"], at(7, 14)),
        use("o3", "Write", ["file_path": "/Users/me/.claude/notes.md"], at(7, 15)),
        result("t1", at(8)),
        prompt("Now push", at(10)),
        use("n1", "Write", ["file_path": "/p/NEW.md"], at(10, 1)),
        result("n1", at(10, 2), detail: ["type": "create", "content": "a\nb\nc"])
    ]
}
private var subEntries: [[String: Any]] {
    [
        use("s1", "Read", ["file_path": "/p/Sources/Models.swift"], at(6, 30)),
        use("s2", "Read", ["file_path": "/p/Sources/Models.swift"], at(6, 31))
    ]
}
private let layout = WorkMap.Places(root: "/p", home: "/Users/me")
private func sources() -> [WorkMap.Source] {
    [
        WorkMap.Source(agent: .init(role: .main, agent: "claude", name: "claude"), log: log(mainEntries)),
        WorkMap.Source(
            agent: .init(role: .subagent, agent: "claude", name: "Explore"), log: log(subEntries), startedBy: "t1")
    ]
}

/// One turn's places: files from the root, a worktree's path folded onto the project, the subagent's reads counted
/// with whose they are, sites by host only, the agent's own folders apart from other folders outside.
@Test func aTurnSaysWhereTheAgentWorked() {
    let work = WorkMap.build(
        sources(), places: layout, turn: 0, whole: false, working: false,
        changed: [
            .init(path: "Package.resolved", added: 2, removed: 2),
            .init(path: "Sources/Child.swift", added: 9, removed: 9)
        ])
    #expect(work.turns.map(\.prompt) == ["Fix the remote tests", "Now push"])
    #expect(work.turn == 0)
    func place(_ kind: AgentWork.Kind, _ name: String) -> AgentWork.Place? {
        work.places.first { $0.kind == kind && $0.name == name }
    }
    let models = place(.file, "Sources/Models.swift")
    #expect(models?.reads == 4)
    #expect(models?.agents == [0, 1])
    #expect(models?.worktree == "fix")
    #expect(place(.file, "Sources/Hooks.swift")?.reads == 1)
    let child = place(.file, "Sources/Child.swift")
    #expect(child?.edits == 1 && child?.added == 2 && child?.removed == 1 && child?.byCommand == false)
    #expect(place(.file, "Package.resolved")?.byCommand == true)
    #expect(place(.folder, "Sources/Daemon")?.reads == 1)
    #expect(place(.web, "127.0.0.1:8765")?.detail == "curl")
    #expect(place(.web, "code.claude.com")?.detail == "fetch")
    #expect(place(.tool, "claude-in-chrome")?.detail == "navigate")
    #expect(place(.outside, "~/projects/fixtures") != nil)
    #expect(place(.own, "/tmp")?.reads == 1)
    #expect(place(.own, "~/.claude")?.edits == 1)
    #expect(place(.file, "NEW.md") == nil)   // the next turn's
    #expect(work.places.allSatisfy { !$0.name.contains("token") })

    let kinds = work.steps.map(\.kind)
    #expect(kinds.contains(.failed) && kinds.contains(.spawn) && kinds.contains(.report))
    #expect(work.steps.first { $0.kind == .spawn }?.other == 1)
    #expect(work.steps.first { $0.kind == .report }?.agent == 1)
    #expect(work.steps.first { $0.kind == .failed }?.detail == "swift test")
}

/// The whole session sums every turn and keeps no steps; the last turn is the default; a working agent's last place is
/// where it is now.
@Test func theWholeSessionAndTheLastTurn() {
    let whole = WorkMap.build(sources(), places: layout, turn: nil, whole: true, working: false)
    #expect(whole.turn == nil && whole.steps.isEmpty)
    #expect(whole.places.contains { $0.name == "NEW.md" } && whole.places.contains { $0.name == "Sources/Child.swift" })
    let last = WorkMap.build(sources(), places: layout, turn: nil, whole: false, working: true)
    #expect(last.turn == 1)
    #expect(last.places.map(\.name) == ["NEW.md"])
    #expect(last.places.first?.added == 3)
    #expect(last.now == 0)
}

/// A file read in pieces gives the same log as read at once; a half line waits for the rest.
@Test func aLogReadsInPieces() {
    let data = Data((mainEntries.map(line).joined(separator: "\n") + "\n").utf8)
    var pieces = WorkLog()
    var offset = 0
    for size in [100, 7, 900, 3000, data.count] {
        let end = min(offset + size, data.count)
        pieces.read(data[offset..<end])
        offset = Int(pieces.offset)
        if offset >= data.count { break }
    }
    #expect(pieces.calls == log(mainEntries).calls)
    #expect(pieces.prompts == log(mainEntries).prompts)
}

/// Codex's rollout: its prompts, shell commands, patches with their lines, a failed command, a web search.
@Test func aCodexRolloutGivesItsWork() {
    func item(_ payload: [String: Any], _ time: String) -> [String: Any] {
        ["type": "response_item", "timestamp": time, "payload": payload]
    }
    let patch = "*** Begin Patch\n*** Update File: Sources/a.swift\n@@\n-old\n+new\n+more\n*** End Patch"
    let rollout = log([
        ["type": "session_meta", "timestamp": at(1), "payload": ["cwd": "/p"]],
        ["type": "event_msg", "timestamp": at(1), "payload": ["type": "user_message", "message": "review the diff"]],
        item(
            [
                "type": "function_call", "name": "exec_command", "call_id": "c1",
                "arguments": line(["cmd": ["bash", "-lc", "rg -n retry Sources"]])
            ], at(1, 5)),
        item(
            [
                "type": "function_call_output", "call_id": "c1",
                "output": line(["output": "", "metadata": ["exit_code": 1]])
            ], at(1, 6)),
        item(
            [
                "type": "function_call", "name": "exec_command", "call_id": "c3",
                "arguments": line(["cmd": "swift build"])
            ], at(1, 7)),
        item(
            [
                "type": "function_call_output", "call_id": "c3",
                "output": "Chunk ID: 1\nWall time: 2s\nProcess exited with code 2\nOutput:\nerror"
            ], at(1, 8)),
        item(["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2", "input": patch], at(2)),
        item(["type": "custom_tool_call_output", "call_id": "c2", "output": "ok"], at(2, 1)),
        item(["type": "web_search_call", "id": "ws", "action": ["query": "swift regex"]], at(2, 2))
    ])
    #expect(rollout.cwd == "/p")
    // Kept small: a patch's file lines and one character of each changed line.
    #expect(rollout.calls[1].failed)   // its output in plain text, as newer Codex writes it
    #expect(rollout.calls[2].patch == "*** Begin Patch\n*** Update File: Sources/a.swift\n-\n+\n+\n*** End Patch")
    #expect(rollout.prompts.map(\.text) == ["review the diff"])
    let work = WorkMap.build(
        [WorkMap.Source(agent: .init(role: .main, agent: "codex", name: "codex"), log: rollout)], places: layout,
        turn: nil, whole: false, working: false)
    #expect(work.places.first { $0.name == "Sources" }?.kind == .folder)
    let edited = work.places.first { $0.name == "Sources/a.swift" }
    #expect(edited?.edits == 1 && edited?.added == 2 && edited?.removed == 1)
    #expect(work.places.contains { $0.kind == .web && $0.name == "Web Search" })
    #expect(work.steps.first?.kind == .failed)
}

/// `git push` goes to the project's origin: its host read from the repository's config, a worktree's followed to it.
@Test func aProjectsRemoteIsItsOriginsHost() throws {
    #expect(WorkMap.Places.host(ofRemote: "git@github.com:o/r.git") == "github.com")
    #expect(WorkMap.Places.host(ofRemote: "https://gitlab.example.org/o/r") == "gitlab.example.org")
    #expect(WorkMap.Places.host(ofRemote: "ssh://git@host.lan:22/r") == "host.lan")
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: repo) }
    let git = repo.appendingPathComponent(".git"), tree = repo.appendingPathComponent("tree")
    try FileManager.default.createDirectory(
        at: git.appendingPathComponent("worktrees/t"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:o/r.git\n".write(
        to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    try "gitdir: \(git.path)/worktrees/t\n".write(
        to: tree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(WorkMap.Places.remote(of: repo.path) == "github.com")
    #expect(WorkMap.Places.remote(of: tree.path) == "github.com")
}

/// A read or an edit that failed touched nothing: it is a failed step, not a place.
@Test func aFailedCallTouchesNothing() {
    let failed = log([
        prompt("try", at(1)),
        use("e1", "Edit", ["file_path": "/p/Sources/Nope.swift"], at(1, 1)), result("e1", at(1, 2), error: true),
        use("r1", "Read", ["file_path": "/p/Sources/Gone.swift"], at(1, 3)), result("r1", at(1, 4), error: true)
    ])
    let work = WorkMap.build(
        [WorkMap.Source(agent: .init(role: .main, agent: "claude", name: "claude"), log: failed)], places: layout,
        turn: nil, whole: false, working: false)
    #expect(work.places.isEmpty)
    #expect(work.steps.map(\.kind) == [.failed, .failed])
}
