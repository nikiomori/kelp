import Core
import DesignKit
import Foundation
import KelpKit

/// One chat on the overview's board, with what its card shows.
struct OverviewCard: Identifiable {
    var session: Session
    var stage: OverviewStage
    var project: String
    /// The chat's git folder (`AppModel.gitKey`, or its own worktree's `branchKey`).
    var folder: String
    var branch: String?
    var pr: GitHub.PullRequest?
    var turn: SessionTurn.Turn?
    /// The files of its last turn not committed yet.
    var uncommitted: Set<String>
    /// How full its conversation is, from 0 to 1.
    var context: Double?
    var line: DayLine
    var id: String { session.id }
    var added: Int { turn?.files.reduce(0) { $0 + $1.added } ?? 0 }
    var removed: Int { turn?.files.reduce(0) { $0 + $1.removed } ?? 0 }
}

/// What the Agents Overview reads: the chats of today (or of the week), each one's stage, day and figures. The live
/// parts (statuses, git, pull requests, context) come from what the app already keeps; the history of statuses and
/// each chat's last turn are read while the tab is shown.
@MainActor @Observable
final class OverviewModel {
    let app: AppModel
    /// Status changes by session, since `since`.
    var history: [String: [SessionHistory.Change]] = [:]
    private(set) var since = Calendar.current.startOfDay(for: Date())
    /// Where "today" begins; midnight unless a picture of a made-up day sets it.
    var dayStart: Date?
    var today: Date { dayStart ?? Calendar.current.startOfDay(for: Date()) }

    /// The hours the day's tracks span, the same on every card and lane: from the hour of the day's first work to the
    /// end of the hour now.
    func hours(_ cards: [OverviewCard], now: Date = Date()) -> (from: Date, to: Date) {
        let first =
            cards.compactMap { $0.line.spans.first?.from }.filter { $0 >= today }.min() ?? now.addingTimeInterval(-3600)
        let hour = Calendar.current
        return (
            hour.dateInterval(of: .hour, for: first)?.start ?? first, hour.dateInterval(of: .hour, for: now)?.end ?? now
        )
    }
    var turns: [String: SessionTurn.Turn] = [:]
    var loaded = false
    private(set) var failed: String?
    @ObservationIgnored private var watched: Set<String> = []

    init(app: AppModel) { self.app = app }

    /// The chats a day covers: one at work or asking now, or one whose status changed since `start`. Terminals, plain
    /// commands and the agents another agent started (their parent's card stands for them) are left out.
    func chats(since start: Date) -> [Session] {
        app.sessions.filter { s in
            s.isChat && s.isAgent && s.parent == nil
                && ([.working, .waiting, .error].contains(s.status) || (s.statusAt ?? s.createdAt) >= start
                    || history[s.id]?.contains { $0.at >= start } == true)
        }
    }

    /// Today's cards, in board order: each stage's asking chats first, then the longest at it.
    var cards: [OverviewCard] {
        let now = Date()
        return chats(since: today).map { card($0, now: now) }.sorted {
            ($0.stage, $0.session.status == .waiting ? 0 : 1, $0.session.statusAt ?? .distantPast)
                < ($1.stage, $1.session.status == .waiting ? 0 : 1, $1.session.statusAt ?? .distantPast)
        }
    }

    func card(_ s: Session, now: Date) -> OverviewCard {
        let folder = s.branchFolder != nil ? s.branchKey : app.gitKey(s.worktreeId)
        let git = app.latest(GitEvent.self, folder), pr = app.latest(PREvent.self, folder)?.pr
        let turn = turns[s.id], dirty = Set((git?.changes ?? []).map(\.path))
        let files = turn?.files.map(\.path) ?? []
        let stage = OverviewStage.of(
            .init(status: s.status, limited: s.limitHit != nil, pr: pr, turnFiles: files, dirty: dirty))
        let usage = app.latest(ContextEvent.self, s.id)?.usage
        let project = app.repo(app.worktree(s.worktreeId)?.repoId)?.name ?? String(localized: "Chats")
        return OverviewCard(
            session: s, stage: stage, project: project, folder: folder, branch: git?.branches?.current, pr: pr,
            turn: turn, uncommitted: Set(files).intersection(dirty),
            context: usage.map { Double($0.used) / Double(max(1, $0.window)) },
            line: DayLine.of(history[s.id] ?? [], now: now))
    }

    /// The day lines of every chat in the span, by session.
    var lines: [String: DayLine] {
        let now = Date()
        return history.mapValues { DayLine.of($0, now: now) }
    }

    /// The project of a session, for the week's table.
    func project(of id: String) -> String? {
        guard let s = app.session(id), s.isChat, s.isAgent else { return nil }
        return app.repo(app.worktree(s.worktreeId)?.repoId)?.name ?? String(localized: "Chats")
    }

    /// The Needs Attention lines for `cards`.
    func insights(_ cards: [OverviewCard]) -> [Insight] { Insight.of(insightChats(cards), limit: limit) }

    /// What the attention rules read of each card.
    func insightChats(_ cards: [OverviewCard]) -> [Insight.Chat] {
        cards.map { c in
            Insight.Chat(
                id: c.id, title: c.session.displayTitle, status: c.session.status, stage: c.stage,
                since: c.session.statusAt ?? c.session.createdAt, folder: c.folder, uncommitted: c.uncommitted,
                added: c.added, removed: c.removed, context: c.context,
                failedPR: c.pr.flatMap { $0.state == "OPEN" && $0.checks.failed > 0 ? $0.number : nil })
        }
    }

    /// The fullest plan limit of any agent, as the sidebar's foot shows it.
    var limit: Insight.Limit? {
        let fullest = UsageView.rows(app).compactMap { row in row.main.map { (row, $0) } }.max { $0.1.used < $1.1.used }
        return fullest.map { row, line in
            Insight.Limit(name: "\(row.name) · \(line.label)", used: line.used, resets: line.resets)
        }
    }

    /// Reads the history from `start` on, and each live chat's last turn.
    func load(since start: Date) async {
        since = start
        do {
            let entries = try await app.get(SessionHistory(since: start))
            history = Dictionary(entries.map { ($0.session, $0.changes) }, uniquingKeysWith: { a, _ in a })
            failed = nil
        } catch {
            failed = error.localizedDescription
        }
        await loadTurns()
        loaded = true
    }

    /// Reads the last turn of each chat that has run today (only a running session keeps one).
    func loadTurns() async {
        var read: [String: SessionTurn.Turn] = [:]
        for s in chats(since: today) where s.status != .exited {
            if let info = await app.quiet(SessionTurn(id: s.id)), let turn = info?.turn { read[s.id] = turn }
        }
        turns = read
    }

    /// Watches what the cards show while the tab is up: each chat's folder (git and pull request) and context. It
    /// follows the chats as they come and go.
    func follow(_ cards: [OverviewCard]) {
        let now = Set(cards.flatMap { ["git|\($0.folder)", "pr|\($0.folder)", "context|\($0.id)"] })
        for key in now.subtracting(watched) { toggle(key, on: true) }
        for key in watched.subtracting(now) { toggle(key, on: false) }
        watched = now
    }

    func stop() { follow([]) }

    private func toggle(_ key: String, on: Bool) {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let topic = WatchTopic(rawValue: parts[0]) else { return }
        if on { app.watch(topic, parts[1]) } else { app.unwatch(topic, parts[1], forgetting: false) }
    }
}
