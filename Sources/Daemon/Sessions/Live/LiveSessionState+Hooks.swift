import Agents
import Core
import Foundation

// What the agent says about itself: reports, hooks and the commands its tools ran.

extension LiveSession.State {
    /// What the program says about itself (OSC 7501 or `kelp report`): its state, a message for its row, how far it got.
    mutating func apply(_ report: ProgramStatus.Report) {
        spoke()
        detector.program(report.state, cutShort: Date().timeIntervalSince(stopKeyAt) < 10)
        lastHookAt = Date()
        // Hooks on a host say nothing of a turn but its state, so a new one has to clear what the last one left.
        let fresh =
            report.state == "idle" || report.state == "clear" || (report.state == "working" && record.tmux != nil)
        if let msg = report.msg, !msg.isEmpty { record.summary = msg } else if fresh { record.summary = "" }
        record.progress = report.progress
    }

    /// A hook event from the agent: its status, and what a compaction or a question says on the row. `trigger`: PreCompact's
    /// manual / auto; `message`: what a Notification says ("Claude needs your permission to use Bash"); `asker`: whose
    /// permission dialog it is, for `tool`; `question`: AskUserQuestion opened, `answered`: its result came; `goal`: what
    /// the prompt set as a /goal.
    mutating func hook(
        _ event: HookEvent, trigger: String? = nil, message: String? = nil, asker: String? = nil,
        question: Bool = false, answered: Bool = false,
        goal: String? = nil, choices: [String]? = nil
    ) {
        heard()
        // A question's answers are good while it waits on it: what it says next (another dialog, its work) has its own.
        if event != .waiting { record.choices = nil }
        // A prompt after a Stop held for its command (yours, or the <task-notification> that it ended): a new turn, which
        // isn't waiting for it. The next Stop says again.
        if kept.holding, event == .working { record.awaiting = nil }
        kept.holding = false
        let compacting = Session.compactingSummary
        switch event {
        case .compacting:
            compactManual = trigger == "manual"
            // Claude Code also compacts a conversation left idle (trigger "auto", nothing running): no turn follows to end
            // it, so the row keeps its status and only says what is going on.
            compactSummary = record.summary
            record.summary = compacting
            if compactManual || detector.status == .working { detector.hook(.working) }
        case .compacted:
            if record.summary == compacting { record.summary = compactSummary ?? "" }
            compactSummary = nil
            if compactManual { detector.override(.idle, because: "/compact finished") }   // back at the prompt; an auto one carries on
            compactManual = false
        case .waiting:
            if let asker { kept.asking[asker, default: 0] += 1 }
            if question { kept.questionOpen = true }
            if let message, !message.isEmpty {
                record.summary = message
                record.choices = choices
            }
            detector.hook(event)
        case .working:
            // Not the end of a dialog a hook counted: a prompt can't be sent past one, and anything in the session can say
            // "working" (`kelp report`, a hook run by hand), after which an Enter typed in would answer it (`asked`).
            // Its answer ends it: a key, Kelp's Allow or Deny, its tools' batch (`tool`), the turn's end.
            if answered { kept.questionOpen = false }
            goalAsked = goal
            if record.summary != compacting { record.summary = "" }   // the last turn's words, or the question just answered
            detector.hook(event)
        default: detector.hook(event)
        }
    }

    /// A tool of the agent or of a subagent (`agent`): a sign of life, not a hook that says what the turn does, so an Esc
    /// that stopped it is still read off the screen. Two things it does say. A tool of the main thread after its turn
    /// ended: the turn goes on with no prompt (a Stop hook that blocked, a goal's first step, something that woke it).
    /// The batch a permission dialog held back is through: it was answered, wherever that was, and with several dialogs
    /// open this is the first hook that means all of them (a PostToolUse comes with the next one still open).
    /// Limit: answered outside Kelp, a long command reads Needs You until it ends.
    mutating func tool(_ hook: String?, agent: String?) {
        lastLifeUp = ProcessInfo.processInfo.systemUptime
        switch hook {
        case "PreToolUse":
            guard agent == nil, [.done, .idle, .error].contains(detector.status) else { return }
            detector.override(.working, because: "a tool started after its turn ended")
        case "PostToolBatch":
            guard kept.asking.removeValue(forKey: agent ?? "") != nil, kept.asking.isEmpty, detector.status == .waiting
            else {
                return
            }
            detector.override(.working, because: "the tools it asked about ran")
        default: break
        }
    }

    static let noHooks = "No hooks from this agent: its status is read off the screen"

    /// A line went in: an agent with hooks answers that with one, if they run at all.
    mutating func expectHook() {
        if hooked, !kept.hooksSpoke, lineSentUp == nil { lineSentUp = ProcessInfo.processInfo.systemUptime }
    }

    /// A hook came. Whatever the row said about them being off is over.
    mutating func spoke() {
        guard !kept.hooksSpoke else { return }
        kept.hooksSpoke = true
        lineSentUp = nil
        if record.summary == Self.noHooks { record.summary = "" }
    }

    /// A line went in and no hook came. They're off (disableAllHooks, a managed policy) or can't run (`kelp` not on PATH, a
    /// version that refuses the file), and with heuristics off the row would stay Idle however long the agent worked.
    /// A hook that comes after all turns them back off (`StatusDetector.hook`).
    mutating func hooksSilent(at up: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let sent = lineSentUp, up - sent > 15 else { return }
        lineSentUp = nil
        detector.hooksSilent()
        record.summary = Self.noHooks
    }

    /// A key answered a dialog: whether none is left open. Several are shown one after another, and a question still on
    /// screen must not read as work. Which one it answered doesn't matter: a batch's tools clear them all (`tool`).
    mutating func answeredOne() -> Bool {
        if let (who, open) = kept.asking.first { kept.asking[who] = open > 1 ? open - 1 : nil }
        return kept.asking.isEmpty && !kept.questionOpen
    }

    /// A dialog a hook counted is still open (a permission's, AskUserQuestion's), whatever the status says since: what
    /// keeps an agent's keys out (`asksSomething`).
    /// Limit: hooks are the session's own word, so a program in it that sends an answer's hooks (PostToolBatch, Stop)
    /// by hand still un-says its question.
    var asked: Bool { !kept.asking.isEmpty || kept.questionOpen }

    /// Whatever it asked is over.
    mutating func nothingAsked() {
        kept.asking.removeAll()
        kept.questionOpen = false
    }

    /// A sign of life from the agent: a hook, or what it printed.
    mutating func heard(at now: Date = Date()) {
        lastHookAt = now
        lastLifeUp = ProcessInfo.processInfo.systemUptime
    }

    /// One more change to its commands, for the watchers (`Watches.touched`).
    mutating func newCommands() -> Int {
        commandChanges += 1
        return commandChanges
    }

    /// The row's running command: the last one started that hasn't ended (one moved to the background has). Whether
    /// that changed.
    mutating func showRunning() -> Bool {
        let now = commands.last { $0.outcome == nil }?.command
        guard now != record.running else { return false }
        record.running = now
        return true
    }

    /// A command it sent to the background mid-turn: on the record now, not only at the next Stop, so asking meanwhile
    /// still shows it runs. It isn't waiting for it yet: it works on, and only a Stop says it waits. Whether the record changed.
    mutating func sentToBackground(_ command: String) -> Bool {
        guard record.background?.contains(command) != true else { return false }
        record.background = (record.background ?? []) + [command]
        return true
    }

    /// Its turn or its program ended: a command whose end wasn't told (a denied permission, an interrupt) runs no more.
    mutating func endCommands(at now: Date) {
        let open = commands.indices.filter { commands[$0].outcome == nil }
        for index in open {
            commands[index].outcome = .stopped
            commands[index].ended = now
        }
        if !open.isEmpty { _ = newCommands() }
        _ = showRunning()
    }
}
