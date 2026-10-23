import Foundation
import Core

/// Derives agent status from output and idle time. Hook events always win over heuristics.
public struct StatusDetector: Sendable {
    public private(set) var status: AgentStatus = .idle
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
    private let manifest: AgentManifest
    private let regexes: [NSRegularExpression]

    public init(manifest: AgentManifest) {
        self.manifest = manifest
        // Agents with hooks report every change themselves; guessing from output would call a TUI that redraws
        // its idle prompt "working" (a resumed Claude Code sits at its prompt until it gets a task).
        hooked = manifest.hooksSettingsFlag != nil
        regexes = manifest.waitingPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// Paused or ended: nothing the program still prints (or reports) as it's stopped changes that. A pause that read as
    /// "working" again would be saved as ended, and the session couldn't resume.
    private var settled: Bool { status == .hibernated || status == .exited }

    public mutating func output(_ chunk: String, at now: Date = Date()) {
        // The agent reports itself: nothing here is read (tick checks the same). Plain shells don't track status.
        guard !hooked, !settled, manifest.quietSeconds < 1e8 else { return }
        let text = Self.stripANSI(chunk)
        tail = String((tail + text).suffix(600))
        // Redraws with no words (spinners, timers, borders) aren't the agent doing anything; a spinner in front of the
        // title is: Codex turns one there every second while it works ("⠋ Fix login | shop"), a long command printing nothing.
        guard active, Self.hasWords(text) || Self.spinsTitle(chunk), now.timeIntervalSince(settledAt ?? .distantPast) > 4,
              now.timeIntervalSince(typedAt ?? .distantPast) > 2 else { return }
        lastOutput = now
        status = .working
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
        let r = NSRange(tail.startIndex..., in: tail)
        status = regexes.contains { $0.firstMatch(in: tail, range: r) != nil } ? .waiting : .done
        settledAt = now
        return status
    }

    /// Hook event: "working" | "waiting" | "done". Once seen, heuristics are off for this session.
    public mutating func hook(_ event: String) {
        hooked = true
        guard !settled else { return }
        switch event {
        case "working": status = .working
        case "waiting": status = .waiting
        case "done": status = .done
        default: break
        }
    }

    /// OSC 7501 report from the agent itself: as good as a hook, heuristics are off from here.
    public mutating func program(_ state: String) {
        hooked = true
        guard !settled else { return }
        switch state {
        case "idle", "clear": status = .idle
        case "working": status = .working
        case "done": status = .done
        case "blocked": status = .waiting
        case "error": status = .error
        default: break
        }
    }

    public mutating func exited() { status = .exited }

    /// Attached again to a program that kept running (tmux): what it prints is its work, typed or not, once tmux's redraw
    /// of the screen in the first seconds is past (that redraw is no turn, and its end no "done").
    public mutating func attachedToRunning(at now: Date = Date()) { active = true; settledAt = now }

    /// Taken over from the kelpd an update replaced: its program went on as `status`, past its first input.
    public mutating func adopted(_ status: AgentStatus, at now: Date = Date()) {
        self.status = status; active = true
        if status == .working { lastOutput = now }   // it settles once quiet, as it would have
    }

    /// The user typed into the agent: whatever it asked before is answered, only what it prints next can ask again.
    /// `typing`: keys without Return (the prompt is still being written); output in the next seconds is their echo.
    public mutating func input(typing: Bool = false, at now: Date = Date()) { tail = ""; active = true; settledAt = nil; typedAt = typing ? now : nil }

    /// A better guess from elsewhere (local model) that does not switch heuristics off like a hook does.
    public mutating func override(_ s: AgentStatus) { if status != .exited && status != .hibernated { status = s } else if s == .hibernated { status = s } }

    // TUIs often place words with cursor moves instead of spaces; keep a space there so text stays readable.
    private static let cursorMoves = try? NSRegularExpression(pattern: #"\x{1B}\[\d*[GC]"#)
    // ESC ( B too (a character set): Grok ends each redraw with it, and its "B"s read as words, a redraw as work.
    private static let escapes = try? NSRegularExpression(pattern: #"\x{1B}\[[0-9;?<>=]*[ -/]*[@-~]|\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)|\x{1B}[78=>]|\x{1B}[()][0-9A-Za-z]"#)

    /// Runs on every chunk of every session: compiled once, and text without an escape is returned as is.
    public static func stripANSI(_ s: String) -> String {
        guard s.utf8.contains(0x1B), let cursorMoves, let escapes else { return s }
        let spaced = cursorMoves.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        return escapes.stringByReplacingMatches(in: spaced, range: NSRange(spaced.startIndex..., in: spaced), withTemplate: "")
    }
}
