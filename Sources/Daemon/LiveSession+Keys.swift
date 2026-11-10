import Agents
import Core
import Foundation

// The user's keys: what a press means (a stop, a menu's answer, y/n) and what typing does to the session.

extension LiveSession {
    /// Esc or ⌃C, as one byte or as the kitty keyboard protocol sends them once the agent turns it on (Claude Code does):
    /// ESC[27u, ESC[99;5u — on a non-Latin layout the layout's own letter comes first (ESC[1089::99;5u).
    static func isStopKey(_ keys: Data) -> Bool {
        keys == Data([0x1B]) || keys.contains(0x03)
            || String(decoding: keys, as: UTF8.self).wholeMatch(of: /\x1B\[(27|([0-9]*:)*99;5)u/) != nil
    }

    /// Keys that pick an option in an agent's menu: Return, a digit, ⇧Tab (Claude Code's "allow all edits during this session").
    static func answersMenu(_ keys: Data) -> Bool {
        let text = String(decoding: keys, as: UTF8.self)
        if keys.contains(0x0D) || (keys.count == 1 && (0x31...0x39).contains(keys[0])) || text == "\u{1B}[Z" {
            return true
        }
        return kittyKey(text).map { $0 == (13, 0) || $0 == (9, 1) } ?? false
    }

    /// Keys that move a menu's cursor without picking: arrows, Tab, ⇧Tab.
    static func movesInMenu(_ keys: Data) -> Bool {
        String(decoding: keys, as: UTF8.self).wholeMatch(of: /(?:\x1B(?:\[[0-9;]*|O)[A-DZ]|\t)+/) != nil
    }

    /// The one key some agents take for an answer (Codex's y, a, n).
    static func saysYesOrNo(_ keys: Data) -> Bool { keys.count == 1 && "yanYAN".utf8.contains(keys[0]) }

    /// A key pressed as the kitty keyboard protocol sends it (ESC[key:shifted:base;mods:event u): its key on the Latin
    /// layout (`base`, when a non-Latin one is on) and its modifiers (⇧ 1, ⌥ 2, ⌃ 4, lock keys left out). nil for a release.
    static func kittyKey(_ sequence: String) -> (key: Int, mods: Int)? {
        guard
            let match = sequence.wholeMatch(
                of: /\x1B\[([0-9]+)(?::[0-9]*)?(?::([0-9]+))?(?:;([0-9]+)(?::([0-9]+))?)?(?:;[0-9:]*)?u/),
            match.4.map({ $0 != "3" }) ?? true, let key = Int(match.2 ?? match.1)
        else { return nil }
        return (key, ((match.3.flatMap { Int($0) } ?? 1) - 1) & 0b111111)
    }

    /// Keystrokes from a UI: the first submitted line becomes the source of the tab title.
    func userInput(_ keys: Data) {
        guard !state.withLock({ $0.letGo }) else { return }   // its program stopping or handed over: an attach's keys go nowhere
        write(keys)
        guard !TerminalReplies.isReply(keys) else { return }   // the terminal answering the agent, not the user typing
        let firstPrompt = state.withLock { st -> String? in
            // Keys that answer a question or menu on screen ("1", Return on an option) aren't a line being written.
            let answering =
                st.trustQuestionOpen() || st.menuOpen()
                || (st.record.status == .waiting && keys.count == 1 && (0x31...0x39).contains(keys[0]))
            st.typedYet = true
            st.lastInputAt = Date()
            // Moving through "trust this folder?" doesn't answer it: a launch prompt typed then would land its Enter on
            // whichever option the cursor reached ("No, exit"), and its text would be lost.
            if !(st.trustQuestionOpen() && Self.movesInMenu(keys)) { st.dialogSettled = true }
            st.draftWaiting = false
            st.detector.input(typing: !keys.contains(0x0D))   // keys without Return: the prompt is still being written
            var read: Session?
            if st.record.unread {
                st.record.unread = false
                read = st.record
            }   // typing into it is having read it
            // Hooks send nothing for a cut-short turn, and a heuristic would call it done a few seconds late: the screen decides.
            if Self.isStopKey(keys), st.record.status == .working || (st.saysItself && st.record.status == .waiting) {
                st.interruptArmed = (Date(), "")
                st.stopKeyAt = Date()
            }
            if st.saysItself {
                // An answer to a question or a permission menu: it works again (Claude Code sends no hook for that).
                if st.record.status == .waiting || st.asked, Self.answersMenu(keys) {
                    st.interruptArmed = (Date(), "")
                    if st.answeredOne() { st.detector.override(.working, because: "an answer typed in the terminal") }
                }
            } else if st.record.status == .waiting,
                Self.answersMenu(keys) || Self.isStopKey(keys) || Self.saysYesOrNo(keys)
            {
                st.detector.answered()
            }
            emit(st.sync() ?? read)
            if answering {
                st.typing = ""
                return nil
            }
            return st.noteTyping(keys)
        }
        if let line = firstPrompt {
            let cb = callbacks.firstPrompt
            DispatchQueue.global().async { cb(line) }
        }
    }
}
