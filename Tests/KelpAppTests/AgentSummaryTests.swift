import Core
import Foundation
import Testing

@testable import KelpKit

/// The row over the projects counts each chat once: who works, who went quiet, who waits at a limit, who finished
/// unread; asking and failed are the capsule's. Each count says less as room runs out, its number last.
@MainActor @Test func summaryCountsEachChatOnce() {
    let now = Date()
    func chat(_ status: AgentStatus, ago: TimeInterval = 0) -> Session {
        var s = Session(cwd: "/", command: "claude", agent: "claude", status: status)
        s.statusAt = now.addingTimeInterval(-ago)
        return s
    }
    let long = chat(.working, ago: 720), short = chat(.working, ago: 30)
    var quiet = chat(.working)
    quiet.quietSince = now.addingTimeInterval(-34 * 60)
    var limited = chat(.done)
    limited.limitHit = LimitHit(kind: "5-hour", resets: "3pm")
    var done = chat(.done)
    done.unread = true
    let asking = chat(.waiting), shell = Session(cwd: "/", command: "zsh", agent: "shell", status: .working)
    let counts = SummaryCounts(
        chats: [short, long, quiet, limited, done, asking, shell], done: [done, limited, asking])

    #expect(counts[.working].map(\.id) == [long.id, short.id])   // the longest at work first: a click starts there
    #expect(counts[.quiet].map(\.id) == [quiet.id])
    #expect(counts[.limit].map(\.id) == [limited.id])
    #expect(counts[.done].map(\.id) == [done.id])
    let working = counts.words(.working, now: now)
    #expect(working[0].hasPrefix("2 working · ") && working[1] == "2 working" && working[2] == "2")
    #expect(counts.words(.limit, now: now) == ["1 at limit", "1 at limit", "1"])
    #expect(counts.words(.done, now: now).last == "1")
    let fresh = SummaryCounts(chats: [short], done: [])
    #expect(fresh.words(.working, now: now)[0] == "1 working")   // under a minute: no time

    #expect(AttentionQueue.next(in: counts[.working], after: long.id)?.id == short.id)
    #expect(AttentionQueue.next(in: counts[.working], after: nil)?.id == long.id)
    #expect(AttentionQueue.next(in: counts[.quiet], after: quiet.id) == nil)
}
