import Agents
import Core
import Foundation
import GitKit
import os

extension LiveSession {
    /// What changes, all of it: only ever read or written inside `state.withLock`. The `let`s are fixed at launch.
    struct State {
        var record: Session
        var detector: StatusDetector
        let hooked: Bool   // agents with hooks report their state themselves; others may through OSC 7501
        let selfNames: [String]   // what a title that only names the program or its folder contains (TerminalTitle.topic)
        let trail: StatusTrail
        let started = Date()
        let wantsTopic: Bool, wantsURL: Bool, wantsLimits: Bool

        // Output: the last `ringLimit` bytes, the modes in effect where they start (what the ring dropped had set them), the log.
        var ring = Data(), ringModes = TerminalModes()
        var logSize: Int
        var attached = Set<Int>()   // connection ids receiving raw output
        var lastOutputAt: Date?
        var lastInputAt: Date?   // keys from a UI, not the terminal's replies
        /// TUIs redraw everything after a resize; that output isn't the agent working.
        var redrawUntil = Date.distantPast
        var final = false   // deleted, or its last record saved: nothing it does may save its record again
        var letGo = false   // out of `live`, its program stopping: no new attach (`letGo()`)
        var inputs = 0, inputsInFlight = 0   // client input taken (`input`)
        var ended = false

        // What the output says.
        var oscCarry = "", titleCarry = "", lastTopic: String?
        var utf8Carry = Data()   // the start of a character the last chunk was cut in (`UTF8Chunks`)
        /// The program turned on bracketed paste (ESC[?2004h): it tells a paste from typing.
        var pasteMode = false, pasteCarry = Data()
        var sawURL = false, sawBusy = false, lastLimits: [ClaudeLimits.Reading] = []
        /// An agent without hooks printed that its plan ran out: it counts if its turn stops by it (`settleLimit`).
        var limitSeen: (hit: LimitHit, at: Date)?
        /// Turns in a row an API error that passes ended and Kelp went on with (`LiveSession.retry`).
        var retries = 0
        var transcript: String?
        var lastHookAt = Date.distantPast, compactManual = false
        /// What the row said before a compaction wrote on it.
        var compactSummary: String?
        /// The last output or hook on the clock that stands still while the Mac sleeps (`releaseStale`).
        var lastLifeUp = ProcessInfo.processInfo.systemUptime
        /// When the latest hook heard ran (`SessionHook.at`).
        var newestHook: TimeInterval = 0
        /// A hook or a report came: it has them, and they run.
        var hooksSpoke = false
        /// When a line went into an agent whose hooks haven't spoken yet: one should come now (`hooksSilent`).
        var lineSentUp: TimeInterval?
        /// The last Stop was held as working (subagents, a goal, a command): the agent is quiet by design until it wakes.
        var holding = false
        /// The last Stop left work in the background or a timer: quiet, but something will wake it. Assumed until a Stop says.
        var parked = true
        var turnEnd = TurnEnd()
        /// What its shell tool ran (`ran`), the last `commandLimit`; `commandChanges` counts the changes, for the watchers.
        /// Limit: in memory, so a restarted background service starts the list over; the transcript keeps them all.
        var commands: [AgentCommand] = [], commandChanges = 0
        /// Esc / ⌃C / an answer while it works or asks: Claude Code sends no hook when a turn is cut short, so the
        /// screen decides ("Interrupted…") within a few seconds. `seen` is the text printed since.
        var interruptArmed: (at: Date, seen: String)?
        /// Whose permission dialogs are open, and how many: subagents by id, "" for the main thread. Claude Code sends no hook
        /// for an answer, and none for the next dialog of a batch when the first is answered.
        var asking: [String: Int] = [:]
        /// Kelp asks these (`LiveSession.askForKelp`), oldest first: the row asks the oldest, whatever the screen and the
        /// hooks say, until they're over.
        var kelpQuestions: [String] = []
        var kelpQuestion: String? { kelpQuestions.first }
        /// AskUserQuestion is open: a key answers one of its questions, and only its PostToolUse says that was the last.
        var questionOpen = false
        /// The prompt that started this turn set a /goal, this one: its first Stop comes before the first check is written.
        var goalAsked: String?
        /// Esc / ⌃C as it worked: an idle it reports in the seconds after is that stop, not a finished turn.
        var stopKeyAt = Date.distantPast

        // Typing into it (LiveSessionInput).
        var autoAnswers: [(NSRegularExpression, AgentManifest.AutoAnswer)]
        /// Drawn and quiet once (or 25 s up): text typed before then could land in a program still starting.
        var startedUp = false
        /// Text waiting until the program is ready (drawn, quiet, no question open), first in first out: the launch
        /// prompt, then whatever was sent while it waited.
        var pendingPrompts: [(text: String, draft: Bool, paste: Bool)] = []
        /// What its children said, for when it rests (`takesReport`).
        var reports: [String] = []
        /// Someone answered the agent's first question (the user typed, or Kelp's auto-answer pressed its key): from then
        /// on a trust dialog's words left in the scrollback no longer hold the launch prompt back.
        var dialogSettled = false
        /// A draft is typed but not sent (an issue's brief, a hand-off's): the user reads it and presses Return. Until they
        /// type anything, text sent meanwhile waits behind it — its Enter would submit the draft unread.
        var draftWaiting = false
        /// Anything typed into it yet, by the user or by Kelp (a prompt): startup answers are only for what the agent asks
        /// before that. After it, a matching line is something the agent read or wrote, not its own dialog.
        var typedYet = false
        /// Menu answer in progress: move one step at a time, re-reading the screen, and press Enter only on the wanted
        /// option. `screen`: what must still be on screen for each key (the dialog being answered); nil for a menu the
        /// user answers from a notification.
        var steering: (choose: NSRegularExpression, since: Date, lastKey: Date, screen: NSRegularExpression?)?
        /// What the user typed and hasn't sent, as far as their keys tell (arrows and history recall aren't followed).
        var typing = ""
        /// A line was sent and no key pressed since, so the input box is empty; `typing` alone can't say (↑ brings back an old prompt).
        var boxEmpty = false
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
            selfNames = [manifest.id, manifest.name, (record.cwd as NSString).lastPathComponent]
            autoAnswers = manifest.autoAnswers.compactMap { answer in
                Log.session.attempt("\(manifest.id)'s auto-answer pattern") {
                    try NSRegularExpression(pattern: answer.pattern)
                }.map { ($0, answer) }
            }
            self.logSize = logSize
            wantsTopic = callbacks.topic != nil
            wantsURL = callbacks.localURL != nil
            wantsLimits = callbacks.limits != nil || record.agent == "codex"
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

        /// A row that says working or asks while the screen stood still for minutes and no hook came. A Stop (or a compaction's
        /// end) Kelp doesn't know of or missed would leave it working, keeping the Mac awake, until the next prompt, and a turn
        /// cut short elsewhere (Remote Control, a No there) sends no hook at all and only prints that it was. Claude Code redraws
        /// its timer every second while it works; one held for what it waits for is quiet by design.
        /// A menu on that screen is a question whose hook never came: it waits for the user, and its turn goes on after.
        /// Limit: a still screen is the only evidence, and the answer, done, is also what a quiet but live agent would get.
        mutating func releaseStale(at up: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            let limit: TimeInterval = holding || record.subagents != nil ? 1800 : 180
            let status = detector.status
            guard saysItself, status == .working || status == .waiting, up - lastLifeUp > limit else { return }
            lastLifeUp = up   // looked at; again after as long
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

        /// Nothing it was held for counts any more.
        private mutating func release() {
            holding = false
            record.goal = nil
            record.awaiting = nil
        }

        /// Nothing a tick would do (`LiveSession.tick`): no status a quiet screen or a silent hook moves on (working,
        /// waiting), nothing timed (the start-up wait, text or a report to type, a menu being walked, an interrupt watched,
        /// a continue, hooks awaited, a quiet working row) and nothing the record hasn't been told.
        var atRest: Bool {
            startedUp && pendingPrompts.isEmpty && reports.isEmpty && steering == nil && interruptArmed == nil
                && lineSentUp == nil && record.continueAt == nil && record.quietSince == nil && kelpQuestions.isEmpty
                && asking.isEmpty && detector.status != .working && detector.status != .waiting
                && (detector.status == record.status || record.status == .exited)
        }

        /// The detector's status into the record; the record when it changed. Ended is final: a hook or a keystroke that
        /// arrives after the exit doesn't bring the session back.
        mutating func sync() -> Session? {
            record.subagentsAsk(asking.keys)
            let status = kelpQuestion == nil || detector.status == .exited ? detector.status : .waiting
            var said = false
            if let question = kelpQuestion, record.summary != question {
                record.summary = question
                said = true
            }
            guard status != record.status, record.status != .exited else { return said ? record : nil }
            trail.add("\(record.status.rawValue) → \(status.rawValue)  \(detector.source)")
            record.status = status
            // Read off the screen: a guess, said as one (`Session.guessed`). Hooks and the program's own reports aren't.
            let src = detector.source
            record.guessed = src.hasPrefix("screen") || src.hasPrefix("no hook") ? true : nil
            if status == .done || status == .waiting || status == .exited || status == .error { record.unread = true }
            if status == .done || status == .error {
                settleLimit()
            } else {
                record.limitHit = nil
                record.continueAt = nil
            }   // it moved on
            return record
        }

        /// Working with no news for 5 minutes: the time of the last (a hook from an agent that sends them, else output),
        /// kept in `record.quietSince` until news comes or it stops working. Whether it changed, for the sidebar.
        mutating func noteQuiet(now: Date = Date()) -> Bool {
            let heard = hooked && hooksSpoke ? lastHookAt : (lastOutputAt ?? .distantPast)
            let last = max(heard, record.statusAt ?? .distantPast)
            let quiet = record.status == .working && now.timeIntervalSince(last) >= 300 ? last : nil
            guard quiet != record.quietSince else { return false }
            record.quietSince = quiet
            return true
        }

        /// The user's keys into `typing`; the first line of 8 characters or more they send (once), which names the session.
        mutating func noteTyping(_ data: Data) -> String? {
            let text = String(decoding: data, as: UTF8.self)
            // Esc puts nothing in the box: a report waiting for it to be empty would wait on the next Return.
            if text != "\u{1B}", LiveSession.kittyKey(text)?.key != 27 { boxEmpty = false }
            if text.hasPrefix("\u{1B}[200~") {   // a paste: its newlines are text, not Return
                typing += text.replacingOccurrences(of: "\u{1B}[200~", with: "").replacingOccurrences(
                    of: "\u{1B}[201~", with: ""
                )
                .replacingOccurrences(of: "\r", with: "\n")
                return nil
            }
            if let kitty = LiveSession.kittyKey(text) {
                switch (kitty.key, kitty.mods) {
                case (13, 0): return sendLine()   // Return (⇧Return is a new line in the box)
                case (99, 4), (117, 4): typing = ""   // ⌃C, ⌃U
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
                case "\u{03}", "\u{15}": typing = ""   // ⌃C, ⌃U: the line is dropped
                case "\u{7F}", "\u{08}": if !typing.isEmpty { typing.removeLast() }
                case "\u{17}": dropWord()   // ⌃W
                default:
                    if !ch.isASCII || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol || ch == " " {
                        typing.append(ch)
                    }
                }
            }
            return sent
        }

        /// Return: the line is sent. The first one of 8 characters or more, once.
        private mutating func sendLine() -> String? {
            let line = typing.trimmingCharacters(in: .whitespacesAndNewlines)
            typing = ""
            boxEmpty = true
            if !line.isEmpty {
                expectHook()
                lastSent = line
            }
            guard !sawFirstPrompt, line.count >= 8 else { return nil }
            sawFirstPrompt = true
            return line
        }

        private mutating func dropWord() {
            while typing.last == " " { typing.removeLast() }
            while let last = typing.last, last != " " { typing.removeLast() }
        }
    }
}
