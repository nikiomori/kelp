import Foundation
import Testing
import Core
import Agents
@testable import Daemon

private let fake = AgentManifest(id: "fake", name: "Fake", command: "/bin/zsh", args: ["-c", "cat"])

/// An extension whose every event writes where it came from to `out`, the texts in the words it's documented to use them.
private func install(_ w: World, id: String = "hears", out: URL) throws {
    let dir = w.root.appendingPathComponent("extensions/\(id)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let run = "printf '%s\\n' \"$KELP_EVENT|$KELP_TITLE|$KELP_SUMMARY\" >> '\(out.path)'"
    let events = ["agent.waiting", "agent.done", "workspace.created"].map { JSONValue.obj(["on": .string($0), "run": .string(run)]) }
    try JSONEncoder().encode(JSONValue.obj(["id": .string(id), "contributes": .obj(["events": .array(events)])]))
        .write(to: dir.appendingPathComponent("extension.json"))
}

private func lines(_ url: URL) -> [String] {
    (FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } ?? "").split(separator: "\n").map(String.init)
}

private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("kelp-event-\(UUID().uuidString)") }

/// What an agent prints reaches a command as a value: run as text, this title would be a command.
@Test func anExtensionHearsAnAgentAskingWithItsWordsAsValues() async throws {
    let w = try await world(agents: [fake]), out = temporary(), pwned = temporary(); defer { w.d.stop() }
    try install(w, out: out)
    let title = "$(touch \(pwned.path))"
    let s = try await w.c.call(SessionCreate(worktreeId: try await firstDesk(w).id, agent: "fake", title: title))
    _ = try await w.c.call(SessionReport(id: s.id, state: "blocked", message: "Allow rm?"))
    #expect(try await waitFor(10) { !lines(out).isEmpty })
    #expect(lines(out) == ["agent.waiting|\(title)|Allow rm?"] && !FileManager.default.fileExists(atPath: pwned.path))
}

/// A result stands though its agent ended right after, as a one-shot does. A question has nobody left to answer it.
@Test func aResultIsHeardThoughItsAgentEnded() async throws {
    let w = try await world(agents: [fake]), out = temporary(); defer { w.d.stop() }
    try install(w, out: out)
    let desk = try await firstDesk(w).id
    let done = try await w.c.call(SessionCreate(worktreeId: desk, agent: "fake", title: "done"))
    let asks = try await w.c.call(SessionCreate(worktreeId: desk, agent: "fake", title: "asks"))
    _ = try await w.c.call(SessionReport(id: done.id, state: "done"))
    _ = try await w.c.call(SessionReport(id: asks.id, state: "blocked"))
    _ = try await w.c.call(SessionKill(id: done.id))
    _ = try await w.c.call(SessionKill(id: asks.id))
    #expect(try await waitFor(10) { !lines(out).isEmpty })
    try await Task.sleep(for: .seconds(1))
    #expect(lines(out) == ["agent.done|done|"])
}

/// A stop it goes on from isn't one, a child's result is its parent's, and an extension switched off hears nothing.
@Test func anEventIsForAStopThatStands() async throws {
    let w = try await world(agents: [fake]), out = temporary(), off = temporary(); defer { w.d.stop() }
    try install(w, out: out)
    try install(w, id: "off", out: off)
    _ = try await w.c.call("settings.set", .obj(["key": "extensions.disabled", "value": .array([.string("off")])]))
    let desk = try await firstDesk(w).id
    let s = try await w.c.call(SessionCreate(worktreeId: desk, agent: "fake", title: "parent"))
    let kid = try await w.c.call(SessionCreate(worktreeId: desk, agent: "fake", title: "child", parent: s.id))
    _ = try await w.c.call(SessionReport(id: s.id, state: "done"))
    _ = try await w.c.call(SessionReport(id: s.id, state: "working"))
    _ = try await w.c.call(SessionReport(id: kid.id, state: "done"))
    try await Task.sleep(for: .seconds(Sessions.eventDelay + 1))
    #expect(lines(out).isEmpty)
    _ = try await w.c.call(SessionReport(id: s.id, state: "done"))
    #expect(try await waitFor(10) { lines(out) == ["agent.done|parent|"] })
    _ = try await w.c.call(WorkspaceCreate(repoId: w.repo.id))
    #expect(try await waitFor(10) { lines(out).count == 2 && lines(out)[1].hasPrefix("workspace.created|") })
    #expect(lines(off).isEmpty)
}
