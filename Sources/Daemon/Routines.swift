import Foundation
import os
import GRDB
import Core

/// Routines (routine.*): agents on a schedule. A 10-second clock runs each due time once — a changed clock, a sleep or a
/// daemon that wasn't running all come down to "the due times since `checked`": the last of them runs, or is recorded as
/// missed when it's long gone and the routine skips those. A run is a session in the routine's own workspace; its outcome
/// follows the session's status. Everything here happens on one queue: a tick and a Run Now can't both start a run.
final class Routines: Sendable {
    let store: Store
    let sessions: Sessions
    let clients: Clients
    /// A routine's last runs keep their tabs; older ones close when a new one starts.
    static let keepRuns = 5
    private let queue = DispatchQueue(label: "kelp.routines")
    private let clock = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)

    init(store: Store, sessions: Sessions, clients: Clients) {
        self.store = store
        self.sessions = sessions
        self.clients = clients
    }

    /// The clock; `desks` makes a routine's workspace at its first run.
    func start(desks: Workspaces) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 10)
        t.setEventHandler { [weak self, weak desks] in if let desks { self?.step(Date(), desks: desks) } }
        clock.withLock { $0?.cancel(); $0 = t }
        t.resume()
    }

    func stop() { clock.withLock { $0?.cancel(); $0 = nil } }

    func list(now: Date = Date()) throws -> RoutinesEvent {
        try store.db.read { d in
            RoutinesEvent(routines: try Routine.order(Column("createdAt")).fetchAll(d),
                          runs: try Routine.Run.filter(Column("started") > now.addingTimeInterval(-14 * 86400)).order(Column("started").desc).fetchAll(d))
        }
    }

    private func changed() {
        guard let e = Log.store.attempt("reading routines", { try list() }) else { return }
        clients.notify(e)
    }

    /// A tick of the clock now (tests).
    func tick(desks: Workspaces, now: Date = Date()) { queue.sync { step(now, desks: desks) } }

    private func step(_ now: Date, desks: Workspaces) {
        var told = false
        Log.store.attempt("running routines") {
            for r in try store.db.read({ try Routine.filter(Column("enabled") == true).fetchAll($0) }) {
                guard let last = r.times(after: r.checked, through: now).last else { continue }
                try store.update(Routine.self, r.id) { $0.checked = now }
                told = true
                if now.timeIntervalSince(last) > Routine.lateAfter && !r.onWake {
                    try store.save(Routine.Run(routineId: r.id, due: last, started: now, ended: now, outcome: .missed))
                } else if try open(r.id) == nil {   // still at the last one: this one is skipped
                    try begin(r, due: last, now: now, desks: desks)
                }
            }
            for run in try store.db.read({ try Routine.Run.filter(Self.isOpen).fetchAll($0) }) where try follow(run) { told = true }
        }
        if told { changed() }
    }

    /// Adds or changes one. A new one, one switched on and one with a new schedule count from now.
    func set(_ new: Routine) throws -> Routine {
        guard try store.repo(new.repoId) != nil else { throw RPCError.invalidParams("no project \(new.repoId)") }
        guard !new.name.trimmingCharacters(in: .whitespaces).isEmpty, !new.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !new.agent.isEmpty else { throw RPCError.invalidParams("A routine needs a name, an agent and a prompt.") }
        guard (0..<1440).contains(new.time), (1...7).contains(new.weekday) else { throw RPCError.invalidParams("no such time") }
        return try queue.sync {
            var r = new
            let old = try new.id.isEmpty ? nil : store.db.read { try Routine.fetchOne($0, key: new.id) }
            if let old {
                let rescheduled = (old.every, old.time, old.weekday) != (r.every, r.time, r.weekday) || !old.enabled && r.enabled
                r.checked = rescheduled ? Date() : old.checked
                r.worktreeId = old.worktreeId; r.createdAt = old.createdAt
            } else {
                (r.id, r.worktreeId) = (UUID().uuidString, nil)
                (r.checked, r.createdAt) = (Date(), Date())
            }
            try store.save(r)
            changed()
            return r
        }
    }

    func delete(_ id: String) throws {
        try queue.sync {
            guard let r = try store.db.read({ try Routine.fetchOne($0, key: id) }) else { return }
            try store.delete(r)
            changed()
        }
    }

    func runNow(_ id: String, desks: Workspaces) throws -> Routine.Run {
        try queue.sync {
            guard let r = try store.db.read({ try Routine.fetchOne($0, key: id) }) else { throw RPCError.invalidParams("no routine \(id)") }
            guard try open(id) == nil else { throw RPCError.invalidParams("\(r.name) is running now.") }
            let run = try begin(r, due: Date(), now: Date(), desks: desks)
            changed()
            return run
        }
    }

    private static let isOpen = [Routine.Run.Outcome.running, .asked].map(\.rawValue).contains(Column("outcome"))

    private func open(_ routine: String) throws -> Routine.Run? {
        try store.db.read { try Routine.Run.filter(Column("routineId") == routine && Self.isOpen).fetchOne($0) }
    }

    /// The agent, with the prompt, in the routine's workspace: "Morning triage · Oct 29".
    @discardableResult
    private func begin(_ r: Routine, due: Date, now: Date, desks: Workspaces) throws -> Routine.Run {
        let w = try workspace(r, desks: desks)
        let s = try SessionCreate(worktreeId: w.id, agent: r.agent, model: r.model, prompt: r.prompt,
                                  title: "\(r.name) · \(due.formatted(.dateTime.month(.abbreviated).day()))").handle(sessions)
        let run = try store.save(Routine.Run(routineId: r.id, sessionId: s.id, due: due, started: now))
        closeOld(r.id)
        return run
    }

    /// Its own desk in the project's folder, named after it: made at its first run, again if it was removed.
    private func workspace(_ r: Routine, desks: Workspaces) throws -> Worktree {
        if let id = r.worktreeId, let w = try store.worktree(id), !w.archived { return w }
        guard let repo = try store.repo(r.repoId) else { throw RPCError.invalidParams("no project \(r.repoId)") }
        let desk = try desks.createDesk(in: repo)
        let w = try store.update(Worktree.self, desk.id) { $0.note = r.name } ?? desk
        try store.update(Routine.self, r.id) { $0.worktreeId = w.id }
        return w
    }

    /// The runs past the last few close their tabs, unless their agent works or waits for an answer still.
    private func closeOld(_ routine: String) {
        Log.store.attempt("closing a routine's old runs") {
            let runs = try store.db.read { try Routine.Run.filter(Column("routineId") == routine).order(Column("started").desc).fetchAll($0) }
            let old = try runs.dropFirst(Self.keepRuns).compactMap { try $0.sessionId.flatMap(store.session) }
                .filter { ![.working, .waiting].contains($0.status) }
            if !old.isEmpty { sessions.discard(old) }
        }
    }

    /// The run as its session is now; true when that changed it.
    private func follow(_ run: Routine.Run) throws -> Bool {
        var r = run
        // The live one when it runs: its status is saved a moment later.
        let s = try run.sessionId.flatMap { id in try sessions.existing(id)?.snapshot ?? store.session(id) }
        switch s?.status {
        case .working?, .idle?: r.outcome = .running
        case .waiting?: (r.outcome, r.summary) = (.asked, s?.summary ?? "")
        case .done?: (r.outcome, r.ended, r.summary) = (.done, s?.statusAt ?? Date(), s.map(reply) ?? "")
        case .error?: (r.outcome, r.ended, r.summary) = (.failed, s?.statusAt ?? Date(), s?.summary ?? "")
        case .exited?, .hibernated?, nil: (r.outcome, r.ended, r.summary) = (.failed, Date(), String(localized: "The agent ended before it finished"))
        }
        guard r != run else { return false }
        try store.save(r)
        return true
    }

    /// The first line of the agent's last reply (Claude Code), else what its row says.
    private func reply(_ s: Session) -> String {
        let text = sessions.existing(s.id).flatMap(sessions.agentUsage.transcript(of:)).flatMap(AgentUsage.lastReply(transcript:))
        let line = text?.split(whereSeparator: \.isNewline).first.map { $0.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces) }
        return String((line ?? s.summary).prefix(200))
    }
}
