import Foundation

public struct TokenCounts: Codable, Sendable, Equatable {
    public var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    public var total: Int { input + output + cacheWrite + cacheRead }
    public static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
    public static func += (a: inout Self, b: Self) {
        a.input += b.input; a.output += b.output; a.cacheWrite += b.cacheWrite; a.cacheRead += b.cacheRead
    }
}

/// USD per million tokens.
public struct Pricing: Sendable, Equatable {
    public var input, output, cacheWrite, cacheRead: Double
    public func cost(_ t: TokenCounts) -> Double {
        (Double(t.input) * input + Double(t.output) * output + Double(t.cacheWrite) * cacheWrite + Double(t.cacheRead) * cacheRead) / 1_000_000
    }

    /// ESTIMATE: list prices as of Oct 2026, hand-copied; they drift. Cache write = 5-minute TTL rate (1h writes cost more).
    /// First substring match wins, so specific ids precede their family fallback.
    public static let table: [(match: String, price: Pricing)] = [
        ("fable-5-1", .init(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 0.25)),
        ("mythos-5-1", .init(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 0.25)),
        ("fable", .init(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1)),
        ("mythos", .init(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1)),
        ("opus-5-5", .init(input: 4, output: 20, cacheWrite: 5, cacheRead: 0.2)),
        ("opus", .init(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)),
        ("sonnet-4", .init(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)),
        ("sonnet", .init(input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.2)),
        ("haiku-5", .init(input: 0.1, output: 0.5, cacheWrite: 0.125, cacheRead: 0.01)),
        ("haiku", .init(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)),
        ("-mini", .init(input: 0.25, output: 2, cacheWrite: 0, cacheRead: 0.025)),
        ("gpt-5.2", .init(input: 1.75, output: 14, cacheWrite: 0, cacheRead: 0.175)),
        ("gpt-5", .init(input: 1.25, output: 10, cacheWrite: 0, cacheRead: 0.125))
    ]

    /// 0 for unknown models.
    public static func cost(model: String, tokens: TokenCounts) -> Double {
        let m = model.lowercased()
        return table.first { m.contains($0.match) }?.price.cost(tokens) ?? 0
    }
}

/// Claude Code's usage over a stretch of time; the numbers come from `UsageIndex`.
public enum ClaudeUsage {
    /// Usage over `start..<end`. For a billing block `end` is when the 5-hour limit resets.
    public struct Block: Sendable, Equatable {
        public var start: Date, end: Date
        public var tokens: TokenCounts
        public var estimatedCostUSD: Double
        public var models: [String]
    }

    public static let blockLength: TimeInterval = 5 * 3600
}

public struct CodexLimits: Sendable, Equatable {
    public var primaryUsedPercent: Double?, primaryResetsAt: Date?
    public var secondaryUsedPercent: Double?, secondaryResetsAt: Date?
    public var observedAt: Date
}

public enum CodexUsage {
    /// Newest `rate_limits` snapshot from `token_count` events in the 3 most recently modified rollouts that have one.
    /// Rollouts without one are skipped: Codex Desktop imports Claude Code conversations as rollouts by the dozen, all
    /// newer than the last real session and with `rate_limits: null`.
    public static func latest(root: URL = CodexHistory.defaultRoot) -> CodexLimits? {
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var found: [CodexLimits] = []
        // ponytail: reads up to 200 rollouts when none has limits (API-key sign-in); remember that if it gets slow.
        for (u, _) in CodexHistory.rollouts(root).map({ ($0, mtime($0)) }).sorted(by: { $0.1 > $1.1 }).prefix(200) where found.count < 3 {
            if let l = latest(in: u) { found.append(l) }
        }
        return found.max { $0.observedAt < $1.observedAt }
    }

    static func latest(in url: URL) -> CodexLimits? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let marker = Data("\"rate_limits\"".utf8)
        return JSONL.lines(data).reversed().lazy.filter { $0.range(of: marker) != nil }.compactMap { limits(JSONL.object($0)) }.first
    }

    static func limits(_ o: [String: Any]?) -> CodexLimits? {
        guard let o, let p = o["payload"] as? [String: Any], p["type"] as? String == "token_count", let at = JSONL.date(o["timestamp"]) else { return nil }
        return limits(rateLimits: p["rate_limits"], at: at)
    }

    /// A rollout's `rate_limits` (`primary: {used_percent, resets_at | resets_in_seconds}`, or the older flat
    /// `primary_used_percent`) or app-server's `rateLimits` (`primary: {usedPercent, resetsAt}`), read at `at`.
    public static func limits(rateLimits: Any?, at: Date) -> CodexLimits? {
        guard let rl = rateLimits as? [String: Any] else { return nil }
        func window(_ k: String) -> (used: Double, resets: Date?)? {
            let w = rl[k] as? [String: Any]
                ?? Dictionary(uniqueKeysWithValues: rl.compactMap { $0.key.hasPrefix(k + "_") ? (String($0.key.dropFirst(k.count + 1)), $0.value) : nil })
            guard let used = ((w["used_percent"] ?? w["usedPercent"]) as? NSNumber)?.doubleValue else { return nil }
            let resets = JSONL.date(w["resets_at"] ?? w["resetsAt"]) ?? (w["resets_in_seconds"] as? NSNumber).map { at + $0.doubleValue }
            return (used, resets)
        }
        let primary = window("primary"), secondary = window("secondary")
        guard primary != nil || secondary != nil else { return nil }
        return CodexLimits(primaryUsedPercent: primary?.used, primaryResetsAt: primary?.resets,
                           secondaryUsedPercent: secondary?.used, secondaryResetsAt: secondary?.resets, observedAt: at)
    }
}
