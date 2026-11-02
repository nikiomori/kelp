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
    func shows(_ items: [StripItem], _ mode: String?, for comes: String? = nil, front: Bool = false) -> Bool {
        StripModel.shows(items, mode: mode, comesFor: comes, front: front)
    }
    #expect(shows(asking, "needed"))
    #expect(shows(working, nil))   // the default: it's where you see them working
    #expect(!shows(asking, "needed", front: true))
    #expect(!shows(asking, "off"))
    #expect(!shows(working, "needed"))
    #expect(shows(working, "always"))
    #expect(!shows([], "always"))
}

@MainActor @Test func whatBringsTheStripUpIsYourChoice() {
    let failed = StripModel.items([session("a", .error)], workspaces: places)
    let done = StripModel.items([session("a", .done, unread: true)], workspaces: places)
    let asking = StripModel.items([session("a", .waiting)], workspaces: places)
    func shows(_ items: [StripItem], _ comes: String?) -> Bool { StripModel.shows(items, mode: "needed", comesFor: comes, front: false) }
    #expect(!shows(failed, "questions"))
    #expect(shows(asking, "questions"))
    #expect(shows(failed, nil) && !shows(done, nil))   // by default a finished agent doesn't hold the strip up all day
    #expect(shows(done, "all"))
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
    let asked = try #require(rig.app.sessions.first)
    strip.hide(until: Date().addingTimeInterval(3600))   // a call: out of the way, whatever comes
    #expect(strip.hiddenUntil != nil)
    strip.hide(until: nil)
    for _ in 0..<100 where !(strip.isShowing && strip.frame?.height == StripButton.stripHeight) { try await Task.sleep(for: .milliseconds(20)) }
    strip.later(asked.id)   // put off: it stops calling
    for _ in 0..<100 where strip.isShowing { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!strip.isShowing)
    var again = asked
    again.statusAt = Date()   // the agent asks something else
    rig.app.sessions = [again]
    for _ in 0..<100 where !strip.isShowing { try await Task.sleep(for: .milliseconds(20)) }
    #expect(strip.isShowing)
    rig.app.sessions = []
    for _ in 0..<100 where strip.isShowing { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!strip.isShowing)
}

@MainActor @Test func thePillSaysWhatACommandIsAndTheCardKeepsItWhole() {
    #expect(StripModel.brief("Allow SP=/private/tmp/x FOO=1 swift build --product KelpApp?") == "Allow swift build --product KelpApp?")
    #expect(StripModel.brief("Allow npm test?") == "Allow npm test?")
    #expect(StripModel.brief("Allow A=1?") == "Allow A=1?")   // nothing else to say
    #expect(StripModel.brief("Which layout, a=1 or b=2?") == "Which layout, a=1 or b=2?")   // a question, not a command
}

private let screenArea = NSRect(x: 0, y: 0, width: 2000, height: 1200)

@MainActor @Test func theStripStandsAboveTheDockUntilItIsPut() {
    let f = StripModel.frame(NSSize(width: 200, height: 40), in: screenArea, spot: nil)
    #expect(f.midX == 1000 && f.minY == 8)
}

@MainActor @Test func aStripPutSomewhereStaysThereAndWidensAroundIt() throws {
    let at = NSRect(x: 300, y: 600, width: 100, height: 40)
    let spot = try #require(StripModel.spot(of: at, in: screenArea, display: 1))
    #expect(StripModel.frame(at.size, in: screenArea, spot: spot) == at)
    let wide = StripModel.frame(NSSize(width: 300, height: 40), in: screenArea, spot: spot)   // a pill opened
    #expect(wide.midX == at.midX && wide.minY == at.minY)
}

@MainActor @Test func aStripLetGoNearItsPlaceGoesBackAboveTheDock() {
    #expect(StripModel.spot(of: NSRect(x: 920, y: 30, width: 200, height: 40), in: screenArea, display: 1) == nil)
    #expect(StripModel.spot(of: NSRect(x: 600, y: 30, width: 200, height: 40), in: screenArea, display: 1) != nil)
}

@MainActor @Test func aStripIsAlwaysWholeOnTheScreen() {
    let corner = StripSpot(x: 0.99, y: 0.99, display: nil)
    let f = StripModel.frame(NSSize(width: 400, height: 40), in: screenArea, spot: corner)
    #expect(screenArea.contains(f))
    let smaller = NSRect(x: 0, y: 0, width: 1000, height: 700)   // put on a bigger screen, seen on a smaller one
    #expect(smaller.contains(StripModel.frame(NSSize(width: 400, height: 40), in: smaller, spot: corner)))
}

@MainActor @Test func aDroppedStripKeepsItsPlaceAndAPillOpensAroundIt() async throws {
    let rig = try await AppRig()
    _ = NSApplication.shared
    let strip = AgentStrip(app: rig.app)
    defer { StripSpot.save(nil) }
    strip.start()
    rig.app.sessions = [session(rig.workspace.id, .working)]
    for _ in 0..<100 where !strip.isShowing { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(400))
    let area = try #require(NSScreen.main?.visibleFrame)
    let target = NSPoint(x: area.minX + 200, y: area.minY + 300)
    strip.panelForTests?.setFrameOrigin(target)
    strip.dropped()
    try await Task.sleep(for: .milliseconds(500))
    let tile = try #require(strip.frame)
    #expect(abs(tile.minX - target.x) < 1 && abs(tile.minY - target.y) < 1)
    #expect(StripSpot.load() != nil)
    rig.app.sessions = [session(rig.workspace.id, .waiting, summary: "Allow npm test?")]
    try await Task.sleep(for: .milliseconds(700))
    let pill = try #require(strip.frame)
    #expect(pill.width > tile.width)
    #expect(abs(pill.midX - tile.midX) < 1 && abs(pill.minY - tile.minY) < 1)
}
