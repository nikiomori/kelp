import Foundation
import os
import Core
import Agents
import AgentData

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
    /// Where Claude Code and Codex keep their conversations, before the account profiles' (tests set it before the first call).
    let agentHomes = OSAllocatedUnfairLock(initialState: (claude: ClaudeHistory.defaultRoot, codex: CodexHistory.defaultRoot))
    /// Latest Claude plan usage by kind ("weekly", "session"…), as printed by Claude Code.
    let claudeLimits = OSAllocatedUnfairLock<[String: (reading: ClaudeLimits.Reading, at: Date)]>(initialState: [:])
    /// From the agents' own /usage screens, by agent id (UsageProbe).
    let plans = OSAllocatedUnfairLock<[String: PlanState]>(initialState: [:])
    /// Codex's limits as its app server last gave them, and when it was last asked (UsageProbe).
    let codexLive = OSAllocatedUnfairLock<(limits: CodexLimits?, at: Date, running: Bool)>(initialState: (nil, .distantPast, false))
    /// The transcripts history.list read last, by the folders read. Its search field asks on every keystroke, and each read
    /// parses the head and tail of every conversation on disk: a search reuses the list read when the window opened (or a
    /// minute ago). Keyed by folders.
    let historyRead = OSAllocatedUnfairLock<[[URL]: (at: Date, list: [AgentSessionInfo])]>(initialState: [:])

    init(root: URL, settings: SettingsStore, store: Store) {
        self.root = root; self.settings = settings; self.store = store
        self.usageIndex = UsageIndex(cache: root.appendingPathComponent("usage-index-2.json"))   // new number: a parser change reads everything again
    }

    func recordLimits(_ r: [ClaudeLimits.Reading]) { claudeLimits.withLock { for x in r { $0[x.kind] = (x, Date()) } } }

    /// Default roots plus each account profile's config dir.
    func agentRoots() -> (claude: [URL], codex: [URL]) {
        let homes = agentHomes.withLock { $0 }
        var c = [homes.claude], x = [homes.codex]
        for p in settings["accounts.profiles"]?.array ?? [] {
            guard let d = p["dir"]?.string else { continue }
            if p["agent"]?.string == "claude" { c.append(URL(fileURLWithPath: d).appendingPathComponent("projects")) }
            if p["agent"]?.string == "codex" { x.append(URL(fileURLWithPath: d).appendingPathComponent("sessions")) }
        }
        return (c, x)
    }

    /// Where a Claude Code session writes its conversation: what its hooks said, else the id Kelp started or resumed it
    /// with (a woken or restarted session has sent no hook yet, but its conversation is already there).
    func transcript(of ls: LiveSession) -> URL? {
        if let t = ls.transcriptPath { return URL(fileURLWithPath: t) }
        let s = ls.snapshot, a = s.argv
        guard s.agent == "claude", let i = a.lastIndex(where: { $0 == "--session-id" || $0 == "--resume" }), i + 1 < a.count else { return nil }
        return agentRoots().claude.map { ClaudeHistory.folder(cwd: s.cwd, root: $0).appendingPathComponent(a[i + 1] + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Claude Code's window for `model`. Transcripts don't name it, so a model seen past 200k tokens here (in the newest
    /// transcripts, then in any reading) has 1M and the rest 200k.
    /// Limit: a 1M model that never went past 200k on this Mac reads as 200k until it does.
    func contextWindow(model: String, peak: Int) -> Int {
        var long = longContextModels.withLock { $0 } ?? Self.longContextModels(in: agentRoots().claude)
        if peak > 200_000 { long.insert(model) }
        longContextModels.withLock { [long] in $0 = long }
        return long.contains(model) ? 1_000_000 : 200_000
    }

    /// Models past 200k tokens at the end of the `count` newest transcripts.
    static func longContextModels(in roots: [URL], count: Int = 20) -> Set<String> {
        let key = URLResourceKey.contentModificationDateKey
        let files = roots.flatMap { (FileManager.default.enumerator(at: $0, includingPropertiesForKeys: [key])?.allObjects as? [URL]) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast) }
        let newest = files.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
        return Set(newest.compactMap { contextUsage(transcript: $0) }.filter { $0.peak > 200_000 }.map(\.model))
    }

    static func block(_ b: ClaudeUsage.Block) -> UsageGet.Block {
        UsageGet.Block(start: b.start.timeIntervalSince1970, end: b.end.timeIntervalSince1970, input: b.tokens.input, output: b.tokens.output,
                       cacheWrite: b.tokens.cacheWrite, cacheRead: b.tokens.cacheRead, cost: b.estimatedCostUSD, models: b.models)
    }

    static func codex(_ l: CodexLimits) -> UsageGet.Codex {
        UsageGet.Codex(observedAt: l.observedAt.timeIntervalSince1970, primaryUsedPercent: l.primaryUsedPercent,
                       primaryResetsAt: l.primaryResetsAt?.timeIntervalSince1970, secondaryUsedPercent: l.secondaryUsedPercent,
                       secondaryResetsAt: l.secondaryResetsAt?.timeIntervalSince1970)
    }

    /// Claude's own percentages from the last 12 hours (they reset; older readings mislead).
    func withLimits(_ v: UsageGet.Result) -> UsageGet.Result {
        var o = v
        refreshPlansIfStale()
        refreshCodexIfStale()
        // The default account's (the first): its app server's reading, unless a session logged a newer one since.
        if let live = codexLive.withLock({ $0.limits }), live.observedAt.timeIntervalSince1970 > o.codex.first?.observedAt ?? 0 {
            if o.codex.isEmpty { o.codex = [Self.codex(live)] } else { o.codex[0] = Self.codex(live) }
        }
        let plans = self.plans.withLock { $0 }
        o.plans = plans.filter { !$0.value.readings.isEmpty }.mapValues { s in
            s.readings.map { UsageGet.Limit(kind: $0.kind, percent: $0.percent, resets: $0.resets) }
        }
        // When each plan was last read: an old reading is shown as old, not as today's.
        o.plansReadAt = plans.compactMapValues { s in s.readAt.map(\.timeIntervalSince1970) }
        let fresh = claudeLimits.withLock { $0 }.values.filter { Date().timeIntervalSince($0.at) < 12 * 3600 }
        o.claudeLimits = fresh.sorted { $0.reading.kind < $1.reading.kind }.map { x in
            UsageGet.Limit(kind: x.reading.kind, percent: x.reading.percent, resets: x.reading.resets, observedAt: x.at.timeIntervalSince1970)
        }
        return o
    }

    /// Tokens in the context of a Claude Code conversation: the last reply's input (with cache) plus its output, or what a
    /// newer compaction left. `peak` is the most it held (a compaction's starting size counts), for telling the window.
    static func contextUsage(transcript url: URL) -> (used: Int, peak: Int, model: String)? {
        guard let data = Data(tailOf: url, bytes: 1 << 20) else { return nil }   // a turn's tool results can be hundreds of KB
        var compacted: (pre: Int, post: Int)?
        for line in data.split(separator: 0x0A).reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["isSidechain"] as? Bool != true else { continue }
            if compacted == nil, o["subtype"] as? String == "compact_boundary" {
                // Without postTokens (older Claude Code) what's left is unknown until the next reply.
                guard let m = o["compactMetadata"] as? [String: Any], let post = m["postTokens"] as? Int else { return nil }
                compacted = (m["preTokens"] as? Int ?? 0, post); continue
            }
            guard o["type"] as? String == "assistant", let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
            let used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
            guard used > 0 else { continue }   // API errors and other synthetic replies carry no usage
            return (compacted?.post ?? used, max(used, compacted?.pre ?? 0), m["model"] as? String ?? "")
        }
        return compacted.map { ($0.post, $0.pre, "") }
    }

    /// The text of the last assistant message in a Claude Code transcript (read from the file's tail).
    static func lastReply(transcript url: URL) -> String? {
        guard let data = Data(tailOf: url, bytes: 262_144) else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["type"] as? String == "assistant",
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
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
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let type = o["type"] as? String,
                  type == "user" || type == "assistant", let msg = o["message"] as? [String: Any] else { continue }
            let text: String
            if let s = msg["content"] as? String { text = s }
            else { text = ((msg["content"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n") }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.hasPrefix("<") else { continue }   // tool results and system notes aren't the conversation
            turns.append("## \(type == "user" ? "You" : "Agent")\n\n\(t)")
        }
        var out = turns.joined(separator: "\n\n")
        if out.count > limit { out = "…\n\n" + String(out.suffix(limit)) }
        return out
    }
}
