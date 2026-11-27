import Agents
import AppKit
import Core
import Testing

@testable import BuiltinAgents
@testable import KelpKit

/// The agent's row only says a question; the card over its terminal is where the login question is answered. It comes
/// for that question alone and goes when the row asks something else or nothing.
@MainActor @Test func theLoginQuestionIsAnsweredOnACardOverTheAgentsTerminal() {
    let card = LoginAskCard(app: AppModel(), session: "s1")
    let question = AgentSites.question(agent: "Demo Agent", site: "x.com")
    #expect(card.isHidden)
    var asking = Session(cwd: "/", command: "demo")
    (asking.status, asking.summary) = (.waiting, question)
    #expect(asking.asksPermission)   // so the row, the Dock's strip and a notification offer Allow and Deny
    card.show(question)
    #expect(!card.isHidden)
    for other in ["Allow changing 3 rows of orders in shop?", "On its page: Sign in", ""] {
        card.show(question)
        card.show(other)
        #expect(card.isHidden, "\(other)")
    }
}
