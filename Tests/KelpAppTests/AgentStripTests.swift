import AppKit
import Core
import Testing
@testable import KelpKit

private let places: [(id: String, name: String, repo: String?)] = [("a", "kelp", nil), ("b", "site", nil), ("c", "docs", nil)]

private func session(_ place: String, _ status: AgentStatus, unread: Bool = false, summary: String = "", at: TimeInterval = 0) -> Session {
    var s = Session(cwd: "/", command: "x", agent: "claude", status: status, unread: unread, summary: summary)
    s.worktreeId = place
    s.statusAt = Date(timeIntervalSince1970: at)
    return s
}

@MainActor @Test func theStripHasAWorkspaceOnceWithItsLoudestState() {
    let items = StripModel.items([session("a", .working), session("a", .waiting, summary: "Allow npm test?"), session("c", .done, unread: true)], workspaces: places)
    #expect(items.map(\.name) == ["kelp", "docs"])   // in the workspaces' order, not by state: nothing changes places
    #expect(items.first?.cell == .asks)
    #expect(items.first?.words == "Allow npm test?")
}

@MainActor @Test func theStripSaysSomethingForAQuestionWithoutWords() {
    #expect(StripModel.items([session("a", .waiting)], workspaces: places).first?.words == "Needs your input")
}

@MainActor @Test func twoQuestionsInAWorkspaceShowTheOldestAndCount() {
    let old = session("a", .waiting, summary: "Old", at: 1), new = session("a", .waiting, summary: "New", at: 2)
    let item = StripModel.items([new, old], workspaces: places).first
    #expect(item?.words == "Old")
    #expect(item?.session == old.id)
    #expect(item?.count == 2)
}

@MainActor @Test func onlyTheOldestQuestionOpensIntoAPill() {
    let items = StripModel.items([session("a", .error, at: 0), session("b", .waiting, at: 5), session("c", .waiting, at: 3)], workspaces: places)
    #expect(StripModel.opened(items) == "c")   // a question before a failure, the oldest first
    #expect(StripModel.opened(StripModel.items([session("a", .working), session("b", .error)], workspaces: places)) == "b")
    #expect(StripModel.opened(StripModel.items([session("a", .working), session("c", .done, unread: true)], workspaces: places)) == nil)
}

@MainActor @Test func theStripComesWhenKelpIsBehindAndSomethingWantsYou() {
    let working = StripModel.items([session("a", .working)], workspaces: places)
    let asking = StripModel.items([session("a", .waiting)], workspaces: places)
    #expect(StripModel.shows(asking, mode: "needed", front: false))
    #expect(StripModel.shows(asking, mode: nil, front: false))   // the default
    #expect(!StripModel.shows(asking, mode: "needed", front: true))
    #expect(!StripModel.shows(asking, mode: "off", front: false))
    #expect(!StripModel.shows(working, mode: "needed", front: false))
    #expect(StripModel.shows(working, mode: "always", front: false))
    #expect(!StripModel.shows([], mode: "always", front: false))
}

@MainActor @Test func theCardsAllowWaitsBeforeItTakesAClick() {
    #expect(StripCard.armAfter == .milliseconds(600))
}

@MainActor @Test func theStripSitsAtTheFootOfTheScreenAndGoesWithTheQuestion() async throws {
    let rig = try await AppRig()
    _ = NSApplication.shared
    let strip = AgentStrip(app: rig.app)
    strip.start()
    #expect(!strip.isShowing)
    rig.app.sessions = [session(rig.workspace.id, .waiting, summary: "Allow npm test?")]
    for _ in 0..<100 where !strip.isShowing { try await Task.sleep(for: .milliseconds(20)) }
    #expect(strip.isShowing)
    let f = try #require(strip.frame), area = try #require(NSScreen.main?.visibleFrame)
    #expect(f.height == StripButton.stripHeight)
    #expect(f.width > 100)   // the pill's words are in it
    #expect(abs(f.midX - area.midX) < 1)
    rig.app.sessions = []
    for _ in 0..<100 where strip.isShowing { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!strip.isShowing)
}
