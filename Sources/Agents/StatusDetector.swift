import Core
import Foundation

/// Derives agent status from output and idle time. Hook events always win over heuristics.
public struct StatusDetector: Sendable {
    public private(set) var status: AgentStatus = .idle
    /// Where `status` came from, for `kelp why`.
    public private(set) var source = "the start"
    private var lastOutput: Date?
    private var tail = ""
    /// Whether the agent reports its status itself (hooks, OSC 7501, `kelp report`), so that nothing is guessed.
    public private(set) var hooked = false
    /// For agents without hooks, nothing counts until the user has typed something, because a welcome menu isn't a
    /// question.
    private var active = false
    /// When heuristics last settled on done or waiting, because the redraws that follow a finished turn ("Worked for
    /// 5.5s") aren't new work.
    private var settledAt: Date?
    /// The time of the user's last keystroke that wasn't Return, because a TUI redraws its input line as you type, and
    /// that isn't work.
    private var typedAt: Date?
    /// Set after attaching again to a running program. Its redraw of the screen is still to come, and that redraw
    /// starts the quiet seconds.
    private var redrawDue = false
    /// An escape sequence that a chunk ended in the middle of (a title split across two reads). It is read with the
    /// next chunk, so its letters aren't taken for words.
    private var carry = ""
    private let manifest: AgentManifest
    private let regexes: [NSRegularExpression]

    /// The clock that quiet is measured on, which stands still while the Mac sleeps. On the wall clock, a lid shut
    /// mid-turn counted as hours of quiet, so the row said Done on waking, and Working again at the next line.
    public static var clock: Date { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }

    public init(manifest: AgentManifest) {
        self.manifest = manifest
        // Agents with hooks report every change themselves; guessing from output would call a TUI that redraws
        // its idle prompt "working" (a resumed Claude Code sits at its prompt until it gets a task).
        hooked = manifest.hooks != nil
        regexes = manifest.waitingPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// Whether the session is paused or ended. Nothing the program still prints or reports as it stops changes that. A
    /// pause that read as "working" again would be saved as ended, and the session couldn't resume.
    private var settled: Bool { status == .paused || status == .exited }

    public mutating func output(_ chunk: String, at now: Date = clock) {
        // An agent that reports its own status isn't read here, and `tick` checks the same. Plain shells don't track
        // status.
        guard !hooked, !settled, manifest.tracksStatus else { return }
        let (chunk, rest) = Self.wholeSequences(carry + chunk)
        carry = rest.count > 4096 ? "" : rest   // a sequence that never ends isn't kept for good
        let text = Self.stripANSI(chunk)
        tail = String((tail + text).suffix(600))
        // However long the connection took (ssh, then tmux's attach), the redraw is measured from when it starts.
        if redrawDue {
            redrawDue = false
            settledAt = now
        }
        // Redraws with no words (spinners, timers, borders) aren't the agent doing anything, but a spinner in front of
        // the title is. Codex turns one there every second while it works ("⠋ Fix login | shop"), even while a long
        // command prints nothing.
        guard active, Self.hasWords(text) || Self.spinsTitle(chunk),
            now.timeIntervalSince(settledAt ?? .distantPast) > 4,
            now.timeIntervalSince(typedAt ?? .distantPast) > 2
        else { return }
        lastOutput = now
        status = .working
        source = "screen: it printed words"
    }

    /// Splits `text` into the part before an escape sequence that it ends inside of, and that unfinished sequence.
    static func wholeSequences(_ text: String) -> (whole: String, rest: String) {
        guard let esc = text.lastIndex(of: "\u{1B}") else { return (text, "") }
        let seq = Array(text[esc...].unicodeScalars)
        let done: Bool =
            switch seq.count > 1 ? seq[1] : "\u{0}" {
            case "\u{0}": false
            case "[": seq.dropFirst(2).contains { (0x40...0x7E).contains($0.value) }   // a CSI ends at its final byte
            case "]", "P", "_", "^": seq.contains("\u{07}")   // OSC and the like end at BEL (ESC \ is a new ESC)
            default: true
            }
        return done ? (text, "") : (String(text[..<esc]), String(text[esc...]))
    }

    private static let letters = CharacterSet.letters
    static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.lazy.filter { letters.contains($0) }.prefix(3).count == 3
    }

    /// An OSC 0 / 2 title that starts with a braille spinner frame (⠋⠙⠹…).
    private static let titleSpinner = try? NSRegularExpression(pattern: #"\x{1B}\][02];[\x{2801}-\x{28FF}]"#)
    static func spinsTitle(_ text: String) -> Bool {
        guard text.utf8.contains(0x1B), let titleSpinner else { return false }
        return titleSpinner.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Call periodically; returns the (possibly new) status.
    @discardableResult
    public mutating func tick(at now: Date = clock) -> AgentStatus {
        guard !hooked, manifest.tracksStatus, status == .working, let last = lastOutput,
            now.timeIntervalSince(last) >= manifest.quietSeconds
        else { return status }
        status = asks ? .waiting : .done
        source =
            "screen: quiet for \(Int(manifest.quietSeconds)) s"
            + (status == .waiting ? ", and its last lines ask something" : "")
        settledAt = now
        return status
    }

    /// Whether the end of what the agent printed asks the user something.
    private var asks: Bool {
        let range = NSRange(tail.startIndex..., in: tail)
        return regexes.contains { $0.firstMatch(in: tail, range: range) != nil }
    }

    /// Takes a hook event. Working, waiting, done and error set the status, and the other events don't change it. Once
    /// a hook is seen, heuristics are off for this session.
    public mutating func hook(_ event: HookEvent) {
        hooked = true
        guard !settled else { return }
        switch event {
        case .working: status = .working
        case .waiting: status = .waiting
        case .done: status = .done
        case .error: status = .error
        case .command, .subagent, .compacting, .compacted: return
        }
        source = "hook: \(event.rawValue)"
    }

    /// Takes an OSC 7501 report from the agent itself. It counts as much as a hook, so heuristics are off from here.
    /// Idle after work means a finished turn, for a program with no "done" of its own, and a finished turn stays done.
    /// `cutShort` means the user just stopped the agent, and a turn the user stopped finished nothing.
    public mutating func program(_ state: String, cutShort: Bool = false) {
        hooked = true
        guard !settled else { return }
        switch state {
        case "idle": status = !cutShort && (status == .working || status == .done) ? .done : .idle
        case "clear":   // with hooks, this only takes back a `kelp report` (`kelp report clear`)
            guard manifest.hooks == nil else { return }
            status = .idle
        case "working": status = .working
        case "done": status = .done
        case "blocked": status = .waiting
        case "error": status = .error
        default: return
        }
        source = "reported by the program: \(state)"
    }

    /// Called when the agent's hooks never spoke after a prompt. From here on, the status is read off the screen as for
    /// an agent without hooks, until a hook comes.
    public mutating func hooksSilent(at now: Date = clock) {
        guard !settled else { return }
        hooked = false
        active = true
        status = .working
        source = "no hook came after a prompt, so it's read off the screen"
        lastOutput = now
    }

    /// Called when a question the agent asked was answered. The agent goes on working, or settles once quiet. An agent
    /// with hooks gets `override` instead, and its hooks say the rest.
    public mutating func answered(at now: Date = clock) {
        guard !settled else { return }
        status = .working
        source = "an answer typed in the terminal"
        lastOutput = now
    }

    public mutating func exited() {
        status = .exited
        source = "the program ended"
    }

    /// Called after attaching again to a program that kept running (tmux). What the program prints counts as work,
    /// whether or not the user typed, once tmux's redraw of the screen in the first seconds is past. That redraw is not
    /// a turn, and its end is not "done".
    public mutating func attachedToRunning(at now: Date = clock) {
        active = true
        settledAt = now
        redrawDue = true
    }

    /// Takes over a session from the kelpd that an update replaced. The session's program went on as `status`, past its
    /// first input, and `screen` is what it printed last. A question that the old kelpd read there is read again with
    /// this kelpd's patterns. Otherwise a pattern the update fixed (Grok's opt-in banner read as "allow … to") would
    /// keep an agent that idles at its prompt in Needs You until it prints again. `hooked` says whether the agent
    /// reported its status itself there, so that a question it asked stays. It is nil from a kelpd that doesn't say,
    /// and then an OSC 7501 on the screen tells.
    public mutating func adopted(
        _ status: AgentStatus, screen: String = "", hooked said: Bool? = nil, at now: Date = clock
    ) {
        self.status = status
        active = true
        source = "taken over from the kelpd an update replaced"
        tail = String(Self.stripANSI(screen).suffix(600))
        if let said { hooked = said }
        if status == .working { lastOutput = now }   // it settles once quiet, as it would have
        guard status == .waiting, !hooked, said != nil || !screen.contains(ProgramStatus.prefix) else { return }
        self.status = asks ? .waiting : .done
        settledAt = now
    }

    /// Called when the user typed into the agent. Whatever the agent asked before is answered, and only what it prints
    /// next can ask again. `typing` means keys without Return (the prompt is still being written), so output in the
    /// next seconds is their echo.
    public mutating func input(typing: Bool = false, at now: Date = clock) {
        tail = ""
        active = true
        settledAt = nil
        typedAt = typing ? now : nil
    }

    /// Called when the agent printed that its turn was cut short. The status is idle at once, and the redraws in the
    /// next seconds ("Conversation interrupted") aren't new work.
    public mutating func interrupted(at now: Date = clock) {
        guard !settled else { return }
        status = .idle
        source = "screen: it says its turn was cut short"
        settledAt = now
    }

    /// A better guess from elsewhere (local model) that does not switch heuristics off like a hook does.
    public mutating func override(_ newStatus: AgentStatus, because why: String = "set by Kelp") {
        guard (status != .exited && status != .paused) || newStatus == .paused else { return }
        status = newStatus
        source = why
    }

    // TUIs often place words with cursor moves instead of spaces; keep a space there so text stays readable. Codex puts
    // each word at its own row;col ("Trust␛[5;9Hthis␛[5;14Hfolder?").
    private static let cursorMoves = try? NSRegularExpression(pattern: #"\x{1B}\[[\d;]*[GCHf]"#)
    // Character set selections are stripped too (ESC ( B, ESC ) 0…), because Grok ends each redraw with one, and its
    // "B"s read as words, so a redraw read as work.
    private static let escapes = try? NSRegularExpression(
        pattern: #"\x{1B}\[[0-9;?<>=]*[ -/]*[@-~]|\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)|\x{1B}[78=>]|\x{1B}[()*+]."#
    )

    /// Strips escape sequences. It runs on every chunk of every session, so the regexes are compiled once, and text
    /// without an escape is returned as it is.
    public static func stripANSI(_ text: String) -> String {
        guard text.utf8.contains(0x1B), let cursorMoves, let escapes else { return text }
        let spaced = cursorMoves.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        return escapes.stringByReplacingMatches(
            in: spaced, range: NSRange(spaced.startIndex..., in: spaced), withTemplate: "")
    }
}

/// What `kelp hook <event>` says (`SessionHook.event`): the words Kelp's hooks files write for an agent's hooks.
public enum HookEvent: String, Sendable, CaseIterable {
    /// A prompt went in, or a question was answered.
    case working
    /// The agent asks the user something.
    case waiting
    /// The agent's turn is over (Stop).
    case done
    /// The agent's turn failed.
    case error
    /// A tool started or ended, or a batch of them.
    case command
    /// A subagent started or ended.
    case subagent
    /// The agent starts compacting its conversation, and then finishes.
    case compacting, compacted
}
