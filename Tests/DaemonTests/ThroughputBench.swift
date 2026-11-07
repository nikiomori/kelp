import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// How fast a session passes output on: 100 MB of coloured lines from an agent (the status detector, ring, log and
/// reports all see every chunk), timed until the session has ended. Opt-in, it takes seconds: KELP_BENCH=1 swift test
/// --filter outputThroughput. Commit 53d79e7 took it from 6.3 s to 2.1 s (a bare PTY: 1.8 s).
@Test(.enabled(if: ProcessInfo.processInfo.environment["KELP_BENCH"] != nil)) func outputThroughput() async throws {
    let file = tmp().appendingPathComponent("big.txt")
    let line = Data("line of output with \u{1B}[32mcolour\u{1B}[0m and some words to read through ......\n".utf8)
    var chunk = Data()
    while chunk.count < 1 << 20 { chunk.append(line) }
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let h = try FileHandle(forWritingTo: file)
    for _ in 0..<100 { try h.write(contentsOf: chunk) }
    try h.close()
    let w = try await world(agents: [AgentManifest(id: "bench", name: "Bench", command: "/bin/cat", args: [file.path])])
    defer { w.d.stop() }
    let wt = try await workspace(w, "bench")
    func cpu() -> Double {   // this process's (the daemon's) user + system time: less noisy than the clock on a busy Mac
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    let start = Date(), cpu0 = cpu()
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bench"))
    #expect(try await waitFor(300) { try await w.c.call(SessionList()).first { $0.id == s.id }?.status == .exited })
    print(
        "BENCH 100 MB through a session: \(String(format: "%.2f", Date().timeIntervalSince(start))) s, CPU \(String(format: "%.2f", cpu() - cpu0)) s"
    )
}
