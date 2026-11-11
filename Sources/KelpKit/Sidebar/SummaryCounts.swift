import Core
import DesignKit
import Foundation

/// What the row over the projects counts beside who needs you, each a button of its own (`SummarySegment`), in the
/// order they stand.
enum SummaryKind: CaseIterable {
    /// At work, news coming.
    case working
    /// Stopped at a plan limit, or set to go on at its reset (`continueAt`): nobody has to do anything yet.
    case limit
    /// Working, but nothing heard from it for minutes (`quietSince`).
    case quiet
    /// Finished and not looked at.
    case done

    /// Which of them a chat is: nil for one that asks or failed (the capsule counts those), finished or resting.
    static func of(_ s: Session) -> SummaryKind? {
        guard s.isChat, ![.waiting, .error].contains(s.shownStatus), ![.paused, .exited].contains(s.status) else {
            return nil
        }
        if s.continueAt != nil || s.limitHit != nil { return .limit }
        guard s.status == .working else { return nil }
        return s.quietSince == nil ? .working : .quiet
    }

    /// Which goes first when the row is short of room: what asks for nothing.
    static let dropOrder: [SummaryKind] = [.done, .quiet, .limit]
}

/// The chats each segment stands for, longest in their state first: the order a click walks them in.
struct SummaryCounts {
    private var lists: [SummaryKind: [Session]] = [:]
    subscript(kind: SummaryKind) -> [Session] { lists[kind] ?? [] }

    /// `done`: the finished ones that wait to be read (`AttentionQueue`), so the count agrees with ⇧⌘U.
    init(chats: [Session], done: [Session]) {
        for s in chats { if let kind = SummaryKind.of(s) { lists[kind, default: []].append(s) } }
        lists[.done] = done.filter { $0.shownStatus == .done && SummaryKind.of($0) == nil }
        for kind in lists.keys { lists[kind]?.sort { Self.since($0, kind) < Self.since($1, kind) } }
    }

    /// When it got into this state: a quiet one from its last news.
    static func since(_ s: Session, _ kind: SummaryKind) -> Date {
        (kind == .quiet ? s.quietSince : nil) ?? s.statusAt ?? s.createdAt
    }

    /// What its segment says as room runs out: all of it, then without the time, then the number (or the clock) alone.
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
