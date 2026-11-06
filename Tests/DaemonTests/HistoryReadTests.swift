import Foundation
import Testing
import Core
@testable import Daemon

/// Typing in the history search reuses the conversations read when the window opened; opening it (no query) reads again.
@Test func historySearchReusesTheListReadOnOpen() async throws {
    let d = try Daemon(root: tmp()), home = tmp()
    d.agentUsage.agentHomes.withLock { $0 = (home.appendingPathComponent("projects"), home.appendingPathComponent("sessions")) }
    let dir = home.appendingPathComponent("projects/-work-app"), now = ISO8601DateFormatter().string(from: Date())
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func conversation(_ id: String, _ prompt: String) throws {
        try #"{"type":"user","sessionId":"\#(id)","cwd":"/work/app","timestamp":"\#(now)","message":{"role":"user","content":"\#(prompt)"}}"#
            .appending("\n").write(to: dir.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
    }
    func titles(_ query: String) async throws -> [String?] {
        try await d.handle("history.list", .obj(["query": .string(query)]), conn: -1).array?.map { $0["title"]?.string } ?? []
    }
    try conversation("s1", "Fix the parser")
    #expect(try await titles("") == ["Fix the parser"])
    try conversation("s2", "Second task")
    #expect(try await titles("second").isEmpty)                 // typing: the list read on open
    #expect(try await Set(titles("")) == ["Second task", "Fix the parser"])
    #expect(try await titles("second") == ["Second task"])     // reopened: read again
}
