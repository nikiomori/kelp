import Foundation

/// A command an agent ran with its shell tool (Claude Code's Bash, Droid's Execute), as its hooks tell it (`kelp hook command`): what it
/// ran, how that went and the end of what it printed. The session's tab lists them (`session.commands`), its row shows the
/// one running.
public struct AgentCommand: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
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

    public init(
        id: String, command: String, description: String? = nil, started: Date = Date(), ended: Date? = nil,
        outcome: Outcome? = nil, exitCode: Int? = nil, output: String? = nil
    ) {
        self.id = id
        self.command = command
        self.description = description
        self.started = started
        self.ended = ended
        self.outcome = outcome
        self.exitCode = exitCode
        self.output = output
    }

    public static let outputLimit = 4096

    /// From a Claude Code hook's payload: PreToolUse starts it, PostToolUse / PostToolUseFailure end it. nil for any other
    /// tool or event.
    public init?(hook payload: JSONValue, now: Date = Date()) {
        guard ["Bash", "Execute"].contains(payload["tool_name"]?.string) else { return nil }
        guard let id = payload["tool_use_id"]?.string, let command = payload["tool_input"]?["command"]?.string else {
            return nil
        }
        self.init(id: id, command: command, description: payload["tool_input"]?["description"]?.string, started: now)
        switch payload["hook_event_name"]?.string {
        case "PreToolUse": return
        case "PostToolUse":
            let response = payload["tool_response"]
            if response?["backgroundTaskId"]?.string != nil {
                outcome = .background
            } else {
                outcome = response?["interrupted"]?.bool == true ? .stopped : .ok
                exitCode = outcome == .ok ? 0 : nil
            }
            output = Self.tail(
                [response?["stdout"]?.string, response?["stderr"]?.string].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(
                        separator: "\n"))
        case "PostToolUseFailure":
            // "Exit code 1\n<what it printed>"; anything else (a refusal, a timeout) is the reason itself.
            let error = payload["error"]?.string ?? ""
            if payload["is_interrupt"]?.bool == true { outcome = .stopped } else { outcome = .failed }
            if let match = error.prefixMatch(of: /Exit code (\d+)\n?/) {
                exitCode = Int(match.1)
                output = Self.tail(String(error[match.range.upperBound...]))
            } else {
                output = Self.tail(error)
            }
        default: return nil
        }
        ended = now
        if let ms = payload["duration_ms"]?.number { started = now.addingTimeInterval(-ms / 1000) }
    }

    /// The end of what it printed, at most `outputLimit` bytes; nil for nothing.
    static func tail(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard text.utf8.count > outputLimit else { return text }
        return String(decoding: text.utf8.suffix(outputLimit), as: UTF8.self)
    }

    /// What it runs, in a line: its first step that does something — past the variables an agent's script sets first
    /// (`S=/tmp/x;`), `cd`, `export`, `set` and comments — without the variables set for that step alone
    /// (`KELP_HOME=/tmp/k make` is `make`), its program by name (`.build/debug/kelp` is `kelp`). Its first line when no
    /// step is left.
    public var shortCommand: String { Self.short(command) }
    public static func short(_ command: String) -> String {
        for step in steps(command) {
            let run = step.replacing(/^(?:[A-Za-z_]\w*=(?:"[^"]*"|'[^']*'|\$\([^)]*\)|\S)*?(?:\s+|$))+/, with: "")
            let program = run.prefix { $0 != " " }
            if run.isEmpty || run.hasPrefix("#") || ["cd", "export", "set"].contains(program) { continue }
            return program.contains("/") ? (program as NSString).lastPathComponent + run.dropFirst(program.count) : run
        }
        return command.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? command
    }

    /// The steps of a shell command — split at `;`, `&&`, `||` and new lines outside quotes and `$( )` — trimmed.
    static func steps(_ command: String) -> [String] {
        var steps: [String] = [], step = "", quote: Character?, depth = 0, escaped = false
        var chars = command.makeIterator(), next = chars.next()
        while let char = next {
            next = chars.next()
            if escaped {
                step.append(char)
                escaped = false
                continue
            }
            if char == "\\" && quote != "'" {
                step.append(char)
                escaped = true
                continue
            }
            if let closing = quote {
                step.append(char)
                if char == closing { quote = nil }
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
            } else if char == "(" {
                depth += 1
            } else if char == ")" {
                depth = max(0, depth - 1)
            }
            let ends = depth == 0 && (char == ";" || char == "\n" || (char == "&" || char == "|") && next == char)
            guard ends else {
                step.append(char)
                continue
            }
            if char != ";" && char != "\n" { next = chars.next() }   // the second & or |
            steps.append(step)
            step = ""
        }
        return (steps + [step]).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
