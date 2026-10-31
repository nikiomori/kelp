import Foundation
import os
import Core
import Agents
import GitKit

extension LiveSession {
    /// What changes, all of it: only ever read or written inside `state.withLock`. The `let`s are fixed at launch.
    struct State {
        var record: Session
        var detector: StatusDetector
        let hooked: Bool                 // agents with hooks report their state themselves; others may through OSC 7501
        let selfNames: [String]          // what a title that only names the program or its folder contains (TerminalTitle.topic)
        let trail: StatusTrail
        let started = Date()
        let wantsTopic: Bool, wantsURL: Bool, wantsLimits: Bool

        // Output: the last `ringLimit` bytes, the modes in effect where they start (what the ring dropped had set them), the log.
        var ring = Data(), ringModes = TerminalModes()
        var logSize: Int
        var attached = Set<Int>()        // connection ids receiving raw output
        var lastOutputAt: Date?
        /// TUIs redraw everything after a resize; that output isn't the agent working.
        var redrawUntil = Date.distantPast
        var final = false                // deleted, or its last record saved: nothing it does may save its record again
        var letGo = false                // out of `live`, its program stopping: no new attach (`letGo()`)
        var inputs = 0, inputsInFlight = 0   // client input taken (`input`)
        var ended = false

        // What the output says.
        var oscCarry = "", titleCarry = "", lastTopic: String?
        var utf8Carry = Data()           // the start of a character the last chunk was cut in (`UTF8Chunks`)
        /// The program turned on bracketed paste (ESC[?2004h): it tells a paste from typing.
        var pasteMode = false, pasteCarry = Data()
        var sawURL = false, lastLimits: [ClaudeLimits.Reading] = []
        /// An agent without hooks printed that its plan ran out: it counts if its turn stops by it (`settleLimit`).
        var limitSeen: (hit: LimitHit, at: Date)?
        var transcript: String?
        var lastHookAt = Date.distantPast, compactManual = false
        /// What the row said before a compaction wrote on it.
        var compactSummary: String?
        /// The last output or hook on the clock that stands still while the Mac sleeps (`releaseStale`).
        var lastLifeUp = ProcessInfo.processInfo.systemUptime
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
        /// Whose permission dialogs are open: subagents by id, "" for the main thread. Claude Code sends no hook for the answer.
        var asking = Set<String>()
        /// Esc / ⌃C as it worked: an idle it reports in the seconds after is that stop, not a finished turn.
        var stopKeyAt = Date.distantPast

        // Typing into it (LiveSessionInput).
        var autoAnswers: [(NSRegularExpression, AgentManifest.AutoAnswer)]
        /// Drawn and quiet once (or 25 s up): text typed before then could land in a program still starting.
        var startedUp = false
        /// Text waiting until the program is ready (drawn, quiet, no question open), first in first out: the launch
        /// prompt, then whatever was sent while it waited.
        var pendingPrompts: [(text: String, draft: Bool, paste: Bool)] = []
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

        init(record: Session, manifest: AgentManifest, logSize: Int, callbacks: Callbacks, trail: StatusTrail) {
            self.record = record
            self.trail = trail
            detector = StatusDetector(manifest: manifest)
            hooked = manifest.hooks != nil
            selfNames = [manifest.id, manifest.name, (record.cwd as NSString).lastPathComponent]
            autoAnswers = manifest.autoAnswers.compactMap { a in
                Log.session.attempt("\(manifest.id)'s auto-answer pattern") { try NSRegularExpression(pattern: a.pattern) }.map { ($0, a) }
            }
            self.logSize = logSize
            wantsTopic = callbacks.topic != nil
            wantsURL = callbacks.localURL != nil
            wantsLimits = callbacks.limits != nil || record.agent == "codex"
        }

        /// The last `bytes` of what it printed, without escapes: what's on screen, near enough.
        func screen(_ bytes: Int) -> String { StatusDetector.stripANSI(String(decoding: ring.suffix(bytes), as: UTF8.self)) }

        /// The modes in effect where the history (the ring's last `ringLimit` bytes) starts.
        var historyModes: TerminalModes {
            var m = ringModes
            m.read(ring.dropLast(LiveSession.ringLimit))
            return m
        }

        // What a chunk of output says. Whether a chunk has a sequence at all is asked of its bytes: String.contains
        // compares Characters, and on a stream of output that was most of the daemon's time.

        /// OSC 7501 reports (true: the agent asked whether Kelp reads them) and ConEmu progress.
        mutating func readReports(_ text: String, _ d: Data) -> Bool {
            var probe = false
            if !hooked, d.range(of: Data(ProgramStatus.prefix.utf8)) != nil || !oscCarry.isEmpty {
                for m in ProgramStatus.scan(text, carry: &oscCarry) {
                    switch m {
                    case .query: probe = true
                    case .report(let r) where r.id == nil: apply(r)   // children (subagents) aren't shown
                    default: break
                    }
                }
            }
            if d.range(of: Data(ProgramStatus.conEmuPrefix.utf8)) != nil, let p = ProgramStatus.conEmuProgress(text).last { record.progress = p }
            return probe
        }

        /// A new topic from the terminal title the agent sets.
        mutating func readTopic(_ text: String, _ d: Data) -> String? {
            guard wantsTopic, d.range(of: Data("\u{1B}]".utf8)) != nil || !titleCarry.isEmpty,
                  let t = TerminalTitle.scan(text, carry: &titleCarry).last.flatMap({ TerminalTitle.topic($0, names: selfNames) }), t != lastTopic else {
                return nil
            }
            lastTopic = t
            return t
        }

        /// Bracketed paste switched on or off (the sequence can be split across two reads).
        mutating func notePasteMode(_ d: Data) {
            let scan = pasteCarry + d
            if let on = scan.range(of: Data("\u{1B}[?2004".utf8), options: .backwards), on.upperBound < scan.endIndex { pasteMode = scan[on.upperBound] == UInt8(ascii: "h") }
            pasteCarry = Data(d.suffix(7))
        }

        /// The keys that answer a question the manifest knows (a menu is steered instead, see `steer`).
        mutating func autoAnswer() -> (input: String, asked: NSRegularExpression, after: Double)? {
            guard !autoAnswers.isEmpty, !typedYet, Date().timeIntervalSince(started) < 90 else { return nil }
            let tail = screen(4000)
            let r = NSRange(tail.startIndex..., in: tail)
            guard let i = autoAnswers.firstIndex(where: { $0.0.firstMatch(in: tail, range: r) != nil }) else { return nil }
            let a = autoAnswers[i].1
            if let choose = a.choose, let re = Log.session.attempt("an auto-answer's choice pattern", { try NSRegularExpression(pattern: choose) }) {
                steering = (re, Date(), .distantPast, autoAnswers[i].0); autoAnswers.remove(at: i)   // closed loop, see steer()
                return nil
            }
            let asked = autoAnswers.remove(at: i).0; dialogSettled = true
            return (a.input, asked, a.after ?? 0.4)
        }

        /// The first local URL it prints (a dev server), with 0.0.0.0 and [::] as localhost.
        mutating func localURL(_ plain: String) -> String? {
            guard !sawURL, wantsURL, let m = LiveSession.urlRegex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
                  let r = Range(m.range, in: plain) else { return nil }
            sawURL = true
            return String(plain[r]).replacingOccurrences(of: "0.0.0.0", with: "localhost").replacingOccurrences(of: "[::]", with: "localhost")
        }

        /// Plan limits Claude Code (or Cursor Agent or Codex, once it ran out) printed, when they changed.
        mutating func newLimits(_ d: Data) -> [ClaudeLimits.Reading] {
            guard wantsLimits, d.range(of: Data("limit".utf8)) != nil else { return [] }
            let found = record.agent == "cursor" ? ClaudeLimits.parseCursorLimitHit(screen(1200)).map { [$0] } ?? []
                : record.agent == "codex" ? ClaudeLimits.parseCodexLimitHit(screen(1200)).map { [$0] } ?? []
                : ClaudeLimits.parse(screen(1200))
            if !hooked, let r = found.first(where: { $0.percent >= 100 }) {
                limitSeen = (LimitHit(kind: r.kind, resets: r.resets), Date())
                settleLimit()
            }
            guard !found.isEmpty, found != lastLimits else { return [] }
            lastLimits = found
            return found
        }

        /// The words count only by a turn that stopped: the same ones in a file it reads, or a test's output, stop nothing.
        /// Hooks say so themselves (`hitLimit`). Limit: words printed in the last half minute of a turn that ended for another
        /// reason count too.
        mutating func settleLimit() {
            guard let seen = limitSeen, [.done, .error].contains(record.status), let at = record.statusAt,
                  abs(seen.at.timeIntervalSince(at)) < 30 else { return }
            record.limitHit = seen.hit
            limitSeen = nil
        }

        /// What the program says about itself (OSC 7501 or `kelp report`): its state, a message for its row, how far it got.
        mutating func apply(_ r: ProgramStatus.Report) {
            detector.program(r.state, cutShort: Date().timeIntervalSince(stopKeyAt) < 10); lastHookAt = Date()
            if let msg = r.msg, !msg.isEmpty { record.summary = msg } else if r.state == "idle" || r.state == "clear" { record.summary = "" }
            record.progress = r.progress
        }

        /// A hook event from the agent: its status, and what a compaction or a question says on the row. `trigger`: PreCompact's
        /// manual / auto; `message`: what a Notification says ("Claude needs your permission to use Bash"); `asker`: whose
        /// permission dialog it is, for `tool`.
        mutating func hook(_ event: String, trigger: String? = nil, message: String? = nil, asker: String? = nil) {
            heard()
            // A prompt after a Stop held for its command (yours, or the <task-notification> that it ended): a new turn, which
            // isn't waiting for it. The next Stop says again.
            if holding, event == "working" { record.awaiting = nil }
            holding = false
            let compacting = "Compacting the conversation…"
            switch event {
            case "compacting":
                compactManual = trigger == "manual"
                // Claude Code also compacts a conversation left idle (trigger "auto", nothing running): no turn follows to end
                // it, so the row keeps its status and only says what is going on.
                compactSummary = record.summary
                record.summary = compacting
                if compactManual || detector.status == .working { detector.hook("working") }
            case "compacted":
                if record.summary == compacting { record.summary = compactSummary ?? "" }
                compactSummary = nil
                if compactManual { detector.override(.idle, because: "/compact finished") }   // back at the prompt; an auto one carries on
                compactManual = false
            case "waiting":
                if let asker { asking.insert(asker) }
                if let message, !message.isEmpty { record.summary = message }
                detector.hook(event)
            case "working":
                asking.removeAll()
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
                guard agent == nil, detector.status == .done || detector.status == .idle else { return }
                detector.override(.working, because: "a tool started after its turn ended")
            case "PostToolBatch":
                guard asking.remove(agent ?? "") != nil, asking.isEmpty, detector.status == .waiting else { return }
                detector.override(.working, because: "the tools it asked about ran")
            default: break
            }
        }

        /// A sign of life from the agent: a hook, or what it printed.
        mutating func heard(at now: Date = Date()) { lastHookAt = now; lastLifeUp = ProcessInfo.processInfo.systemUptime }

        /// One more change to its commands, for the watchers (`Watches.touched`).
        mutating func newCommands() -> Int { commandChanges += 1; return commandChanges }

        /// The row's running command: the last one started that hasn't ended (one moved to the background has). Whether
        /// that changed.
        mutating func showRunning() -> Bool {
            let now = commands.last { $0.outcome == nil }?.command
            guard now != record.running else { return false }
            record.running = now
            return true
        }

        /// A command it sent to the background mid-turn: on the record now, not only at the next Stop, so asking meanwhile
        /// still shows it runs; the one it waits for unless it looks like a server. Whether the record changed.
        /// Limit: its end isn't told; it stays listed until that Stop says what still runs.
        mutating func sentToBackground(_ command: String) -> Bool {
            guard record.background?.contains(command) != true else { return false }
            record.background = (record.background ?? []) + [command]
            if record.awaiting == nil, !TurnEnd.looksLikeServer(command) { record.awaiting = command }
            return true
        }

        /// Its turn or its program ended: a command whose end wasn't told (a denied permission, an interrupt) runs no more.
        mutating func endCommands(at now: Date) {
            let open = commands.indices.filter { commands[$0].outcome == nil }
            for i in open { commands[i].outcome = .stopped; commands[i].ended = now }
            if !open.isEmpty { _ = newCommands() }
            _ = showRunning()
        }

        /// A row that says working while the screen stood still for minutes and no hook came: a Stop (or a compaction's end) was
        /// one Kelp doesn't know of or missed, and the row would stay working, keeping the Mac awake, until the next prompt.
        /// Claude Code redraws its timer every second while it works; one held for what it waits for is quiet by design.
        /// A menu on that screen is a question whose hook never came: it waits for the user, and its turn goes on after.
        /// Limit: a still screen is the only evidence, and the answer, done, is also what a quiet but live agent would get.
        mutating func releaseStale(at up: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            let limit: TimeInterval = holding ? 1800 : 180
            guard hooked, detector.status == .working, up - lastLifeUp > limit else { return }
            if menuOpen() {
                detector.override(.waiting, because: "no sign of life for \(Int(limit)) s, and a menu on screen")
                return
            }
            holding = false
            record.goal = nil
            record.awaiting = nil
            detector.override(.done, because: "no sign of life for \(Int(limit)) s")
        }

        /// The detector's status into the record; the record when it changed. Ended is final: a hook or a keystroke that
        /// arrives after the exit doesn't bring the session back.
        mutating func sync() -> Session? {
            let s = detector.status
            guard s != record.status, record.status != .exited else { return nil }
            trail.add("\(record.status.rawValue) → \(s.rawValue)  \(detector.source)")
            record.status = s
            if s == .done || s == .waiting || s == .exited || s == .error { record.unread = true }
            if s == .done || s == .error { settleLimit() } else { record.limitHit = nil; record.continueAt = nil }   // it moved on
            return record
        }

        /// The user's keys into `typing`; the first line of 8 characters or more they send (once), which names the session.
        mutating func noteTyping(_ d: Data) -> String? {
            boxEmpty = false
            let s = String(decoding: d, as: UTF8.self)
            if s.hasPrefix("\u{1B}[200~") {   // a paste: its newlines are text, not Return
                typing += s.replacingOccurrences(of: "\u{1B}[200~", with: "").replacingOccurrences(of: "\u{1B}[201~", with: "")
                    .replacingOccurrences(of: "\r", with: "\n")
                return nil
            }
            if let k = LiveSession.kittyKey(s) {
                switch (k.key, k.mods) {
                case (13, 0): return sendLine()   // Return (⇧Return is a new line in the box)
                case (99, 4), (117, 4): typing = ""   // ⌃C, ⌃U
                case (119, 4), (127, 2): dropWord()   // ⌃W, ⌥⌫
                default: break
                }
                return nil
            }
            if s == "\u{1B}\u{7F}" { dropWord(); return nil }   // ⌥⌫
            if s.hasPrefix("\u{1B}") { return nil }   // arrows, function keys
            var sent: String?
            for ch in s {
                switch ch {
                case "\r", "\n", "\r\n": sent = sendLine() ?? sent
                case "\u{03}", "\u{15}": typing = ""   // ⌃C, ⌃U: the line is dropped
                case "\u{7F}", "\u{08}": if !typing.isEmpty { typing.removeLast() }
                case "\u{17}": dropWord()   // ⌃W
                default: if !ch.isASCII || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol || ch == " " { typing.append(ch) }
                }
            }
            return sent
        }

        /// Return: the line is sent. The first one of 8 characters or more, once.
        private mutating func sendLine() -> String? {
            let line = typing.trimmingCharacters(in: .whitespacesAndNewlines)
            typing = ""; boxEmpty = true
            guard !sawFirstPrompt, line.count >= 8 else { return nil }
            sawFirstPrompt = true
            return line
        }

        private mutating func dropWord() {
            while typing.last == " " { typing.removeLast() }
            while let c = typing.last, c != " " { typing.removeLast() }
        }
    }
}
