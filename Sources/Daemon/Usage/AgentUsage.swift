import AgentData
import Agents
import Core
import Foundation
import os

/// What the agents leave on disk and what their plans allow: conversations (`history.list`; whose file is whose is
/// `Conversations`'), token usage (`usage.get`, `usage.report`), context windows and plan limits. Reading them takes long (gigabytes of transcripts), so what was read
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
    /// Latest Claude plan usage by kind ("weekly", "session"…), as printed by Claude Code.
    let claudeLimits = OSAllocatedUnfairLock<[String: UsageGet.Limit]>(initialState: [:])
    /// From the agents' own /usage screens, by agent id (UsageProbe).
    let plans = OSAllocatedUnfairLock<[String: PlanState]>(initialState: [:])
    /// Codex's limits as its app server last gave them, and when it was last asked (UsageProbe).
    let codexLive = OSAllocatedUnfairLock<(limits: CodexLimits?, at: Date, running: Bool)>(
        initialState: (nil, .distantPast, false))
    /// The usage probes running now, so the daemon's end ends them too.
    let openProbes: OpenProbes
    /// Which file each session's agent keeps its conversation in, and the Codex thread a transcript becomes.
    let conversations: Conversations
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
        let probes = OpenProbes()
        self.openProbes = probes
        self.conversations = Conversations(settings: settings, openProbes: probes, remotes: remotes)
        self.usageIndex = UsageIndex(cache: root.appendingPathComponent("usage-index-3.json"))   // new number: a parser or price change reads everything again
        self.agentIndexes = Dictionary(
            uniqueKeysWithValues: UsageFormat.allCases.filter { $0 != .claude }.map {
                ($0, UsageIndex(cache: root.appendingPathComponent("usage-index-\($0.rawValue)-2.json"), format: $0))
            })
    }

    /// Where the agents keep their conversations, account profiles' included (`Conversations.roots`).
    func agentRoots() -> (claude: [URL], codex: [URL]) { conversations.roots() }

    func recordLimits(_ readings: [LimitScreens.Reading]) {
        let now = Date().timeIntervalSince1970
        claudeLimits.withLock {
            for var reading in readings {
                reading.observedAt = now
                $0[reading.kind] = reading
            }
        }
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
        return Set(newest.compactMap { ClaudeContext.usage(transcript: $0) }.filter { $0.peak > 200_000 }.map(\.model))
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
        result.plans = plans.filter { !$0.value.readings.isEmpty }.mapValues(\.readings)
        // When each plan was last read: an old reading is shown as old, not as today's.
        result.plansReadAt = plans.compactMapValues { s in s.readAt.map(\.timeIntervalSince1970) }
        let now = Date().timeIntervalSince1970
        result.claudeLimits = claudeLimits.withLock { $0 }.values.filter { now - ($0.observedAt ?? 0) < 12 * 3600 }
            .sorted { $0.kind < $1.kind }
        return result
    }
}
