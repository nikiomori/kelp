import AgentData
import Agents
import Core
import Foundation
import os

/// What the agents leave on disk and what their plans allow: conversations (`history.list`), token usage (`usage.get`,
/// `usage.report`), context windows and plan limits. Reading them takes long (gigabytes of transcripts), so what was read
/// is kept here.
final class AgentUsage: Sendable {
    let root: URL
    let settings: SettingsStore
    let store: Store
    let usageCache = OSAllocatedUnfairLock<(at: Date, value: UsageGet.Result)?>(initialState: nil)
    /// Claude models with the 1M context window (contextWindow); nil until first asked.
    let longContextModels = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)
    /// Claude Code's usage by day / model / folder, read incrementally (usage.report).
    let usageIndex: UsageIndex
    /// The other agents' logs (Codex, Grok, Kimi Code, pi, oh-my-pi, Qwen Code, Gemini CLI), read the same way (usage.agents).
    let agentIndexes: [UsageFormat: UsageIndex]
    /// Where Claude Code and Codex keep their conversations, before the account profiles' (tests set it before the first call).
    let agentHomes = OSAllocatedUnfairLock(
        initialState: (claude: ClaudeHistory.defaultRoot, codex: CodexHistory.defaultRoot))
    /// Latest Claude plan usage by kind ("weekly", "session"…), as printed by Claude Code.
    let claudeLimits = OSAllocatedUnfairLock<[String: (reading: ClaudeLimits.Reading, at: Date)]>(initialState: [:])
    /// From the agents' own /usage screens, by agent id (UsageProbe).
    let plans = OSAllocatedUnfairLock<[String: PlanState]>(initialState: [:])
    /// Codex's limits as its app server last gave them, and when it was last asked (UsageProbe).
    let codexLive = OSAllocatedUnfairLock<(limits: CodexLimits?, at: Date, running: Bool)>(
        initialState: (nil, .distantPast, false))
    /// The usage probes running now, so the daemon's end ends them too.
    let openProbes = OpenProbes()
    /// The transcripts history.list read last, by the folders read. Its search field asks on every keystroke, and each read
    /// parses the head and tail of every conversation on disk: a search reuses the list read when the window opened (or a
    /// minute ago). Keyed by folders.
    let historyRead = OSAllocatedUnfairLock<[[URL]: (at: Date, list: [AgentSessionInfo])]>(initialState: [:])

    let remotes: Remotes

    init(root: URL, settings: SettingsStore, store: Store, remotes: Remotes) {
        self.root = root
        self.settings = settings
        self.store = store
        self.remotes = remotes
        self.usageIndex = UsageIndex(cache: root.appendingPathComponent("usage-index-3.json"))   // new number: a parser or price change reads everything again
        self.agentIndexes = Dictionary(
            uniqueKeysWithValues: UsageFormat.allCases.filter { $0 != .claude }.map {
                ($0, UsageIndex(cache: root.appendingPathComponent("usage-index-\($0.rawValue)-2.json"), format: $0))
            })
    }

    func recordLimits(_ readings: [ClaudeLimits.Reading]) {
        claudeLimits.withLock { for reading in readings { $0[reading.kind] = (reading, Date()) } }
    }

    /// Default roots plus each account profile's config dir.
    func agentRoots() -> (claude: [URL], codex: [URL]) {
        let homes = agentHomes.withLock { $0 }
        var claude = [homes.claude], codex = [homes.codex]
        for profile in settings[SettingKeys.accounts] {
            guard let dir = profile["dir"]?.string else { continue }
            if profile["agent"]?.string == "claude" {
                claude.append(URL(fileURLWithPath: dir).appendingPathComponent("projects"))
            }
            if profile["agent"]?.string == "codex" {
                codex.append(URL(fileURLWithPath: dir).appendingPathComponent("sessions"))
            }
        }
        return (claude, codex)
    }

    /// Every agent's usage since `since`, by agent id: the logs each keeps on this Mac (all account profiles' for Claude and
    /// Codex). Cursor, Amp and fx keep no token counts there; Droid, Goose, Hermes and Kiro only a session's, not read.
    typealias AgentRow = (agent: String, row: UsageIndex.Row)
    func agentRows(since: Date) -> [AgentRow] {
        let roots = agentRoots(), exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        var out: [AgentRow] = usageIndex.rows(roots: roots.claude.filter(exists), since: since).map { ("claude", $0) }
        for (format, index) in agentIndexes {
            let folders = format == .codex ? roots.codex : [format.defaultRoot].compactMap { $0 }
            out += index.rows(roots: folders.filter(exists), since: since).map { (format.rawValue, $0) }
        }
        return out + databaseRows(since: since)
    }

    /// The agents that keep their calls in SQLite (`AgentDatabases`), each database copied with its WAL to read. A copy on
    /// the same disk is a clone: it takes no time or room however big the database.
    private func databaseRows(since: Date) -> [AgentRow] {
        let fm = FileManager.default,
            dir = fm.temporaryDirectory.appendingPathComponent("kelp-usage-\(UUID().uuidString)")
        defer {
            if fm.fileExists(atPath: dir.path) {
                Log.session.attempt("removing the agents' copied usage") { try fm.removeItem(at: dir) }
            }
        }
        return AgentDatabases.agents.flatMap { agent -> [AgentRow] in
            let copies = AgentDatabases.files(agent, changedSince: since).enumerated().compactMap {
                offset, db -> URL? in
                let copy = dir.appendingPathComponent("\(agent)-\(offset).db")
                return Log.session.attempt("copying \(agent)'s usage") {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    for part in ["", "-wal"] where part.isEmpty || fm.fileExists(atPath: db.path + part) {
                        try fm.copyItem(atPath: db.path + part, toPath: copy.path + part)
                    }
                    return copy
                }
            }
            return AgentDatabases.rows(agent, copies: copies, since: since).map { (agent, $0) }
        }
    }

    /// Where a Claude Code session writes its conversation: what its hooks said, else the id Kelp started or resumed it
    /// with (a woken or restarted session has sent no hook yet, but its conversation is already there).
    func transcript(of ls: LiveSession) -> URL? {
        ls.transcriptPath.map { URL(fileURLWithPath: $0) } ?? transcript(of: ls.snapshot)
    }
    func transcript(of session: Session) -> URL? {
        let argv = session.argv
        guard session.agent == "claude",
            let flagIndex = argv.lastIndex(where: { $0 == "--session-id" || $0 == "--resume" }),
            flagIndex + 1 < argv.count
        else { return nil }
        return agentRoots().claude.map {
            ClaudeHistory.folder(cwd: session.cwd, root: $0).appendingPathComponent(argv[flagIndex + 1] + ".jsonl")
        }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What its last turn ended with, if the agent keeps that somewhere Kelp can read.
    func lastReply(of ls: LiveSession) -> String? {
        let session = ls.snapshot
        guard session.agent == "codex" else { return transcript(of: ls).flatMap(Self.lastReply(transcript:)) }
        if let open = Self.openRollout(pid: session.pid) { return CodexHistory.lastReply(rollout: open) }
        return agentRoots().codex.lazy.compactMap {
            CodexHistory.lastReply(cwd: session.cwd, since: session.createdAt, root: $0)
        }
        .first
    }

    /// The conversation a running Codex has open, the one thing that says whose it is when two work in a folder. The program
    /// behind its node wrapper holds it: another process of its group.
    private static func openRollout(pid: Int32) -> URL? {
        func lines(_ argv: [String]) -> [Substring] {
            let out = Log.session.attempt("asking \(argv[0])") {
                try Subprocess.run(argv, cwd: "/", env: [:], timeLimit: 5)
            }
            return String(decoding: out?.stdout ?? Data(), as: UTF8.self).split(whereSeparator: \.isNewline)
        }
        let group = lines(["/usr/bin/pgrep", "-g", String(pid)]).joined(separator: ",")
        guard !group.isEmpty else { return nil }
        return lines(["/usr/sbin/lsof", "-nP", "-Fn", "-p", group])
            .first { $0.hasPrefix("n") && $0.contains("/rollout-") && $0.hasSuffix(".jsonl") }.map {
                URL(fileURLWithPath: String($0.dropFirst()))
            }
    }

    /// Claude Code's window for `model`. Transcripts don't name it: 1M for the models that have it natively (Claude Code's
    /// catalog says `native_1m`), else 1M once the model was seen past 200k tokens here (an older model with the [1m] opt-in;
    /// in the newest transcripts, then in any reading), else 200k.
    /// Limit: an older model with the opt-in that never went past 200k on this Mac reads as 200k until it does.
    func contextWindow(model: String, peak: Int) -> Int {
        if Self.nativeMillion(model) { return 1_000_000 }
        var long = longContextModels.withLock { $0 } ?? Self.longContextModels(in: agentRoots().claude)
        if peak > 200_000 { long.insert(model) }
        longContextModels.withLock { [long] in $0 = long }
        return long.contains(model) ? 1_000_000 : 200_000
    }

    /// Opus 4.7 and later, every Claude 5 model and later (Haiku 5.5, Sonnet 5, Fable…): "claude-opus-4-7", "claude-sonnet-5".
    static func nativeMillion(_ model: String) -> Bool {
        let parts = model.lowercased().split(separator: "-")
        // "claude-3-7-sonnet": the old order puts the version before the family, and no 3.x model has 1M.
        guard parts.count >= 3, parts[0] == "claude", Int(parts[1]) == nil, let major = Int(parts[2]) else {
            return false
        }
        let minor = parts.count > 3 ? Int(parts[3]) ?? 0 : 0   // "claude-sonnet-4-20250514": a date, not a minor version
        return major >= 5 || (parts[1] == "opus" && major == 4 && (7..<100).contains(minor))
    }

    /// Models past 200k tokens at the end of the `count` newest transcripts.
    static func longContextModels(in roots: [URL], count: Int = 20) -> Set<String> {
        let key = URLResourceKey.contentModificationDateKey
        let all: [URL] = roots.flatMap { root -> [URL] in
            (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [key])?.allObjects as? [URL]) ?? []
        }
        let files: [(URL, Date)] = all.filter { $0.pathExtension == "jsonl" }
            .map { url -> (URL, Date) in
                (url, (try? url.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast)
            }
        let newest = files.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
        return Set(newest.compactMap { contextUsage(transcript: $0) }.filter { $0.peak > 200_000 }.map(\.model))
    }

    static func block(_ block: ClaudeUsage.Block) -> UsageGet.Block {
        UsageGet.Block(
            start: block.start.timeIntervalSince1970, end: block.end.timeIntervalSince1970, input: block.tokens.input,
            output: block.tokens.output,
            cacheWrite: block.tokens.cacheWrite, cacheRead: block.tokens.cacheRead, cost: block.estimatedCostUSD,
            models: block.models)
    }

    static func codex(_ limits: CodexLimits) -> UsageGet.Codex {
        UsageGet.Codex(
            observedAt: limits.observedAt.timeIntervalSince1970, primaryUsedPercent: limits.primaryUsedPercent,
            primaryResetsAt: limits.primaryResetsAt?.timeIntervalSince1970,
            secondaryUsedPercent: limits.secondaryUsedPercent,
            secondaryResetsAt: limits.secondaryResetsAt?.timeIntervalSince1970,
            primaryWindowMinutes: limits.primaryWindowMinutes, secondaryWindowMinutes: limits.secondaryWindowMinutes)
    }

    /// Claude's own percentages from the last 12 hours (they reset; older readings mislead).
    func withLimits(_ usage: UsageGet.Result) -> UsageGet.Result {
        var result = usage
        refreshPlansIfStale()
        refreshCodexIfStale()
        let plans = self.plans.withLock { $0 }
        result.plans = plans.filter { !$0.value.readings.isEmpty }.mapValues { plan in
            plan.readings.map { UsageGet.Limit(kind: $0.kind, percent: $0.percent, resets: $0.resets) }
        }
        // When each plan was last read: an old reading is shown as old, not as today's.
        result.plansReadAt = plans.compactMapValues { s in s.readAt.map(\.timeIntervalSince1970) }
        let fresh = claudeLimits.withLock { $0 }.values.filter { Date().timeIntervalSince($0.at) < 12 * 3600 }
        result.claudeLimits = fresh.sorted { $0.reading.kind < $1.reading.kind }.map { limit in
            UsageGet.Limit(
                kind: limit.reading.kind, percent: limit.reading.percent, resets: limit.reading.resets,
                observedAt: limit.at.timeIntervalSince1970)
        }
        return result
    }

    /// Tokens in the context of a Claude Code conversation: the last reply's input with cache, as Claude Code's own
    /// statusline counts it (the reply's output isn't in it until it's sent back), or what a newer compaction left. `peak` is the most it held (a compaction's starting size counts), for telling the window.
    static func contextUsage(transcript url: URL) -> (used: Int, peak: Int, model: String, cacheUntil: Date?)? {
        guard let data = Data(tailOf: url, bytes: 1 << 20) else { return nil }   // a turn's tool results can be hundreds of KB
        var compacted: (pre: Int, post: Int)?
        for line in data.split(separator: 0x0A).reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                entry["isSidechain"] as? Bool != true
            else { continue }
            if compacted == nil, entry["subtype"] as? String == "compact_boundary" {
                // Without postTokens (older Claude Code) what's left is unknown until the next reply.
                guard let metadata = entry["compactMetadata"] as? [String: Any],
                    let post = metadata["postTokens"] as? Int
                else {
                    return nil
                }
                compacted = (metadata["preTokens"] as? Int ?? 0, post)
                continue
            }
            guard entry["type"] as? String == "assistant", let message = entry["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { continue }
            let used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) {
                $0 + ((usage[$1] as? Int) ?? 0)
            }
            guard used > 0 else { continue }   // API errors and other synthetic replies carry no usage
            let cacheUntil = compacted == nil ? ClaudeContext.cacheUntil(entry, usage) : nil
            return (
                compacted?.post ?? used, max(used, compacted?.pre ?? 0), message["model"] as? String ?? "", cacheUntil
            )
        }
        return compacted.map { ($0.post, $0.pre, "", nil) }
    }

    /// The text of the last assistant message in a Claude Code transcript (read from the file's tail).
    static func lastReply(transcript url: URL) -> String? {
        guard let data = Data(tailOf: url, bytes: 262_144) else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                entry["type"] as? String == "assistant",
                let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(
                separator: "\n"
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(4000)) }
        }
        return nil
    }

    /// "## You / ## Claude" turns from a Claude Code transcript, newest kept when it's longer than `limit`.
    static func conversation(transcript url: URL, limit: Int) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var turns: [String] = []
        for line in data.split(separator: 0x0A) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let type = entry["type"] as? String,
                type == "user" || type == "assistant", let msg = entry["message"] as? [String: Any]
            else { continue }
            let text: String
            if let plain = msg["content"] as? String {
                text = plain
            } else {
                text = ((msg["content"] as? [[String: Any]]) ?? []).compactMap {
                    $0["type"] as? String == "text" ? $0["text"] as? String : nil
                }
                .joined(separator: "\n")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { continue }   // tool results and system notes aren't the conversation
            turns.append("## \(type == "user" ? "You" : "Agent")\n\n\(trimmed)")
        }
        var out = turns.joined(separator: "\n\n")
        if out.count > limit { out = "…\n\n" + String(out.suffix(limit)) }
        return out
    }
}
