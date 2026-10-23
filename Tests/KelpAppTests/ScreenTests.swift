import AppKit
import Foundation
import Testing
import Core
@testable import KelpApp

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

@MainActor private func withSidebar(repos: [Repo], worktrees: [Worktree], sessions: [Session], _ check: (SidebarController, NSOutlineView) throws -> Void) throws {
    _ = testHome
    let m = AppModel()
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

@Test func anEndedAgentAndAPlainTerminalAreNotListed() throws {
    let ended = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .exited, title: "Old chat")
    let shell = Session(worktreeId: "w1", cwd: "/", command: "zsh", agent: "shell", status: .idle, title: "zsh")
    try withSidebar(repos: [project], worktrees: [desk("w1", "main")], sessions: [ended, shell]) { _, o in
        let all = rows(of: o).flatMap { $0 }
        #expect(!all.contains("Old chat") && !all.contains("zsh"))
        #expect(o.numberOfRows == 2)                            // the project and its workspace, nothing else
    }
}

@Test func withNoProjectsTheSidebarShowsItsEmptyStateNotAnEmptyList() throws {
    try withSidebar(repos: [], worktrees: [], sessions: []) { vc, o in
        #expect(o.numberOfRows == 0)
        #expect(texts(vc.view).contains { $0.localizedCaseInsensitiveContains("project") })   // it says what to do
    }
}

@Test func theAgentWaitingForYouIsPulledToTheTopWhenThereAreSeveralWorkspaces() throws {
    var ask = Session(worktreeId: "w3", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "Allow rm?", summary: "Needs permission")
    ask.statusAt = Date().addingTimeInterval(-10)   // past the few seconds an agent is held back from Needs You
    try withSidebar(repos: [project], worktrees: [desk("w1", "a"), desk("w2", "b"), desk("w3", "c")], sessions: [ask]) { _, o in
        let r = rows(of: o)
        #expect(r.first?.contains { $0.localizedCaseInsensitiveContains("needs you") } == true)   // the section comes first
        let asks = r.flatMap { $0 }.filter { $0 == "Allow rm?" }
        #expect(asks.count == 2)                                                                      // under the section, and under its workspace
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
    let app = AppModel(), main = MainWindowController(app: app)
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
