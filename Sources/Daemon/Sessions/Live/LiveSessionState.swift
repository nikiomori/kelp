import Agents
import Core
import Foundation
import GitKit
import os

extension LiveSession {
    /// What a session's status and typing rest on beside its record, all of it handed to the kelpd that takes over
    /// (`Handover.Status`), so a field added here goes over an update by itself. When this was lost, a Stop held for
    /// subagents read as done three minutes after an update, a dialog answered elsewhere stayed Needs You, an agent
    /// that reports itself was guessed at again, a multi-line send was submitted line by line, and the next send's
    /// Enter sent an unread draft or the user's half line. It is read leniently, so a field an older kelpd didn't hand
    /// over has its default.
    struct Kept: Codable, Sendable {
        /// The last Stop was held as working (subagents, a goal, a command): the agent is quiet by design until it wakes.
        var holding = false
        /// The last Stop left work in the background or a timer, so the agent is quiet but something will wake it. It
        /// is assumed until a Stop says otherwise.
        var parked = true
        /// Whose permission dialogs are open, and how many: subagents by id, "" for the main thread. Claude Code sends
        /// no hook for an answer, and none for the next dialog of a batch when the first is answered.
        var asking: [String: Int] = [:]
        /// Whether AskUserQuestion is open. A key answers one of its questions, and only its PostToolUse says that was
        /// the last.
        var questionOpen = false
        var turnEnd = TurnEnd()
        var transcript: String?
        var codexThread: UUID?
        /// A line was sent and no key pressed since, so the input box is empty; `typing` alone can't say (↑ brings
        /// back an old prompt).
        var boxEmpty = false
        /// Whether the program turned on bracketed paste (ESC[?2004h), so it tells a paste from typing.
        var pasteMode = false
        /// A draft is typed but not sent (an issue's brief, a hand-off's): the user reads it and presses Return. Until
        /// the user types anything, text sent meanwhile waits behind the draft, because its Enter would submit the
        /// draft unread.
        var draftWaiting = false
        /// What the user typed and hasn't sent, as far as their keys tell (arrows and history recall aren't followed).
        var typing = ""
        /// Whether a hook or a report came, which shows the agent has hooks and they run.
        var hooksSpoke = false

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kept = Kept()
            holding = try container.decodeIfPresent(Bool.self, forKey: .holding) ?? kept.holding
            parked = try container.decodeIfPresent(Bool.self, forKey: .parked) ?? kept.parked
            asking = try container.decodeIfPresent([String: Int].self, forKey: .asking) ?? kept.asking
            questionOpen = try container.decodeIfPresent(Bool.self, forKey: .questionOpen) ?? kept.questionOpen
            turnEnd = try container.decodeIfPresent(TurnEnd.self, forKey: .turnEnd) ?? kept.turnEnd
            transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
            codexThread = try container.decodeIfPresent(UUID.self, forKey: .codexThread)
            boxEmpty = try container.decodeIfPresent(Bool.self, forKey: .boxEmpty) ?? kept.boxEmpty
            pasteMode = try container.decodeIfPresent(Bool.self, forKey: .pasteMode) ?? kept.pasteMode
            draftWaiting = try container.decodeIfPresent(Bool.self, forKey: .draftWaiting) ?? kept.draftWaiting
            typing = try container.decodeIfPresent(String.self, forKey: .typing) ?? kept.typing
            hooksSpoke = try container.decodeIfPresent(Bool.self, forKey: .hooksSpoke) ?? kept.hooksSpoke
        }
    }

    /// Everything about the session that changes, only ever read or written inside `state.withLock`. The `let`s are
    /// fixed at launch.
    struct State {
        var record: Session
        var detector: StatusDetector
        let hooked: Bool   // agents with hooks report their state themselves; others may through OSC 7501
        let agent: AgentManifest   // how its argv names the conversation it continues (`following`)
        let selfNames: [String]   // what a title that only names the program or its folder contains (TerminalTitle.topic)
        let trail: StatusTrail
        let started = Date()
        let wantsTopic: Bool, wantsURL: Bool
        let limitScreen: AgentManifest.LimitScreen?   // what it prints of its plan's limits, read as it runs

        // Output: the last `ringLimit` bytes, the modes in effect where they start (the bytes the ring dropped had set
        // them), and the log.
        var ring = Data(), ringModes = TerminalModes()
        var logSize: Int
        var attached = Set<Int>()   // connection ids receiving raw output
        var lastOutputAt: Date?
        var lastInputAt: Date?   // keys from a UI, not the terminal's replies
        /// TUIs redraw everything after a resize; that output isn't the agent working.
        var redrawUntil = Date.distantPast
        var kept = Kept()   // what goes over an update
        var final = false   // deleted, or its last record saved: nothing it does may save its record again
        var letGo = false   // out of `live`, its program stopping: no new attach (`letGo()`)
        var inputs = 0, inputsInFlight = 0   // client input taken (`input`)
        var ended = false

        // What the output says.
        var oscCarry = "", titleCarry = "", lastTopic: String?
        var utf8Carry = Data()   // the start of a character the last chunk was cut in (`UTF8Chunks`)
        var pasteCarry = Data()
        var sawURL = false, sawBusy = false, lastLimits: [LimitScreens.Reading] = []
        /// An agent without hooks printed that its plan ran out. It counts if the turn then stops (`settleLimit`).
        var limitSeen: (hit: LimitHit, at: Date)?
        /// Turns in a row an API error that passes ended and Kelp went on with (`LiveSession.retry`).
        var retries = 0
        var lastHookAt = Date.distantPast, compactManual = false
        /// What the row said before a compaction wrote on it.
        var compactSummary: String?
        /// The last output or hook on the clock that stands still while the Mac sleeps (`releaseStale`).
        var lastLifeUp = ProcessInfo.processInfo.systemUptime
        /// When the latest hook heard ran (`SessionHook.at`).
        var newestHook: TimeInterval = 0
        /// When a line went into an agent whose hooks haven't spoken yet, so a hook should come now (`hooksSilent`).
        var lineSentUp: TimeInterval?
        /// What its shell tool ran (`ran`), the last `commandLimit`; `commandChanges` counts the changes, for the watchers.
        /// Limit: in memory, so a restarted background service starts the list over; the transcript keeps them all.
        var commands: [AgentCommand] = [], commandChanges = 0
        /// The subagent that runs each of those still running, by tool call id, when its hook said (`browsing`).
        var commandAgents: [String: String] = [:]
        /// The file its tools changed last, and how many edits so far (`edits` watchers).
        var lastEdit: String?, edits = 0
        /// Set by Esc, ⌃C or an answer while the agent works or asks. Claude Code sends no hook when a turn is cut
        /// short, so the screen decides ("Interrupted…") within a few seconds. `seen` is the text printed since.
        var interruptArmed: (at: Date, seen: String)?
        /// The questions Kelp asks (`LiveSession.askForKelp`), oldest first. The row asks the oldest, whatever the
        /// screen and the hooks say, until they're over.
        var kelpQuestions: [String] = []
        var kelpQuestion: String? { kelpQuestions.first }
        /// The /goal that the prompt starting this turn set. The turn's first Stop comes before the first check is
        /// written.
        var goalAsked: String?
        /// When Esc or ⌃C was pressed while the agent worked. An idle it reports in the seconds after is that stop, not
        /// a finished turn.
        var stopKeyAt = Date.distantPast

        // Typing into it (LiveSessionInput).
        var autoAnswers: [(NSRegularExpression, AgentManifest.AutoAnswer)]
        /// Whether the program has drawn and gone quiet once (or 25 s passed). Text typed before then could land in a
        /// program still starting.
        var startedUp = false
        /// Text waiting until the program is ready (drawn, quiet, no question open), first in first out: the launch
        /// prompt, then whatever was sent while it waited.
        var pendingPrompts: [(text: String, draft: Bool, paste: Bool)] = []
        /// What its children said, for when it rests (`takesReport`).
        var reports: [String] = []
        /// Someone answered the agent's first question (the user typed, or Kelp's auto-answer pressed its key). From
        /// then on, a trust dialog's words left in the scrollback no longer hold the launch prompt back.
        var dialogSettled = false
        /// Whether anything was typed into the session yet, by the user or by Kelp (a prompt). Startup answers are only
        /// for what the agent asks before that; after it, a matching line is something the agent read or wrote, not its
        /// own dialog.
        var typedYet = false
        /// A menu answer in progress: it moves one step at a time, re-reading the screen, and presses Enter only on the
        /// wanted option. `screen` is what must still be on screen for each key (the dialog being answered); it is nil
        /// for a menu the user answers from a notification.
        var steering: (choose: NSRegularExpression, since: Date, lastKey: Date, screen: NSRegularExpression?)?
        /// The version an update last restarted it for (`restartAgent`).
        var updatedTo: String?
        var sawFirstPrompt = false

        // Turns: written by turnWork, read by requests.
        var turnTree: String?, turnFolder: String?, turnResult: Turn?, turnStart: Date?, inTurn = false
        /// What the user sent to start this turn: a message queued during it doesn't name it.
        var turnPrompt = ""
        /// The last line sent (a prompt): what a turn that starts is named after in its history.
        var lastSent = ""

        init(record: Session, manifest: AgentManifest, logSize: Int, callbacks: Callbacks, trail: StatusTrail) {
            self.record = record
            self.trail = trail
            detector = StatusDetector(manifest: manifest)
            hooked = manifest.hooks != nil
            agent = manifest
            selfNames = [manifest.id, manifest.name, (record.cwd as NSString).lastPathComponent]
            autoAnswers = manifest.autoAnswers.compactMap { answer in
                Log.session.attempt("\(manifest.id)'s auto-answer pattern") {
                    try NSRegularExpression(pattern: answer.pattern)
                }.map { ($0, answer) }
            }
            self.logSize = logSize
            wantsTopic = callbacks.topic != nil
            wantsURL = callbacks.localURL != nil
            limitScreen = manifest.limitScreen
        }

        /// The last `bytes` of what it printed, without escapes: what's on screen, near enough.
        func screen(_ bytes: Int) -> String {
            StatusDetector.stripANSI(String(decoding: ring.suffix(bytes), as: UTF8.self))
        }

        /// The modes in effect where the history (the ring's last `ringLimit` bytes) starts.
        var historyModes: TerminalModes {
            var modes = ringModes
            modes.read(ring.dropLast(LiveSession.ringLimit))
            return modes
        }

        /// Whether this status starts its turn or ends it. A dialog is part of the turn: what it did before the question counts
        /// too, and the answer doesn't start another.
        mutating func turnMoved(to status: AgentStatus) -> (starting: Bool, ending: Bool) {
            let starting = status == .working && !inTurn, ending = inTurn && status != .working && status != .waiting
            if starting {
                inTurn = true
                turnStart = Date()
                turnFolder = record.currentDir
            }
            if ending { inTurn = false }
            return (starting, ending)
        }

        /// Releases a row that says working or asks while the screen stood still for minutes and no hook came. A Stop
        /// (or a compaction's end) Kelp doesn't know of or missed would leave it working, keeping the Mac awake, until
        /// the next prompt, and a turn cut short elsewhere (Remote Control, a No there) sends no hook at all and only
        /// prints that it was. Claude Code redraws its timer every second while it works, but a session held for what
        /// it waits for is quiet by design.
        /// A menu on that screen is a question whose hook never came, so it waits for the user, and its turn goes on
        /// after.
        /// Limit: a still screen is the only evidence, and the answer, done, is also what a quiet but live agent would
        /// get.
        mutating func releaseStale(at up: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            let limit: TimeInterval = kept.holding || record.subagents != nil ? 1800 : 180
            let status = detector.status
            guard saysItself, status == .working || status == .waiting, up - lastLifeUp > limit else { return }
            lastLifeUp = up   // looked at; the next look comes as long after
            if menuOpen() {
                if status == .working {
                    detector.override(.waiting, because: "no sign of life for \(Int(limit)) s, and a menu on screen")
                }
                return
            }
            if LiveSession.printedStopped(screen(1500)) {
                nothingAsked()
                release()
                detector.override(
                    .idle, because: "no sign of life for \(Int(limit)) s, and it says its turn was cut short")
                return
            }
            guard status == .working else { return }
            release()
            detector.override(.done, because: "no sign of life for \(Int(limit)) s")
        }

        /// Drops what the session was held for, which no longer counts.
        private mutating func release() {
            kept.holding = false
            record.goal = nil
            record.awaiting = nil
        }

        /// Whether a tick has nothing to do (`LiveSession.tick`): no status a quiet screen or a silent hook moves on
        /// (working, waiting), nothing timed (the start-up wait, text or a report to type, a menu being walked, an
        /// interrupt watched, a continue, hooks awaited, a quiet working row), and nothing the record hasn't been told.
        var atRest: Bool {
            startedUp && pendingPrompts.isEmpty && reports.isEmpty && steering == nil && interruptArmed == nil
                && lineSentUp == nil && record.continueAt == nil && record.quietSince == nil && kelpQuestions.isEmpty
                && kept.asking.isEmpty && detector.status != .working && detector.status != .waiting
                && (detector.status == record.status || record.status == .exited)
        }

        /// Copies the detector's status into the record and returns the record when it changed. Ended is final, so a
        /// hook or a keystroke that arrives after the exit doesn't bring the session back.
        mutating func sync() -> Session? {
            record.subagentsAsk(kept.asking.keys)
            let status = kelpQuestion == nil || detector.status == .exited ? detector.status : .waiting
            var said = false
            if let question = kelpQuestion, record.summary != question {
                record.summary = question
                said = true
            }
            guard status != record.status, record.status != .exited else { return said ? record : nil }
            trail.add("\(record.status.rawValue) → \(status.rawValue)  \(detector.source)")
            record.status = status
            // A status read off the screen is a guess and is marked as one (`Session.guessed`); hooks and the program's
            // own reports aren't. So is one from `releaseStale` ("no sign of life"), because a still screen is all it
            // had, whatever the agent reported before.
            let src = detector.source
            record.guessed = ["screen", "no hook", "no sign of life"].contains(where: src.hasPrefix) ? true : nil
            if status == .done || status == .waiting || status == .exited || status == .error { record.unread = true }
            if status == .done || status == .error {
                settleLimit()
            } else {
                record.limitHit = nil
                record.continueAt = nil
            }   // it moved on
            return record
        }

        /// Notes a session working with no news for 5 minutes. The time of the last news (a hook from an agent that
        /// sends them, else output) is kept in `record.quietSince` until news comes or the session stops working.
        /// Returns whether it changed, for the sidebar.
        mutating func noteQuiet(now: Date = Date()) -> Bool {
            let heard = hooked && kept.hooksSpoke ? lastHookAt : (lastOutputAt ?? .distantPast)
            let last = max(heard, record.statusAt ?? .distantPast)
            let quiet = record.status == .working && now.timeIntervalSince(last) >= 300 ? last : nil
            guard quiet != record.quietSince else { return false }
            record.quietSince = quiet
            return true
        }

        /// Adds the user's keys to `typing`. Returns the first line of 8 characters or more they send (once), which
        /// names the session.
        mutating func noteTyping(_ data: Data) -> String? {
            let text = String(decoding: data, as: UTF8.self)
            // Esc puts nothing in the box, so it doesn't count as filling it; otherwise a report waiting for an empty
            // box would wait for the next Return.
            if text != "\u{1B}", LiveSession.kittyKey(text)?.key != 27 { kept.boxEmpty = false }
            if text.hasPrefix("\u{1B}[200~") {   // a paste: its newlines are text, not Return
                kept.typing += text.replacingOccurrences(of: "\u{1B}[200~", with: "").replacingOccurrences(
                    of: "\u{1B}[201~", with: ""
                )
                .replacingOccurrences(of: "\r", with: "\n")
                return nil
            }
            if let kitty = LiveSession.kittyKey(text) {
                switch (kitty.key, kitty.mods) {
                case (13, 0): return sendLine()   // Return (⇧Return is a new line in the box)
                case (99, 4), (117, 4): kept.typing = ""   // ⌃C, ⌃U
                case (119, 4), (127, 2): dropWord()   // ⌃W, ⌥⌫
                default: break
                }
                return nil
            }
            if text == "\u{1B}\u{7F}" {
                dropWord()
                return nil
            }   // ⌥⌫
            if text.hasPrefix("\u{1B}") { return nil }   // arrows, function keys
            var sent: String?
            for ch in text {
                switch ch {
                case "\r", "\n", "\r\n": sent = sendLine() ?? sent
                case "\u{03}", "\u{15}": kept.typing = ""   // ⌃C, ⌃U: the line is dropped
                case "\u{7F}", "\u{08}": if !kept.typing.isEmpty { kept.typing.removeLast() }
                case "\u{17}": dropWord()   // ⌃W
                default:
                    if !ch.isASCII || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol || ch == " " {
                        kept.typing.append(ch)
                    }
                }
            }
            return sent
        }

        /// Return sends the line. Returns the first line of 8 characters or more, once.
        private mutating func sendLine() -> String? {
            let line = kept.typing.trimmingCharacters(in: .whitespacesAndNewlines)
            kept.typing = ""
            kept.boxEmpty = true
            if !line.isEmpty {
                expectHook()
                lastSent = line
            }
            guard !sawFirstPrompt, line.count >= 8 else { return nil }
            sawFirstPrompt = true
            return line
        }

        private mutating func dropWord() {
            while kept.typing.last == " " { kept.typing.removeLast() }
            while let last = kept.typing.last, last != " " { kept.typing.removeLast() }
        }
    }
}
