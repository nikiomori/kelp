import Foundation

/// One model call's tokens as an agent logged it.
struct UsageEntry {
    var time: TimeInterval, model: String, cwd: String, id: String?
    var tokens: TokenCounts
    /// What the agent itself said it cost (Grok); nil: priced from `Pricing`.
    var cost: Double?
}

/// Whose logs a `UsageIndex` reads: which files, which lines, and what a line says. `context` keeps what earlier lines of
/// the file said (Codex names the model and folder once, not with every call) from one read to the next.
public enum UsageFormat: String, Sendable, CaseIterable {
    case claude, codex, grok, kimi, pi, omp, qwen, gemini

    /// Where each keeps its sessions, as its own env moves them; Claude's and Codex's come with account profiles.
    public var defaultRoot: URL? {
        let env = ProcessInfo.processInfo.environment, home = FileManager.default.homeDirectoryForCurrentUser
        func dir(_ variable: String, _ fallback: String) -> URL { env[variable].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(fallback) }
        return switch self {
        case .grok: dir("GROK_HOME", ".grok").appendingPathComponent("sessions")
        case .kimi: dir("KIMI_CODE_HOME", ".kimi-code").appendingPathComponent("sessions")
        case .pi: dir("PI_CODING_AGENT_DIR", ".pi/agent").appendingPathComponent("sessions")
        case .omp: home.appendingPathComponent(".omp/agent/sessions")
        case .qwen: dir("QWEN_HOME", ".qwen").appendingPathComponent("projects")
        case .gemini: dir("GEMINI_CLI_HOME", "").appendingPathComponent(".gemini/tmp")
        case .claude, .codex: nil
        }
    }

    func reads(_ f: URL) -> Bool {
        switch self {
        case .claude: f.pathExtension == "jsonl"
        case .codex: f.pathExtension == "jsonl" && f.lastPathComponent.hasPrefix("rollout-")
        case .grok: f.lastPathComponent == "updates.jsonl"
        case .kimi: f.lastPathComponent == "wire.jsonl"
        case .pi, .omp: f.pathExtension == "jsonl"
        case .qwen: f.pathExtension == "jsonl" && f.deletingLastPathComponent().lastPathComponent == "chats"
        case .gemini: f.pathExtension == "jsonl" && f.lastPathComponent.hasPrefix("session-")
        }
    }

    /// A line with none of these isn't parsed (gigabytes of Claude transcripts).
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

    /// What the file's folder says, before its first line.
    func start(_ f: URL) -> [String: String] {
        switch self {
        // sessions/<cwd, percent-encoded>/<id>/updates.jsonl. A subagent's turns are already in its parent's.
        case .grok:
            let dir = f.deletingLastPathComponent()
            let summary = FileManager.default.contents(atPath: dir.appendingPathComponent("summary.json").path).flatMap(JSONL.object)
            let info = summary?["info"] as? [String: Any]
            let kind = (summary?["session_kind"] ?? info?["session_kind"]) as? String ?? ""
            let cwd = info?["cwd"] as? String ?? dir.deletingLastPathComponent().lastPathComponent.removingPercentEncoding ?? ""
            return kind.hasPrefix("subagent") ? ["skip": "1"] : ["cwd": cwd]
        // sessions/<folder>/session_<id>/agents/<agent>/wire.jsonl; the folder is in the session's state.json.
        case .kimi:
            let session = f.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let state = FileManager.default.contents(atPath: session.appendingPathComponent("state.json").path).flatMap(JSONL.object)
            return ["cwd": state?["cwd"] as? String ?? ""]
        // tmp/<project>/chats/session-….jsonl; projects.json says which folder a project's name stands for.
        case .gemini:
            let project = f.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let list = FileManager.default.contents(atPath: f.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("projects.json").path).flatMap(JSONL.object)
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

    /// Codex's rollouts: the folder in `session_meta`, the model in each `turn_context`, a call's tokens in `token_count`'s
    /// `last_token_usage` (its input counts the cached part). The same snapshot is often written twice (one running total:
    /// counted once); an estimate has nothing but a total (an imported Claude Code conversation has one), so it's left out.
    /// Limit: a fork replays its parent's events stamped with the time it forked; those in its first 2 s are taken as its parent's.
    static func codex(_ line: Data, _ c: inout [String: String]) -> UsageEntry? {
        guard let o = JSONL.object(line), let p = o["payload"] as? [String: Any],
              let t = JSONL.date(o["timestamp"])?.timeIntervalSince1970 else { return nil }
        switch o["type"] as? String {
        case "session_meta":
            c["cwd"] = p["cwd"] as? String
            if p["forked_from_id"] is String { c["fork"] = String(t) }
        case "turn_context":
            c["model"] = p["model"] as? String ?? c["model"]
            c["cwd"] = p["cwd"] as? String ?? c["cwd"]
        case "event_msg" where p["type"] as? String == "token_count":
            let info = p["info"] as? [String: Any]
            guard let last = info?["last_token_usage"] as? [String: Any] else { return nil }
            let total = (info?["total_token_usage"] as? [String: Any])?["total_tokens"].map { "\($0)" }
            guard total == nil || total != c["total"] else { return nil }
            c["total"] = total
            if let fork = c["fork"].flatMap(Double.init), t < fork + 2 { return nil }
            let input = n(last, "input_tokens"), cached = n(last, "cached_input_tokens"), written = n(last, "cache_write_input_tokens")
            let tokens = TokenCounts(input: max(0, input - cached - written), output: n(last, "output_tokens"), cacheWrite: written, cacheRead: cached)
            guard tokens.input + tokens.output > 0 else { return nil }
            return UsageEntry(time: t, model: c["model"] ?? "codex", cwd: c["cwd"] ?? "", id: nil, tokens: tokens)
        default: break
        }
        return nil
    }

    /// Grok Build's `updates.jsonl`: a `turn_completed` per prompt with its tokens (input counts the cached part) and what it
    /// cost (`costUsdTicks`, 10¹⁰ to the dollar). The model is the one that took most of it.
    static func grok(_ line: Data, _ c: [String: String]) -> UsageEntry? {
        guard let o = JSONL.object(line), let params = o["params"] as? [String: Any], let u = params["update"] as? [String: Any],
              u["sessionUpdate"] as? String == "turn_completed", let usage = u["usage"] as? [String: Any] else { return nil }
        let ms = ((params["_meta"] as? [String: Any])?["agentTimestampMs"] as? NSNumber)?.doubleValue
        guard let t = ms.map({ $0 / 1000 }) ?? JSONL.date(o["timestamp"])?.timeIntervalSince1970 else { return nil }
        let models = usage["modelUsage"] as? [String: [String: Any]] ?? [:]
        let model = models.max { n($0.value, "totalTokens") < n($1.value, "totalTokens") }?.key ?? "grok"
        let cached = n(usage, "cachedReadTokens"), written = n(usage, "cacheCreationTokens")
        let tokens = TokenCounts(input: max(0, n(usage, "inputTokens") - cached - written), output: n(usage, "outputTokens"),
                                 cacheWrite: written, cacheRead: cached)
        return UsageEntry(time: t, model: model, cwd: c["cwd"] ?? "", id: u["prompt_id"] as? String, tokens: tokens,
                          cost: (usage["costUsdTicks"] as? NSNumber).map { $0.doubleValue / 1e10 })
    }

    /// Kimi Code's `wire.jsonl`: a `usage.record` per model call (`inputOther` leaves the cache out), its time in milliseconds.
    static func kimi(_ line: Data, _ c: [String: String]) -> UsageEntry? {
        guard let o = JSONL.object(line), o["type"] as? String == "usage.record", let u = o["usage"] as? [String: Any],
              let ms = (o["time"] as? NSNumber)?.doubleValue else { return nil }
        let tokens = TokenCounts(input: n(u, "inputOther"), output: n(u, "output"), cacheWrite: n(u, "inputCacheCreation"),
                                 cacheRead: n(u, "inputCacheRead"))
        return UsageEntry(time: ms / 1000, model: o["model"] as? String ?? "kimi", cwd: c["cwd"] ?? "", id: nil, tokens: tokens)
    }

    /// pi's (and oh-my-pi's) sessions: the folder on the first line (`type: session`), then an assistant message's `usage`
    /// (input without the cache, output with the reasoning) and what pi priced it at. A fork copies its parent's lines with
    /// their old times: the index skips those as older than the file.
    static func pi(_ line: Data, _ c: inout [String: String]) -> UsageEntry? {
        guard let o = JSONL.object(line) else { return nil }
        if o["type"] as? String == "session" { c["cwd"] = o["cwd"] as? String; return nil }
        guard o["type"] as? String == "message", let m = o["message"] as? [String: Any], m["role"] as? String == "assistant",
              let u = m["usage"] as? [String: Any],
              let t = (m["timestamp"] as? NSNumber).map({ $0.doubleValue / 1000 }) ?? JSONL.date(o["timestamp"])?.timeIntervalSince1970 else { return nil }
        let tokens = TokenCounts(input: n(u, "input"), output: n(u, "output"), cacheWrite: n(u, "cacheWrite"), cacheRead: n(u, "cacheRead"))
        guard tokens.total > 0 else { return nil }
        let cost = ((u["cost"] as? [String: Any])?["total"] as? NSNumber)?.doubleValue
        return UsageEntry(time: t, model: m["model"] as? String ?? "pi", cwd: c["cwd"] ?? "", id: m["responseId"] as? String, tokens: tokens,
                          cost: cost.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Qwen Code's chats: an assistant line's `usageMetadata`, Gemini's shape (the prompt counts the cache; what's past the
    /// prompt in the total is output, thinking included, whichever provider answered).
    static func qwen(_ line: Data) -> UsageEntry? {
        guard let o = JSONL.object(line), o["type"] as? String == "assistant", let u = o["usageMetadata"] as? [String: Any],
              let t = JSONL.date(o["timestamp"])?.timeIntervalSince1970 else { return nil }
        let prompt = n(u, "promptTokenCount"), cached = n(u, "cachedContentTokenCount")
        let tokens = TokenCounts(input: max(0, prompt - cached), output: max(0, n(u, "totalTokenCount") - prompt), cacheWrite: 0, cacheRead: cached)
        guard tokens.total > 0 else { return nil }
        return UsageEntry(time: t, model: o["model"] as? String ?? "qwen", cwd: o["cwd"] as? String ?? "", id: o["uuid"] as? String, tokens: tokens)
    }

    /// Gemini CLI's sessions: a reply's record (`type: gemini`) with its `tokens` (input counts the cache, thoughts aren't
    /// in output). A reply is written again once its tokens come, under the same id: one counts.
    static func gemini(_ line: Data, _ c: [String: String]) -> UsageEntry? {
        guard let o = JSONL.object(line), o["type"] as? String == "gemini", let u = o["tokens"] as? [String: Any],
              let t = JSONL.date(o["timestamp"])?.timeIntervalSince1970 else { return nil }
        let cached = n(u, "cached")
        let tokens = TokenCounts(input: max(0, n(u, "input") - cached), output: n(u, "output") + n(u, "thoughts"), cacheWrite: 0, cacheRead: cached)
        guard tokens.total > 0 else { return nil }
        return UsageEntry(time: t, model: o["model"] as? String ?? "gemini", cwd: c["cwd"] ?? "", id: o["id"] as? String, tokens: tokens)
    }

    private static func n(_ o: [String: Any], _ k: String) -> Int { JSONL.int(o, k) }
}
