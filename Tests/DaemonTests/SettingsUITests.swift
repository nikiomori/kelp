import Foundation
import IOKit.pwr_mgt
import Testing
import Core
@testable import Daemon

final class EventBox: @unchecked Sendable {
    private let l = NSLock(); private var events: [(String, JSONValue)] = []
    func add(_ m: String, _ p: JSONValue) { l.withLock { events.append((m, p)) } }
    func last(_ m: String) -> JSONValue? { l.withLock { events.last { $0.0 == m }?.1 } }
}

@Test func settingsMigrateSetAndHandEdit() async throws {
    let root = tmp()
    try #"{"hibernateMinutes":5,"keepAwake":"off","profiles":[{"name":"Work","agent":"claude","dir":"/x"}],"other":1}"#
        .write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try client(root)
    let box = EventBox(); c.onNotification = { box.add($0, $1) }

    let s0 = try await c.call("settings.get")
    #expect(s0["sessions.hibernateMinutes"] == 5 && s0["power.keepAwake"] == "off" && s0["accounts.profiles"]?.array?.count == 1 && s0["other"] == nil)

    let s1 = try await c.call("settings.set", .obj(["key": "editor.fontSize", "value": 13]))
    #expect(s1["editor.fontSize"] == 13)
    let file = root.appendingPathComponent("settings.json")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == s1)
    let (a, e) = (try #require(text.range(of: "accounts.profiles")), try #require(text.range(of: "editor.fontSize")))
    #expect(text.contains("\n  ") && a.lowerBound < e.lowerBound)   // pretty-printed, sorted keys
    #expect(try await waitFor { box.last("event.settings")?["settings"] == s1 })
    #expect(try await c.call("settings.set", .obj(["key": "editor.fontSize"]))["editor.fontSize"] == nil)   // no value removes

    try #"{"theme": "dark"}"#.write(to: file, atomically: true, encoding: .utf8)   // a hand edit
    #expect(try await waitFor { box.last("event.settings")?["settings"] == .obj(["theme": "dark"]) })
    #expect(try await c.call("settings.get") == .obj(["theme": "dark"]))
    try "{ not json".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
    d.pollSettings()   // what the ticker does: the daemon has now seen the broken file
    #expect(try await c.call("settings.get") == .obj(["theme": "dark"]))   // a broken file keeps the last good settings
}

@Test func uiRelayReachesTheApp() async throws {
    let (d, agent, root) = try daemon(); defer { d.stop() }
    #expect(try await agent.call("ui.state") == .object([:]))
    await #expect(throws: RPCError.internalError("The Kelp app isn't running")) { try await agent.call("ui.open", .obj(["uri": "/a.swift"])) }

    let app = try client(root)
    let box = EventBox(); app.onNotification = { box.add($0, $1) }
    let state: JSONValue = .obj(["extensions": .array([.obj(["id": "git", "name": "Git", "enabled": true, "builtin": true])])])
    _ = try await app.call("ui.publish", .obj(["state": state]))
    #expect(try await agent.call("ui.state") == state)
    #expect(try await agent.call("ui.open", .obj(["uri": "file:///a.swift#L3", "split": "right"])) == .obj(["delivered": 1]))
    #expect(try await waitFor { box.last("event.ui") == .obj(["action": "open", "uri": "file:///a.swift#L3", "split": "right"]) })
    _ = try await agent.call("ui.command", .obj(["id": "extensions.reload"]))
    #expect(try await waitFor { box.last("event.ui") == .obj(["action": "command", "id": "extensions.reload"]) })
    await #expect(throws: RPCError.self) { try await agent.call("ui.open", .obj(["uri": "x", "split": "left"])) }

    app.close()   // the app quit: nothing to deliver to, nothing shown
    #expect(try await waitFor { (try? await agent.call("ui.open", .obj(["uri": "/a"]))) == nil })
    #expect(try await agent.call("ui.state") == .object([:]))
}

/// What the app restores lives in the daemon: by key, by prefix, null deletes; a removed workspace takes its layout along.
@Test func uiStateByKeyAndPrefix() async throws {
    let (d, c, _) = try daemon(); defer { d.stop() }
    func get(_ k: String) async throws -> JSONValue { try await c.call("state.get", .obj(["key": .string(k)])) }
    func set(_ k: String, _ v: JSONValue) async throws { _ = try await c.call("state.set", .obj(["key": .string(k), "value": v])) }
    #expect(try await get("sidebar.order") == .null)
    try await set("sidebar.order", .array(["a", "b"]))
    try await set("layout/w1", .obj(["groups": .object([:])]))
    #expect(try await get("sidebar.order") == .array(["a", "b"]))
    #expect(try await c.call("state.get", .obj(["prefix": "layout/"])) == .obj(["layout/w1": .obj(["groups": .object([:])])]))
    try await set("sidebar.order", .null)
    #expect(try await c.call("state.get", .obj(["prefix": ""])) == .obj(["layout/w1": .obj(["groups": .object([:])])]))

    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    let desk: Worktree = try await c.call("workspace.create", .obj(["repoId": .string(repo.id)]), as: Worktree.self)
    let first = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.id != desk.id })
    try await set("layout/\(desk.id)", 1); try await set("layout/\(first.id)", 2)
    _ = try await c.call("worktree.remove", .obj(["id": .string(desk.id)]))
    #expect(try await get("layout/\(desk.id)") == .null)
    #expect(try await get("layout/\(first.id)") == 2)
    _ = try await c.call("repo.remove", .obj(["id": .string(repo.id)]))   // its workspaces go with it
    #expect(try await get("layout/\(first.id)") == .null)
    #expect(try await get("layout/w1") != .null)
}

/// Keep Mac Awake as macOS sees it: "always" keeps the screen on (a system-sleep assertion alone lets it sleep and lock),
/// "off" lets go.
@Test func keepAwakeAlwaysHoldsTheDisplay() throws {
    func held() -> [String] {
        var all: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&all) == kIOReturnSuccess, let byPID = all?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        // Only the display's: other tests' daemons in this process hold system-sleep assertions while their agents work.
        return (byPID[NSNumber(value: getpid())] ?? []).compactMap { $0[kIOPMAssertionTypeKey] as? String }
            .filter { $0 == kIOPMAssertPreventUserIdleDisplaySleep }
    }
    let root = tmp()
    let d = try Daemon(root: root)
    _ = try d.settings.set("power.keepAwake", .string("always")); d.sessions.applyKeepAwake()
    #expect(held() == [kIOPMAssertPreventUserIdleDisplaySleep])
    _ = try d.settings.set("power.keepAwake", .string("off")); d.sessions.applyKeepAwake()
    #expect(held().isEmpty)
}
