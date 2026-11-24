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
    let running = OSAllocatedUnfairLock(initialState: 0)
    func sleeper(_ seconds: String, in place: String?) throws -> Subprocess.Output {
        try ProjectFiles.replacingSearch(in: place) { started in
            try Subprocess.checked(["/bin/sleep", seconds], cwd: "/tmp") { pid in
                started?(pid)
                running.withLock { $0 += 1 }
            }
        }
    }
    let first = Task.detached { try? sleeper("30", in: folder) }
    let agents = Task.detached { try? sleeper("1", in: nil) }
    try await waitFor { running.withLock { $0 } == 2 }   // both running
    let t0 = Date()
    _ = try sleeper("0", in: folder)
    #expect(await first.value == nil)   // stopped
    #expect(Date().timeIntervalSince(t0) < 10)
    #expect(await agents.value != nil)
}
