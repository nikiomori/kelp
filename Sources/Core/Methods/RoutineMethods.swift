import Foundation

/// An agent on a schedule. At the scheduled time, the daemon starts `agent` with `prompt` in the routine's own
/// workspace (in the project's folder, made at its first run), and records how each run went.
public struct Routine: Codable, Sendable, Equatable, Identifiable {
    public enum Every: String, Codable, Sendable, CaseIterable { case hourly, daily, weekdays, weekly }
    /// Empty for a new routine, which routine.set gives an id.
    public var id: String
    public var name: String
    public var repoId: String
    public var agent: String
    public var model: String?
    public var prompt: String
    public var every: Every
    /// Minutes after midnight, or for an hourly routine, minutes past the hour.
    public var time: Int
    /// For a weekly routine, 1 (Sunday) to 7 (Saturday), as Calendar counts.
    public var weekday: Int
    public var enabled: Bool
    /// What happens to a run missed while the Mac slept or Kelp wasn't running. True runs it once when Kelp is back,
    /// and false skips it.
    public var onWake: Bool
    /// The routine's workspace, once it has run.
    public var worktreeId: String?
    /// Due times up to this date are handled: run, missed, or from before the routine was on.
    public var checked: Date
    public var createdAt: Date

    public init(
        id: String = "", name: String, repoId: String, agent: String, model: String? = nil, prompt: String,
        every: Every = .weekdays,
        time: Int = 9 * 60, weekday: Int = 2, enabled: Bool = true, onWake: Bool = true, worktreeId: String? = nil,
        checked: Date = Date(), createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.repoId = repoId
        self.agent = agent
        self.model = model
        self.prompt = prompt
        self.every = every
        self.time = time
        self.weekday = weekday
        self.enabled = enabled
        self.onWake = onWake
        self.worktreeId = worktreeId
        self.checked = checked
        self.createdAt = createdAt
    }

    /// One run: the agent's session, and how it went.
    public struct Run: Codable, Sendable, Equatable, Identifiable {
        public enum Outcome: String, Codable, Sendable, CaseIterable {
            case running
            /// The agent waits for an answer (a permission, a question), and `summary` is what it asks.
            case asked
            case done, failed
            /// The run was due while the Mac slept or Kelp wasn't running, and the routine skips such runs.
            case missed
        }
        public var id: String
        public var routineId: String
        public var sessionId: String?
        /// When the run was due, or for Run Now, when it was asked for.
        public var due: Date
        public var started: Date
        public var ended: Date?
        public var outcome: Outcome
        /// The agent's first line when done, what it asks, or why it failed.
        public var summary: String
        public init(
            id: String = UUID().uuidString, routineId: String, sessionId: String? = nil, due: Date,
            started: Date = Date(),
            ended: Date? = nil, outcome: Outcome = .running, summary: String = ""
        ) {
            self.id = id
            self.routineId = routineId
            self.sessionId = sessionId
            self.due = due
            self.started = started
            self.ended = ended
            self.outcome = outcome
            self.summary = summary
        }
        /// True when the run started well after it was due, because the Mac slept or Kelp wasn't running.
        public var late: Bool { started.timeIntervalSince(due) > Routine.lateAfter }
    }

    /// A due time this long past counts as missed, not just reached.
    public static let lateAfter: TimeInterval = 120

    /// Returns the first time the routine is due after `date`. The same function plans the runs and draws the week
    /// ahead.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        let at = DateComponents(
            hour: every == .hourly ? nil : time / 60, minute: time % 60, weekday: every == .weekly ? weekday : nil)
        var cursor = date
        for _ in 0..<7 {   // For weekdays, this skips at most a Saturday and a Sunday.
            guard let due = calendar.nextDate(after: cursor, matching: at, matchingPolicy: .nextTime) else {
                return nil
            }
            let day = calendar.component(.weekday, from: due)
            if every != .weekdays || (day != 1 && day != 7) { return due }
            cursor = due
        }
        return nil
    }

    /// Returns the due times after `from`, up to and including `to`.
    public func times(after from: Date, through to: Date, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = [], cursor = from
        while out.count < 400, let due = next(after: cursor, calendar: calendar), due <= to {
            out.append(due)
            cursor = due
        }
        return out
    }
}

/// Every routine and its runs of the last two weeks, newest run first. It is routine.list's answer, and is sent as
/// `event.routines` whenever a routine changes.
public struct RoutinesEvent: RPCEvent, Equatable {
    public static let name = "event.routines"
    public var routines: [Routine], runs: [Routine.Run]
    public init(routines: [Routine], runs: [Routine.Run]) {
        self.routines = routines
        self.runs = runs
    }
}

/// Lists all routines and their recent runs.
public struct RoutineList: InternalMethod {
    public static let name = "routine.list"
    public typealias Result = RoutinesEvent
    public init() {}
}

/// Adds the routine (when it has no id) or changes it. A new routine, one switched on, and one with a new schedule all
/// count from now, so nothing due before is run.
public struct RoutineSet: InternalMethod {
    public static let name = "routine.set"
    public typealias Result = Routine
    /// A new routine from an agent asks the user first, on the agent's row, for up to ten minutes; the user's own
    /// routine is saved at once.
    public static let answerWithin: TimeInterval = 600
    public static var timeout: TimeInterval? { answerWithin + 60 }
    public var routine: Routine
    public init(routine: Routine) { self.routine = routine }
}

/// Deletes the routine and its runs. Its workspace and the runs' sessions stay.
public struct RoutineDelete: InternalMethod {
    public static let name = "routine.delete"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}

/// Runs the routine now, off schedule (Run Now).
public struct RoutineRun: InternalMethod {
    public static let name = "routine.run"
    public typealias Result = Routine.Run
    public var id: String
    public init(id: String) { self.id = id }
}
