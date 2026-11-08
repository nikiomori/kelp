import Agents
import Core
import Foundation
import Testing

@testable import Daemon

private let fake = AgentManifest(id: "fake", name: "Fake", command: "/bin/zsh", args: ["-c", "cat"])

/// An extension whose every event writes where it came from to `out`, the texts in the words it's documented to use them.
private func install(_ w: World, id: String = "hears", out: URL, allowed: Bool = true) throws {
    let dir = w.root.appendingPathComponent("extensions/\(id)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let run = "printf '%s\\n' \"$KELP_EVENT|$KELP_TITLE|$KELP_SUMMARY\" >> '\(out.path)'"
    let events = ["agent.waiting", "agent.done", "workspace.created"].map {
        JSONValue.obj(["on": .string($0), "run": .string(run)])
    }
    try JSONEncoder().encode(JSONValue.obj(["id": .string(id), "contributes": .obj(["events": .array(events)])]))
        .write(to: dir.appendingPathComponent("extension.json"))
    if allowed { try allow(w, id) }
}

/// Allowed as it is now, as Kelp's window records it.
private func allow(_ w: World, _ id: String) throws {
    var record: [String: JSONValue] = [:]
    if case .object(let was)? = try w.d.sessions.store.uiState(prefix: IDE.extensionTrustKey)[IDE.extensionTrustKey] {
        record = was
    }
    record[id] = .string(IDE.extensionDigest(w.root.appendingPathComponent("extensions/\(id)")))
    try w.d.sessions.store.setUIState(IDE.extensionTrustKey, .object(record))
}

private func lines(_ url: URL) -> [String] {
    (FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } ?? "").split(
        separator: "\n"
    ).map(String.init)
}

private func temporary() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("kelp-event-\(UUID().uuidString)")
}

/// What an agent prints reaches a command as a value: run as text, this title would be a command.
@Test func anExtensionHearsAnAgentAskingWithItsWordsAsValues() async throws {
    let w = try await world(agents: [fake]), out = temporary(), pwned = temporary()
    defer { w.d.stop() }
    try install(w, out: out)
    let title = "$(touch \(pwned.path))"
    let s = try await w.c.call(SessionCreate(worktreeId: try await firstWorkspace(w).id, agent: "fake", title: title))
    _ = try await w.c.call(SessionReport(id: s.id, state: "blocked", message: "Allow rm?"))
    #expect(try await waitFor(10) { !lines(out).isEmpty })
    #expect(lines(out) == ["agent.waiting|\(title)|Allow rm?"] && !FileManager.default.fileExists(atPath: pwned.path))
}

/// A result stands though its agent ended right after, as a one-shot does. A question has nobody left to answer it.
@Test func aResultIsHeardThoughItsAgentEnded() async throws {
    let w = try await world(agents: [fake]), out = temporary()
    defer { w.d.stop() }
    try install(w, out: out)
    let workspace = try await firstWorkspace(w).id
    let done = try await w.c.call(SessionCreate(worktreeId: workspace, agent: "fake", title: "done"))
    let asks = try await w.c.call(SessionCreate(worktreeId: workspace, agent: "fake", title: "asks"))
    // The question first: events are judged in turn, so once the result is heard, the question's turn has passed.
    _ = try await w.c.call(SessionReport(id: asks.id, state: "blocked"))
    _ = try await w.c.call(SessionReport(id: done.id, state: "done"))
    _ = try await w.c.call(SessionKill(id: done.id))
    _ = try await w.c.call(SessionKill(id: asks.id))
    #expect(try await waitFor(10) { !lines(out).isEmpty })
    #expect(lines(out) == ["agent.done|done|"])
}

/// A stop it goes on from isn't one, a child's result is its parent's, and an extension switched off hears nothing.
@Test func anEventIsForAStopThatStands() async throws {
    let w = try await world(agents: [fake]), out = temporary(), off = temporary()
    defer { w.d.stop() }
    try install(w, out: out)
    try install(w, id: "off", out: off)
    _ = try await w.c.call("settings.set", .obj(["key": "extensions.disabled", "value": .array([.string("off")])]))
    let workspace = try await firstWorkspace(w).id
    let s = try await w.c.call(SessionCreate(worktreeId: workspace, agent: "fake", title: "parent"))
    let kid = try await w.c.call(SessionCreate(worktreeId: workspace, agent: "fake", title: "child", parent: s.id))
    _ = try await w.c.call(SessionReport(id: s.id, state: "done"))
    _ = try await w.c.call(SessionReport(id: s.id, state: "working"))
    _ = try await w.c.call(SessionReport(id: kid.id, state: "done"))
    // Time: the delay is what's tested, the stop judged before it stands again.
    try await Task.sleep(for: .seconds(ExtensionEvents.eventDelay + 1))
    #expect(lines(out).isEmpty)
    _ = try await w.c.call(SessionReport(id: s.id, state: "done"))
    #expect(try await waitFor(10) { lines(out) == ["agent.done|parent|"] })
    _ = try await w.c.call(WorkspaceCreate(repoId: w.repo.id))
    #expect(try await waitFor(10) { lines(out).count == 2 && lines(out)[1].hasPrefix("workspace.created|") })
    #expect(lines(off).isEmpty)
}

/// With no record of what the user allowed (a new home, or one the window hasn't looked at yet), an extension is
/// allowed nothing: no command, no event.
@Test func anExtensionWithoutARecordRunsNothing() async throws {
    let w = try await world(agents: [fake]), out = temporary(), other = temporary()
    defer { w.d.stop() }
    try install(w, out: out, allowed: false)
    let workspace = try await firstWorkspace(w).id
    await #expect(throws: RPCError.self) {
        try await w.c.call(ProcessRun(argv: ["/bin/echo", "ran"], extensionId: "hears"))
    }
    try install(w, id: "other", out: other)   // allowed: what it hears is the moment "hears" would have
    let s = try await w.c.call(SessionCreate(worktreeId: workspace, agent: "fake", title: "asks"))
    _ = try await w.c.call(SessionReport(id: s.id, state: "blocked"))
    // The other heard it, after "hears" would have: they run one after the other, in folder order.
    #expect(try await waitFor(10) { lines(other) == ["agent.waiting|asks|"] })
    #expect(lines(out).isEmpty)
}

/// Once Kelp's window has recorded what the user allowed, an extension that's new or changed since runs no event and
/// no command until it's allowed as it is.
@Test func anExtensionRunsOnlyAsItWasAllowed() async throws {
    let w = try await world(agents: [fake]), out = temporary(), other = temporary()
    defer { w.d.stop() }
    try install(w, out: out)
    try install(w, id: "other", out: other)
    let dir = w.root.appendingPathComponent("extensions"), workspace = try await firstWorkspace(w).id
    let allowed = IDE.extensionDigest(dir.appendingPathComponent("other"))
    try w.d.sessions.store.setUIState(
        IDE.extensionTrustKey, .obj(["hears": .string("what was there before"), "other": .string(allowed)]))
    let before = try await w.c.call(SessionCreate(worktreeId: workspace, agent: "fake", title: "before"))
    _ = try await w.c.call(SessionReport(id: before.id, state: "blocked"))
    await #expect(throws: RPCError.self) {
        try await w.c.call(ProcessRun(argv: ["/bin/echo", "ran"], extensionId: "hears"))
    }
    // The other heard it, after "hears" would have: they run one after the other, in folder order.
    #expect(try await waitFor(10) { lines(other) == ["agent.waiting|before|"] })
    #expect(lines(out) == [])
    try w.d.sessions.store.setUIState(
        IDE.extensionTrustKey, .obj(["hears": .string(IDE.extensionDigest(dir.appendingPathComponent("hears")))]))
    #expect(try await w.c.call(ProcessRun(argv: ["/bin/echo", "ran"], extensionId: "hears")).stdout == "ran\n")
    let after = try await w.c.call(SessionCreate(worktreeId: workspace, agent: "fake", title: "after"))
    _ = try await w.c.call(SessionReport(id: after.id, state: "blocked"))
    #expect(try await waitFor(10) { lines(out) == ["agent.waiting|after|"] })
}
