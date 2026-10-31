import Foundation
import Core

/// Derives agent status from output and idle time. Hook events always win over heuristics.
public struct StatusDetector: Sendable {
    public private(set) var status: AgentStatus = .idle
    /// Where `status` came from, for `kelp why`.
    public private(set) var source = "the start"
    private var lastOutput: Date?
    private var tail = ""
    private var hooked = false
    /// Agents without hooks: nothing counts until the user has typed something — a welcome menu isn't a question.
    private var active = false
    /// When heuristics last settled on done / waiting: the redraws that follow a finished turn ("Worked for 5.5s")
    /// aren't new work.
    private var settledAt: Date?
    /// The user's last keystroke that wasn't Return: a TUI redraws its input line as you type, which isn't work.
    private var typedAt: Date?
    /// Attached again to a running program: its redraw of the screen is still to come, and starts the quiet seconds.
    private var redrawDue = false
    /// An escape sequence a chunk ended in the middle of (a title split across two reads): read with the next one, so
    /// its letters aren't taken for words.
    private var carry = ""
    private let manifest: AgentManifest
    private let regexes: [NSRegularExpression]

    public init(manifest: AgentManifest) {
        self.manifest = manifest
        // Agents with hooks report every change themselves; guessing from output would call a TUI that redraws
        // its idle prompt "working" (a resumed Claude Code sits at its prompt until it gets a task).
        hooked = manifest.hooks != nil
        regexes = manifest.waitingPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// Paused or ended: nothing the program still prints (or reports) as it's stopped changes that. A pause that read as
    /// "working" again would be saved as ended, and the session couldn't resume.
    private var settled: Bool { status == .hibernated || status == .exited }

    public mutating func output(_ chunk: String, at now: Date = Date()) {
        // The agent reports itself: nothing here is read (tick checks the same). Plain shells don't track status.
        guard !hooked, !settled, manifest.quietSeconds < 1e8 else { return }
        let (chunk, rest) = Self.wholeSequences(carry + chunk)
        carry = rest.count > 4096 ? "" : rest   // a sequence that never ends isn't kept for good
        let text = Self.stripANSI(chunk)
        tail = String((tail + text).suffix(600))
        // However long the connection took (ssh, then tmux's attach), the redraw is measured from when it starts.
        if redrawDue { redrawDue = false; settledAt = now }
        // Redraws with no words (spinners, timers, borders) aren't the agent doing anything; a spinner in front of the
        // title is: Codex turns one there every second while it works ("⠋ Fix login | shop"), a long command printing nothing.
        guard active, Self.hasWords(text) || Self.spinsTitle(chunk), now.timeIntervalSince(settledAt ?? .distantPast) > 4,
              now.timeIntervalSince(typedAt ?? .distantPast) > 2 else { return }
        lastOutput = now
        status = .working
        source = "screen: it printed words"
    }

    /// `s` up to an escape sequence it ends inside of, and that unfinished sequence.
    static func wholeSequences(_ s: String) -> (whole: String, rest: String) {
        guard let esc = s.lastIndex(of: "\u{1B}") else { return (s, "") }
        let seq = Array(s[esc...].unicodeScalars)
        let done: Bool = switch seq.count > 1 ? seq[1] : "\u{0}" {
        case "\u{0}": false
        case "[": seq.dropFirst(2).contains { (0x40...0x7E).contains($0.value) }   // CSI: its final byte
        case "]", "P", "_", "^": seq.contains("\u{07}")   // OSC and the like: BEL (an ESC \ ending is its own ESC)
        default: true
        }
        return done ? (s, "") : (String(s[..<esc]), String(s[esc...]))
    }

    private static let letters = CharacterSet.letters
    static func hasWords(_ s: String) -> Bool {
        s.unicodeScalars.lazy.filter { letters.contains($0) }.prefix(3).count == 3
    }

    /// An OSC 0 / 2 title that starts with a braille spinner frame (⠋⠙⠹…).
    private static let titleSpinner = try? NSRegularExpression(pattern: #"\x{1B}\][02];[\x{2801}-\x{28FF}]"#)
    static func spinsTitle(_ s: String) -> Bool {
        guard s.utf8.contains(0x1B), let titleSpinner else { return false }
        return titleSpinner.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Call periodically; returns the (possibly new) status.
    @discardableResult
    public mutating func tick(at now: Date = Date()) -> AgentStatus {
        guard !hooked, status == .working, let last = lastOutput, now.timeIntervalSince(last) >= manifest.quietSeconds else { return status }
        status = asks ? .waiting : .done
        source = "screen: quiet for \(Int(manifest.quietSeconds)) s" + (status == .waiting ? ", and its last lines ask something" : "")
        settledAt = now
        return status
    }

    /// The end of what it printed asks the user something.
    private var asks: Bool {
        let r = NSRange(tail.startIndex..., in: tail)
        return regexes.contains { $0.firstMatch(in: tail, range: r) != nil }
    }

    /// Hook event: "working" | "waiting" | "done". Once seen, heuristics are off for this session.
    public mutating func hook(_ event: String) {
        hooked = true
        guard !settled else { return }
        switch event {
        case "working": status = .working
        case "waiting": status = .waiting
        case "done": status = .done
        default: return
        }
        source = "hook: \(event)"
    }

    /// OSC 7501 report from the agent itself: as good as a hook, heuristics are off from here. Idle after work is a finished
    /// turn, for a program with no "done" of its own, and a finished one stays so. `cutShort`: the user just stopped it, and
    /// what they stopped themselves finished nothing.
    public mutating func program(_ state: String, cutShort: Bool = false) {
        hooked = true
        guard !settled else { return }
        switch state {
        case "idle": status = !cutShort && (status == .working || status == .done) ? .done : .idle
        case "clear": status = .idle
        case "working": status = .working
        case "done": status = .done
        case "blocked": status = .waiting
        case "error": status = .error
        default: return
        }
        source = "reported by the program: \(state)"
    }

    public mutating func exited() { status = .exited; source = "the program ended" }

    /// Attached again to a program that kept running (tmux): what it prints is its work, typed or not, once tmux's redraw
    /// of the screen in the first seconds is past (that redraw is no turn, and its end no "done").
    public mutating func attachedToRunning(at now: Date = Date()) {
        active = true
        settledAt = now
        redrawDue = true
    }

    /// Taken over from the kelpd an update replaced: its program went on as `status`, past its first input. `screen`: what it
    /// printed last. A question that kelpd read there is read again with this one's patterns: one the update fixed (Grok's
    /// opt-in banner as "allow … to") would otherwise keep an agent idling at its prompt in Needs You until it prints again.
    /// One the agent reported itself stays: its OSC 7501 is on the screen (the handover doesn't say).
    public mutating func adopted(_ status: AgentStatus, screen: String = "", at now: Date = Date()) {
        self.status = status; active = true; source = "taken over from the kelpd an update replaced"
        tail = String(Self.stripANSI(screen).suffix(600))
        if status == .working { lastOutput = now }   // it settles once quiet, as it would have
        guard status == .waiting, !hooked, !screen.contains(ProgramStatus.prefix) else { return }
        self.status = asks ? .waiting : .done
        settledAt = now
    }

    /// The user typed into the agent: whatever it asked before is answered, only what it prints next can ask again.
    /// `typing`: keys without Return (the prompt is still being written); output in the next seconds is their echo.
    public mutating func input(typing: Bool = false, at now: Date = Date()) { tail = ""; active = true; settledAt = nil; typedAt = typing ? now : nil }

    /// The agent printed that its turn was cut short: idle at once, and its redraws in the next seconds ("Conversation
    /// interrupted") aren't new work.
    public mutating func interrupted(at now: Date = Date()) {
        guard !settled else { return }
        status = .idle
        source = "screen: it says its turn was cut short"
        settledAt = now
    }

    /// A better guess from elsewhere (local model) that does not switch heuristics off like a hook does.
    public mutating func override(_ s: AgentStatus, because why: String = "set by Kelp") {
        guard (status != .exited && status != .hibernated) || s == .hibernated else { return }
        status = s; source = why
    }

    // TUIs often place words with cursor moves instead of spaces; keep a space there so text stays readable. Codex puts
    // each word at its own row;col ("Trust␛[5;9Hthis␛[5;14Hfolder?").
    private static let cursorMoves = try? NSRegularExpression(pattern: #"\x{1B}\[[\d;]*[GCHf]"#)
    // Character set selections too (ESC ( B, ESC ) 0…): Grok ends each redraw with one, and its "B"s read as words, a redraw as work.
    private static let escapes = try? NSRegularExpression(
        pattern: #"\x{1B}\[[0-9;?<>=]*[ -/]*[@-~]|\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)|\x{1B}[78=>]|\x{1B}[()*+]."#)

    /// Runs on every chunk of every session: compiled once, and text without an escape is returned as is.
    public static func stripANSI(_ s: String) -> String {
        guard s.utf8.contains(0x1B), let cursorMoves, let escapes else { return s }
        let spaced = cursorMoves.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        return escapes.stringByReplacingMatches(in: spaced, range: NSRange(spaced.startIndex..., in: spaced), withTemplate: "")
    }
}
