import Agents
import Core
import Foundation

/// Typing into a session: what holds text back (a trust question, a startup menu, text queued before it), answering an
/// agent's menu, and sending text as text.
extension LiveSession {
    /// Whether the session asks the user something an agent's keys would answer: a question it said it asks
    /// (`.waiting`, or a dialog a hook counted that nothing answered yet, `asked`), "trust this folder?" or a numbered
    /// menu on screen, said or not. An agent may not type into such a session (`typesInto`, an agent's attach).
    var asksSomething: Bool {
        state.withLock { $0.record.status == .waiting || $0.asked || $0.trustQuestionOpen() || $0.menuOpen() }
    }
}

extension LiveSession.State {
    func trustQuestionOpen() -> Bool { !dialogSettled && StartupQuestion.trustAsked(screen(4000)) }

    /// Whether a numbered menu with its cursor is on screen ("❯ 1. Use this and all future MCP servers"). The input
    /// box's own "❯" is followed by text, not "1.", and once a menu is answered the newer cursor belongs to the input
    /// box.
    func menuOpen() -> Bool { StartupQuestion.menuOpen(menuScreen()) }

    /// Whether a hook, or an agent in tmux on a host, says it's asking something, whether or not a menu can be read,
    /// because typed text's Enter would answer it.
    private var asks: Bool { reportsTurns && record.status == .waiting }

    /// Whether the session's status comes from the agent turn by turn: hooks, or what they write in tmux on a host
    /// (`Hooks.hostSettingsJSON`).
    var reportsTurns: Bool { hooked || record.tmux != nil }
    /// `reportsTurns`, and the agent really does report. Hooks that stayed silent, or an agent on a host with no hooks
    /// there, are read off the screen instead. Code that waits for a status to come, instead of reading one, asks this.
    var saysItself: Bool { reportsTurns && detector.hooked }

    /// The output a menu is read from: the last bytes, or, when it's asking or being answered, around the last cursor. TUIs
    /// redraw only what changed, and Claude Code blinks a dot beside the tool a dialog is about, which takes the menu out of
    /// the last bytes in 20 s or so while it's still on screen.
    func menuScreen() -> String {
        let reach = ring.suffix(LiveSession.menuReach)
        let cursor =
            reach.range(of: Data("❯".utf8), options: .backwards) ?? reach.range(of: Data("›".utf8), options: .backwards)
        guard asks || (hooked && steering != nil), let mark = cursor else { return screen(1500) }
        let around = max(reach.startIndex, mark.lowerBound - 1500)..<min(reach.endIndex, mark.upperBound + 1500)
        return StatusDetector.stripANSI(String(decoding: reach[around], as: UTF8.self))
    }

    /// Whether nothing on screen would take typed text's Enter as an answer: no question or numbered menu is open
    /// (their default is usually "Yes": trusting a project, its new MCP servers, a permission), no menu is being
    /// answered, and no unread draft is in the input box. For text that's sent (`submits`), the user must also have
    /// nothing typed and unsent, because the Enter would send their half line.
    func readyForText(submits: Bool) -> Bool {
        steering == nil && !kept.draftWaiting && !(submits && !kept.typing.isEmpty) && !asks && !trustQuestionOpen()
            && !menuOpen()
    }

    /// Whether nothing came up on screen since a send's `text` went in. A dialog that opens in those moments would take
    /// the send's Enter as its answer, usually "Yes". The text's own first line next to the input box's cursor ("❯ 1.
    /// fix the tests") isn't a menu.
    func takesEnter(after text: String) -> Bool {
        guard steering == nil, !asks, !trustQuestionOpen() else { return false }
        guard menuOpen(), let option = AgentManifest.AutoAnswer.optionAtCursor(menuScreen()) else { return true }
        return text.hasPrefix(option)
    }

    /// Notes that a send's Enter wasn't pressed: its text is a draft for the user now, and no line went in for a hook
    /// to answer.
    mutating func enterHeld() {
        kept.boxEmpty = false
        kept.draftWaiting = true
        lineSentUp = nil
    }

    /// Whether `question` is what the session asks now, and nothing else, because with several dialogs open the summary
    /// is the newest and the screen shows the oldest.
    func asksOnly(_ question: String) -> Bool {
        record.status == .waiting && record.summary == question && kept.asking.values.reduce(0, +) <= 1
    }

    /// Whether a child's report can be typed now. It waits until the agent rests at an empty prompt, because in a turn
    /// its Enter could land on a dialog that opened meanwhile, which nobody sent it to answer. ↑ leaves an old prompt
    /// in the box with nothing typed.
    func takesReport() -> Bool {
        !reports.isEmpty && pendingPrompts.isEmpty && [.done, .idle, .error].contains(record.status)
            && (kept.boxEmpty || !typedYet)
            && readyForText(submits: true)
    }
}

extension LiveSession {
    /// Steers an armed menu answer, on every tick. It reads the latest menu render and presses Enter only when the
    /// cursor sits on the wanted option.
    func steer() {
        let key = state.withLock { state -> String? in
            guard let st = state.steering else { return nil }
            if Date().timeIntervalSince(st.since) > 30 {
                state.steering = nil
                return nil
            }
            guard Date().timeIntervalSince(st.lastKey) > 0.7 else { return nil }
            let screen = state.menuScreen()
            // The dialog it was armed for has to be the one on screen, at every key: another menu is never pressed.
            if let must = st.screen,
                must.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)) == nil || state.typedYet
            {
                state.steering = nil
                return nil
            }
            guard let option = AgentManifest.AutoAnswer.optionAtCursor(screen) else { return nil }
            if st.choose.firstMatch(in: option, range: NSRange(option.startIndex..., in: option)) != nil {
                state.steering = nil
                state.dialogSettled = true
                return "\r"
            }
            state.steering?.lastKey = Date()
            return "\u{1B}[B"   // menus wrap, so stepping down always reaches it
        }
        if let key { write(Data(key.utf8)) }   // after what's being typed: never between a send's text and its Enter
    }

    /// Answers the menu the agent shows (a permission request) from outside the terminal — a notification's Allow / Deny.
    /// The cursor is walked to the option and Enter pressed only there (see `steer`). Returns nil when no such menu is
    /// on screen, or it isn't the one `question` was about, so a banner left from before never answers what came after
    /// it.
    func choose(_ answer: String, to question: String? = nil) -> Session? {
        state.withLock { state in
            if let question, !state.asksOnly(question) { return nil }
            let inTmux = state.record.tmux != nil,
                screen = inTmux ? StartupQuestion.optionsOnLines(state.menuScreen()) : state.menuScreen()
            let pattern =
                switch answer {
                case "allow": #"^(\d+\.\s*)?(Yes|Allow|Approve)\b(?!,)"#
                case "deny": #"^(\d+\.\s*)?(No|Deny|Reject)\b"#
                // one of its answers, by its label
                default: #"^(\d+\.\s*)?"# + NSRegularExpression.escapedPattern(for: answer) + #"\s*$"#
                }
            let lines = screen.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " ❯›>"))
            }
            guard AgentManifest.AutoAnswer.optionAtCursor(screen) != nil,
                let re = try? NSRegularExpression(pattern: pattern),
                lines.contains(where: { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil })
            else { return nil }
            // tmux sends only the cells that changed, so the option a moving cursor reaches can't be read, and the
            // option's number picks it instead.
            let option = lines.first { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            if inTmux, let number = option?.prefix(while: \.isNumber), !number.isEmpty {
                write(Data(number.utf8))
            } else {
                state.steering = (re, Date(), .distantPast, nil)
            }
            state.detector.input()
            state.record.unread = false
            // A "No" ends the turn: the screen says so.
            if state.saysItself {
                state.interruptArmed = (Date(), "")
                if state.answeredOne() { state.detector.override(.working, because: "an answer from a notification") }
            } else {
                state.detector.answered()
            }
            return state.sync() ?? state.record
        }
    }

    /// Whether the session asks `question` now and nothing else. nil (an answer not tied to a question shown) matches
    /// whatever is up.
    func asks(_ question: String?) -> Bool {
        guard let question else { return true }
        return state.withLock { $0.asksOnly(question) }
    }

    /// Allow or Deny went to the question's hook, so the agent works again (it goes on either way, told what was
    /// decided).
    func answeredThroughHook() -> Session {
        state.withLock { state in
            state.detector.input()
            state.record.unread = false
            _ = state.answeredOne()
            state.detector.override(.working, because: "an answer from Kelp, through its hook")
            return state.sync() ?? state.record
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        state.withLock { $0.redrawUntil = Date().addingTimeInterval(1) }
        pty.resize(cols: cols, rows: rows)
    }

    /// Makes the program repaint for a terminal just attached to history the ring cut off. A full-screen program
    /// (Claude Code, Codex) paints only the cells that changed, so what it drew before the cut (the prompt's frame, the
    /// mode line) would stay blank there. Shrinking by a row and back makes it paint the whole screen. The two sizes
    /// are 0.1 s apart, because SIGWINCHes closer together are read as one, at the size it already had. A size from the
    /// terminal in between wins.
    func repaint() {
        guard state.withLock({ $0.ring.count >= Self.ringLimit }), let size = pty.size, size.rows > 1 else { return }
        resize(cols: size.cols, rows: size.rows - 1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            guard let now = pty.size, now == (size.cols, size.rows - 1) else { return }
            resize(cols: size.cols, rows: size.rows)
        }
    }

    /// Queues a task's text (a launch prompt), typed once the program is ready, as a paste, so a leading "!" or "/" is
    /// text.
    func queuePrompt(_ prompt: String, draft: Bool = false) {
        state.withLock { state in
            state.pendingPrompts.append((prompt, draft, true))
            state.sawFirstPrompt = true
        }
    }

    /// Takes text sent from outside (`session.send`: `kelp send`, review comments), one gate for all of it. It is typed
    /// now when the program is ready for it, or else queued and typed once it is, in the order sent, none overtaking
    /// another. Text to send while the user has typed part of a line is refused, because its Enter would send their
    /// line too, and queued it would wait on a line they may never finish. Text that isn't sent (a reference, a draft)
    /// goes in beside theirs.
    func submit(_ text: String, enter: Bool) throws {
        try state.withLock { state in
            if enter, !state.kept.typing.isEmpty {
                throw RPCError.invalidParams(
                    "Not sent: the prompt has text you typed and haven't sent. Send it or clear it (⌃U), then try again."
                )
            }
            if state.startedUp, state.pendingPrompts.isEmpty, state.readyForText(submits: enter) {
                type(text, enter: enter, paste: false, &state)
            } else {
                state.pendingPrompts.append((text, !enter, false))
                state.sawFirstPrompt = true
            }
        }
    }

    /// Queues a child's news, typed when `takesReport` says so; nothing the agent does until then loses it. Returns
    /// false when the session no longer runs and what it owes has been taken, so the report has to wait in the store.
    func report(_ text: String) -> Bool {
        state.withLock { state in
            guard !state.final, !state.letGo else { return false }
            state.reports.append(text)
            return true
        }
    }

    /// Takes what the session was given and hasn't typed, which it no longer holds afterwards.
    func takeOwed() -> [OwedInput] {
        state.withLock { state in
            let id = state.record.id
            defer {
                state.pendingPrompts.removeAll()
                state.reports.removeAll()
            }
            return state.pendingPrompts.map { OwedInput(session: id, text: $0.text, draft: $0.draft, paste: $0.paste) }
                + state.reports.map { OwedInput(session: id, text: $0, report: true) }
        }
    }

    /// Gives back what was kept while the session didn't run, typed once it's ready as if it had just come.
    func giveBack(_ owed: [OwedInput]) {
        state.withLock { state in
            state.pendingPrompts += owed.filter { !$0.report }.map { ($0.text, $0.draft, $0.paste) }
            state.reports += owed.filter(\.report).map(\.text)
        }
    }

    /// Types text into the agent now (the gate is `submit`). Multi-line text goes as a bracketed paste so TUIs don't
    /// submit each line. Call it inside `state.withLock`: the write is queued under it, so the order of these calls is
    /// the order typed.
    /// `paste` sends the text as a paste even on one line (when the program takes pastes), so a leading "!" or "/" (an
    /// issue title) is text, not a mode or command. Without it one line is typed as keys, so `kelp send <id> /compact`
    /// still runs the command.
    func type(_ text: String, enter: Bool, paste: Bool, _ locked: inout State) {
        locked.detector.input()
        locked.typedYet = true
        locked.inputs += 1
        if enter {
            locked.kept.boxEmpty = true
            locked.expectHook()
            locked.lastSent = text   // what the turn it starts is named after
        } else {
            locked.kept.draftWaiting = true
        }   // a draft is left for the user to read and send
        let takesPastes = locked.kept.pasteMode
        var text = Self.typeable(text)
        // Text not to be sent (a draft, such as an issue's text) goes to a program that takes no pastes as one line,
        // because each newline would submit a line of it, and nothing should go before the user presses Return.
        if !enter, !takesPastes { text = text.replacingOccurrences(of: "\n", with: " ") }
        // A program that never asked for pastes (a plain line reader) has no modes to trip: it gets the text as is.
        let typed = text,
            body = (paste || text.contains("\n")) && takesPastes ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
        // One after another, Enter included: two quick sends must arrive as text, Enter, text, Enter, not text, text,
        // Enter, Enter.
        sends.async { [weak self] in
            guard let self else { return }
            pty.write(Data(body.utf8))
            guard enter else { return }
            Thread.sleep(forTimeInterval: 0.3)
            let safe = state.withLock { state in
                if state.takesEnter(after: typed) { return true }
                state.enterHeld()
                return false
            }
            if safe { pty.write(Data("\r".utf8)) }
        }
    }

    /// Text from elsewhere (an issue, a recipe, a review comment) as plain text: no escape sequences and no control keys but
    /// newlines and tabs. An issue body with ESC[201~ would end the paste, then Return, Shift-Tab or "!cmd" would act as keys.
    static func typeable(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { scalar in
                    scalar == "\n" || scalar == "\t"
                        || !(scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value))
                }))
    }
}
