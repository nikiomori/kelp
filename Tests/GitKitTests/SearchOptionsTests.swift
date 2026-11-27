import Core
import Foundation
import TestSupport
import Testing
import os

@testable import GitKit

@Test func searchTakesWholeWordsCaseAndPatterns() throws {
    let repo = try tempRepo()
    try "id\nvalid\nID\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    #expect(try ProjectFiles.search(repo, query: "id", remotes: .none).count == 3)
    #expect(try ProjectFiles.search(repo, query: "id", wholeWord: true, remotes: .none).map(\.line) == [1, 3])
    #expect(
        try ProjectFiles.search(repo, query: "id", caseSensitive: true, wholeWord: true, remotes: .none).map(\.line)
            == [1])
    #expect(try ProjectFiles.search(repo, query: "^v.*d$", regex: true, remotes: .none).map(\.line) == [2])
    #expect(throws: (any Error).self) { try ProjectFiles.search(repo, query: "(", regex: true, remotes: .none) }
}

/// The search box asks once per pause in the typing: a newer search in the same folder stops the program the one before
/// it still runs (each went on to the end, one rg per key on a big repo); a search nothing replaces (an agent's) runs on.
@Test func aNewerSearchBoxSearchStopsTheOneBefore() async throws {
    let folder = "/tmp/search-\(UUID().uuidString.prefix(6))"
    let running = OSAllocatedUnfairLock<[pid_t]>(initialState: [])
    func sleeper(_ seconds: String, in place: String?) throws -> Subprocess.Output {
        try ProjectFiles.replacingSearch(in: place) { started in
            try Subprocess.checked(["/bin/sleep", seconds], cwd: "/tmp") { pid in
                started?(pid)
                running.withLock { $0.append(pid) }
            }
        }
    }
    let first = Task.detached { try? sleeper("30", in: folder) }
    try await waitFor { running.withLock { $0.count } == 1 }
    let agents = Task.detached { () -> Int32? in
        do { _ = try sleeper("30", in: nil) } catch { return (error as? ProgramError)?.status }
        return nil
    }
    try await waitFor { running.withLock { $0.count } == 2 }   // both running
    let agent = running.withLock { $0[1] }
    let t0 = Date()
    _ = try sleeper("0", in: folder)
    #expect(await first.value == nil)   // stopped
    #expect(Date().timeIntervalSince(t0) < 10)
    // The agent's runs on: it ends of the signal sent now, not of the stop's SIGTERM.
    kill(agent, SIGINT)
    #expect(await agents.value == SIGINT)
}
