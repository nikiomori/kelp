import Core
import DesignKit
import Foundation

/// What the row above the projects counts beside who needs you, in the order the counts stand. Each count is a button
/// of its own (`SummarySegment`).
enum SummaryKind: CaseIterable {
    /// At work, with news coming.
    case working
    /// Stopped at a plan limit, or set to go on at the limit's reset (`continueAt`). Nobody has to do anything yet.
    case limit
    /// Working, but with nothing heard from it for minutes (`quietSince`).
    case quiet
    /// Finished and not looked at.
    case done

    /// Returns the count a chat belongs to. It is nil for a chat that asks or failed (the capsule counts those), and
    /// for one that is finished or resting.
    static func of(_ session: Session) -> SummaryKind? {
        guard session.isChat, ![.waiting, .error].contains(session.shownStatus),
            ![.paused, .exited].contains(session.status)
        else {
            return nil
        }
        if session.continueAt != nil || session.limitHit != nil { return .limit }
        guard session.status == .working else { return nil }
        return session.quietSince == nil ? .working : .quiet
    }

    /// The counts that go first when the row is short of room, in order. They are the ones that ask for nothing.
    static let dropOrder: [SummaryKind] = [.done, .quiet, .limit]
}

/// The chats each segment stands for, with the longest in their state first, which is the order a click walks them in.
struct SummaryCounts {
    private var lists: [SummaryKind: [Session]] = [:]
    subscript(kind: SummaryKind) -> [Session] { lists[kind] ?? [] }

    /// `done` holds the finished chats that wait to be read (`AttentionQueue`), so the count agrees with ⇧⌘U.
    init(chats: [Session], done: [Session]) {
        for s in chats { if let kind = SummaryKind.of(s) { lists[kind, default: []].append(s) } }
        lists[.done] = done.filter { $0.shownStatus == .done && SummaryKind.of($0) == nil }
        for kind in lists.keys { lists[kind]?.sort { Self.since($0, kind) < Self.since($1, kind) } }
    }

    /// When the chat got into this state. For a quiet chat, it is the time of its last news.
    static func since(_ session: Session, _ kind: SummaryKind) -> Date {
        (kind == .quiet ? session.quietSince : nil) ?? session.statusAt ?? session.createdAt
    }

    /// What a segment says as room runs out: all of it, then without the time, then the number (or the clock) alone.
    func words(_ kind: SummaryKind, now: Date = Date()) -> [String] {
        let list = self[kind], n = list.count
        switch kind {
        case .working:
            let words = String(localized: "\(n) working")
            let longest = list.first.map { Self.since($0, kind) }
            let time = longest.flatMap { now.timeIntervalSince($0) >= 60 ? shortAgo($0, now: now) : nil }
            return [time.map { "\(words) · \($0)" } ?? words, words, "\(n)"]
        case .limit:
            let clock = list.compactMap(\.continueAt).min()?.formatted(date: .omitted, time: .shortened)
            let words = clock.map { String(localized: "\(n) until \($0)") } ?? String(localized: "\(n) at limit")
            return [words, words, clock ?? "\(n)"]
        case .quiet:
            let words = String(localized: "\(n) quiet \(shortAgo(list.first.map { Self.since($0, kind) }, now: now))")
            return [words, words, "\(n)"]
        case .done:
            let words = String(localized: "\(n) done")
            return [words, words, "\(n)"]
        }
    }
}
