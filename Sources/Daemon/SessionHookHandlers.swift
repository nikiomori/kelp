import Agents
import Core
import Foundation

// session.hook and session.annotate: what an agent's hooks, and Kelp's window, say about a session.

/// A late one (it was paused or ended since) wakes nothing.
extension SessionHook: Handled {
    var reportsFor: String? { id }
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
        guard let event else { throw RPCError.invalidParams("missing event") }
        if event == "command", let command {   // a Bash command for the list and the row, whenever its hook arrives
            if ls.ran(command) != nil { sessions.publish(ls) }
            sessions.touchCommands(ls)
        }
        if let endedTasks, ls.tasksEnded(endedTasks) { sessions.publish(ls) }
        if event == "subagent" {   // who runs says nothing of the turn: its Stop does
            ls.trail.add(trailLine)
            if ls.subagent(agentId, kind: hookName == "SubagentStart" ? agentType ?? "" : nil) { sessions.publish(ls) }
            return Done()
        }
        guard ls.newest(at, says: event != "command") else {
            ls.trail.add("\(trailLine): older than what it said since")
            return Done()
        }
        if event == "command" {   // a tool started or ended: what that says of its turn
            ls.tool(hookName, agent: agentId)
            return Done()
        }
        ls.trail.add(trailLine)
        guard event == "done" else {
            ls.hook(
                event, trigger: trigger,
                message: notification.flatMap { Hooks.message($0, alreadyWaiting: ls.snapshot.status == .waiting) },
                asker: hookName == "PermissionRequest" ? agentId ?? "" : nil, question: hookName == "PreToolUse",
                goal: goal, at: at)
            return Done()
        }
        // Its turn is over, and every command of it: a question Kelp asked for one goes unanswered.
        sessions.permissions.endKelpQuestions(id)
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

    /// What it says, for the session's trail.
    private var trailLine: String {
        ["hook", event, hookName, trigger, notification?["notification_type"]?.string].compactMap { $0 }.joined(
            separator: " ")
    }

    /// How long a command the agent waits for may run before its row says done anyway (a server TurnEnd took for a test).
    static let commandWait: TimeInterval = 600

    /// What a held Stop waits for, in the kelpd that took it over: the wait ended with the one before.
    static func waitAgain(_ ls: LiveSession) {
        guard let at = ls.heldAgain() else { return }
        let held = ls.snapshot
        if held.goal != nil, let path = ls.transcriptPath, let goal = GoalStatus.last(inFile: path) {
            watchGoal(ls, path: path, after: goal, stoppedAt: at)
        } else if held.awaiting != nil {
            DispatchQueue.global().asyncAfter(deadline: .now() + commandWait) { ls.release(at) }
        }
    }

    /// After a Stop with a goal open, Claude Code checks it (a model's answer, seconds): met, the turn is done; not met,
    /// it goes on and stops again. No answer within a minute: done.
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

extension SessionAnnotate: Handled {
    static var quick: Bool { true }
    /// The window's own reading of a session (its notifier's summary): no agent sets another's status or summary.
    var onlyFromKelp: String? { "Only Kelp's window annotates a session." }
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
