import Agents
import Core
import Foundation

/// What an agent's hooks do to its session (`SessionHook`): its status, a Stop's verdict, its tools and commands.
extension LiveSession {
    /// Whether a hook that ran at `at` is the latest heard, or nothing says it isn't (a caller that doesn't send the
    /// time).
    /// `says` means the hook says what the status is. A tool's hook doesn't, and it runs side by side with
    /// AskUserQuestion's own hook for the same event. When the tool's hook was taken for the latest, it dropped that
    /// one, and the row kept asking.
    func newest(_ at: TimeInterval?, says: Bool) -> Bool {
        state.withLock { st in
            st.spoke()
            guard let at else { return true }
            // The same time twice is a hook sent again after the daemon went away with its reply, and it was already
            // counted.
            guard says ? at > st.newestHook : at >= st.newestHook else { return false }
            if says { st.newestHook = at }
            return true
        }
    }

    /// Applies a hook (`State.hook`); the record goes out when its status or what the row says changed. `at` is checked
    /// again here, in the lock the change is made in, because a newer hook on another thread may have gone first since
    /// `newest` said yes.
    func hook(
        _ event: HookEvent, trigger: String? = nil, message: String? = nil, asker: String? = nil,
        question: Bool = false,
        answered: Bool = false, goal: String? = nil, choices: [String]? = nil, at: TimeInterval? = nil
    ) {
        state.withLock { st in
            if let at, at < st.newestHook { return }
            let said = st.record.summary, awaited = st.record.awaiting, offered = st.record.choices
            st.hook(
                event, trigger: trigger, message: message, asker: asker, question: question, answered: answered,
                goal: goal, choices: choices)
            let changed = st.record.summary != said || st.record.awaiting != awaited || st.record.choices != offered
            emit(st.sync() ?? (changed ? st.record : nil))
        }
    }

    /// Asks Kelp's `question` for one of the agent's commands (a database change, `Databases`). The row asks it until
    /// `kelpAsked`, whatever the screen says meanwhile (the command's own spinner), after the questions asked before
    /// it.
    func askForKelp(_ question: String) {
        state.withLock { st in
            st.kelpQuestions.append(question)
            emit(st.sync() ?? st.record)
        }
    }

    /// Ends one of Kelp's questions, answered or not. Its command goes on (or has ended), and the row asks the next
    /// question or says what the agent does.
    func kelpAsked(_ question: String) {
        state.withLock { st in
            guard let index = st.kelpQuestions.firstIndex(of: question) else { return }
            st.kelpQuestions.remove(at: index)
            if st.kelpQuestions.isEmpty, st.record.summary == question { st.record.summary = "" }
            emit(st.sync() ?? st.record)
        }
    }

    /// Removes background shells that ended from the record now, not at the next Stop. Returns whether the record
    /// changed.
    func tasksEnded(_ ids: [String]) -> Bool {
        state.withLock { st in
            let gone = st.kept.turnEnd.ended(ids), left = st.record.background?.filter { !gone.contains($0) }
            guard left != st.record.background else { return false }
            st.record.background = left?.isEmpty == true ? nil : left
            if let awaited = st.record.awaiting, gone.contains(awaited) { st.record.awaiting = nil }
            return true
        }
    }

    /// The agent says it has sat at its prompt for a minute. Claude Code says so only after a finished turn, not with a
    /// dialog open and not after Esc (2.1.316), so a row still working or asking missed a Stop. Droid says it instead
    /// of a Stop when Esc stopped it.
    func atPrompt() {
        state.withLock { st in
            guard !st.kept.holding, st.detector.status == .working || st.detector.status == .waiting else { return }
            st.nothingAsked()
            st.detector.override(.done, because: "it says it sits at its prompt")
            emit(st.sync())
        }
    }

    /// Takes, once, the /goal the turn's prompt set, so the turn's first Stop goes by it.
    func takeGoalAsked() -> String? {
        state.withLock { st in
            defer { st.goalAsked = nil }
            return st.goalAsked
        }
    }

    /// Handles Stop: the session is done, or still working while the agent goes on by itself (TurnEnd); the record says
    /// what it works toward and what runs in the background. `failure` means an API error ended the turn, with what it
    /// said; `passes` is a failure that goes on later (`retry`). Returns the verdict and the hook's time, which
    /// `release` checks.
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
            let (verdict, running) = st.kept.turnEnd.stop(tasks, goal: goal)
            st.trail.add("stop: \(verdict)")
            st.nothingAsked()
            st.endCommands(at: now)
            st.kept.holding = verdict != .done
            st.kept.parked = !tasks.isEmpty || !crons.isEmpty
            st.record.background = running.isEmpty ? nil : running
            if case .command(let command) = verdict { st.record.awaiting = command } else { st.record.awaiting = nil }
            if case .goal(let goalText) = verdict {
                st.record.goal = goalText
            } else if goal?.met != false {
                st.record.goal = nil
            }
            st.detector.hook(verdict != .done ? .working : failure == nil ? .done : .error)
            if verdict == .done, let failure, !failure.isEmpty { st.record.summary = failure }
            if verdict == .done, failure == nil { st.retries = 0 }   // it ended well: the count starts again
            if verdict == .done, failure != nil, passes { retry(now: now, &st) }
            emit(st.sync() ?? st.record)
            return (verdict, now)
        }
    }

    /// Records that a subagent started (`kind` says what it is) or ended (nil). Returns whether the record changed.
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

    /// Records that a tool started or ended, or a batch of them did (`kelp hook command`), through `State.tool`.
    func tool(_ hook: String?, agent: String?) {
        state.withLock { st in
            st.tool(hook, agent: agent)
            emit(st.sync())
        }
    }

    /// Adds a command the shell tool started or ended (`kelp hook command`) to the session's list; the row says the one
    /// running. Returns the record when what it runs changed. `agent` is the subagent whose tool it is.
    func ran(_ command: AgentCommand, by agent: String? = nil) -> Session? {
        state.withLock { st in
            st.commandAgents[command.id] = command.outcome == nil ? agent : nil
            if let index = st.commands.lastIndex(where: { $0.id == command.id }) {
                let started = st.commands[index].started   // the end keeps the start it was told of
                st.commands[index] = command
                st.commands[index].started = min(started, command.started)
            } else {
                st.commands.append(command)
                if st.commands.count > Self.commandLimit {
                    st.commands.removeFirst(st.commands.count - Self.commandLimit)
                    let kept = Set(st.commands.map(\.id))
                    st.commandAgents = st.commandAgents.filter { kept.contains($0.key) }
                }
            }
            _ = st.newCommands()
            if command.outcome == .background { st.kept.turnEnd.started(command.id, command: command.command) }
            let moved = command.outcome == .background && st.sentToBackground(command.command)
            let shown = st.showRunning()
            return moved || shown ? st.record : nil
        }
    }

    /// The subagent whose `kelp browser` command asks now (nil for the agent's own), from `LiveSession.browsing`.
    func browsing(_ words: String) -> String? {
        state.withLock { st in Self.browsing(words, st.commands, st.commandAgents) }
    }

    /// Finds which subagent a `kelp browser` command belongs to. Among the running commands that run `kelp browser`, it
    /// takes the one whose text contains `words` (`click e12`), ignoring quotes and matching an address as typed (`open
    /// localhost:3000` for `open http://localhost:3000`); failing that, the only such command running. It returns that
    /// command's subagent; when none is found, the command is the agent's own.
    /// Limit: two subagents running the very same words at once can't be told apart.
    static func browsing(_ words: String, _ commands: [AgentCommand], _ agents: [String: String]) -> String? {
        let running = commands.filter { $0.outcome == nil && $0.command.contains("kelp browser") }
        let bare = words.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        let typed = [words, bare]
        let match =
            running.first { command in
                let said = command.command.filter { $0 != "\"" && $0 != "'" }
                return typed.contains { said.contains("browser " + $0) }
            } ?? (running.count == 1 ? running.first : nil)
        return match.flatMap { agents[$0.id] }
    }

    /// The time to `release` by, if a Stop is held. The wait starts over, because an update ended the old one.
    func heldAgain() -> Date? {
        state.withLock { st in
            guard st.kept.holding else { return nil }
            let now = Date()
            st.lastHookAt = now
            return now
        }
    }

    /// Releases a Stop held as working that nothing came after (`at` is its time), because the goal was met or the wait
    /// ran out.
    func release(_ at: Date) {
        state.withLock { st in
            guard st.lastHookAt == at, st.detector.status == .working else { return }
            st.kept.holding = false
            st.record.goal = nil
            st.record.awaiting = nil
            st.detector.override(.done, because: "what the last Stop was held for is over")
            emit(st.sync())
        }
    }
}
