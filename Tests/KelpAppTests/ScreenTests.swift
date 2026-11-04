import AppKit
import Foundation
import Testing
import Core
import WorkbenchKit
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

/// What a window would show, without showing one: the real controllers, filled from the model, laid out in a window that
/// is never ordered on screen. The rows are read back out of the outline the user would be looking at.

@MainActor private func texts(_ v: NSView) -> [String] {
    var out: [String] = []
    if let t = v as? NSTextField, !t.stringValue.isEmpty, !t.isHidden { out.append(t.stringValue) }
    for s in v.subviews where !s.isHidden { out += texts(s) }
    return out
}

@MainActor private func outline(in v: NSView) -> NSOutlineView? {
    if let o = v as? NSOutlineView { return o }
    for s in v.subviews { if let o = outline(in: s) { return o } }
    return nil
}

@MainActor private func rows(of o: NSOutlineView) -> [[String]] {
    (0..<o.numberOfRows).map { r in (o.view(atColumn: 0, row: r, makeIfNecessary: true)).map(texts) ?? [] }
}

@MainActor private func withSidebar(repos: [Repo], worktrees: [Worktree], sessions: [Session], settings: [String: JSONValue] = [:],
                                    _ check: (SidebarController, NSOutlineView) throws -> Void) throws {
    _ = testHome
    let m = AppModel(builtins: Builtins.all)
    if !settings.isEmpty { m.settings.apply(settings) }
    m.repos = repos; m.worktrees = worktrees; m.sessions = sessions
    let vc = SidebarController(app: m)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.titled], backing: .buffered, defer: true)   // never shown
    window.contentViewController = vc
    vc.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
    vc.view.layoutSubtreeIfNeeded()
    let o = try #require(outline(in: vc.view))
    try check(vc, o)
}

private let project = Repo(id: "r1", name: "Atlas", path: "/tmp/kelp-screen-atlas")
private func desk(_ id: String, _ branch: String, note: String = "") -> Worktree {
    Worktree(id: id, repoId: "r1", branch: branch, path: "/tmp/kelp-screen-atlas/\(id)", note: note)
}

/// The project's own screen: its chats have no heading.
private func own(_ id: String) -> Worktree { Worktree(id: id, repoId: "r1", branch: "main", path: project.path) }

// Windows keep their panels' state in UserDefaults, the process's: one at a time.
extension OneAtATime {
@Test func theSidebarListsTheProjectItsWorkspacesAndTheirAgents() throws {
    let agent = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Fix login bug")
    try withSidebar(repos: [project], worktrees: [desk("w1", "feat/login"), desk("w2", "feat/billing", note: "Billing rewrite")], sessions: [agent]) { _, o in
        let r = rows(of: o)
        #expect(r.count == 4)                                   // project, two workspaces, one agent under the first
        #expect(r[0].contains("Atlas"))
        #expect(r[1].contains("feat/login") && r[2].contains("Fix login bug"))   // the agent sits right under its workspace
        #expect(r.flatMap { $0 }.contains("Billing rewrite"))   // a note is the workspace's name
        #expect(r.flatMap { $0 }.contains("feat/billing"))      // and its branch stands beside it, not twice when they're one
        #expect(r[1].filter { $0 == "feat/login" }.count == 1)
        #expect(r.flatMap { $0 }.contains("Fix login bug"))
    }
}

/// An agent's children take no rows: dots stand for them on its row, and what one asks is its second line.
@Test func childrenStandOnTheirParentsRow() throws {
    let parent = Session(id: "p", worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Graph")
    var kid = Session(id: "k", worktreeId: "w1", cwd: "/", command: "codex", agent: "codex", status: .waiting, title: "reviewer", summary: "May I run npm test?")
    kid.parent = "p"
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: [parent, kid]) { _, o in
        let r = rows(of: o)
        #expect(r.count == 2)   // the project and the parent
        #expect(r[1].contains("Graph") && !r[1].contains("reviewer"))
        let line = try #require(SidebarCell.line(parent, mode: "needsYou", among: [parent, kid]))
        #expect(line.prefix?.0 == "reviewer:" && line.text.contains("npm test"))
    }
}

/// A chat's menu says where it can go.
@Test func aChatCanMoveAmongTheScreensOfItsFolder() throws {
    let group = Worktree(id: "g", repoId: "r1", branch: "main", path: project.path, note: "Merge", createdAt: Date(timeIntervalSinceNow: 60))
    let there = Worktree(id: "b", repoId: "r1", branch: "feat", path: "/tmp/kelp-screen-atlas/b")
    let here = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .idle, title: "Here")
    let inGroup = Session(worktreeId: "g", cwd: "/", command: "claude", agent: "claude", status: .idle, title: "In group")
    let onBranch = Session(worktreeId: "b", cwd: "/", command: "claude", agent: "claude", status: .idle, title: "On a branch")
    try withSidebar(repos: [project], worktrees: [own("w1"), group, there], sessions: [here, inGroup, onBranch]) { vc, _ in
        @MainActor func items(_ s: Session) -> [String] {
            let m = NSMenu()
            vc.moveItems(m, chat: s.id)
            return m.items.first?.submenu?.items.map(\.title) ?? []
        }
        #expect(items(here) == ["New Group", "Merge"])
        #expect(items(inGroup) == ["New Group", "Back to Project"])
        #expect(items(onBranch) == [])   // its files are elsewhere
    }
}

@Test func aRemoteProjectNamedLikeAnotherSaysItsMachineAndItsRowRenamesTheProject() throws {
    let folder = Paths.root.appendingPathComponent("remote/beet/infra")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONEncoder().encode(RemoteHost(host: "beet", path: "/srv/infra")).write(to: folder.appendingPathComponent(RemoteHost.marker))
    let here = Repo(id: "r1", name: "infra", path: "/tmp/kelp-screen-infra"), there = Repo(id: "r2", name: "infra", path: folder.path)
    try withSidebar(repos: [here, there], worktrees: [], sessions: []) { vc, o in
        let names = rows(of: o).flatMap { $0 }
        // Both by their names; the remote one has its machine beside it, in grey, and this Mac's nothing.
        #expect(names.filter { $0 == "infra" }.count == 2 && names.filter { $0 == "beet" }.count == 1)
        #expect(vc.app.projectPlace(there) == "beet:/srv/infra")
        // The project's row edits the project's own name, not the workspace it stands for.
        vc.startRename("r2", project: true)
        #expect(vc.renaming?.id == "r2" && vc.renaming?.project == true)
        // Its name, editable in its row, without the machine the row adds.
        let edited = (0..<o.numberOfRows).compactMap { o.view(atColumn: 0, row: $0, makeIfNecessary: true) }
            .flatMap { v in v.subviews.flatMap { ($0 as? NSStackView)?.views ?? [] } }.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        #expect(edited.map(\.stringValue) == ["infra"])
        vc.app.repos = [there]
        #expect(vc.app.projectName("r2") == "infra")   // no namesake left: no machine
    }
}

@Test func aProjectFoldsFromItsChevronAndSaysWhatItsAgentsDo() throws {
    let agent = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Fix login bug")
    try withSidebar(repos: [project], worktrees: [desk("w1", "feat/login"), desk("w2", "feat/billing")], sessions: [agent]) { vc, o in
        #expect(o.numberOfRows == 4)
        func fold() throws -> NSButton {
            let cell = try #require(o.view(atColumn: 0, row: 0, makeIfNecessary: true))
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, ["Collapse", "Expand"].contains(b.image?.accessibilityDescription ?? "") { return b }
                return v.subviews.lazy.compactMap(find).first
            }
            return try #require(find(cell))
        }
        try fold().performClick(nil)
        #expect(o.numberOfRows == 1)                            // the project alone
        #expect(rows(of: o)[0].contains("1"))                   // and how many of its agents need you
        #expect(vc.app.uiState.strings("sidebar.collapsed") == ["p:r1"])   // kept for the next launch
        try fold().performClick(nil)
        #expect(o.numberOfRows == 4)                            // its workspaces open as they were
        #expect(vc.app.uiState.strings("sidebar.collapsed").isEmpty)
    }
}

@Test func aBackgroundCommandTakesItsMarksRoomOnlyAndItsNameIsInTheTooltip() throws {
    var agent = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working,
                        title: "Структура и плотность левой панели")
    agent.background = ["cd /tmp\nnpm run dev -- --port 3000"]
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: [agent]) { _, o in
        let cell = try #require(o.view(atColumn: 0, row: 1, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let chip = try #require(all(cell).compactMap { $0 as? Chip }.first { !$0.isHidden })
        let name = try #require(all(cell).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Структура") })
        #expect(chip.frame.width <= 16, "\(chip.frame.width) pt")      // a symbol, no words, and no number for one
        #expect(name.frame.width >= 80)      // the name keeps the row
        #expect(chip.toolTip?.contains("npm run dev -- --port 3000") == true)
        #expect(chip.toolTip?.contains("cd /tmp") == false)   // a line, as the list shows it
    }
}

@Test func theCommandItWaitsForIsItsMarkNotOneBesideIt() throws {
    var agent = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Тесты")
    agent.background = ["npm test", "npm run dev"]
    agent.awaiting = "npm test"
    #expect(agent.waitsForCommand && agent.aside == ["npm run dev"])
    #expect(agent.backgroundTip == "Waits for its command:\nnpm test\nRunning in the background:\nnpm run dev")
    agent.status = .waiting   // it asks: the ring is the question's, so the command stands beside it
    #expect(!agent.waitsForCommand && agent.aside == ["npm test", "npm run dev"])
    agent.status = .exited
    #expect(agent.aside.isEmpty && agent.backgroundTip == nil)
}

@Test func aProjectsRowFindsItsWorkspaceWhenThatArrivesAfterIt() throws {
    try withSidebar(repos: [project], worktrees: [], sessions: []) { vc, _ in
        vc.app.worktrees = [desk("w1", "main")]   // the daemon's projects came first, their workspaces a moment later
        vc.refresh()
        #expect(vc.workspaceNode("w1") != nil)   // else the workspace on screen is never picked in the list
    }
}

@Test func aProjectsColourShowsInTheStyleTheSettingNames() throws {
    let here = Repo(id: "r1", name: "Atlas", path: NSTemporaryDirectory())   // a folder that's there: its menu isn't Locate…
    try withSidebar(repos: [here], worktrees: [], sessions: []) { vc, o in
        #expect(vc.cards.isEmpty)
        let row = o.rect(ofRow: 0), at = o.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(o.menu(for: click))
        vc.menuNeedsUpdate(menu)
        let color = try #require(menu.items.first { $0.title == "Color" })   // a row of dots, or a submenu for the keyboard
        if let dots = color.view as? ColorSwatches { dots.pick(.blue) } else { color.submenu?.performActionForItem(at: color.submenu?.indexOfItem(withTitle: "Blue") ?? 0) }
        #expect(vc.app.projectColors["r1"] == .blue)
        vc.placeCards()
        #expect(vc.cards.isEmpty)                   // on its icon: the row stays plain
        #expect(vc.app.iconColor(folder: here.path) == .blue)
        vc.app.settings.apply(["workbench.sidebar.projectColor": "card"])
        vc.placeCards()
        #expect(vc.cards["p:r1"]?.look.color == .blue)
        #expect(vc.app.iconColor(folder: here.path) == nil)
        vc.app.colorPreview = ("r1", nil)           // the dot under the pointer: shown, not kept
        vc.placeCards()
        #expect(vc.cards.isEmpty)
        vc.app.colorPreview = nil
        #expect(vc.app.projectColors["r1"] == .blue)
        #expect(ProjectColor.read(.obj(["r1": .string("a colour a later build dropped")])).isEmpty)
    }
}

@Test func anEndedAgentAndAPlainTerminalAreNotListed() throws {
    let ended = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .exited, title: "Old chat")
    let shell = Session(worktreeId: "w1", cwd: "/", command: "zsh", agent: "shell", status: .idle, title: "zsh")
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: [ended, shell]) { _, o in
        let all = rows(of: o).flatMap { $0 }
        #expect(!all.contains("Old chat") && !all.contains("zsh"))
        #expect(o.numberOfRows == 1)                            // the project, standing for its one workspace: nothing else
    }
}

/// The middle of the window says what to do first (WelcomeView): the sidebar doesn't say it a second time.
@Test func withNoProjectsTheSidebarKeepsQuiet() throws {
    try withSidebar(repos: [], worktrees: [], sessions: []) { vc, o in
        #expect(o.numberOfRows == 0)
        let line = try #require(vc.view.subviews.compactMap { $0 as? AgentSummary }.first)
        #expect(line.isHidden)
    }
}

@Test func theAgentWaitingForYouSaysWhatItAsksAndTheLineOverTheListCountsIt() throws {
    var ask = Session(worktreeId: "w3", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Allow rm?", summary: "Needs permission")
    ask.statusAt = Date() - 60   // it has needed you a while (Inbox.settle)
    try withSidebar(repos: [project], worktrees: [desk("w1", "a"), desk("w2", "b"), desk("w3", "c")], sessions: [ask]) { vc, o in
        let all: [String] = rows(of: o).flatMap { $0 }   // typed: CI's type check gave up on it
        #expect(all.filter { $0 == "Allow rm?" }.count == 1)                   // listed once, under its workspace
        #expect(all.contains { $0.contains("Needs permission") })              // what it asks, under its name
        #expect(texts(vc.view).contains("1 need you"))                         // and counted over the list
        let row = (0..<o.numberOfRows).compactMap { o.view(atColumn: 0, row: $0, makeIfNecessary: true) }
            .first { ($0.accessibilityLabel() ?? "").hasPrefix("Allow rm?") }
        #expect(row?.accessibilityLabel() == "Allow rm?, Needs your input, Asks: Needs permission, Atlas, 1m")   // one sentence for VoiceOver
    }
}

@Test func moreAgentsAskingChangeTheCountNotTheList() throws {
    func asking(_ n: Int) -> [Session] {
        (1...n).map { i in
            var s = Session(worktreeId: "w\(i)", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Ask \(i)", summary: "Question \(i)")
            s.statusAt = Date() - 60
            return s
        }
    }
    try withSidebar(repos: [project], worktrees: (1...4).map { desk("w\($0)", "b\($0)") }, sessions: asking(1)) { vc, o in
        let top = { o.convert(o.rect(ofRow: 0), to: nil).minY }   // the project's row, in the window
        let before = top()
        vc.app.sessions = asking(4)
        for case let line as AgentSummary in vc.view.subviews { line.update() }   // what it hears on the main queue's next turn
        vc.view.layoutSubtreeIfNeeded()
        #expect(texts(vc.view).contains("4 need you"))
        #expect(top() == before)   // the line over the list keeps its height: nothing in the list moved
    }
}

/// Laid out narrow first (as the window opens), then at its width: the capsule's words are whole, inside its glass.
@Test func theCapsuleTakesItsWordsBackWhenTheSidebarWidens() throws {
    let asks = (1...6).map { i in
        var s = Session(worktreeId: "w\(i)", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Ask \(i)")
        s.statusAt = Date() - 60
        return s
    }
    try withSidebar(repos: [project], worktrees: (1...6).map { desk("w\($0)", "b\($0)") }, sessions: asks) { vc, _ in
        let line = try #require(vc.view.subviews.compactMap { $0 as? AgentSummary }.first)
        let title = try #require(textFields(line).first { $0.stringValue == "6 need you" })
        let capsule = try #require(title.superview?.superview)
        vc.view.frame.size.width = 60
        vc.view.layoutSubtreeIfNeeded()
        vc.view.frame.size.width = 280
        vc.view.layoutSubtreeIfNeeded()
        #expect(title.frame.width >= title.intrinsicContentSize.width)
        #expect(title.convert(title.bounds, to: capsule).maxX <= capsule.bounds.maxX)
    }
}

/// Nobody asking: what works and what finished stand side by side over the list, words and marks with a width of their own.
@Test func theLineOverTheListSaysWhatWorksAndWhatFinished() throws {
    func agent(_ w: String, _ status: AgentStatus) -> Session {
        var s = Session(worktreeId: w, cwd: "/", command: "claude", agent: "claude", status: status, title: "Report", summary: "")
        s.unread = status == .done
        return s
    }
    try withSidebar(repos: [project], worktrees: [desk("w1", "a"), desk("w2", "b")], sessions: [agent("w1", .working), agent("w2", .done)]) { vc, _ in
        vc.view.layoutSubtreeIfNeeded()
        let line = try #require(vc.view.subviews.compactMap { $0 as? AgentSummary }.first)
        for words in ["1 working", "1 done"] {
            let field = try #require(textFields(line).first { $0.stringValue == words })
            #expect(!field.isHidden && field.frame.width > 0)
        }
    }
}

/// Too narrow for the whole line (a large Text size): one line still, saying how many need you, never two inside the capsule.
@Test func theCapsuleDropsWhoWorksWhenItsLineWontFit() throws {
    var ask = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Ask")
    ask.statusAt = Date() - 60
    let work = Session(worktreeId: "w2", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Work")
    try withSidebar(repos: [project], worktrees: [desk("w1", "b1"), desk("w2", "b2")], sessions: [ask, work]) { vc, _ in
        let line = try #require(vc.view.subviews.compactMap { $0 as? AgentSummary }.first)
        vc.view.layoutSubtreeIfNeeded()
        #expect(textFields(line).contains { $0.stringValue.hasSuffix("1 working") })
        vc.view.frame.size.width = 120
        vc.view.layoutSubtreeIfNeeded()
        line.layoutSubtreeIfNeeded()
        #expect(textFields(line).contains { $0.stringValue == "1 need you" })
    }
}

@MainActor private func textFields(_ v: NSView) -> [NSTextField] {
    if let t = v as? NSTextField { return [t] }
    return v.subviews.flatMap(textFields)
}

@Test func theLineOverTheListCountsWhatAskedNotWhatFinished() throws {
    func agent(_ w: String, _ status: AgentStatus, _ title: String) -> Session {
        var s = Session(worktreeId: w, cwd: "/", command: "claude", agent: "claude", status: status, title: title, summary: "Question")
        s.statusAt = Date() - 60
        s.unread = true
        return s
    }
    let sessions = [agent("w1", .waiting, "Ask"), agent("w2", .done, "Report A"), agent("w3", .done, "Report B"), agent("w4", .done, "Put away")]
    // w4 is archived: the daemon doesn't list it, its agent stays in the session list.
    try withSidebar(repos: [project], worktrees: (1...3).map { desk("w\($0)", "b\($0)") }, sessions: sessions) { vc, o in
        #expect(texts(vc.view).contains("1 need you"))   // the question: finished reports nobody has read ask for nothing; nor the archived one's
        #expect(texts(vc.view).contains("2 done"))       // beside it in grey, those two and not the archived one
        let listed: [String] = rows(of: o).flatMap { $0 }
        #expect(listed.contains("Report A") && listed.contains("Report B"))   // each on its own row
    }
}

/// The row over the list stays, so the list never moves: with nobody asking or working it names the list.
@Test func nobodyAskingOrWorkingLeavesTheListsName() throws {
    let done = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .idle, title: "Old chat")
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: [done]) { vc, _ in
        let line = try #require(vc.view.subviews.compactMap { $0 as? AgentSummary }.first)
        #expect(!line.isHidden && texts(vc.view).contains("Projects"))
    }
}

/// A row's slot says what it is, and under the pointer gives its action, a moment later: a chat's ✕, reached from a little
/// around it. A project with nothing to fold keeps its icon.
@Test func theSlotGivesTheRowsActionUnderThePointer() throws {
    let chat = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Refactor")
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: [chat]) { _, o in
        let cell = try #require(o.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SidebarCell)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                        eventNumber: 0, trackingNumber: 0, userData: nil))
        func slot() -> NSPoint { cell.convert(NSPoint(x: 10, y: cell.bounds.midY), to: nil) }
        #expect(!cell.overAction(slot()))
        cell.setFrameSize(NSSize(width: 200, height: 28))
        cell.layoutSubtreeIfNeeded()
        cell.mouseEntered(with: enter)
        cell.showAction()   // what the moment after it does: the main queue doesn't turn under a test
        cell.layoutSubtreeIfNeeded()
        #expect(cell.overAction(slot()))
        cell.mouseExited(with: enter)
        #expect(!cell.overAction(slot()))
    }
}

/// What a row asks of you is timed; how long the rest has been at it would only take the name's room.
@Test func onlyWhoWaitsShowsATime() throws {
    func agent(_ status: AgentStatus, _ title: String) -> Session {
        var s = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: status, title: title, summary: "?")
        s.statusAt = Date() - 600
        return s
    }
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: [agent(.working, "Busy"), agent(.waiting, "Asks")]) { _, o in
        let listed = rows(of: o)
        #expect(listed[1].contains("Busy") && !listed[1].contains("10m"))
        #expect(listed[2].contains("Asks") && listed[2].contains("10m"))
    }
}

/// The capsule goes to who waits, so it counts only them: how many work is said beside it, in words.
@Test func theCapsuleCountsOnlyWhoWaits() throws {
    func agent(_ status: AgentStatus) -> Session {
        var s = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: status, title: "A")
        s.statusAt = Date() - 60
        return s
    }
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: [agent(.waiting), agent(.working), agent(.working)]) { vc, _ in
        #expect(texts(vc.view).contains("1 need you") && texts(vc.view).contains("2 working"))
    }
}

@Test func theSidebarActuallyDrawsItsRows() throws {
    let agent = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Allow rm?")
    try withSidebar(repos: [project], worktrees: [desk("w1", "feat/login")], sessions: [agent]) { vc, o in
        let v = vc.view
        // A window on screen makes its table's rows as it draws; this one is never shown, and cacheDisplay doesn't.
        for r in 0..<o.numberOfRows { _ = o.rowView(atRow: r, makeIfNecessary: true) }
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        // Text, icons and the status mark: the card's rounded corners alone make about 8 colors, its rows over 150.
        #expect(colors.count > 40, "the sidebar's rows weren't drawn: \(colors.count) distinct colors")
    }
}

/// Focus mode's panels wait in floaters over the editor area (they don't squeeze it when they come in) and go back to
/// their columns after.
@Test func focusModesPanelsFloatOverTheEditorAreaAndComeBack() throws {
    _ = testHome
    let app = AppModel(builtins: Builtins.all), main = MainWindowController(app: app)
    #expect(app.workbench.window === main)   // what acts on the window (open, show, focus) reaches it through the workbench
    // The split's view: over the theme's backdrop, under the bar and the floaters.
    let split = try #require(main.window?.contentView?.subviews.first { !($0 is Backdrop) })
    #expect(main.inspector.view.isDescendant(of: split))
    main.toggleFocusMode()
    #expect(!main.inspector.view.isDescendant(of: split))
    main.toggleInspectorPanel()   // ⌥⌘0 brings it in
    #expect(main.inspectorShown && !main.inspector.view.isDescendant(of: split))
    main.toggleFocusMode()
    #expect(main.inspector.view.isDescendant(of: split))
}
}

/// No open pull requests: the panel starts empty, its list hidden, and an Issues list comes later. It used to get no height.
@MainActor @Test func aListAfterAnEmptyStartTakesThePanel() throws {
    _ = testHome
    let vc = TasksViewController(app: AppModel(builtins: Builtins.all))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 800), styleMask: [.titled], backing: .buffered, defer: true)   // never shown
    window.contentViewController = vc
    vc.view.frame = NSRect(x: 0, y: 0, width: 250, height: 800)
    vc.view.layoutSubtreeIfNeeded()
    #expect(vc.split.isHidden)
    vc.showEmpty(nil)
    vc.view.layoutSubtreeIfNeeded()
    #expect(vc.split.frame.height > 700)
    #expect(try #require(vc.split.arrangedSubviews.first).frame.height > 400)
}

/// A chat's row closes it the way its tab does, with the tab's question.
@MainActor @Test func closingAChatFromItsRowGoesThroughItsTab() throws {
    let here = Repo(id: "r1", name: "Atlas", path: NSTemporaryDirectory())
    let chat = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Here")
    try withSidebar(repos: [here], worktrees: [own("w1")], sessions: [chat]) { vc, o in
        let menus = try (0..<o.numberOfRows).map { row -> [String] in
            let r = o.rect(ofRow: row), at = o.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
            let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try #require(o.menu(for: click))
            vc.menuNeedsUpdate(menu)
            return menu.items.map(\.title)
        }
        let items = try #require(menus.first { $0.contains("Hand Off to") })
        #expect(items.contains("Close Chat"))   // its tab's question comes with it
        #expect(!items.contains("Stop"))   // the word that ended it at once
    }
}

/// A terminal has no conversation: its tab offers nothing about one.
@MainActor @Test func aTerminalsTabOffersNothingAboutAConversation() throws {
    let shell = Session(worktreeId: "w1", cwd: "/", command: "zsh", agent: "shell", status: .idle, title: "zsh")
    let chat = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .idle, title: "Here")
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: [shell, chat]) { vc, _ in
        @MainActor func items(_ s: Session) -> [String] {
            let m = NSMenu()
            SessionTab.menu(vc.app, m, uri: TabURI.session(s.id), workspace: "w1") { _ in }
            return m.items.map(\.title)
        }
        #expect(items(shell) == ["Rename…", "Restart"])
        #expect(items(chat).contains("Hand Off to"))
    }
}

/// Right-clicking a part of the window sets how it looks: pointing at a choice shows it, leaving puts back what was
/// there, and a click keeps it.
@MainActor @Test func aPartOfTheWindowSetsItsLookFromItsMenu() throws {
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: []) { vc, _ in
        let app = vc.app, key = "workbench.sidebar.agentDetail"
        app.extensions.reload()   // the choices come from the settings extensions declare
        @MainActor func now() -> String? { app.settings.string(key) }
        let m = AgentSummary.viewMenu(app)
        #expect(m.items.first { $0.title == "When They Need You" }?.state == .on)
        let always = try #require(m.items.first { $0.title == "Always" })
        let never = try #require(m.items.first { $0.title == "Never" })
        m.delegate?.menu?(m, willHighlight: always)
        #expect(now() == "always")
        m.delegate?.menu?(m, willHighlight: never)
        #expect(now() == "never")
        m.delegate?.menu?(m, willHighlight: nil)
        #expect(now() == "needsYou")
        m.performActionForItem(at: m.index(of: always))
        #expect(now() == "always")
    }
}

/// The empty space under the rows offers the ways in and how the list looks.
@MainActor @Test func theSidebarsEmptySpaceSetsHowTheListLooks() throws {
    try withSidebar(repos: [project], worktrees: [own("w1")], sessions: []) { vc, o in
        vc.app.extensions.reload()
        let menu = try #require(o.menu)
        vc.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Project Order") && titles.contains("Row Height") && titles.contains("Sidebar Settings…"))
        #expect(menu.items.first { $0.title == "Project Order" }?.submenu?.items.map(\.title) == ["As You Arrange Them", "Agents First"])
    }
}

/// Back's and Forward's lists: every place that way once, nearest first, and never the one on screen.
@MainActor @Test func backListsThePlacesBehind() throws {
    let group = Worktree(id: "g", repoId: "r1", branch: "main", path: project.path, note: "Merge")
    try withSidebar(repos: [project], worktrees: [own("w1"), group], sessions: []) { vc, _ in
        let bench = vc.app.workbench
        for id in ["w1", "g", "w1"] { bench.history.visit(id) }
        bench.workspaceId = "w1"
        #expect(bench.places(-1).map(\.0) == [1])
        #expect(bench.places(1).isEmpty)
    }
}

@Test func aCommitsPageFollowsItsSite() {
    func page(_ forge: String) -> GitWebPages.Pages { .init(forge: forge, repo: "https://x/r", ci: "", pulls: "", issues: "") }
    #expect(page("github").commitURL("abc") == "https://x/r/commit/abc")
    #expect(page("gitlab").commitURL("abc") == "https://x/r/-/commit/abc")
    #expect(page("bitbucket").commitURL("abc") == "https://x/r/commits/abc")
}
