import Foundation
import Core

extension Main {
    /// `session …`, `terminal …`, `wait`, `why`, `report`.
    static func sessions(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("session", "new"):
            let wait = has("--wait"), split = flag("--split")
            var p = SessionCreate(agent: flag("--agent"), command: flag("--cmd"))
            // A session outside every workspace would run where no tab or sidebar row shows it.
            if let w = flag("--worktree") { p.worktreeId = try await resolve(c, w, "worktree.list") }
            else if let w = try? await currentWorktree(c) { p.worktreeId = w.id }
            else { fail("not inside a Kelp project: run it in a project's folder or pass --worktree <id> (see `kelp status`)") }
            let s = try await c.call(p), id = s.id
            // Its tab beside yours; without the app it runs all the same (its row shows once the app opens).
            if let split { _ = try? await IDE.open("session:\(id)", split: split, cwd: FileManager.default.currentDirectoryPath, client: c) }
            guard wait else { show(try .from(s)); return }
            print(id)   // for `kelp terminal read`, once it ends
            exit(Int32(try await waitFor(c, id, timeout: nil) { $0.status == .exited }?.exitCode ?? 1))
        case ("session", "list"), ("terminal", "list"): show(try await c.call(SessionList()))
        case ("wait", let target?):   // until the session stops working, or reaches one of --for; prints the state it reached
            let want = flag("--for").map { Set($0.split(separator: ",").map(String.init)) }, timeout = flag("--timeout").map(duration)
            let id = try await resolve(c, target, "session.list")
            guard let s = try await waitFor(c, id, timeout: timeout, until: { want?.contains($0.status.rawValue) ?? ($0.status != .working) })
            else { fail("timed out") }
            print(s.status.rawValue)
            if s.status == .exited { exit(Int32(s.exitCode ?? 0)) }   // its command's exit code
        case ("why", let target?):
            let id = try await resolve(c, target, "session.list")
            let why = try await c.call(SessionWhy(id: id)), trail = try await c.call(SessionTrail(id: id)).split(separator: "\n")
            guard why != nil || !trail.isEmpty else { fail("session \(id) isn't running") }
            print(why ?? "not running")
            trail.suffix(has("--all") ? trail.count : 30).forEach { print($0) }
        case ("report", let state?):   // inside a session: what this program is doing, on its row and tab
            guard let id = ProcessInfo.processInfo.environment["KELP_SESSION"] else { fail("report: run it inside a Kelp session") }
            let progress = flag("--progress").flatMap { Int($0) }, kind = flag("--kind"), msg = args.joined(separator: " ")
            _ = try await c.call(SessionReport(id: id, state: state, message: msg.isEmpty ? nil : msg, progress: progress, kind: kind))
        case ("terminal", "read"):
            show(try await c.call(SessionRead(id: try await resolve(c, args.first ?? "", "session.list"),
                                              bytes: args.dropFirst().first.flatMap(Int.init) ?? 8192)))
        case ("terminal", "send"):
            let enter = !has("--no-enter")
            guard args.count >= 2 else { fail("terminal send <session> <text>") }
            let id = try await resolve(c, args[0], "session.list")
            show(try await c.call(SessionSend(id: id, text: args.dropFirst().joined(separator: " "), enter: enter)))
        case ("session", "restart"):
            show(try .from(try await c.call(SessionRestart(id: try await resolve(c, args.first ?? "", "session.list")))))
        case ("session", "rename"):
            _ = try await c.call(SessionRename(id: try await resolve(c, args.first ?? "", "session.list"), title: args.dropFirst().joined(separator: " ")))
        case ("session", "handoff"):
            show(try .from(try await c.call(SessionHandoff(id: try await resolve(c, args.first ?? "", "session.list"), agent: flag("--agent")))))
        case ("terminal", "context"):
            show(try await c.call(SessionContext(id: try await resolve(c, args.first ?? "", "session.list"))))
        default: print(usage)
        }
    }

    /// Looks at the session twice a second until `done` says so, or it ended or was paused (it can't change then);
    /// nil when `timeout` ran out first.
    static func waitFor(_ c: RPCClient, _ id: String, timeout: TimeInterval?, until done: (Session) -> Bool) async throws -> Session? {
        let end = timeout.map { Date().addingTimeInterval($0) }
        while true {
            guard let s = try await c.call(SessionList()).first(where: { $0.id == id }) else { fail("no session \(id)") }
            if done(s) || s.status == .exited || s.status == .hibernated { return s }
            if let end, Date() > end { return nil }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// "90", "30s", "10m", "1h" → seconds.
    static func duration(_ s: String) -> TimeInterval {
        let unit = ["s": 1.0, "m": 60, "h": 3600][String(s.suffix(1))]
        guard let n = Double(unit == nil ? s : String(s.dropLast())) else { fail("bad duration \(s): use 30s, 10m or 1h") }
        return n * (unit ?? 1)
    }
}
