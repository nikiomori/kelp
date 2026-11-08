import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// What `hooks/list` answers, with Kelp's hooks trusted or not, and one of the user's own among them.
private func listed(trusted: Bool, leaving: String? = nil) -> [String: Any] {
    let ours: [[String: Any]] = CodexHooks.events.filter { $0.label != leaving }.map {
        ["key": CodexHooks.key($0.label), "trustStatus": trusted ? "trusted" : "untrusted"]
    }
    let theirs: [String: Any] = ["key": "/Users/me/.codex/hooks.json:stop:0:0", "trustStatus": "trusted"]
    return ["id": 2, "result": ["data": [["cwd": "/tmp", "hooks": ours + [theirs], "warnings": [], "errors": []]]]]
}

/// Codex's hooks go on only when Codex lists every one of Kelp's as trusted; it's asked once per binary.
@Test func codexGetsKelpsHooksOnlyWhenItTrustsThemAll() {
    #expect(CodexHookCheck.agrees(listed(trusted: true)))
    #expect(!CodexHookCheck.agrees(listed(trusted: false)))
    #expect(!CodexHookCheck.agrees(listed(trusted: true, leaving: "stop")), "an older Codex without one of the events")
    #expect(!CodexHookCheck.agrees(nil) && !CodexHookCheck.agrees(["id": 2, "error": ["message": "unknown method"]]))

    let asked = OSAllocatedUnfairLockBox()
    let check = CodexHookCheck { _ in
        asked.bump()
        return listed(trusted: true)
    }
    #expect(check.agrees("/bin/sh") && check.agrees("/bin/sh") && asked.count == 1)
}

/// On a Mac with Codex: the Codex installed takes Kelp's hooks as they're passed (the hash is still Codex's).
@Test(.enabled(if: (try? LoginPath.resolve("codex")) != nil))
func theInstalledCodexTrustsKelpsHooks() throws {
    let codex = try LoginPath.resolve("codex")
    // The tests' own CODEX_HOME (TestIsolation), empty: Codex won't start in a home that isn't there.
    if let home = ProcessInfo.processInfo.environment["CODEX_HOME"] {
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    let started = Date()
    let answer = CodexHookCheck.hooksList(codex)
    #expect(
        CodexHookCheck.agrees(answer),
        "\(Date().timeIntervalSince(started)) s: \(String(describing: answer).prefix(600))")
}

private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
