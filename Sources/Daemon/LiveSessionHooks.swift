import Agents
import Core
import Foundation

/// What an agent's hooks do to its session (`SessionHook`): its status, a Stop's verdict, its tools and commands.
extension LiveSession {
    /// Whether a hook that ran at `at` is the latest heard, or nothing says it isn't (a caller that doesn't send the time).
    /// `says`: it says what the status is. A tool's hook doesn't, and it runs side by side with AskUserQuestion's own for the
    /// same event: taken for the latest, it dropped that one, and the row kept asking.
    func newest(_ at: TimeInterval?, says: Bool) -> Bool {
        state.withLock { st in
            st.spoke()
            guard let at else { return true }
            // The same time twice: a hook sent again when the daemon went away with its reply, already counted.
            guard says ? at > st.newestHook : at >= st.newestHook else { return false }
            if says { st.newestHook = at }
            return true
        }
    }

    /// `State.hook`: the record goes out when its status or what the row says changed. `at`: checked again here, in the lock
    /// the change is made in: a newer hook on another thread may have gone first since `newest` said yes.
    func hook(
        _ event: String, trigger: String? = nil, message: String? = nil, asker: String? = nil, question: Bool = false,
        goal: String? = nil, at: TimeInterval? = nil
    ) {
        state.withLock { st in
            if let at, at < st.newestHook { return }
            let said = st.record.summary, awaited = st.record.awaiting
            st.hook(event, trigger: trigger, message: message, asker: asker, question: question, goal: goal)
            emit(st.sync() ?? (st.record.summary != said || st.record.awaiting != awaited ? st.record : nil))
        }
    }

    /// Background shells ended: they leave the record now, not at the next Stop. Whether it changed.
    func tasksEnded(_ ids: [String]) -> Bool {
        state.withLock { st in
            let gone = st.turnEnd.ended(ids), left = st.record.background?.filter { !gone.contains($0) }
            guard left != st.record.background else { return false }
            st.record.background = left?.isEmpty == true ? nil : left
            if let awaited = st.record.awaiting, gone.contains(awaited) { st.record.awaiting = nil }
            return true
        }
    }

    /// It says it has sat at its prompt for a minute. Claude Code says so only after a finished turn: not with a dialog open,
    /// not after Esc (2.1.316), so a row still working or asking missed a Stop. Droid says it instead of a Stop when Esc stopped it.
    func atPrompt() {
        state.withLock { st in
            guard !st.holding, st.detector.status == .working || st.detector.status == .waiting else { return }
            st.nothingAsked()
            st.detector.override(.done, because: "it says it sits at its prompt")
            emit(st.sync())
        }
    }

    /// The /goal the turn's prompt set, once: its first Stop goes by it.
    func takeGoalAsked() -> String? {
        state.withLock { st in
            defer { st.goalAsked = nil }
            return st.goalAsked
        }
    }

    /// Stop: done, or still working while it goes on by itself (TurnEnd); the record says what it works toward and
    /// what runs in the background. `failure`: an API error ended the turn, and what it said; `passes`: one that goes on
    /// later (`retry`). Returns the verdict and the hook's time, which `release` checks.
    func stop(
        _ tasks: [JSONValue], crons: [JSONValue] = [], goal: GoalStatus?, failure: String? = nil, passes: Bool = false,
        at: TimeInterval? = nil
    )
        -> (TurnEnd.Verdict, Date)?
    {
        state.withLock { st in
            if let at, at < st.newestHook { return nil }   // as in `hook`
            let now = Date()
            st.heard(at: now)
            let (verdict, running) = st.turnEnd.stop(tasks, goal: goal)
            st.trail.add("stop: \(verdict)")
            st.nothingAsked()
            st.endCommands(at: now)
            st.holding = verdict != .done
            st.parked = !tasks.isEmpty || !crons.isEmpty
            st.record.background = running.isEmpty ? nil : running
            if case .command(let command) = verdict { st.record.awaiting = command } else { st.record.awaiting = nil }
            if case .goal(let goalText) = verdict {
                st.record.goal = goalText
            } else if goal?.met != false {
                st.record.goal = nil
            }
            st.detector.hook(verdict != .done ? "working" : failure == nil ? "done" : "error")
            if verdict == .done, let failure, !failure.isEmpty { st.record.summary = failure }
            if verdict == .done, failure == nil { st.retries = 0 }   // it ended well: the count starts again
            if verdict == .done, failure != nil, passes { retry(now: now, &st) }
            emit(st.sync() ?? st.record)
            return (verdict, now)
        }
    }

    /// One of its subagents started (`kind` says what it is) or ended (nil). Whether the record changed.
    func subagent(_ id: String?, kind: String?) -> Bool {
        state.withLock { st in
            st.heard()
            guard let id, st.record.subagents?[id] != kind else { return false }
            var running = st.record.subagents ?? [:]
            running[id] = kind
            st.record.subagents = running.isEmpty ? nil : running
            if kind == nil { st.record.subagentTasks?[id] = nil }
            if st.record.subagentTasks?.isEmpty == true { st.record.subagentTasks = nil }
            return true
        }
    }

    static let commandLimit = 100

    /// A tool started or ended, or a batch of them did (`kelp hook command`): `State.tool`.
    func tool(_ hook: String?, agent: String?) {
        state.withLock { st in
            st.tool(hook, agent: agent)
            emit(st.sync())
        }
    }

    /// A command its shell tool started or ended (`kelp hook command`), into its list; the row says the one running. The
    /// record when what it runs changed.
    func ran(_ command: AgentCommand) -> Session? {
        state.withLock { st in
            if let index = st.commands.lastIndex(where: { $0.id == command.id }) {
                let started = st.commands[index].started   // the end keeps the start it was told of
                st.commands[index] = command
                st.commands[index].started = min(started, command.started)
            } else {
                st.commands.append(command)
                if st.commands.count > Self.commandLimit {
                    st.commands.removeFirst(st.commands.count - Self.commandLimit)
                }
            }
            _ = st.newCommands()
            if command.outcome == .background { st.turnEnd.started(command.id, command: command.command) }
            let moved = command.outcome == .background && st.sentToBackground(command.command)
            let shown = st.showRunning()
            return moved || shown ? st.record : nil
        }
    }

    /// The time to `release` by, if a Stop is held (an update took the wait for it along: it starts over).
    func heldAgain() -> Date? {
        state.withLock { st in
            guard st.holding else { return nil }
            let now = Date()
            st.lastHookAt = now
            return now
        }
    }

    /// A Stop held as working that nothing came after (`at`: its time): the goal was met, or the wait ran out.
    func release(_ at: Date) {
        state.withLock { st in
            guard st.lastHookAt == at, st.detector.status == .working else { return }
            st.holding = false
            st.record.goal = nil
            st.record.awaiting = nil
            st.detector.override(.done, because: "what the last Stop was held for is over")
            emit(st.sync())
        }
    }
}
