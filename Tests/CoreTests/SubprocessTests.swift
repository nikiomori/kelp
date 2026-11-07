import Foundation
import TestSupport
import Testing

@testable import Core

private let env = ProcessInfo.processInfo.environment

/// A big input and a big output at once don't block each other (stdin is written alongside the reads).
@Test func aSubprocessTakesAndGivesMoreThanAPipeHolds() throws {
    let text = Data(String(repeating: "line of text\n", count: 100_000).utf8)   // 1.3 MB each way
    let r = try Subprocess.run(["/bin/cat"], cwd: "/tmp", env: env, stdin: text, timeLimit: 30)
    #expect(r.status == 0 && !r.timedOut && r.stdout == text)
}

/// Past its time limit a program is stopped with what it started, even both ignoring SIGTERM.
@Test func aSubprocessPastItsLimitStopsWithItsChildren() async throws {
    let pidFile = NSTemporaryDirectory() + "sp-\(UUID().uuidString)"
    let script = "trap '' TERM; (trap '' TERM; while :; do sleep 0.1; done) & echo $! > \(pidFile); wait"
    let start = Date()
    let r = try await Subprocess.run(["/bin/bash", "-c", script], cwd: "/tmp", env: env, timeLimit: 0.5)
    #expect(r.timedOut && Date().timeIntervalSince(start) < 20)   // 0.5 s, then TERM, then KILL: far less than 20 even on a busy runner
    let child = try #require(
        pid_t((try String(contentsOfFile: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(child, SIGKILL) }
    #expect(try await waitFor(20) { kill(child, 0) != 0 })   // a busy runner takes its time
}

/// A child left running with the pipes open (a daemon it started) doesn't hold up the result.
@Test func aSubprocessDoesntWaitForAChildHoldingItsPipes() throws {
    let pidFile = NSTemporaryDirectory() + "sp-\(UUID().uuidString)"
    let start = Date()
    let r = try Subprocess.run(
        ["/bin/bash", "-c", "echo hi; sleep 30 & echo $! > \(pidFile)"], cwd: "/tmp", env: env, timeLimit: 30)
    if let child = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({
        pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }) {
        kill(child, SIGKILL)
    }
    #expect(r.status == 0 && String(decoding: r.stdout, as: UTF8.self) == "hi\n")
    #expect(Date().timeIntervalSince(start) < 10)
}

/// Once the result is back, the pipes a lingering child holds are let go: no reader thread and pipe stay for the life of
/// the daemon. The child then can't write to them (it would have printed to nobody anyway).
@Test func aSubprocessLetsGoOfPipesAChildStillHolds() async throws {
    let mark = NSTemporaryDirectory() + "sp-\(UUID().uuidString)", ended = mark + ".ended"
    defer { for f in [mark, ended] { try? FileManager.default.removeItem(atPath: f) } }
    let child = "(trap '' PIPE; trap 'touch \(ended)' EXIT; sleep 3; echo late && touch \(mark)) &"
    let r = try await Subprocess.run(["/bin/bash", "-c", "echo hi; " + child], cwd: "/tmp", env: env, timeLimit: 30)
    #expect(String(decoding: r.stdout, as: UTF8.self) == "hi\n")   // back after the pipes' 2 s, before the child writes
    #expect(try await waitFor(10) { FileManager.default.fileExists(atPath: ended) })   // past the child's write at 3 s
    #expect(!FileManager.default.fileExists(atPath: mark))   // it failed (nobody reads), so no mark
}

/// A lingering child that keeps writing is let go of too, not read for as long as it lives.
@Test func aSubprocessLetsGoOfAChildThatKeepsWriting() async throws {
    let mark = NSTemporaryDirectory() + "sp-\(UUID().uuidString)", ended = mark + ".ended"
    defer { for f in [mark, ended] { try? FileManager.default.removeItem(atPath: f) } }
    let child =
        "(trap '' PIPE; trap 'touch \(ended)' EXIT; for i in $(seq 40); do echo x || exit; sleep 0.1; done; "
        + "touch \(mark)) &"
    // Back after 2 s.
    _ = try await Subprocess.run(["/bin/bash", "-c", "echo hi; " + child], cwd: "/tmp", env: env, timeLimit: 30)
    #expect(try await waitFor(10) { FileManager.default.fileExists(atPath: ended) })   // the loop left (or ran its 4 s)
    #expect(!FileManager.default.fileExists(atPath: mark))   // a write after the pipes went failed, and it left
}

/// Past its limit a stream is still read, so the program runs to its end (its status is its own), but only the first
/// `limit` bytes are kept, and the output says it's cut.
@Test func aSubprocessKeepsItsLimitAndRunsToTheEnd() throws {
    let r = try Subprocess.run(
        ["/bin/sh", "-c", "head -c 3000000 /dev/zero; echo done >&2; exit 3"], cwd: "/tmp", env: env, timeLimit: 30,
        limit: 1 << 20)
    #expect(r.status == 3 && !r.timedOut && r.truncated)
    #expect(r.stdout.count == 1 << 20 && String(decoding: r.stderr, as: UTF8.self) == "done\n")
    let whole = try Subprocess.run(
        ["/bin/sh", "-c", "head -c 1048576 /dev/zero"], cwd: "/tmp", env: env, timeLimit: 30, limit: 1 << 20)
    #expect(whole.stdout.count == 1 << 20 && !whole.truncated)   // exactly the limit is all of it
}

/// A process is known by its pid and start time: the SIGKILL that follows a SIGTERM (`killLater`) goes only to the same
/// process, never to one given its pid since.
@Test func aProcessIsKnownByItsStartTime() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["30"]
    try p.run()
    let pid = p.processIdentifier
    let t = try #require(Subprocess.started(pid))
    #expect(Subprocess.started(pid) == t)
    #expect(Subprocess.started(getpid()).map { $0 < t } == true)   // this test started first
    Subprocess.killLater([pid], after: 0)
    p.waitUntilExit()
    #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL)
    #expect(Subprocess.started(pid) == nil)
}

/// A process's parent and owner are read for another account's process too (root's `login` under a terminal): a line
/// walked up from a terminal goes on past it to the app.
@Test func anotherAccountsProcessHasItsParentAndOwnerRead() throws {
    let r = try Subprocess.run(["/usr/bin/pgrep", "-U", "0", "-x", "syslogd"], cwd: "/", env: [:], timeLimit: 5)
    let pid = try #require(pid_t(String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").first ?? ""))
    #expect(Subprocess.parent(pid) == 1 && Subprocess.owner(pid) == 0)
    #expect(Subprocess.parent(getpid()) == getppid() && Subprocess.owner(getpid()) == getuid())
    #expect(Subprocess.parent(999_999) == nil)
}

/// Arguments longer than the first read's buffer are read whole: the system fills a short buffer with their tail.
@Test func longArgumentsAreReadWhole() throws {
    let long = String(repeating: "x", count: 20_000)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["5", long]   // sleep reads its first; the rest is only there to be read back
    try p.run()
    defer { p.terminate() }
    #expect(Subprocess.arguments(p.processIdentifier) == ["/bin/sleep", "5", long])
}

/// A child that has ended and isn't reaped is a zombie, and stops being one once its parent reaps it.
@Test func anEndedChildIsAZombieUntilReaped() async throws {
    var pid: pid_t = 0
    var args: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
    defer { args.forEach { free($0) } }
    #expect(posix_spawn(&pid, "/usr/bin/true", nil, nil, &args, nil) == 0)
    #expect(try await waitFor { Subprocess.isZombie(pid) })
    var status: Int32 = 0
    #expect(waitpid(pid, &status, 0) == pid)
    #expect(!Subprocess.isZombie(pid))
}
