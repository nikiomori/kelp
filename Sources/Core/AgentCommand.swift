import Foundation

/// A command an agent ran with its shell tool (Claude Code's Bash), as its hooks tell it (`kelp hook command`): what it
/// ran, how that went and the end of what it printed. The session's tab lists them (`session.commands`), its row shows the
/// one running.
public struct AgentCommand: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// Exited 0.
        case ok
        /// Exited with another code (`exitCode`), or the tool refused it or timed out (`output` says why).
        case failed
        /// Interrupted, or its turn ended without its end being told (a denied permission, a killed agent).
        case stopped
        /// Moved to the background (`run_in_background`, or it ran past the tool's timeout): its end isn't told here.
        case background
    }

    /// The tool call's id.
    public var id: String
    public var command: String
    /// The agent's own words for it ("Run the tests").
    public var description: String?
    public var started: Date
    public var ended: Date?
    /// nil while it runs.
    public var outcome: Outcome?
    public var exitCode: Int?
    /// The last `outputLimit` bytes it printed (stdout, then stderr).
    public var output: String?

    public init(id: String, command: String, description: String? = nil, started: Date = Date(), ended: Date? = nil,
                outcome: Outcome? = nil, exitCode: Int? = nil, output: String? = nil) {
        self.id = id; self.command = command; self.description = description; self.started = started; self.ended = ended
        self.outcome = outcome; self.exitCode = exitCode; self.output = output
    }

    public static let outputLimit = 4096

    /// From a Claude Code hook's payload: PreToolUse starts it, PostToolUse / PostToolUseFailure end it. nil for any other
    /// tool or event.
    public init?(hook v: JSONValue, now: Date = Date()) {
        guard v["tool_name"]?.string == "Bash", let id = v["tool_use_id"]?.string, let command = v["tool_input"]?["command"]?.string else { return nil }
        self.init(id: id, command: command, description: v["tool_input"]?["description"]?.string, started: now)
        switch v["hook_event_name"]?.string {
        case "PreToolUse": return
        case "PostToolUse":
            let r = v["tool_response"]
            if r?["backgroundTaskId"]?.string != nil { outcome = .background } else {
                outcome = r?["interrupted"]?.bool == true ? .stopped : .ok
                exitCode = outcome == .ok ? 0 : nil
            }
            output = Self.tail([r?["stdout"]?.string, r?["stderr"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        case "PostToolUseFailure":
            // "Exit code 1\n<what it printed>"; anything else (a refusal, a timeout) is the reason itself.
            let error = v["error"]?.string ?? ""
            if v["is_interrupt"]?.bool == true { outcome = .stopped } else { outcome = .failed }
            if let m = error.prefixMatch(of: /Exit code (\d+)\n?/) {
                exitCode = Int(m.1)
                output = Self.tail(String(error[m.range.upperBound...]))
            } else { output = Self.tail(error) }
        default: return nil
        }
        ended = now
        if let ms = v["duration_ms"]?.number { started = now.addingTimeInterval(-ms / 1000) }
    }

    /// The end of what it printed, at most `outputLimit` bytes; nil for nothing.
    static func tail(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        guard s.utf8.count > outputLimit else { return s }
        return String(decoding: s.utf8.suffix(outputLimit), as: UTF8.self)
    }

    /// The command without the `cd <folder> &&` agents put in front of it: what it runs.
    public var shortCommand: String { Self.short(command) }
    public static func short(_ command: String) -> String {
        let s = command.replacing(/^\s*cd\s+("[^"]*"|'[^']*'|\S+)\s*&&\s*/, with: "")
        return s.isEmpty ? command : s
    }
}
