import Core
import Foundation
import Testing

@testable import KelpKit

/// One click goes on with an agent back at its prompt, done or failed; not with one that works, asks, or that a limit
/// stopped.
@MainActor @Test func quickRepliesAreForAnAgentBackAtItsPrompt() {
    var s = Session(cwd: "/", command: "claude", agent: "claude")
    for (status, fits) in [(AgentStatus.done, true), (.error, true), (.working, false), (.waiting, false)] {
        s.status = status
        #expect(QuickReply.fits(s) == fits, "\(status)")
    }
    s.status = .done
    s.limitHit = LimitHit(kind: "5-hour", resets: "3pm")
    #expect(!QuickReply.fits(s))
}
