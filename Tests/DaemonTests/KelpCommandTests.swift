import Core
import Foundation
import TestSupport
import Testing

@testable import Daemon

// `kelp`'s commands run as an agent or the user types them, against this daemon: each flag reaches the field it names,
// and what the command prints and exits with is what the daemon answered.

/// `kelp <args>` from `cwd`, as a terminal of the user's runs it: its exit code and what it printed. Not through
/// `Subprocess`, whose programs this in-process daemon takes for its own; into a file, not a pipe, which a session the
/// daemon forks meanwhile would hold open.
private func kelp(_ w: World, _ args: [String], cwd: String) async throws -> (code: Int32, out: String) {
    let file = w.root.appendingPathComponent("kelp-\(UUID().uuidString).out")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: file) }
    let out = try FileHandle(forWritingTo: file), p = Process()
    p.executableURL = URL(fileURLWithPath: try builtProduct("kelp"))
    p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    var env = ProcessInfo.processInfo.environment
    env["KELP_SESSION"] = nil
    env["KELP_HOME"] = w.root.path   // its socket: never Kelp's own daemon
    p.environment = env
    (p.standardOutput, p.standardError) = (out, out)
    let exited = AsyncStream<Void> { done in p.terminationHandler = { _ in done.finish() } }
    try p.run()
    try out.close()
    for await _ in exited {}
    return (p.terminationStatus, try String(contentsOf: file, encoding: .utf8))
}

/// `kelp session new`: the command, title and workspace it's given; `--wait` exits with the command's code, as
/// `kelp wait --for exited` does.
@Test func kelpSessionNewAndWaitPassTheirFlagsOn() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "feat/cli")
    let made = try await kelp(
        w, ["session", "new", "--cmd", "cat", "--title", "Tail", "--worktree", String(wt.id.prefix(8))],
        cwd: w.repo.path)
    #expect(made.code == 0, "\(made.out)")
    let tail = try #require(try await w.c.call(SessionList()).first { $0.title == "Tail" }, "\(made.out)")
    #expect(tail.worktreeId == wt.id && tail.argv.last == "cat", "\(tail.argv)")
    let waited = try await kelp(w, ["session", "new", "--cmd", "exit 3", "--wait"], cwd: wt.path)
    #expect(waited.code == 3, "\(waited.out)")
    let ended = try #require(try await w.c.call(SessionList()).first { $0.argv.last == "exit 3" })
    #expect(waited.out.contains(ended.id) && ended.worktreeId == wt.id)   // the folder's workspace, none given
    let again = try await kelp(w, ["wait", String(ended.id.prefix(8)), "--for", "exited", "--timeout", "10s"], cwd: "/")
    #expect(again.code == 3 && again.out.contains("exited"), "\(again.out)")
}

/// `kelp report` inside a session: its state, message and progress land on that session's row.
@Test func kelpReportSaysWhatTheSessionItRunsInIsDoing() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "feat/report")
    let kelp = try builtProduct("kelp")
    let s = try await w.c.call(
        SessionCreate(
            worktreeId: wt.id,
            command: "\(ShellQuote.word(kelp)) report working Migrating the database --progress 40; cat"))
    #expect(
        try await waitFor(10) {
            try await w.c.call(SessionList()).first { $0.id == s.id }.map {
                $0.status == .working && $0.summary == "Migrating the database" && $0.progress == 40
            } == true
        })
}

/// What acts on the workspace the folder is in: a comment on lines of a file, a note; and settings, set and read back.
@Test func kelpCommentNoteAndSettingsReachTheirFields() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "feat/notes")
    let added = try await kelp(w, ["comment", "add", "a.txt", "2-3", "this", "needs", "a", "test"], cwd: wt.path)
    #expect(added.code == 0, "\(added.out)")
    let comment = try #require(try await w.c.call(CommentList(id: wt.id)).first, "\(added.out)")
    #expect(comment.file == "a.txt" && comment.startLine == 2 && comment.endLine == 3)
    #expect(comment.text == "this needs a test" && comment.author == nil)   // the user's: no session
    #expect(try await kelp(w, ["worktree", "note", "halfway", "there"], cwd: wt.path).code == 0)
    #expect(try await w.c.call(WorktreeList()).first { $0.id == wt.id }?.note == "halfway there")
    #expect(try await kelp(w, ["settings", "set", "editor.fontSize", "15"], cwd: "/").code == 0)
    #expect(try await w.c.call(SettingsGet())["editor.fontSize"] == .int(15))
    #expect(
        try await kelp(w, ["settings", "get", "editor.fontSize"], cwd: "/").out.trimmingCharacters(
            in: .whitespacesAndNewlines) == "15")
}

/// `kelp call`: a method by its name, its params as they're typed, its result printed as JSON; params that aren't an
/// object are refused before the daemon is asked.
@Test func kelpCallSendsAnyMethodByItsName() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let set = try await kelp(w, ["call", "settings.set", #"{"key":"editor.fontSize","value":17}"#], cwd: "/")
    #expect(set.code == 0, "\(set.out)")
    #expect(try await w.c.call(SettingsGet())["editor.fontSize"] == .int(17))
    let read = try await kelp(w, ["call", "settings.get"], cwd: "/")
    #expect(read.code == 0 && read.out.contains(#""editor.fontSize" : 17"#), "\(read.out)")
    let bare = try await kelp(w, ["call", "settings.set", "17"], cwd: "/")
    #expect(bare.code == 1 && bare.out.contains("JSON object"), "\(bare.out)")
    let unknown = try await kelp(w, ["call", "no.such.method"], cwd: "/")
    #expect(unknown.code == 1 && unknown.out.hasPrefix("error:"), "\(unknown.out)")
}
