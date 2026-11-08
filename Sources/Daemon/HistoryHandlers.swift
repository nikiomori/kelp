import AgentData
import Agents
import Core
import Foundation
import os

/// Per account: Claude 5h block / today / week, Codex limits.
extension UsageGet: Handled {
    func handle(_ usage: AgentUsage) throws -> Result {
        // Limit: one cached answer for 60 s (a scan reads GBs of transcripts); per-file incremental parsing if it gets slow
        let cached = usage.usageCache.withLock { $0 }
        if let cached, Date().timeIntervalSince(cached.at) < 60, force != true { return usage.withLimits(cached.value) }
        let roots = usage.agentRoots()
        var claude: [Claude] = [], codex: [Codex] = []
        let names = ["Default"] + usage.settings[SettingKeys.accounts].compactMap { $0["name"]?.string }
        for (index, root) in roots.claude.enumerated() where FileManager.default.fileExists(atPath: root.path) {
            // Today, the week and the 5-hour block from the index (read incrementally).
            let cal = Calendar.current, today = cal.startOfDay(for: Date()), now = Date()
            let weekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
            let rows = usage.usageIndex.rows(roots: [root], since: weekStart)
            claude.append(
                Claude(
                    account: index == 0 ? "Default" : names[min(index, names.count - 1)],
                    today: AgentUsage.block(UsageIndex.block(rows, from: today, to: now)),
                    week: AgentUsage.block(UsageIndex.block(rows, from: weekStart, to: now)),
                    block: usage.usageIndex.currentBlock(roots: [root], now: now, fresh: true).map(AgentUsage.block)))
        }
        let live = usage.codexLive.withLock { $0.limits }
        for (index, root) in roots.codex.enumerated()
        where index == 0 || FileManager.default.fileExists(atPath: root.path) {
            // The default account's (the first) is also asked of its app server (UsageProbe): the newer reading wins.
            let latest = [CodexUsage.latest(root: root), index == 0 ? live : nil].compactMap { $0 }.max {
                $0.observedAt < $1.observedAt
            }
            if let latest { codex.append(AgentUsage.codex(latest)) }
        }
        let result = Result(claude: claude, codex: codex)
        usage.usageCache.withLock { $0 = (Date(), result) }
        return usage.withLimits(result)
    }
}

/// What Claude Code used, by day / model / project, priced as the API would.
extension UsageReport: Handled {
    func handle(_ usage: AgentUsage) throws -> Result {
        let since = AgentUsage.since(days: days)
        let rows = usage.usageIndex.rows(
            roots: usage.agentRoots().claude.filter { FileManager.default.fileExists(atPath: $0.path) }, since: since)
        let all = rows.map { ("claude", $0) }, project = usage.projects()
        func group(_ key: (AgentUsage.AgentRow) -> String) -> [Group] { AgentUsage.groups(all, by: key) }
        return Result(
            days: group { $0.row.day }, models: group { $0.row.model }, projects: group { project($0.row.cwd) },
            since: since.timeIntervalSince1970)
    }
}

/// What every agent used, by day and agent, agent, model and project.
extension UsageAgents: Handled {
    func handle(_ usage: AgentUsage) throws -> Result {
        let since = AgentUsage.since(days: days)
        let rows = usage.agentRows(since: since), project = usage.projects()
        func group(_ key: (AgentUsage.AgentRow) -> String) -> [UsageReport.Group] { AgentUsage.groups(rows, by: key) }
        let days = Dictionary(grouping: rows) { [$0.row.day, $0.agent] }.map { key, rs in
            Day(
                day: key[0], agent: key[1], cost: rs.reduce(0) { $0 + $1.row.tally.cost },
                tokens: rs.reduce(0) { $0 + $1.row.tally.tokens.total })
        }
        .sorted { ($0.day, $0.agent) < ($1.day, $1.agent) }
        let agents = Dictionary(grouping: rows, by: \.agent).map { id, rs in
            // a group is never empty
            let tokens = rs.dropFirst().reduce(rs[0].row.tally.tokens) { $0 + $1.row.tally.tokens }
            return Agent(
                id: id, cost: rs.reduce(0) { $0 + $1.row.tally.cost }, tokens: tokens.total, input: tokens.input,
                output: tokens.output,
                cacheWrite: tokens.cacheWrite, cacheRead: tokens.cacheRead,
                models: AgentUsage.groups(rs) { $0.row.model }, projects: AgentUsage.groups(rs) { project($0.row.cwd) })
        }
        .sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }
        return Result(
            days: days, agents: agents, models: group { $0.row.model }, projects: group { project($0.row.cwd) },
            since: since.timeIntervalSince1970)
    }
}

extension AgentUsage {
    /// The first of the last `days` days (1–371: the Usage tab's year of weeks; 30 if not said), from midnight.
    static func since(days: Int?) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 1 - max(1, min(371, days ?? 30)), to: cal.startOfDay(for: Date()))
            ?? Date()
    }

    /// The Kelp project a folder is in, else the folder's name; the projects read once (a reply names thousands of rows').
    func projects() -> (String) -> String {
        let repos = (try? store.repos()) ?? []
        var named: [String: String] = [:]   // each folder looked up once: the rows repeat a few
        return { cwd in
            if let name = named[cwd] { return name }
            let name =
                repos.first { !cwd.isEmpty && IDE.inside(cwd, $0.path) }?.name
                ?? (cwd.isEmpty ? "Other" : (cwd as NSString).lastPathComponent)
            named[cwd] = name
            return name
        }
    }

    /// Sums `rows` by a key, most expensive first (then most tokens: a model with no list price costs 0).
    static func groups(_ rows: [AgentRow], by key: (AgentRow) -> String) -> [UsageReport.Group] {
        Dictionary(grouping: rows, by: key).map { name, rs in
            UsageReport.Group(
                name: name, cost: rs.reduce(0) { $0 + $1.row.tally.cost },
                tokens: rs.reduce(0) { $0 + $1.row.tally.tokens.total })
        }
        .sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }
    }
}

extension HistoryList: Handled {
    func handle(_ usage: AgentUsage) throws -> [AgentSessionInfo] {
        let roots = usage.agentRoots(), key = roots.claude + roots.codex
        var all: [AgentSessionInfo]
        if query?.isEmpty == false, let read = usage.historyRead.withLock({ $0[key] }),
            Date().timeIntervalSince(read.at) < 60
        {
            all = read.list
        } else {
            all =
                roots.claude.flatMap { ClaudeHistory.sessions(root: $0) }
                + roots.codex.flatMap { CodexHistory.sessions(root: $0) }
            all.sort { $0.updated > $1.updated }
            usage.historyRead.withLock { [all] in $0[key] = (Date(), all) }
        }
        if let query, !query.isEmpty {
            all =
                fullText == true
                ? History.fullTextSearch(query: query, in: all, limit: 100) : History.search(all, query: query)
        }
        if let cwd = cwd { all = all.filter { $0.cwd == cwd } }
        return Array(all.prefix(max(0, limit ?? 400)))
    }
}
