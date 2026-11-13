import AppKit
import Core
import Foundation
import Testing
import WorkbenchKit

@testable import BuiltinAgents
@testable import KelpKit

/// A session of the workspace, known to the app.
@MainActor private func session(_ rig: AppRig, _ p: SessionCreate) async throws -> Session {
    let s = try #require(await rig.app.call(p))
    rig.app.upsert(s)
    return s
}

extension OneAtATime {
    /// What someone else starts gets a tab behind the one you're looking at: it neither covers it nor takes the pane.
    @Test func aSessionStartedElsewhereTakesNothing() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        let mine = try await session(rig, SessionCreate(worktreeId: rig.workspace.id, command: "sleep 30"))
        area.open(TabURI.session(mine.id))
        let other = try await session(rig, SessionCreate(worktreeId: rig.workspace.id, command: "sleep 31"))
        area.reconcile()
        #expect(area.layout.tab(uri: TabURI.session(other.id)) != nil)
        #expect(area.layout.focusedGroup?.selectedTab?.uri == TabURI.session(mine.id))
    }

    /// `kelp open` beside you: the pane appears, and the one you're in stays the focused one.
    @Test func openingBesideYouLeavesYourPaneFocused() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        area.arrangedByHand()
        let mine = try await session(rig, SessionCreate(worktreeId: rig.workspace.id, command: "sleep 30"))
        area.open(TabURI.session(mine.id))
        let other = try await session(rig, SessionCreate(worktreeId: rig.workspace.id, command: "sleep 31"))
        area.showAside(TabURI.session(other.id), split: .down)
        #expect(area.layout.root?.sessions.count == 2)
        #expect(area.layout.focusedGroup?.selectedTab?.uri == TabURI.session(mine.id))
    }

    /// A chat offers Move to the copies of its project, by where they are; a project with none offers nothing.
    @Test func aChatOffersItsProjectsCopiesToMoveTo() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let chat = Session(worktreeId: rig.workspace.id, cwd: rig.workspace.path, command: "claude", agent: "claude")
        rig.app.sessions = [chat]
        func moves() -> [String]? {
            let menu = NSMenu()
            AgentActions(rig.app).addMove(to: menu, chat.id)
            return menu.items.first { $0.title == "Move to" }?.submenu?.items.map(\.title)
        }
        #expect(moves() == nil)
        rig.app.repos.append(
            Repo(name: rig.project.name, path: "/tmp/elsewhere/" + rig.project.name, baseBranch: "main"))
        #expect(moves() == ["This Mac"])
    }

    /// Follow Edits: an edited file shows in a pane beside the agent, which stays in front and focused; the next file
    /// takes that tab, one the user edited meanwhile stays.
    @Test func followedEditsShowBesideTheAgentInOneTab() async throws {
        let rig = try await AppRig(files: ["a.txt": "a\n", "b.txt": "b\n", "c.txt": "c\n"])
        defer { rig.done() }
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        area.arrangedByHand()
        let mine = try await session(rig, SessionCreate(worktreeId: rig.workspace.id, command: "sleep 30"))
        let agent = TabURI.session(mine.id)
        area.open(agent)
        let a = TabURI.file(rig.workspace.path + "/a.txt"), b = TabURI.file(rig.workspace.path + "/b.txt")
        area.showBeside(a, of: agent, replacing: nil)
        #expect(area.layout.root?.sessions.count == 2)
        #expect(area.layout.focusedGroup?.selectedTab?.uri == agent)
        #expect(
            area.layout.group(of: area.layout.tab(uri: a)?.id ?? "")
                != area.layout.group(of: area.layout.tab(uri: agent)?.id ?? ""))
        area.showBeside(b, of: agent, replacing: a)
        #expect(area.layout.tab(uri: a) == nil && area.layout.tab(uri: b) != nil)
        #expect(area.layout.root?.sessions.count == 2 && area.layout.focusedGroup?.selectedTab?.uri == agent)
    }
}

extension OneAtATime {
    /// An agent's command lives on the agent's line: no tab, no sidebar row, not an agent among agents. The agent gone, a
    /// command still running gets a tab; moved to a tab, it stays there.
    @Test func aCommandBelongsToItsAgentWhileItLives() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let wid = rig.workspace.id, app = rig.app
        var agent = Session(worktreeId: wid, cwd: "/", command: "claude", agent: "claude")
        var run = Session(worktreeId: wid, cwd: "/", command: "swift build", agent: "custom", title: "swift build")
        run.startedBy = agent.id
        app.sessions = [agent, run]
        let area = EditorArea(app: app, workspaceId: wid)
        area.reconcile()
        #expect(area.layout.tab(uri: TabURI.session(agent.id)) != nil)
        #expect(area.layout.tab(uri: TabURI.session(run.id)) == nil)
        #expect(app.workbench.shownSessions.map(\.id) == [agent.id])
        #expect(!run.isChat && agent.isChat)

        agent.status = .exited
        app.sessions = [agent, run]
        area.reconcile()
        #expect(area.layout.tab(uri: TabURI.session(run.id)) != nil)

        agent.status = .idle
        app.sessions = [agent, run]
        app.workbench.openInTab(run.id)
        #expect(!app.workbench.isOnLine(run))
    }
}

/// What a command last printed: the last line with anything on it, a progress line's latest state.
@MainActor @Test func aRunsLastLineIsWhatItPrintedLast() {
    #expect(CommandsBar.lastLine("Compiling\n[1/5] a\r[2/5] b\r\n\n") == "[2/5] b")
    #expect(CommandsBar.lastLine("  \n") == nil)
}

/// A command's end, by its exit code.
@MainActor @Test func aRunEndsFineStoppedOrFailed() {
    #expect(CommandRow.status(exit: 0) == .done)
    #expect(CommandRow.status(exit: 143) == .exited)
    #expect(CommandRow.status(exit: 1) == .error && CommandRow.status(exit: nil) == .error)
}

/// `session(_:)` answers from an index made after each change of `sessions`: a record replaced, added or removed is
/// what the next lookup finds, never the one before it.
@MainActor @Test func aSessionLookupFollowsEveryChange() {
    let m = AppModel(builtins: [])
    var a = Session(id: "a", cwd: "/", command: "x"), b = Session(id: "b", cwd: "/", command: "y")
    m.sessions = [a, b]
    #expect(m.session("b")?.command == "y" && m.session("zz") == nil)
    a.title = "renamed"
    m.sessions[0] = a
    #expect(m.session("a")?.title == "renamed")
    m.sessions.remove(at: 0)
    #expect(m.session("a") == nil && m.session("b")?.command == "y")
    b.command = "z"
    m.sessions.append(Session(id: "c", cwd: "/", command: "c"))
    m.upsert(b)
    #expect(m.session("b")?.command == "z" && m.session("c")?.command == "c")
}
