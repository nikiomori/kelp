import Foundation
import Core
import Agents

/// What an agent's hooks do to its session (`SessionHook`): its status, a Stop's verdict, its tools and commands.
extension LiveSession {
    /// Whether a hook that ran at `at` is the latest heard, or nothing says it isn't (a caller that doesn't send the time).
    /// `says`: it says what the status is. A tool's hook doesn't, and it runs side by side with AskUserQuestion's own for the
    /// same event: taken for the latest, it dropped that one, and the row kept asking.
    func newest(_ at: TimeInterval?, says: Bool) -> Bool {
        state.withLock { s in
            s.spoke()
            guard let at else { return true }
            // The same time twice: a hook sent again when the daemon went away with its reply, already counted.
            guard says ? at > s.newestHook : at >= s.newestHook else { return false }
            if says { s.newestHook = at }
            return true
        }
    }

    /// `State.hook`: the record goes out when its status or what the row says changed. `at`: checked again here, in the lock
    /// the change is made in: a newer hook on another thread may have gone first since `newest` said yes.
    func hook(_ event: String, trigger: String? = nil, message: String? = nil, asker: String? = nil, question: Bool = false,
              goal: String? = nil, at: TimeInterval? = nil) {
        state.withLock { s in
            if let at, at < s.newestHook { return }
            let said = s.record.summary, awaited = s.record.awaiting
            s.hook(event, trigger: trigger, message: message, asker: asker, question: question, goal: goal)
            emit(s.sync() ?? (s.record.summary != said || s.record.awaiting != awaited ? s.record : nil))
        }
    }

    /// It says it has sat at its prompt for a minute. Claude Code says so only after a finished turn: not with a dialog open,
    /// not after Esc (2.1.316), so a row still working or asking missed a Stop. Droid says it instead of a Stop when Esc stopped it.
    func atPrompt() {
        state.withLock { s in
            guard !s.holding, s.detector.status == .working || s.detector.status == .waiting else { return }
            s.nothingAsked()
            s.detector.override(.done, because: "it says it sits at its prompt")
            emit(s.sync())
        }
    }

    /// The /goal the turn's prompt set, once: its first Stop goes by it.
    func takeGoalAsked() -> String? { state.withLock { s in defer { s.goalAsked = nil }; return s.goalAsked } }

    /// Stop: done, or still working while it goes on by itself (TurnEnd); the record says what it works toward and
    /// what runs in the background. `failure`: an API error ended the turn, and what it said. Returns the verdict and the
    /// hook's time, which `release` checks.
    func stop(_ tasks: [JSONValue], crons: [JSONValue] = [], goal: GoalStatus?, failure: String? = nil, at: TimeInterval? = nil)
        -> (TurnEnd.Verdict, Date)? {
        state.withLock { s in
            if let at, at < s.newestHook { return nil }   // as in `hook`
            let now = Date()
            s.heard(at: now)
            let (verdict, running) = s.turnEnd.stop(tasks, goal: goal)
            s.trail.add("stop: \(verdict)")
            s.nothingAsked()
            s.endCommands(at: now)
            s.holding = verdict != .done
            s.parked = !tasks.isEmpty || !crons.isEmpty
            s.record.background = running.isEmpty ? nil : running
            if case .command(let c) = verdict { s.record.awaiting = c } else { s.record.awaiting = nil }
            if case .goal(let c) = verdict { s.record.goal = c } else if goal?.met != false { s.record.goal = nil }
            s.detector.hook(verdict != .done ? "working" : failure == nil ? "done" : "error")
            if verdict == .done, let failure, !failure.isEmpty { s.record.summary = failure }
            emit(s.sync() ?? s.record)
            return (verdict, now)
        }
    }

    /// One of its subagents started (`kind` says what it is) or ended (nil). Whether the record changed.
    func subagent(_ id: String?, kind: String?) -> Bool {
        state.withLock { s in
            s.heard()
            guard let id, s.record.subagents?[id] != kind else { return false }
            var running = s.record.subagents ?? [:]
            running[id] = kind
            s.record.subagents = running.isEmpty ? nil : running
            if kind == nil { s.record.subagentTasks?[id] = nil }
            if s.record.subagentTasks?.isEmpty == true { s.record.subagentTasks = nil }
            return true
        }
    }

    static let commandLimit = 100

    /// A tool started or ended, or a batch of them did (`kelp hook command`): `State.tool`.
    func tool(_ hook: String?, agent: String?) { state.withLock { s in s.tool(hook, agent: agent); emit(s.sync()) } }

    /// A command its shell tool started or ended (`kelp hook command`), into its list; the row says the one running. The
    /// record when what it runs changed.
    func ran(_ c: AgentCommand) -> Session? {
        state.withLock { s in
            if let i = s.commands.lastIndex(where: { $0.id == c.id }) {
                let started = s.commands[i].started   // the end keeps the start it was told of
                s.commands[i] = c
                s.commands[i].started = min(started, c.started)
            } else {
                s.commands.append(c)
                if s.commands.count > Self.commandLimit { s.commands.removeFirst(s.commands.count - Self.commandLimit) }
            }
            _ = s.newCommands()
            let moved = c.outcome == .background && s.sentToBackground(c.command)
            let shown = s.showRunning()
            return moved || shown ? s.record : nil
        }
    }

    /// The time to `release` by, if a Stop is held (an update took the wait for it along: it starts over).
    func heldAgain() -> Date? {
        state.withLock { s in
            guard s.holding else { return nil }
            let now = Date()
            s.lastHookAt = now
            return now
        }
    }

    /// A Stop held as working that nothing came after (`at`: its time): the goal was met, or the wait ran out.
    func release(_ at: Date) {
        state.withLock { s in
            guard s.lastHookAt == at, s.detector.status == .working else { return }
            s.holding = false
            s.record.goal = nil
            s.record.awaiting = nil
            s.detector.override(.done, because: "what the last Stop was held for is over")
            emit(s.sync())
        }
    }
}
