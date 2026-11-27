import Agents
import Core
import Foundation
import TestSupport
import Testing

@testable import Daemon

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])
private func summary(_ w: World, _ id: String) throws -> String { try w.d.store.session(id)?.summary ?? "" }

/// A site the user allowed covers its subdomains, never a name that only ends the same way, and only web addresses.
@Test(arguments: [
    ("x.com", "x.com"), ("https://mobile.x.com/home", "x.com"), ("www.x.com/elonmusk", "x.com"),
    ("evilx.com", nil), ("x.com.evil.io", nil), ("http://localhost:3000", nil), ("file:///x.com", nil)
])
func aSiteCoversItsSubdomainsOnly(address: String, covered: String?) {
    let list = AgentSites.adding("x.com", chat: "read x posts", to: [])
    #expect(AgentSites.site(of: address).flatMap { AgentSites.allowed($0, in: AgentSites.entries(list)) } == covered)
}

/// A login question names its site, read back by the card that answers it; any other question names none.
@Test(arguments: [
    (AgentSites.question(agent: "Demo Agent", site: "x.com"), "x.com"),
    (AgentSites.question(agent: "Claude Code", site: "mobile.x.com"), "mobile.x.com"),
    ("Allow changing 3 rows of orders in shop?", nil), ("On its page: Sign in", nil)
])
func aLoginQuestionNamesItsSite(question: String, site: String?) {
    #expect(AgentSites.asked(question) == site)
}

/// Allow keeps the site for every agent in every project, so the question says that, not only the agent asking.
@Test func theLoginQuestionSaysItIsForEveryAgent() {
    let question = AgentSites.question(agent: "Demo Agent", site: "x.com")
    #expect(question.contains("every other agent") && question.contains("every project"))
    #expect(AgentSites.asked(question) == "x.com")
}

/// An agent gets the user's login only on a site they allowed. `--shared` asks on its row; no answer says nobody
/// answered; a Deny isn't asked again until the turn ends; Allow adds the site, and after that a plain open gets the
/// login with no question.
@Test func anAgentGetsTheUsersLoginOnlyWhereTheyAllowedIt() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let relay = BrowserRelay.of(w.d), permissions = w.d.sessions.permissions
    let question = BrowserRelay.question(agent: "Bot", site: "x.com")   // its own name, from its file
    /// Whether kelpd waits on the question now, with the row saying it. Not the row alone: after an answer it may
    /// still show the question before.
    func asked() throws -> Bool {
        let waits = permissions.kelpWaits.withLock { $0[agent.id]?.count == 1 }
        return try waits && summary(w, agent.id) == question
    }
    func login(_ url: String, shared: Bool = false) async throws -> JSONValue? {
        try await relay.login(["url": .string(url), "shared": .bool(shared)], driver: (agent.id, nil), asker: nil)
    }
    #expect(try await login("x.com") == nil)   // not allowed: a page of its own, nobody asked

    let cutShort = Task { try await login("x.com", shared: true) }
    #expect(try await waitFor { try asked() })
    #expect(permissions.answerKelp(agent.id, question: nil, PermissionWaits.askerGone))   // its tool's time ran out
    do {
        _ = try await cutShort.value
        Issue.record("a command cut short got the login")
    } catch { #expect("\(error)".contains("ended before the user answered")) }

    let unanswered = Task { try await login("x.com", shared: true) }   // asked again: no Deny was heard
    #expect(try await waitFor { try asked() })
    #expect(permissions.answerKelp(agent.id, question: nil, nil))   // its ten minutes ran out
    do {
        _ = try await unanswered.value
        Issue.record("an unanswered question let the agent in")
    } catch { #expect("\(error)".contains("Nobody answered")) }
    permissions.endKelpQuestions(agent.id)

    let denied = Task { try await login("x.com", shared: true) }
    #expect(try await waitFor { try asked() })
    #expect(permissions.answerKelp(agent.id, question: nil, "deny"))
    await #expect(throws: RPCError.self) { try await denied.value }
    await #expect(throws: RPCError.self) { try await login("x.com", shared: true) }   // not asked again this turn
    permissions.endKelpQuestions(agent.id)   // the turn ends

    let allowed = Task { try await login("https://x.com/home", shared: true) }
    #expect(try await waitFor { try asked() })
    // An answer names the login question's run: another site's, or a question worded like it, answers nothing.
    #expect(!permissions.answerKelp(agent.id, question: nil, "allow", run: AgentSites.run("evil.com")))
    #expect(permissions.answerKelp(agent.id, question: nil, "allow", run: AgentSites.run("x.com")))
    #expect(try await allowed.value == "x.com")
    #expect(AgentSites.entries(w.d.settings[SettingKeys.agentSites]).map(\.site) == ["x.com"])
    #expect(try await login("mobile.x.com") == "x.com")   // allowed now: at once, no question

    // A page driven from an ssh host never gets the login, even on a site in the list.
    let fromHost = try await HostBrowser.$page.withValue(.object(["host": "box"])) {
        let plain = try await login("x.com")
        do { _ = try await login("x.com", shared: true) } catch { return (plain, "\(error)") }
        return (plain, "")
    }
    #expect(fromHost.0 == nil && fromHost.1.contains("stays on this Mac"))
}
