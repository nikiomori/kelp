import Core
import Foundation
import Testing

@testable import KelpApp
@testable import KelpKit

/// Text for "the agent" (Send to Agent, Fix with Agent, findings) goes by one rule: agents only, never a reviewer
/// (marked by its role, whatever its title says), the one the user was last with, else the only one.
@MainActor @Test func textForTheAgentGoesToTheAgentNotItsReviewerNorAServer() {
    _ = testHome
    let app = AppModel(builtins: Builtins.all)
    func add(_ id: String, _ agent: String, title: String = "", role: SessionRole? = nil) {
        var s = Session(id: id, worktreeId: "w", cwd: "/", command: agent, agent: agent, status: .idle, title: title)
        s.role = role
        app.upsert(s)
    }
    add("server", Session.customAgent, title: "npm run dev")
    add("shell", Session.shellAgent)
    add("coder", "claude")
    add("pr-review", "claude", title: "Review: #12", role: .reviewer)   // a pull request's review: no agent's name in it
    app.workbench.workspaceId = "w"
    let actions = FileActions(app)
    #expect(actions.agents(in: "w").map(\.id) == ["coder"])
    app.workbench.lastSession = "server"   // a dev server last looked at isn't who gets "fix this"
    #expect(actions.agent(in: "w")?.id == "coder")
    app.workbench.lastSession = "pr-review"
    #expect(actions.agent(in: "w")?.id == "coder")
    add("second", "codex")
    #expect(actions.agent(in: "w") == nil)   // two, and the user with neither: asked, not guessed
    app.workbench.lastSession = "second"
    #expect(actions.agent(in: "w")?.id == "second")
}
