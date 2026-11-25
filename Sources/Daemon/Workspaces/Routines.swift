import Core
import Foundation
import GRDB
import os

/// Routines (routine.*) start agents on a schedule. A clock ticks every 10 seconds and runs each due time once. A
/// changed clock, a sleep or a daemon that wasn't running all come down to the due times that passed since `checked`.
/// The last of those times runs, or it is recorded as missed when it is long past and the routine skips such runs. A
/// run is a session in the routine's own workspace, and the run's outcome follows the session's status. Everything
/// here happens on one queue, so a tick and a Run Now can't both start a run.
final class Routines: Sendable {
    let store: Store
    let sessions: Sessions
    let clients: Clients
    /// How many of a routine's latest runs keep their tabs. Older runs close when a new one starts.
    static let keepRuns = 5
    private let queue = DispatchQueue(label: "kelp.routines")
    private let clock = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)

    init(store: Store, sessions: Sessions, clients: Clients) {
        self.store = store
        self.sessions = sessions
        self.clients = clients
    }

    /// Starts the clock. `workspaces` makes a routine's workspace at its first run.
    func start(workspaces: Workspaces) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 10)
        timer.setEventHandler { [weak self, weak workspaces] in
            if let workspaces { self?.step(Date(), workspaces: workspaces) }
        }
        clock.withLock {
            $0?.cancel()
            $0 = timer
        }
        timer.resume()
    }

    func stop() {
        clock.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    func list(now: Date = Date()) throws -> RoutinesEvent {
        try store.db.read { db in
            RoutinesEvent(
                routines: try Routine.order(Column("createdAt")).fetchAll(db),
                runs: try Routine.Run.filter(Column("started") > now.addingTimeInterval(-14 * 86400)).order(
                    Column("started").desc
                ).fetchAll(db))
        }
    }

    private func changed() {
        guard let event = Log.store.attempt("reading routines", { try list() }) else { return }
        clients.notify(event)
    }

    /// Runs one tick of the clock now, for tests.
    func tick(workspaces: Workspaces, now: Date = Date()) { queue.sync { step(now, workspaces: workspaces) } }

    private func step(_ now: Date, workspaces: Workspaces) {
        var told = false
        Log.store.attempt("running routines") {
            for routine in try store.db.read({ try Routine.filter(Column("enabled") == true).fetchAll($0) }) {
                guard let last = routine.times(after: routine.checked, through: now).last else { continue }
                try store.update(Routine.self, routine.id) { $0.checked = now }
                told = true
                if now.timeIntervalSince(last) > Routine.lateAfter && !routine.onWake {
                    try store.save(
                        Routine.Run(routineId: routine.id, due: last, started: now, ended: now, outcome: .missed))
                } else if try open(routine.id) == nil {   // with the last run still open, this one is skipped
                    // A routine that can't start leaves a failed run that says why. Its due time has passed anyway,
                    // and the other routines are still due.
                    do { try begin(routine, due: last, now: now, workspaces: workspaces) } catch {
                        try store.save(
                            Routine.Run(
                                routineId: routine.id, due: last, started: now, ended: now, outcome: .failed,
                                summary: Self.why(error)))
                    }
                }
            }
            for run in try store.db.read({ try Routine.Run.filter(Self.isOpen).fetchAll($0) }) where try follow(run) {
                told = true
            }
        }
        if told { changed() }
    }

    /// Checks what a routine must have before it is saved or the user is asked about it.
    func check(_ new: Routine) throws {
        guard try store.repo(new.repoId) != nil else { throw RPCError.invalidParams("no project \(new.repoId)") }
        guard !new.name.trimmingCharacters(in: .whitespaces).isEmpty,
            !new.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !new.agent.isEmpty
        else { throw RPCError.invalidParams("A routine needs a name, an agent and a prompt.") }
        guard (0..<1440).contains(new.time), (1...7).contains(new.weekday) else {
            throw RPCError.invalidParams("no such time")
        }
    }

    /// Adds or changes a routine. A new routine, one just switched on and one with a new schedule count their due times
    /// from now.
    func set(_ new: Routine) throws -> Routine {
        try check(new)
        return try queue.sync {
            var routine = new
            let old = try new.id.isEmpty ? nil : store.db.read { try Routine.fetchOne($0, key: new.id) }
            if let old {
                let rescheduled =
                    (old.every, old.time, old.weekday) != (routine.every, routine.time, routine.weekday)
                    || !old.enabled && routine.enabled
                routine.checked = rescheduled ? Date() : old.checked
                routine.worktreeId = old.worktreeId
                routine.createdAt = old.createdAt
            } else {
                (routine.id, routine.worktreeId) = (UUID().uuidString, nil)
                (routine.checked, routine.createdAt) = (Date(), Date())
            }
            try store.save(routine)
            changed()
            return routine
        }
    }

    func delete(_ id: String) throws {
        try queue.sync {
            guard let routine = try store.db.read({ try Routine.fetchOne($0, key: id) }) else { return }
            try store.delete(routine)
            changed()
        }
    }

    func runNow(_ id: String, workspaces: Workspaces) throws -> Routine.Run {
        try queue.sync {
            guard let routine = try store.db.read({ try Routine.fetchOne($0, key: id) }) else {
                throw RPCError.invalidParams("no routine \(id)")
            }
            guard try open(id) == nil else { throw RPCError.invalidParams("\(routine.name) is running now.") }
            let run = try begin(routine, due: Date(), now: Date(), workspaces: workspaces)
            changed()
            return run
        }
    }

    private static let isOpen = [Routine.Run.Outcome.running, .asked].map(\.rawValue).contains(Column("outcome"))

    private func open(_ routine: String) throws -> Routine.Run? {
        try store.db.read { try Routine.Run.filter(Column("routineId") == routine && Self.isOpen).fetchOne($0) }
    }

    /// Starts the routine's agent with its prompt in the routine's workspace, titled like "Morning triage · Oct 29".
    @discardableResult
    private func begin(_ routine: Routine, due: Date, now: Date, workspaces: Workspaces) throws -> Routine.Run {
        let worktree = try workspace(routine, workspaces: workspaces)
        // A remote project's agent starts over ssh in a tab nobody watches, where a host that wants a password would
        // hold the agent at the prompt. So the host is connected first without a password (a key login), or else the
        // run says why it didn't start.
        if let remote = workspaces.remotes.of(worktree.path), remote.connection == nil { try remote.connect() }
        let session = try SessionCreate(
            worktreeId: worktree.id, agent: routine.agent, model: routine.model, prompt: routine.prompt,
            title: "\(routine.name) · \(due.formatted(.dateTime.month(.abbreviated).day()))"
        ).handle(sessions)
        let run = try store.save(Routine.Run(routineId: routine.id, sessionId: session.id, due: due, started: now))
        closeOld(routine.id)
        return run
    }

    /// Returns the routine's own workspace in the project's folder, named after the routine. The workspace is made at
    /// the first run, and made again if it was removed.
    private func workspace(_ routine: Routine, workspaces: Workspaces) throws -> Worktree {
        if let id = routine.worktreeId, let worktree = try store.worktree(id), !worktree.archived { return worktree }
        guard let repo = try store.repo(routine.repoId) else {
            throw RPCError.invalidParams("no project \(routine.repoId)")
        }
        let workspace = try workspaces.createWorkspace(in: repo)
        let worktree = try store.update(Worktree.self, workspace.id) { $0.note = routine.name } ?? workspace
        try store.update(Routine.self, routine.id) { $0.worktreeId = worktree.id }
        return worktree
    }

    static let neverStartedAfter: TimeInterval = 1800
    private static func why(_ error: Error) -> String { (error as? RPCError)?.message ?? error.localizedDescription }

    /// Closes the tabs of the runs older than the latest few, unless the run's agent is still working or waiting for an
    /// answer, or its tab is open.
    private func closeOld(_ routine: String) {
        Log.store.attempt("closing a routine's old runs") {
            let runs = try store.db.read {
                try Routine.Run.filter(Column("routineId") == routine).order(Column("started").desc).fetchAll($0)
            }
            let old = try runs.dropFirst(Self.keepRuns).compactMap { try $0.sessionId.flatMap(store.session) }
                // A session in an open tab is kept. A hidden tab lets go of its terminal, so the layout tells whether
                // the tab is open, not the attachment.
                .filter { session in
                    try ![.working, .waiting].contains(session.status)
                        && sessions.existing(session.id)?.isAttached != true
                        && !store.inALayout("session:" + session.id)
                }
            if !old.isEmpty { sessions.discard(old) }
        }
    }

    /// Updates the run to match its session's current status. Returns true when that changed the run.
    private func follow(_ run: Routine.Run) throws -> Bool {
        var updated = run
        // The live session is read while it runs, because its status is saved to the store a moment later.
        let session = try run.sessionId.flatMap { id in try sessions.existing(id)?.snapshot ?? store.session(id) }
        switch session?.status {
        // The prompt is stuck behind a dialog nobody answers. If the run were left running, every later run would be
        // skipped, and nothing would say so.
        case .idle? where Date().timeIntervalSince(run.started) > Self.neverStartedAfter:
            (updated.outcome, updated.ended, updated.summary) = (
                .failed, Date(), String(localized: "The agent didn't start on it")
            )
        case .working?, .idle?: updated.outcome = .running
        case .waiting?: (updated.outcome, updated.summary) = (.asked, session?.summary ?? "")
        case .done?:
            (updated.outcome, updated.ended, updated.summary) = (
                .done, session?.statusAt ?? Date(), session.map(reply) ?? ""
            )
        case .error?:
            (updated.outcome, updated.ended, updated.summary) = (
                .failed, session?.statusAt ?? Date(), session?.summary ?? ""
            )
        case .exited?, .paused?, nil:
            (updated.outcome, updated.ended, updated.summary) = (
                .failed, Date(), String(localized: "The agent ended before it finished")
            )
        }
        guard updated != run else { return false }
        try store.save(updated)
        return true
    }

    /// Returns the first line of the agent's last reply, or else the summary its row shows.
    private func reply(_ session: Session) -> String {
        let text = sessions.existing(session.id).flatMap(sessions.agentUsage.conversations.lastReply(of:))
        let line = text?.split(whereSeparator: \.isNewline).first.map {
            $0.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        }
        return String((line ?? session.summary).prefix(200))
    }
}

extension RoutineList: Handled {
    static let agents = AgentAccess.reads
    func handle(_ routines: Routines) throws -> RoutinesEvent { try routines.list() }
}

/// A routine starts agents later with nobody at the keys, so the user decides. When an agent adds a routine in the
/// project it works in, the agent's row asks the user (Allow / Deny), the way adding a machine does, with the whole
/// routine in the question. Changing or deleting a routine stays the user's job.
extension RoutineSet: AsyncHandled {
    // An agent may add a routine the user asked for, as a new one in the agent's project, and it is added only once
    // the user allows it on the agent's row. Changing, running and deleting routines stay the user's.
    static let agents = AgentAccess.acts
    static let theUsers =
        "A routine is the user's to change or delete: in Kelp's window (Routines), or `kelp routine` in a terminal of theirs."
    /// The longest name and prompt an agent's routine may have, which is what the card beside Allow shows whole
    /// (`StripModel.permission`).
    /// Limit: a prompt in wide letters (Chinese, Japanese) near this length is cut off on the card, and the user reads
    /// it whole on the row.
    static let asked = (name: 40, prompt: 200)

    var fence: Fence {
        Fence(notForAgents: routine.id.isEmpty ? nil : Self.theUsers, makesInProject: routine.repoId)
    }

    func handle(_ routines: Routines, conn: Int) async throws -> Routine {
        let sessions = routines.sessions
        if case .some(let session) = routines.store.agent(origin: Sessions.asker) {
            guard let session, let ls = sessions.existing(session) else {
                throw RPCError.refused("A routine is the user's to add: tell them `kelp routine add` makes one.")
            }
            try routines.check(routine)   // the user isn't asked about a routine that can't be saved
            guard routine.name.count <= Self.asked.name, routine.prompt.count <= Self.asked.prompt else {
                throw RPCError.invalidParams(
                    "The user reads all of an agent's routine before allowing it: a name of up to \(Self.asked.name) "
                        + "characters, a prompt of up to \(Self.asked.prompt). Put longer instructions in a file of "
                        + "the project and name it in the prompt.")
            }
            let who = try sessions.setup.manifest(routine.agent, command: nil).name
            let question = Self.question(routine, agent: who)
            let answer = await sessions.permissions.waitForKelp(
                ls, question: question, within: Self.answerWithin,
                asker: routines.clients.connection(conn)?.peerPID)
            guard answer == "allow" else {
                throw RPCError.refused(
                    answer == "deny"
                        ? "The user didn't allow the routine \(routine.name)."
                        : "Nobody answered: \(routine.name) wasn't added.")
            }
        }
        return try await sessions.offloads.run { [self] in try routines.set(routine) }
    }

    /// Returns the question the agent's row asks, with all of the routine in it, for example
    /// "Allow a routine, Morning triage: “Label the new issues.” (Claude Code, weekdays at 9:00)?".
    static func question(_ routine: Routine, agent: String) -> String {
        func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let minute = String(format: "%02d", routine.time % 60), at = "\(routine.time / 60):\(minute)"
        var english = Calendar(identifier: .gregorian)
        english.locale = Locale(identifier: "en_US")
        let when =
            switch routine.every {
            case .hourly: "every hour at :\(minute)"
            case .daily: "every day at \(at)"
            case .weekdays: "weekdays at \(at)"
            case .weekly: "\(english.weekdaySymbols[routine.weekday - 1])s at \(at)"
            }
        let who = [agent, routine.model].compactMap { $0 }.joined(separator: " ")
        return "Allow a routine, \(oneLine(routine.name)): “\(oneLine(routine.prompt))” (\(who), \(when))?"
    }
}

extension RoutineDelete: Handled {
    var fence: Fence { Fence(notForAgents: RoutineSet.theUsers) }
    func handle(_ routines: Routines) throws -> Done {
        try routines.delete(id)
        return Done()
    }
}

extension RoutineRun: Handled {
    func handle(_ workspaces: Workspaces) throws -> Routine.Run {
        try workspaces.routines.runNow(id, workspaces: workspaces)
    }
}

extension Methods {
    static let routineMethods: [any Answered.Type] = [
        RoutineList.self, RoutineSet.self, RoutineDelete.self, RoutineRun.self
    ]
}
