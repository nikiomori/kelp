import Core
import DesignKit
import Foundation

/// A line of the overview's Needs Attention column: what holds the work up now, found by a rule over what the board
/// already shows. No model reads anything. A click takes the user to the chat it names.
struct Insight: Equatable, Identifiable {
    enum Kind: Int { case asks, failed, sameFile, review, context, limit }
    var kind: Kind
    var title: String
    var detail: String
    var session: String?
    var id: Int { kind.rawValue }

    /// What a rule reads of one chat on the board.
    struct Chat {
        var id: String, title: String
        var status: AgentStatus
        var stage: OverviewStage
        /// Since when its status is what it is.
        var since: Date
        var folder: String
        /// The files its last turn changed that aren't committed yet.
        var uncommitted: Set<String> = []
        var added = 0, removed = 0
        /// How full its conversation is, from 0 to 1.
        var context: Double?
        /// Its branch's pull request, when that has failed checks.
        var failedPR: Int?
    }
    /// A plan limit that is nearly used up.
    struct Limit { var name: String, used: Double, resets: String? }

    static let fullContext = 0.7, nearLimit = 0.8
    static let reviewWait: TimeInterval = 3600

    /// The lines, most pressing first: who asks, what broke, two chats on one file, a review left waiting, a full
    /// conversation, a plan near its limit.
    static func of(_ chats: [Chat], limit: Limit?, now: Date = Date()) -> [Insight] {
        var out: [Insight] = []
        let asking = chats.filter { $0.status == .waiting }.sorted { $0.since < $1.since }
        if let first = asking.first {
            out.append(
                .init(
                    kind: .asks, title: String(localized: "\(asking.count) chats need you"),
                    detail: String(
                        localized: "“\(first.title)” has waited \(shortSpan(now.timeIntervalSince(first.since)))"),
                    session: first.id))
        }
        if let broken = chats.first(where: { $0.failedPR != nil || $0.status == .error }) {
            let title =
                broken.failedPR.map { String(localized: "CI failed in #\($0)") }
                ?? String(localized: "“\(broken.title)” failed")
            out.append(.init(kind: .failed, title: title, detail: broken.title, session: broken.id))
        }
        if let shared = sharedFile(chats) {
            out.append(
                .init(
                    kind: .sameFile,
                    title: String(localized: "2 chats edit \((shared.file as NSString).lastPathComponent)"),
                    detail: "“\(shared.a.title)” · “\(shared.b.title)”", session: shared.a.id))
        }
        if let waiting = chats.filter({ $0.stage == .review && now.timeIntervalSince($0.since) > reviewWait })
            .min(by: { $0.since < $1.since })
        {
            out.append(
                .init(
                    kind: .review,
                    title: String(
                        localized: "Review waits \(shortSpan(now.timeIntervalSince(waiting.since), units: 2))"),
                    detail: "“\(waiting.title)”: +\(waiting.added) −\(waiting.removed)", session: waiting.id))
        }
        let full = chats.filter { ($0.context ?? 0) >= fullContext && $0.stage == .working }
        if let fullest = full.max(by: { ($0.context ?? 0) < ($1.context ?? 0) }) {
            out.append(
                .init(
                    kind: .context, title: String(localized: "\(full.count) chats near a full context"),
                    detail: String(localized: "“\(fullest.title)” will compact soon"), session: fullest.id))
        }
        if let limit, limit.used >= nearLimit {
            out.append(
                .init(
                    kind: .limit, title: "\(limit.name) — \(Int((limit.used * 100).rounded())) %",
                    detail: limit.resets.map { String(localized: "resets \($0)") } ?? "", session: nil))
        }
        return out
    }

    /// The first file two chats of one folder both changed and haven't committed.
    static func sharedFile(_ chats: [Chat]) -> (file: String, a: Chat, b: Chat)? {
        let live = chats.filter { $0.stage != .done && !$0.uncommitted.isEmpty }
        for (i, a) in live.enumerated() {
            for b in live[(i + 1)...] where b.folder == a.folder {
                if let file = a.uncommitted.intersection(b.uncommitted).sorted().first { return (file, a, b) }
            }
        }
        return nil
    }
}
