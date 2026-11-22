import Core
import Foundation

extension Main {
    /// Runs `session …`, `terminal …`, `wait`, `why` and `report`.
    static func sessions(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("session", "new"):
            // First, so a value such as `--arg --oss` isn't read as a flag of its own.
            let extra = all("--arg"), env = variables(all("--env"))
            let wait = has("--wait"), split = flag("--split"), outlive = has("--outlive")
            var request = SessionCreate(
                agent: flag("--agent"), command: flag("--cmd"), model: flag("--model"), prompt: flag("--prompt"),
                title: flag("--title"))
            (request.env, request.args) = (env.isEmpty ? nil : env, extra.isEmpty ? nil : extra)
            // Inside an agent, an agent it starts becomes its child, and a command goes on its line, split or not.
            // Agents keep asking for a split out of habit, and the line exists to spare a pane. The daemon ignores this
            // for anything else.
            if !outlive { request.parent = ProcessInfo.processInfo.environment["KELP_SESSION"] }
            // A session outside every workspace would run where no tab or sidebar row shows it.
            if let ref = flag("--worktree") {
                request.worktreeId = try await workspace(c, ref)
            } else if let worktree = try await worktreeHere(c) {
                request.worktreeId = worktree.id
            } else {
                fail(
                    "not inside a Kelp project: run it in a project's folder or pass --worktree <id> (see `kelp status`)"
                )
            }
            let session = try await c.call(request), id = session.id
            // Open the session's tab beside yours. Without the app it runs all the same, and its row shows once the app
            // opens.
            if let split, session.startedBy == nil {
                _ = try? await IDE.open(
                    "session:\(id)", split: split, cwd: FileManager.default.currentDirectoryPath, client: c)
            }
            guard wait else {
                show(try .from(session))
                return
            }
            print(id)   // For `kelp terminal read`, once it ends.
            exit(Int32(try await waitFor(c, id, timeout: nil) { $0.status == .exited }?.exitCode ?? 1))
        case ("session", "list"), ("terminal", "list"): show(try await c.call(SessionList()))
        case ("wait", let target?):   // Waits for the session to stop working or reach a --for state; prints it.
            let want = flag("--for").map { Set($0.split(separator: ",").map(String.init)) },
                timeout = flag("--timeout").map(duration)
            let id = try await session(c, target)
            guard
                let session = try await waitFor(
                    c, id, timeout: timeout, until: { want?.contains($0.status.rawValue) ?? ($0.status != .working) })
            else { fail("timed out") }
            print(session.status.rawValue)
            if session.status == .exited { exit(Int32(session.exitCode ?? 0)) }   // The command's exit code.
        case ("wait", nil):
            guard let how = flag("--children"), ["all", "any"].contains(how),
                let me = ProcessInfo.processInfo.environment["KELP_SESSION"]
            else {
                fail("wait --children all|any, inside an agent")
            }
            let kids = try await waitChildren(c, of: me, all: how == "all", timeout: flag("--timeout").map(duration))
            kids.forEach { print($0.id.prefix(8), $0.displayTitle, "·", $0.status.rawValue) }
        case ("why", let target?):
            let id = try await session(c, target)
            let why = try await c.call(SessionWhy(id: id)),
                trail = try await c.call(SessionTrail(id: id)).split(separator: "\n")
            guard why != nil || !trail.isEmpty else { fail("session \(id) isn't running") }
            print(why ?? "not running")
            trail.suffix(has("--all") ? trail.count : 30).forEach { print($0) }
        case ("report", let state?):   // Inside a session: what this program does, shown on its row and tab.
            guard let id = ProcessInfo.processInfo.environment["KELP_SESSION"] else {
                fail("report: run it inside a Kelp session")
            }
            let progress = flag("--progress").flatMap { Int($0) }, kind = flag("--kind"),
                msg = args.joined(separator: " ")
            _ = try await c.call(
                SessionReport(id: id, state: state, message: msg.isEmpty ? nil : msg, progress: progress, kind: kind))
        case ("terminal", "read"):
            show(
                try await c.call(
                    SessionRead(
                        id: try await session(c, args.first ?? ""),
                        bytes: args.dropFirst().first.flatMap(Int.init) ?? 8192)))
        case ("terminal", "send"):
            let enter = !has("--no-enter")
            guard args.count >= 2 else { fail("terminal send <session> <text>") }
            let id = try await session(c, args[0])
            show(try await c.call(SessionSend(id: id, text: args.dropFirst().joined(separator: " "), enter: enter)))
        case ("session", "restart"):
            show(
                try .from(try await c.call(SessionRestart(id: try await session(c, args.first ?? "")))))
        case ("session", "rename"):
            _ = try await c.call(
                SessionRename(
                    id: try await session(c, args.first ?? ""),
                    title: args.dropFirst().joined(separator: " ")))
        case ("session", "handoff"):
            show(
                try .from(
                    try await c.call(
                        SessionHandoff(
                            id: try await session(c, args.first ?? ""), agent: flag("--agent")))))
        case ("terminal", "context"):
            show(try await c.call(SessionContext(id: try await session(c, args.first ?? ""))))
        default: print(usage)
        }
    }

    /// Checks the session twice a second until `done` returns true, or the session ended or was paused, because it
    /// can't change then. Returns nil when `timeout` ran out first.
    static func waitFor(_ client: RPCClient, _ id: String, timeout: TimeInterval?, until done: (Session) -> Bool)
        async throws -> Session?
    {
        let end = timeout.map { Date().addingTimeInterval($0) }
        while true {
            guard let session = try await client.call(SessionList()).first(where: { $0.id == id }) else {
                fail("no session \(id)")
            }
            if done(session) || session.status == .exited || session.status == .paused { return session }
            if let end, Date() > end { return nil }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Waits until all of this agent's working children have stopped, or with `all` false, until one of them has. It
    /// fails when there are none to wait for. Only children that haven't stopped yet count, so a report read earlier
    /// doesn't end the wait at once.
    static func waitChildren(_ client: RPCClient, of me: String, all: Bool, timeout: TimeInterval?) async throws
        -> [Session]
    {
        func stopped(_ session: Session) -> Bool { ![.working, .idle].contains(session.status) }
        func kids() async throws -> [Session] { try await client.call(SessionList()).filter { $0.parent == me } }
        let watched = Set(try await kids().filter { !stopped($0) }.map(\.id))
        guard !watched.isEmpty else { fail("no children working") }
        let end = timeout.map { Date().addingTimeInterval($0) }
        while true {
            let now = try await kids().filter { watched.contains($0.id) }
            let over = now.filter(stopped)
            if all ? over.count == now.count : !over.isEmpty || now.count < watched.count { return over }   // one closed has stopped too
            if let end, Date() > end { fail("timed out") }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Converts "90", "30s", "10m" or "1h" into seconds.
    static func duration(_ text: String) -> TimeInterval {
        let unit = ["s": 1.0, "m": 60, "h": 3600][String(text.suffix(1))]
        guard let amount = Double(unit == nil ? text : String(text.dropLast())) else {
            fail("bad duration \(text): use 30s, 10m or 1h")
        }
        return amount * (unit ?? 1)
    }
}
