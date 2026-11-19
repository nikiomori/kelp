import Core
import Foundation
import TestSupport
import Testing

@testable import Daemon

/// The next edit's llama-server from start to stop, with a stand-in that answers /health as llama-server does once
/// its model is in (or never does), and notes its pid beside it.
struct NextEditServerTests {
    struct StandIn {
        let command: String, notes: URL
        /// The stand-in's pid, once it has started.
        var pid: pid_t? { String(contentsIfAny: notes.appendingPathComponent("pid")).flatMap { pid_t($0) } }
    }

    static func standIn(healthy: Bool) throws -> StandIn {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("next-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("llama-server")
        let body =
            healthy
            ? """
            #!/usr/bin/env python3
            import os, sys, http.server
            open(os.path.join(os.path.dirname(sys.argv[0]), "pid"), "w").write(str(os.getpid()))
            port = int(sys.argv[sys.argv.index("--port") + 1])
            class Health(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200 if self.path == "/health" else 404)
                    self.end_headers()
                def log_message(self, *args):
                    pass
            http.server.HTTPServer(("127.0.0.1", port), Health).serve_forever()
            """
            : "#!/bin/sh\nprintf %s $$ > \"$(dirname \"$0\")/pid\"\nexec sleep 600\n"   // never has its model in
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return StandIn(command: script.path, notes: folder)
    }

    /// A start of the healthy stand-in that hangs ends in a failed answer the test reports, not in a silent wait till
    /// the product's 15 minutes run out.
    static let startLimit = Duration.seconds(10 * testSlowness)

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 && !Subprocess.isZombie(pid) }

    @Test func itStartsAndGoesWhenUnaskedOrStopped() async throws {
        let stand = try Self.standIn(healthy: true)
        let server = NextEditServer(
            command: stand.command, idleDelay: .milliseconds(300), startLimit: Self.startLimit, notes: stand.notes)
        #expect(await server.start(Slots(1)) == SuggestAnswer())
        let first = try #require(stand.pid)
        try await waitFor { !Self.alive(first) }   // unasked for its idle delay: stopped
        try FileManager.default.removeItem(at: stand.notes.appendingPathComponent("pid"))
        #expect(await server.start(Slots(1)) == SuggestAnswer())
        let second = try #require(stand.pid)
        server.stop(now: true)
        #expect(!Self.alive(second))
    }

    @Test func aMemoryWarningStopsItAndNoAskStartsItTillMemoryIsBack() async throws {
        let stand = try Self.standIn(healthy: true)
        let server = NextEditServer(command: stand.command, startLimit: Self.startLimit, notes: stand.notes)
        #expect(await server.start(Slots(1)) == SuggestAnswer())
        let pid = try #require(stand.pid)
        server.memory(.warning)
        try await waitFor { !Self.alive(pid) }
        #expect(!server.mayStartUnasked())
        server.memory(.normal)
        #expect(server.mayStartUnasked())
    }

    /// Without the start's deadline this one never ends: the limit is wide, as under Thread Sanitizer in CI a daemon
    /// test can wait minutes for a thread before it runs.
    @Test(.timeLimit(minutes: 5)) func aStartThatTakesTooLongIsEndedAndNotTriedAgainAtOnce() async throws {
        let stand = try Self.standIn(healthy: false)
        let server = NextEditServer(
            command: stand.command, startLimit: .milliseconds(700), retryDelay: 3600, notes: stand.notes)
        #expect(await server.start(Slots(1)).problem == .failed)
        let pid = try #require(stand.pid)
        try await waitFor { !Self.alive(pid) }
        #expect(!server.mayStartUnasked())   // an ask doesn't start it again at each pause in typing
        let missing = NextEditServer(command: "kelp-no-such-server", retryDelay: 0, notes: nil)
        #expect(await missing.start(Slots(1)).problem == .noServer)
        #expect(missing.mayStartUnasked())   // once the delay is over, it does
    }

    @Test func aServerLeftByAKelpdThatDiedIsEndedAtTheNextStart() async throws {
        let notes = FileManager.default.temporaryDirectory.appendingPathComponent("next-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let left = Process()
        left.executableURL = URL(fileURLWithPath: "/bin/sleep")
        left.arguments = ["600"]
        try left.run()
        let pid = left.processIdentifier
        try "\(pid) \(Subprocess.started(pid) ?? 0)".write(
            to: VMFolder(notes).child(NextEditServer.note), atomically: true, encoding: .utf8)
        let server = NextEditServer(command: "kelp-no-such-server", notes: notes)
        #expect(await server.start(Slots(1)).problem == .noServer)
        try await waitFor { !left.isRunning }
    }
}
