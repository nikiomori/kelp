import AppKit
import Foundation
import Testing
import Core
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
        #expect(r.flatMap { $0 }.contains("Fix login bug"))
    }
}

@Test func aRemoteProjectNamedLikeAnotherSaysItsMachineAndItsRowRenamesTheProject() throws {
    let folder = Paths.root.appendingPathComponent("remote/beet/infra")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONEncoder().encode(RemoteHost(host: "beet", path: "/srv/infra")).write(to: folder.appendingPathComponent(RemoteHost.marker))
    let here = Repo(id: "r1", name: "infra", path: "/tmp/kelp-screen-infra"), there = Repo(id: "r2", name: "infra", path: folder.path)
    try withSidebar(repos: [here, there], worktrees: [], sessions: []) { vc, o in
        let names = rows(of: o).flatMap { $0 }
        #expect(names.contains("infra") && names.contains("infra · beet"))   // this Mac's stays bare
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

@Test func aLongNameAndABackgroundCommandBothStayReadable() throws {
    var agent = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working,
                        title: "Структура и плотность левой панели")
    agent.background = ["npm run test -- --watch --coverage"]
    agent.awaiting = agent.background?.first
    try withSidebar(repos: [project], worktrees: [desk("w1", "main")], sessions: [agent]) { _, o in
        let cell = try #require(o.view(atColumn: 0, row: 1, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let chip = try #require(all(cell).compactMap { $0 as? Chip }.first { !$0.isHidden && $0.label.stringValue.hasPrefix("npm") })
        let name = try #require(all(cell).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Структура") })
        #expect(chip.frame.width >= 40 && chip.frame.width <= 72)   // shortened, not crushed into letters
        #expect(name.frame.width >= 60)                               // and the name still reads
    }
}

@Test func aShortBackgroundCommandStaysOnOneLine() throws {
    var agent = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Отслеживание лимитов")
    agent.background = ["p/cl"]
    agent.awaiting = "p/cl"
    try withSidebar(repos: [project], worktrees: [desk("w1", "main")], sessions: [agent]) { _, o in
        let cell = try #require(o.view(atColumn: 0, row: 1, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let chip = try #require(all(cell).compactMap { $0 as? Chip }.first { !$0.isHidden && $0.label.stringValue == "p/cl" })
        let label = try #require(chip.label.cell)
        func tall(_ w: CGFloat) -> CGFloat { label.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 100)).height }
        #expect(tall(chip.label.frame.width) == tall(500), "the chip wrapped at \(chip.label.frame.width) pt")   // "p/" over "cl" was 2 lines
        #expect(chip.frame.height <= cell.frame.height)
    }
}

@Test func aProjectsRowFindsItsWorkspaceWhenThatArrivesAfterIt() throws {
    try withSidebar(repos: [project], worktrees: [], sessions: []) { vc, _ in
        vc.app.worktrees = [desk("w1", "main")]   // the daemon's projects came first, their workspaces a moment later
        vc.refresh()
        #expect(vc.workspaceNode("w1") != nil)   // else the workspace on screen is never picked in the list
    }
}

@Test func anEndedAgentAndAPlainTerminalAreNotListed() throws {
    let ended = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .exited, title: "Old chat")
    let shell = Session(worktreeId: "w1", cwd: "/", command: "zsh", agent: "shell", status: .idle, title: "zsh")
    try withSidebar(repos: [project], worktrees: [desk("w1", "main")], sessions: [ended, shell]) { _, o in
        let all = rows(of: o).flatMap { $0 }
        #expect(!all.contains("Old chat") && !all.contains("zsh"))
        #expect(o.numberOfRows == 1)                            // the project, standing for its one workspace: nothing else
    }
}

@Test func withNoProjectsTheSidebarShowsItsEmptyStateNotAnEmptyList() throws {
    try withSidebar(repos: [], worktrees: [], sessions: []) { vc, o in
        #expect(o.numberOfRows == 0)
        #expect(texts(vc.view).contains { $0.localizedCaseInsensitiveContains("project") })   // it says what to do
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
    let done = (1...6).map { i in
        var s = Session(worktreeId: "w\(i)", cwd: "/", command: "claude", agent: "claude", status: .done, title: "Report \(i)")
        s.statusAt = Date() - 60
        s.unread = true
        return s
    }
    try withSidebar(repos: [project], worktrees: (1...6).map { desk("w\($0)", "b\($0)") }, sessions: done) { vc, _ in
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

@MainActor private func textFields(_ v: NSView) -> [NSTextField] {
    if let t = v as? NSTextField { return [t] }
    return v.subviews.flatMap(textFields)
}

@Test func theLineOverTheListCountsWhatAskedAndWhatFinished() throws {
    func agent(_ w: String, _ status: AgentStatus, _ title: String) -> Session {
        var s = Session(worktreeId: w, cwd: "/", command: "claude", agent: "claude", status: status, title: title, summary: "Question")
        s.statusAt = Date() - 60
        s.unread = true
        return s
    }
    let sessions = [agent("w1", .waiting, "Ask"), agent("w2", .done, "Report A"), agent("w3", .done, "Report B")]
    try withSidebar(repos: [project], worktrees: (1...3).map { desk("w\($0)", "b\($0)") }, sessions: sessions) { vc, o in
        #expect(texts(vc.view).contains("3 need you"))   // a question and two reports nobody has read
        let listed: [String] = rows(of: o).flatMap { $0 }
        #expect(listed.contains("Report A") && listed.contains("Report B"))   // each on its own row
    }
}

@Test func asTabsEachAgentThatNeedsYouHasARowOverTheListAndPastSixTheLastSaysHowManyMore() throws {
    let sessions = (1...8).map { i in
        var s = Session(worktreeId: "w\(i)", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Ask \(i)", summary: "Question")
        s.statusAt = Date() - 60
        return s
    }
    let desks = (1...8).map { desk("w\($0)", "b\($0)") }
    // Checked after the closure: its statements are type-checked with the call, and Xcode 26.6 ran out of budget there.
    var shown: [String] = [], all: [String] = [], listed: [String] = []
    try withSidebar(repos: [project], worktrees: desks, sessions: sessions, settings: ["workbench.sidebar.needsYou": .string("tabs")]) { vc, o in
        let zone = try #require(vc.view.subviews.compactMap { $0 as? NeedsYouZone }.first)
        shown = texts(zone)
        all = texts(vc.view)
        listed = rows(of: o).flatMap { $0 }
    }
    #expect(shown.contains("Needs You") && shown.contains("8"))
    #expect(shown.filter { $0.hasPrefix("Ask ") }.count == 5 && shown.contains("3 more"))
    #expect(!all.contains("8 need you"))   // no capsule beside the zone
    #expect(listed.filter { $0 == "Ask 1" }.count == 1)   // the list keeps its own row too
}

@Test func automaticCountsWhileWhoNeedsYouIsInViewAndListsThemOnceOneIsNot() throws {
    func asking(_ w: String) -> Session {
        var s = Session(worktreeId: w, cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Ask " + w, summary: "Question")
        s.statusAt = Date() - 60
        return s
    }
    let many = (1...40).map { desk("w\($0)", "b\($0)") }
    try withSidebar(repos: [project], worktrees: many, sessions: [asking("w1")], settings: ["workbench.sidebar.needsYou": .string("automatic")]) { vc, _ in
        #expect(vc.view.subviews.contains { $0 is AgentSummary })   // its row is on screen: the count will do
        vc.app.sessions = [asking("w1"), asking("w40")]   // the 40th workspace is far below the window's bottom
        vc.refresh()
        #expect(vc.view.subviews.contains { $0 is NeedsYouZone })
        #expect(!vc.view.subviews.contains { $0 is AgentSummary })
    }
}

@Test func nobodyAskingOrWorkingLeavesNoEmptyBandOverTheList() throws {
    let done = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .idle, title: "Old chat")
    try withSidebar(repos: [project], worktrees: [desk("w1", "main")], sessions: [done]) { vc, _ in
        let line = try #require(vc.view.subviews.compactMap { $0 as? AgentSummary }.first)
        #expect(line.isHidden)
    }
}

@Test func theSidebarActuallyDrawsItsRows() throws {
    let agent = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Allow rm?")
    try withSidebar(repos: [project], worktrees: [desk("w1", "feat/login")], sessions: [agent]) { vc, _ in
        let v = vc.view
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        #expect(colors.count > 8, "the sidebar rendered as a flat fill: \(colors.count) distinct colors")   // text, icons and the status mark are not one color
    }
}

/// Focus mode's panels wait in floaters over the editor area (they don't squeeze it when they come in) and go back to
/// their columns after.
@Test func focusModesPanelsFloatOverTheEditorAreaAndComeBack() throws {
    _ = testHome
    let app = AppModel(builtins: Builtins.all), main = MainWindowController(app: app)
    #expect(app.workbench.window === main)   // what acts on the window (open, show, focus) reaches it through the workbench
    let split = try #require(main.window?.contentView?.subviews.first)   // the split's view; the bar and the floaters lie over it
    #expect(main.inspector.view.isDescendant(of: split))
    main.toggleFocusMode()
    #expect(!main.inspector.view.isDescendant(of: split))
    main.toggleInspectorPanel()   // ⌥⌘0 brings it in
    #expect(main.inspectorShown && !main.inspector.view.isDescendant(of: split))
    main.toggleFocusMode()
    #expect(main.inspector.view.isDescendant(of: split))
}
}
