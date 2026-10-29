import Foundation

/// An agent on a schedule: at its time the daemon starts `agent` with `prompt` in the routine's own workspace (a desk in
/// the project's folder, made at its first run), and keeps how each run went.
public struct Routine: Codable, Sendable, Equatable, Identifiable {
    public enum Every: String, Codable, Sendable, CaseIterable { case hourly, daily, weekdays, weekly }
    /// Empty: a new one (routine.set gives it an id).
    public var id: String
    public var name: String
    public var repoId: String
    public var agent: String
    public var model: String?
    public var prompt: String
    public var every: Every
    /// Minutes after midnight; hourly: minutes past the hour.
    public var time: Int
    /// Weekly: 1 Sunday … 7 Saturday, as Calendar counts.
    public var weekday: Int
    public var enabled: Bool
    /// A run missed while the Mac slept or Kelp wasn't running: once when it's back (true), or skipped.
    public var onWake: Bool
    /// Its workspace, once it ran.
    public var worktreeId: String?
    /// Due times up to here are handled: run, missed, or before the routine was on.
    public var checked: Date
    public var createdAt: Date

    public init(id: String = "", name: String, repoId: String, agent: String, model: String? = nil, prompt: String, every: Every = .weekdays,
                time: Int = 9 * 60, weekday: Int = 2, enabled: Bool = true, onWake: Bool = true, worktreeId: String? = nil,
                checked: Date = Date(), createdAt: Date = Date()) {
        self.id = id; self.name = name; self.repoId = repoId; self.agent = agent; self.model = model; self.prompt = prompt
        self.every = every; self.time = time; self.weekday = weekday; self.enabled = enabled; self.onWake = onWake
        self.worktreeId = worktreeId; self.checked = checked; self.createdAt = createdAt
    }

    /// One run: its agent's session, and how it went.
    public struct Run: Codable, Sendable, Equatable, Identifiable {
        public enum Outcome: String, Codable, Sendable {
            case running
            /// The agent waits for an answer (a permission, a question): `summary` is what it asks.
            case asked
            case done, failed
            /// Due while the Mac slept or Kelp wasn't running, and the routine skips those.
            case missed
        }
        public var id: String
        public var routineId: String
        public var sessionId: String?
        /// When it was due; Run Now: when it was asked for.
        public var due: Date
        public var started: Date
        public var ended: Date?
        public var outcome: Outcome
        /// The agent's first line when done, what it asks, why it failed.
        public var summary: String
        public init(id: String = UUID().uuidString, routineId: String, sessionId: String? = nil, due: Date, started: Date = Date(),
                    ended: Date? = nil, outcome: Outcome = .running, summary: String = "") {
            self.id = id; self.routineId = routineId; self.sessionId = sessionId; self.due = due; self.started = started
            self.ended = ended; self.outcome = outcome; self.summary = summary
        }
        /// Started well after it was due: the Mac slept, or Kelp wasn't running.
        public var late: Bool { started.timeIntervalSince(due) > Routine.lateAfter }
    }

    /// A due time this long gone was missed, not just reached.
    public static let lateAfter: TimeInterval = 120

    /// The first time it's due after `date`. The same function plans the runs and draws the week ahead.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        let at = DateComponents(hour: every == .hourly ? nil : time / 60, minute: time % 60, weekday: every == .weekly ? weekday : nil)
        var d = date
        for _ in 0..<7 {   // weekdays: past a Saturday and a Sunday at most
            guard let n = calendar.nextDate(after: d, matching: at, matchingPolicy: .nextTime) else { return nil }
            let day = calendar.component(.weekday, from: n)
            if every != .weekdays || (day != 1 && day != 7) { return n }
            d = n
        }
        return nil
    }

    /// The due times after `from`, up to and including `to`.
    public func times(after from: Date, through to: Date, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = [], d = from
        while out.count < 400, let n = next(after: d, calendar: calendar), n <= to { out.append(n); d = n }
        return out
    }
}

/// Every routine and their runs of the last two weeks, newest run first: routine.list's answer, and `event.routines`,
/// sent whenever one of them changes.
public struct RoutinesEvent: RPCEvent, Equatable {
    public static let name = "event.routines"
    public var routines: [Routine], runs: [Routine.Run]
    public init(routines: [Routine], runs: [Routine.Run]) { self.routines = routines; self.runs = runs }
}

public struct RoutineList: RPCMethod {
    public static let name = "routine.list"; public typealias Result = RoutinesEvent
    public init() {}
}

/// Adds the routine (no id) or changes it. A new one, one switched on and one with a new schedule count from now:
/// nothing before is run.
public struct RoutineSet: RPCMethod {
    public static let name = "routine.set"; public typealias Result = Routine
    public var routine: Routine
    public init(routine: Routine) { self.routine = routine }
}

/// The routine and its runs; its workspace and their sessions stay.
public struct RoutineDelete: RPCMethod {
    public static let name = "routine.delete"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}

/// Runs it now, off schedule (Run Now).
public struct RoutineRun: RPCMethod {
    public static let name = "routine.run"; public typealias Result = Routine.Run
    public var id: String
    public init(id: String) { self.id = id }
}
