import Core
import Foundation

/// One model call's tokens as an agent logged it.
struct UsageEntry {
    var time: TimeInterval, model: String, cwd: String, id: String?
    var tokens: TokenCounts
    /// The call's cost, when the line alone can tell it (Grok's own figure, Claude's hour-long cache writes). When it
    /// is nil, the call is priced from `Pricing`.
    var cost: Double?
}

/// The agent whose logs a `UsageIndex` reads, which decides which files and lines are read and what a line means.
/// `context` keeps what earlier lines of a file said from one read to the next, because Codex names the model and
/// folder once, not with every call.
public enum UsageFormat: String, Sendable, CaseIterable {
    case claude, codex, grok, kimi, pi, omp, qwen, gemini

    /// The folder where each agent keeps its sessions, inside its own folder (`AgentHome`). It is nil for Claude and
    /// Codex, whose folders come with account profiles.
    public var defaultRoot: URL? {
        let inside: String? =
            switch self {
            case .grok, .kimi, .pi, .omp: "sessions"
            case .qwen: "projects"
            case .gemini: "tmp"
            case .claude, .codex: nil
            }
        return inside.flatMap { inside in AgentHome.dir(rawValue)?.appendingPathComponent(inside) }
    }

    /// Whether this agent's lines say what a call cost (Grok's own figure, pi's). If so, that is the price used, not
    /// the price list's.
    public var ownPrice: Bool { [.grok, .pi, .omp].contains(self) }

    func reads(_ file: URL) -> Bool {
        switch self {
        case .claude: file.pathExtension == "jsonl"
        case .codex: file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-")
        case .grok: file.lastPathComponent == "updates.jsonl"
        case .kimi: file.lastPathComponent == "wire.jsonl"
        case .pi, .omp: file.pathExtension == "jsonl"
        // An archived chat is in chats/archive/.
        case .qwen:
            file.pathExtension == "jsonl"
                && (file.deletingLastPathComponent().lastPathComponent == "chats"
                    || file.deletingLastPathComponent().path.hasSuffix("/chats/archive"))
        case .gemini:
            file.pathExtension == "jsonl"
                && (file.lastPathComponent.hasPrefix("session-")
                    || Self.geminiChats(file) != file.deletingLastPathComponent())
        }
    }

    /// Returns the `tmp/<project>/chats/` folder that a Gemini file belongs to. A subagent's conversation sits one
    /// folder further down, in `chats/<parent id>/<id>.jsonl`.
    static func geminiChats(_ file: URL) -> URL {
        let up = file.deletingLastPathComponent()
        return up.lastPathComponent == "chats" ? up : up.deletingLastPathComponent()
    }

    /// A line that contains none of these isn't parsed, which matters for gigabytes of Claude transcripts.
    var markers: [Data] {
        switch self {
        case .claude: [UsageIndex.marker]
        case .codex: [#""session_meta""#, #""turn_context""#, #""token_count""#].map { Data($0.utf8) }
        case .grok: [Data(#""turn_completed""#.utf8)]
        case .kimi: [Data(#""usage.record""#.utf8)]
        case .pi, .omp: [#""usage""#, #""type":"session""#].map { Data($0.utf8) }
        case .qwen: [Data(#""usageMetadata""#.utf8)]
        case .gemini: [Data(#""tokens""#.utf8)]
        }
    }

    /// Returns what the file's folder says, read before the file's first line.
    func start(_ file: URL) -> [String: String] {
        switch self {
        // Grok keeps sessions/<cwd, percent-encoded>/<id>/updates.jsonl. A subagent's turns are already in its
        // parent's file, so the subagent's file is skipped.
        case .grok:
            let dir = file.deletingLastPathComponent()
            let summary = FileManager.default.contents(atPath: dir.appendingPathComponent("summary.json").path).flatMap(
                JSONL.object)
            let info = summary?["info"] as? [String: Any]
            let kind = (summary?["session_kind"] ?? info?["session_kind"]) as? String ?? ""
            let cwd =
                info?["cwd"] as? String ?? dir.deletingLastPathComponent().lastPathComponent.removingPercentEncoding
                ?? ""
            return kind.hasPrefix("subagent") ? ["skip": "1"] : ["cwd": cwd]
        // Kimi keeps sessions/<folder>/session_<id>/agents/<agent>/wire.jsonl. The folder is in the session's
        // state.json.
        case .kimi:
            let session = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let state = FileManager.default.contents(atPath: session.appendingPathComponent("state.json").path).flatMap(
                JSONL.object)
            return ["cwd": state?["cwd"] as? String ?? ""]
        // Gemini keeps tmp/<project>/chats/session-….jsonl. projects.json says which folder a project's name stands
        // for.
        case .gemini:
            let folder = Self.geminiChats(file).deletingLastPathComponent(), project = folder.lastPathComponent
            let list = FileManager.default.contents(
                atPath: folder.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("projects.json").path
            ).flatMap(JSONL.object)
            let names = list?["projects"] as? [String: String] ?? [:]
            return ["cwd": names.first { $0.value == project }?.key ?? project]
        case .claude, .codex, .pi, .omp, .qwen: return [:]
        }
    }

    func entry(_ line: Data, _ context: inout [String: String]) -> UsageEntry? {
        switch self {
        case .claude: UsageIndex.entry(line)
        case .codex: Self.codex(line, &context)
        case .grok: context["skip"] == nil ? Self.grok(line, context) : nil
        case .kimi: Self.kimi(line, context)
        case .pi, .omp: Self.pi(line, &context)
        case .qwen: Self.qwen(line)
        case .gemini: Self.gemini(line, context)
        }
    }

    /// Reads Codex's rollouts. The folder comes from `session_meta`, the model from each `turn_context`, and a call's
    /// tokens from `last_token_usage` in `token_count` (its input includes the cached part). The same snapshot is often
    /// written twice with the same running total, so it is counted once. An estimate has nothing but a total (an
    /// imported Claude Code conversation has one), so it is left out.
    /// Limit: a fork replays its parent's events stamped with the time it forked; those in its first 2 s are taken as
    /// its parent's.
    static func codex(_ line: Data, _ context: inout [String: String]) -> UsageEntry? {
        guard let object = JSONL.object(line), let payload = object["payload"] as? [String: Any],
            let time = JSONL.date(object["timestamp"])?.timeIntervalSince1970
        else { return nil }
        switch object["type"] as? String {
        case "session_meta":
            context["cwd"] = payload["cwd"] as? String
            if payload["forked_from_id"] is String { context["fork"] = String(time) }
        case "turn_context":
            context["model"] = payload["model"] as? String ?? context["model"]
            context["cwd"] = payload["cwd"] as? String ?? context["cwd"]
        case "event_msg" where payload["type"] as? String == "token_count":
            let info = payload["info"] as? [String: Any]
            guard let last = info?["last_token_usage"] as? [String: Any] else { return nil }
            let total = (info?["total_token_usage"] as? [String: Any])?["total_tokens"].map { "\($0)" }
            guard total == nil || total != context["total"] else { return nil }
            context["total"] = total
            if let fork = context["fork"].flatMap(Double.init), time < fork + 2 { return nil }
            let input = n(last, "input_tokens"), cached = n(last, "cached_input_tokens"),
                written = n(last, "cache_write_input_tokens")
            let tokens = TokenCounts(
                input: max(0, input - cached - written), output: n(last, "output_tokens"), cacheWrite: written,
                cacheRead: cached)
            guard tokens.input + tokens.output > 0 else { return nil }
            return UsageEntry(
                time: time, model: context["model"] ?? "codex", cwd: context["cwd"] ?? "", id: nil, tokens: tokens)
        default: break
        }
        return nil
    }

    /// Reads Grok Build's `updates.jsonl`, which has a `turn_completed` per prompt with its tokens (input includes the
    /// cached part) and its cost (`costUsdTicks`, 10¹⁰ to the dollar). The model is the one that used most tokens.
    static func grok(_ line: Data, _ context: [String: String]) -> UsageEntry? {
        guard let object = JSONL.object(line), let params = object["params"] as? [String: Any],
            let update = params["update"] as? [String: Any],
            update["sessionUpdate"] as? String == "turn_completed", let usage = update["usage"] as? [String: Any]
        else { return nil }
        let ms = ((params["_meta"] as? [String: Any])?["agentTimestampMs"] as? NSNumber)?.doubleValue
        guard let time = ms.map({ $0 / 1000 }) ?? JSONL.date(object["timestamp"])?.timeIntervalSince1970 else {
            return nil
        }
        let models = usage["modelUsage"] as? [String: [String: Any]] ?? [:]
        let model = models.max { n($0.value, "totalTokens") < n($1.value, "totalTokens") }?.key ?? "grok"
        let cached = n(usage, "cachedReadTokens"), written = n(usage, "cacheCreationTokens")
        let tokens = TokenCounts(
            input: max(0, n(usage, "inputTokens") - cached - written), output: n(usage, "outputTokens"),
            cacheWrite: written, cacheRead: cached)
        return UsageEntry(
            time: time, model: model, cwd: context["cwd"] ?? "", id: update["prompt_id"] as? String, tokens: tokens,
            cost: (usage["costUsdTicks"] as? NSNumber).map { $0.doubleValue / 1e10 })
    }

    /// Reads Kimi Code's `wire.jsonl`, which has a `usage.record` per model call with its time in milliseconds.
    /// `inputOther` leaves the cache out.
    static func kimi(_ line: Data, _ context: [String: String]) -> UsageEntry? {
        guard let object = JSONL.object(line), object["type"] as? String == "usage.record",
            let usage = object["usage"] as? [String: Any],
            let ms = (object["time"] as? NSNumber)?.doubleValue
        else { return nil }
        let tokens = TokenCounts(
            input: n(usage, "inputOther"), output: n(usage, "output"), cacheWrite: n(usage, "inputCacheCreation"),
            cacheRead: n(usage, "inputCacheRead"))
        return UsageEntry(
            time: ms / 1000, model: object["model"] as? String ?? "kimi", cwd: context["cwd"] ?? "", id: nil,
            tokens: tokens)
    }

    /// Reads pi's and oh-my-pi's sessions. The folder is on the first line (`type: session`). After that, each
    /// assistant message has a `usage` (input without the cache, output including the reasoning) and the price pi gave
    /// it. A fork copies its parent's lines with their old times, so the index skips lines older than the file.
    static func pi(_ line: Data, _ context: inout [String: String]) -> UsageEntry? {
        guard let object = JSONL.object(line) else { return nil }
        if object["type"] as? String == "session" {
            context["cwd"] = object["cwd"] as? String
            return nil
        }
        // A call made outside the conversation is a line of its own: oh-my-pi's `model_usage` (titles, thinking), or
        // pi's `usage`.
        let type = object["type"] as? String
        let assistant = (object["message"] as? [String: Any]).flatMap {
            $0["role"] as? String == "assistant" ? $0 : nil
        }
        guard let message = type == "message" ? assistant : ["model_usage", "usage"].contains(type) ? object : nil,
            let usage = message["usage"] as? [String: Any],
            let time = (message["timestamp"] as? NSNumber).map({ $0.doubleValue / 1000 })
                ?? JSONL.date(object["timestamp"])?.timeIntervalSince1970
        else { return nil }
        let tokens = TokenCounts(
            input: n(usage, "input"), output: n(usage, "output"), cacheWrite: n(usage, "cacheWrite"),
            cacheRead: n(usage, "cacheRead"))
        guard tokens.total > 0 else { return nil }
        let cost = ((usage["cost"] as? [String: Any])?["total"] as? NSNumber)?.doubleValue
        return UsageEntry(
            time: time, model: message["model"] as? String ?? "pi", cwd: context["cwd"] ?? "",
            id: message["responseId"] as? String,
            tokens: tokens,
            cost: cost.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Reads Qwen Code's chats from each assistant line's `usageMetadata`, which has Gemini's shape. The prompt count
    /// includes the cache, and whatever the total holds beyond the prompt is output, thinking included, whichever
    /// provider answered.
    static func qwen(_ line: Data) -> UsageEntry? {
        guard let object = JSONL.object(line), object["type"] as? String == "assistant",
            let usage = object["usageMetadata"] as? [String: Any],
            let time = JSONL.date(object["timestamp"])?.timeIntervalSince1970
        else { return nil }
        let prompt = n(usage, "promptTokenCount"), cached = n(usage, "cachedContentTokenCount")
        let tokens = TokenCounts(
            input: max(0, prompt - cached), output: max(0, n(usage, "totalTokenCount") - prompt), cacheWrite: 0,
            cacheRead: cached)
        guard tokens.total > 0 else { return nil }
        return UsageEntry(
            time: time, model: object["model"] as? String ?? "qwen", cwd: object["cwd"] as? String ?? "",
            id: object["uuid"] as? String,
            tokens: tokens)
    }

    /// Reads Gemini CLI's sessions from each reply's record (`type: gemini`) and its `tokens`. Input includes the
    /// cache. Output leaves out thoughts, so they are added to it. A reply is written again under the same id once its
    /// tokens arrive, and only one copy counts.
    static func gemini(_ line: Data, _ context: [String: String]) -> UsageEntry? {
        guard let object = JSONL.object(line), object["type"] as? String == "gemini",
            let usage = object["tokens"] as? [String: Any],
            let time = JSONL.date(object["timestamp"])?.timeIntervalSince1970
        else { return nil }
        let cached = n(usage, "cached")
        let tokens = TokenCounts(
            input: max(0, n(usage, "input") - cached), output: n(usage, "output") + n(usage, "thoughts"), cacheWrite: 0,
            cacheRead: cached)
        guard tokens.total > 0 else { return nil }
        return UsageEntry(
            time: time, model: object["model"] as? String ?? "gemini", cwd: context["cwd"] ?? "",
            id: object["id"] as? String,
            tokens: tokens)
    }

    private static func n(_ object: [String: Any], _ key: String) -> Int { JSONL.int(object, key) }
}
