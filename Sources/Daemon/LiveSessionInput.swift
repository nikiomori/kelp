import Foundation
import Core
import Agents

/// Typing into a session: what holds text back (a trust question, a startup menu, text queued before it), answering an
/// agent's menu, and sending text as text.
extension LiveSession.State {
    func trustQuestionOpen() -> Bool { !dialogSettled && StartupQuestion.trustAsked(screen(4000)) }

    /// A numbered menu with its cursor on screen ("❯ 1. Use this and all future MCP servers"). The input box's own "❯"
    /// is followed by text, not "1.", and once a menu is answered the newer cursor is the input box's.
    func menuOpen() -> Bool { StartupQuestion.menuOpen(screen(1500)) }

    /// Nothing on screen that typed text with its Enter would answer: no question or numbered menu open (their default
    /// is usually "Yes": trusting a project, its new MCP servers), no menu being answered, no unread draft in the input box,
    /// and for text that's sent (`submits`) nothing the user typed and hasn't sent: its Enter would send their half line.
    func readyForText(submits: Bool) -> Bool {
        steering == nil && !draftWaiting && !(submits && !typing.isEmpty) && !trustQuestionOpen() && !menuOpen()
    }
}

extension LiveSession {
    /// Called on every tick. Reads the latest menu render; Enter only when the cursor sits on the wanted option.
    func steer() {
        let key = state.withLock { s -> String? in
            guard let st = s.steering else { return nil }
            if Date().timeIntervalSince(st.since) > 30 { s.steering = nil; return nil }
            guard Date().timeIntervalSince(st.lastKey) > 0.7 else { return nil }
            let screen = s.screen(1500)
            // The dialog it was armed for has to be the one on screen, at every key: another menu is never pressed.
            if let must = st.screen, must.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)) == nil || s.typedYet {
                s.steering = nil; return nil
            }
            guard let option = AgentManifest.AutoAnswer.optionAtCursor(screen) else { return nil }
            if st.choose.firstMatch(in: option, range: NSRange(option.startIndex..., in: option)) != nil {
                s.steering = nil
                s.dialogSettled = true
                return "\r"
            }
            s.steering?.lastKey = Date(); return "\u{1B}[B"   // menus wrap, so stepping down always reaches it
        }
        if let key { write(Data(key.utf8)) }   // after what's being typed: never between a send's text and its Enter
    }

    /// Answers the menu the agent shows (a permission request) from outside the terminal — a notification's Allow / Deny.
    /// The cursor is walked to the option and Enter pressed only there (see `steer`). nil: no such menu on screen.
    func choose(_ answer: String) -> Session? {
        state.withLock { s in
            let screen = s.screen(1500)
            let pattern = answer == "allow" ? #"^(\d+\.\s*)?(Yes|Allow|Approve)\b(?!,)"# : #"^(\d+\.\s*)?(No|Deny|Reject)\b"#
            let lines = screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ❯›>")) }
            guard AgentManifest.AutoAnswer.optionAtCursor(screen) != nil, let re = try? NSRegularExpression(pattern: pattern),
                  lines.contains(where: { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) else { return nil }
            s.steering = (re, Date(), .distantPast, nil)
            s.detector.input(); s.record.unread = false
            if s.hooked { s.detector.override(.working); s.interruptArmed = (Date(), "") }   // a "No" ends the turn: the screen says so
            return s.sync() ?? s.record
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        state.withLock { $0.redrawUntil = Date().addingTimeInterval(1) }
        pty.resize(cols: cols, rows: rows)
    }

    /// A task's text (a launch prompt): typed once the program is ready, as a paste, so a leading "!" or "/" is text.
    func queuePrompt(_ p: String, draft: Bool = false) {
        state.withLock { s in s.pendingPrompts.append((p, draft, true)); s.sawFirstPrompt = true }
    }

    /// Text sent from outside (`session.send`: `kelp send`, review comments): one gate for all of it. Typed now when the
    /// program is ready for it, else queued and typed once it is — in the order sent, none overtaking another. Text to
    /// send while the user has typed part of a line is refused: its Enter would send their line too, and queued it would
    /// wait on a line they may never finish. Text that isn't sent (a reference, a draft) goes in beside theirs.
    func submit(_ text: String, enter: Bool) throws {
        try state.withLock { s in
            if enter, !s.typing.isEmpty {
                throw RPCError.invalidParams("Not sent: the prompt has text you typed and haven't sent. Send it or clear it (⌃U), then try again.")
            }
            if s.startedUp, s.pendingPrompts.isEmpty, s.readyForText(submits: enter) { type(text, enter: enter, paste: false, &s) }
            else { s.pendingPrompts.append((text, !enter, false)); s.sawFirstPrompt = true }
        }
    }

    /// Type text into the agent, now (the gate is `submit`). Multi-line text goes as a bracketed paste so TUIs don't
    /// submit each line. Called inside `state.withLock`: the write is queued under it, so the order of these calls is the
    /// order typed. `paste`: as a paste even on one line (when the program takes pastes), so a leading "!" or "/" (an
    /// issue title) is text, not a mode or command. Without it one line is typed, so `kelp send <id> /compact` still runs it.
    func type(_ text: String, enter: Bool, paste: Bool, _ s: inout State) {
        s.detector.input(); s.typedYet = true
        if enter { s.boxEmpty = true } else { s.draftWaiting = true }   // a draft is left for the user to read and send
        let takesPastes = s.pasteMode
        var text = Self.typeable(text)
        // Not to be sent (a draft: an issue's text, say) to a program that takes no pastes: each newline would submit a
        // line of it. One line instead, so nothing goes before the user presses Return.
        if !enter, !takesPastes { text = text.replacingOccurrences(of: "\n", with: " ") }
        // A program that never asked for pastes (a plain line reader) has no modes to trip: it gets the text as is.
        let body = (paste || text.contains("\n")) && takesPastes ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
        // One after another, Enter included: two quick sends must arrive as text, Enter, text, Enter, not text, text, Enter, Enter.
        sends.async { [weak self] in
            self?.pty.write(Data(body.utf8))
            if enter { Thread.sleep(forTimeInterval: 0.3); self?.pty.write(Data("\r".utf8)) }
        }
    }

    /// Text from elsewhere (an issue, a recipe, a review comment) as plain text: no escape sequences and no control keys but
    /// newlines and tabs. An issue body with ESC[201~ would end the paste, then Return, Shift-Tab or "!cmd" would act as keys.
    static func typeable(_ s: String) -> String {
        String(String.UnicodeScalarView(s.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { c in
            c == "\n" || c == "\t" || !(c.value < 0x20 || c.value == 0x7F || (0x80...0x9F).contains(c.value))
        }))
    }
}
