import Agents
import Core
import Foundation

// session.hook and session.annotate: what an agent's hooks, and Kelp's window, say about a session.

/// A late hook (its session was paused or ended since) wakes nothing.
extension SessionHook: Handled {
    static let agents = AgentAccess.acts
    var fence: Fence { Fence(reportsFor: id) }
    static var quick: Bool { true }   // the agent waits for its hook
    func handle(_ sessions: Sessions) throws -> Done {
        guard let ls = sessions.existing(id) else {
            try sessions.trail(id)?.add("\(trailLine): nothing runs here")
            return Done()
        }
        if let transcript, !transcript.isEmpty {
            ls.transcriptPath = transcript
            sessions.follow(ls, transcript: transcript)
        }
        if let reply, ls.snapshot.parent != nil { sessions.reports.said(reply, by: id) }   // before the status its report goes out on
        if let cwd, ls.workIn(cwd) != nil { sessions.publish(ls) }
        if let notification, Hooks.isInformational(notification) {
            ls.trail.add("\(trailLine): asks nothing")
            if Hooks.atPrompt(notification), ls.newest(at, says: true) { ls.atPrompt() }
            return Done()
        }
        guard let name = event else { throw RPCError.invalidParams("missing event") }
        guard let event = HookEvent(rawValue: name) else {
            // A hooks file from another Kelp, or a typo in an agent's, is logged here, where it arrives, and nothing
            // more happens.
            Log.session.error("a hook said \(name, privacy: .public), which is no event")
            ls.trail.add("\(trailLine): no such event")
            return Done()
        }
        if event == .command, let command {   // a Bash command for the list and the row, whenever its hook arrives
            if ls.ran(command, by: agentId) != nil { sessions.publish(ls) }
            sessions.touchCommands(ls)
        }
        if let endedTasks, ls.tasksEnded(endedTasks) { sessions.publish(ls) }
        if let edited {   // for whoever follows its edits
            ls.edited(edited)
            sessions.touchEdits(ls)
        }
        notePage(ls, sessions)
        if event == .subagent {   // a subagent starting or stopping says nothing of the turn; its Stop does
            ls.trail.add(trailLine)
            if ls.subagent(agentId, kind: hookName == "SubagentStart" ? agentType ?? "" : nil) { sessions.publish(ls) }
            return Done()
        }
        guard ls.newest(at, says: event != .command) else {
            ls.trail.add("\(trailLine): older than what it said since")
            return Done()
        }
        if event == .command {   // a tool started or ended, which says something of its turn
            ls.tool(hookName, agent: agentId)
            return Done()
        }
        ls.trail.add(trailLine)
        guard event == .done else {
            ls.hook(
                event, trigger: trigger,
                message: notification.flatMap { Hooks.message($0, alreadyWaiting: ls.snapshot.status == .waiting) },
                asker: hookName == "PermissionRequest" ? agentId ?? "" : nil, question: hookName == "PreToolUse",
                answered: hookName == "PostToolUse", goal: goal, choices: notification.flatMap(Hooks.choices), at: at)
            return Done()
        }
        // The turn is over, and so is every command of it, so a question Kelp asked for one of them goes unanswered.
        sessions.permissions.endKelpQuestions(id)
        leavePage(ls, sessions)
        let limit = notification.flatMap(Hooks.limitHit)
        if let limit { ls.hitLimit(limit) }
        let path = ls.transcriptPath
        let last = path.flatMap(GoalStatus.last(inFile:))
        let asked = ls.takeGoalAsked().map { GoalStatus(met: false, condition: $0, id: "") }   // its first check isn't written yet
        let failure = limit == nil ? notification.flatMap(Hooks.failure) : nil
        guard
            let (verdict, stoppedAt) = ls.stop(
                backgroundTasks ?? [], crons: sessionCrons ?? [], goal: asked ?? last, failure: failure,
                passes: notification.map(Hooks.passes) ?? false, at: at)
        else {
            return Done()
        }
        switch verdict {
        case .goal:
            guard let path, let after = last ?? asked else {
                ls.release(stoppedAt)
                break
            }
            Self.watchGoal(ls, path: path, after: after, stoppedAt: stoppedAt)
        case .command: DispatchQueue.global().asyncAfter(deadline: .now() + Self.commandWait) { ls.release(stoppedAt) }
        case .done, .working: break
        }
        return Done()
    }

    /// What the hook said, as a line for the session's trail.
    private var trailLine: String {
        ["hook", event, hookName, trigger, notification?["notification_type"]?.string].compactMap { $0 }.joined(
            separator: " ")
    }

    /// How long a command the agent waits for may run before its row says done anyway (a server TurnEnd took for a test).
    static let commandWait: TimeInterval = 600

    /// Waits again for what a held Stop waits for, in the kelpd that took the session over, because the wait ended with
    /// the kelpd before.
    static func waitAgain(_ ls: LiveSession) {
        guard let at = ls.heldAgain() else { return }
        let held = ls.snapshot
        if held.goal != nil, let path = ls.transcriptPath, let goal = GoalStatus.last(inFile: path) {
            watchGoal(ls, path: path, after: goal, stoppedAt: at)
        } else if held.awaiting != nil {
            DispatchQueue.global().asyncAfter(deadline: .now() + commandWait) { ls.release(at) }
        }
    }

    /// After a Stop with a goal open, Claude Code checks the goal (a model's answer, in seconds). When it is met, the
    /// turn is done; when not, the agent goes on and stops again. With no answer within a minute, the turn is done.
    static func watchGoal(_ ls: LiveSession, path: String, after: GoalStatus, stoppedAt: Date, tries: Int = 30) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            guard let now = GoalStatus.last(inFile: path), now.id != after.id else {
                if tries > 1 {
                    watchGoal(ls, path: path, after: after, stoppedAt: stoppedAt, tries: tries - 1)
                } else {
                    ls.release(stoppedAt)
                }
                return
            }
            if now.met { ls.release(stoppedAt) }
        }
    }
}

extension SessionHook {
    /// Puts on the agent's row the page its own thread's tool starts on (`page`), for its face on that page.
    fileprivate func notePage(_ ls: LiveSession, _ sessions: Sessions) {
        guard let page, agentId == nil else { return }
        let roots = [ls.snapshot.cwd] + [ls.snapshot.workDir].compactMap { $0 }
        guard let target = Artifacts.target(of: page, roots: roots),
            ls.works(on: SessionPage(target: target, doing: page.doing, at: Date())) != nil
        else { return }
        sessions.publish(ls)
    }

    /// The turn is over: the agent leaves the page it worked on.
    fileprivate func leavePage(_ ls: LiveSession, _ sessions: Sessions) {
        if ls.works(on: nil) != nil { sessions.publish(ls) }
    }
}

extension SessionAnnotate: Handled {
    static var quick: Bool { true }
    /// The window's own reading of a session (its notifier's summary). No agent may set another session's status or
    /// summary.
    var fence: Fence { Fence(onlyFromKelp: "Only Kelp's window annotates a session.") }
    func handle(_ sessions: Sessions) throws -> Done {
        guard let ls = sessions.existing(id), ifStatus.map({ $0 == ls.snapshot.status.rawValue }) ?? true else {
            return Done()
        }
        if let summary {
            _ = ls.update { $0.summary = summary }
            sessions.publish(ls)
        }
        if let st = status.flatMap(AgentStatus.init(rawValue:)) { ls.overrideStatus(st) }
        return Done()
    }
}

extension SessionReport: Handled {
    static let agents = AgentAccess.acts
    var fence: Fence { Fence(reportsFor: id) }
    static var quick: Bool { true }   // `kelp report`: the agent waits for it
    func handle(_ sessions: Sessions) throws -> Done {
        guard ProgramStatus.states.contains(state) else {
            throw RPCError.invalidParams("state is one of idle, working, blocked, done, error, clear")
        }
        guard let ls = sessions.existing(id) else { return Done() }   // ended or paused: there's nothing to show it on
        let report = ProgramStatus.Report(
            state: state, kind: state == "blocked" ? kind : nil, msg: message,
            progress: state == "working" ? progress.map { min(100, max(0, $0)) } : nil)
        if ls.report(report) != nil { sessions.publish(ls) }
        return Done()
    }
}

/// herdr has no "done": idle after work is a finished turn (`StatusDetector.program`).
extension PaneReportAgent: Handled {
    static let agents = AgentAccess.acts
    var fence: Fence { Fence(reportsFor: paneId) }
    static var quick: Bool { true }   // fx waits for the reply
    func handle(_ sessions: Sessions) throws -> Done {
        guard ["idle", "working", "blocked"].contains(state) else {
            throw RPCError.invalidParams("state is one of idle, working, blocked")
        }
        guard let ls = sessions.existing(paneId) else { return Done() }
        if ls.report(ProgramStatus.Report(state: state)) != nil { sessions.publish(ls) }
        return Done()
    }
}

extension Methods {
    static let hookMethods: [any Answered.Type] = [
        SessionHook.self, SessionAnnotate.self, SessionReport.self, PaneReportAgent.self
    ]
}
