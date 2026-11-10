import Core
import Foundation
import Testing

@testable import Daemon

/// The daemon runs the app's programs: output and exit code, stdin, the home and `kelp` on PATH, a time limit that stops
/// it, a program that can't start; an extension's command only while that extension is installed and on.
@Test func processRunRunsAndRefuses() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let echo = try await c.call(ProcessRun(argv: ["/bin/cat"], stdin: "hi"))
    #expect(echo == .init(code: 0, stdout: "hi", stderr: "", timedOut: false))
    let failed = try await c.call(ProcessRun(argv: ["/bin/sh", "-c", "echo e >&2; exit 3"]))
    #expect(failed.code == 3 && failed.stderr == "e\n")
    let env = try await c.call(
        ProcessRun(argv: ["/bin/sh", "-c", #"echo "$KELP_HOME"; command -v kelp >/dev/null && echo kelp"#]))
    #expect(env.stdout.hasPrefix(root.path + "\n"))
    let t = Date(), slow = try await c.call(ProcessRun(argv: ["/bin/sleep", "5"], timeLimit: 0.2))
    #expect(slow.timedOut && Date().timeIntervalSince(t) < 2)
    await #expect(throws: RPCError.self) { try await c.call(ProcessRun(argv: ["/nonexistent/tool"])) }

    let ext = root.appendingPathComponent("extensions/demo")
    try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
    try #"{"id": "me.demo", "name": "Demo"}"#.write(
        to: ext.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
    await #expect(throws: RPCError.self, "not allowed yet") {
        try await c.call(ProcessRun(argv: ["/bin/echo", "ran"], extensionId: "demo"))
    }
    try d.sessions.store.setDaemonState(
        ExtensionFiles.extensionTrustKey, JSONValue.obj(["demo": .string(ExtensionFiles.extensionDigest(ext))]))
    #expect(try await c.call(ProcessRun(argv: ["/bin/echo", "ok"], extensionId: "demo")).stdout == "ok\n")
    _ = try await c.call(SettingsSet(key: "extensions.disabled", value: .array(["me.demo"])))   // turned off
    for id in ["demo", "nope", "..", "demo/../demo"] {
        await #expect(throws: RPCError.self, "\(id)") {
            try await c.call(ProcessRun(argv: ["/bin/echo", "ran"], extensionId: id))
        }
    }
}

/// Output past what the reply carries is an error, not a part passed off as the whole (a formatter's would replace the
/// file's text with it).
@Test func aProgramThatPrintsTooMuchFails() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    await #expect(throws: RPCError.self) {
        try await c.call(ProcessRun(argv: ["/bin/sh", "-c", "head -c \((16 << 20) + 1) /dev/zero"]))
    }
    #expect(try await c.call(ProcessRun(argv: ["/bin/sh", "-c", "head -c 1000 /dev/zero"])).stdout.utf8.count == 1000)
}

/// With PATH given outright (KELP_LOGIN_PATH, as the tests run) there's no login shell to read again: it stays.
@Test func refreshingThePathKeepsOneGivenOutright() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let before = LoginPath.value
    _ = try await c.call(ProcessRefreshPath())
    #expect(LoginPath.value == before)
}
