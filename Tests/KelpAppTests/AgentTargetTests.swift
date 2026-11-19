import AppKit
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

/// A remote project's empty workspace offers the agents its host has, once the host answers, and New Agent starts one
/// of those: never an agent only this Mac has, which the host can't run ("claude: not found").
@MainActor @Test func aRemoteProjectOffersTheAgentsItsHostHas() async throws {
    _ = testHome
    let folder = URL(fileURLWithPath: Paths.root.path).appendingPathComponent("remote/box/app-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try JSONEncoder().encode(RemoteHost(host: "box", path: "/srv/app"))
        .write(to: folder.appendingPathComponent(RemoteHost.marker))
    let app = AppModel(builtins: Builtins.all)
    app.worktrees = [Worktree(id: "w", repoId: "r", branch: "main", path: folder.path)]
    let area = EditorArea(app: app, workspaceId: "w")
    area.render()
    func tiles() -> [String] {
        func labels(_ v: NSView) -> [String] {
            (v as? AgentTile).map { $0.subviews.flatMap(texts) } ?? v.subviews.flatMap(labels)
        }
        func texts(_ v: NSView) -> [String] {
            ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts)
        }
        return labels(area.start ?? NSView()).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    await mainActorTurns()
    #expect(tiles() == [])   // the host hasn't answered, and this Mac has none
    app.availability.heard("box", ["codex"])
    await mainActorTurns()
    #expect(tiles() == ["Codex", "⌥⌘T", "Agent Catalog…"])   // codex alone, the default here, and the catalog
    #expect(app.catalog.defaultAgent(in: app.worktree("w")) == "codex")
}
