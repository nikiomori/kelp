import AppKit
import Core
import TestSupport
import Testing

@testable import BuiltinAgents
@testable import KelpKit

private let places: [(id: String, name: String, repo: String?)] = [
    ("a", "kelp", nil), ("b", "site", nil), ("c", "docs", nil)
]

private func session(
    _ place: String, _ status: AgentStatus, unread: Bool = false, summary: String = "", at: TimeInterval = 0
) -> Session {
    var s = Session(cwd: "/", command: "x", agent: "claude", status: status, unread: unread, summary: summary)
    s.worktreeId = place
    s.statusAt = Date(timeIntervalSince1970: at)
    return s
}

@MainActor @Test func theStripHasAWorkspaceOnceWithItsLoudestState() {
    let items = StripModel.items(
        [
            session("a", .working), session("a", .waiting, summary: "Allow npm test?"),
            session("c", .done, unread: true)
        ], workspaces: places)
    #expect(items.map(\.name) == ["kelp", "docs"])   // in the workspaces' order, not by state: nothing changes places
    #expect(items.first?.cell == .asks)
    #expect(items.first?.words == "Allow npm test?")
}

@MainActor @Test func theStripSaysSomethingForAQuestionWithoutWords() {
    #expect(StripModel.items([session("a", .waiting)], workspaces: places).first?.words == "Needs your input")
}

@MainActor @Test func twoQuestionsInAWorkspaceShowTheOldestAndListTheOther() {
    var old = session("a", .waiting, summary: "Old", at: 1), new = session("a", .waiting, summary: "New", at: 2)
    old.title = "Login"
    new.title = "Docs"
    let item = StripModel.items([new, old], workspaces: places).first
    #expect(item?.words == "Old")
    #expect(item?.session == old.id)
    #expect(item?.agents == ["Old · Login", "Needs your input · Docs"])
}

/// One agent finished while another (or one it started) still works: the project isn't done yet, and the tip says who is.
@MainActor @Test func aProjectIsDoneOnlyOnceNothingInItWorks() {
    var done = session("a", .done, unread: true, summary: "Release notes updated", at: 5),
        busy = session("a", .working, at: 1)
    done.title = "Notes"
    busy.title = "Dev release"
    let item = StripModel.items([done, busy], workspaces: places).first
    #expect(item?.cell == .working)
    #expect(item?.words == "Working")
    #expect(item?.agents == ["Working · Dev release", "Done · Notes"])
    #expect(StripModel.items([done], workspaces: places).first?.cell == .done)
    #expect(StripTip.lines((1...7).map { "\($0)" }) == "1\n2\n3\n4\n5\nand 2 more")
}

@MainActor @Test func onlyTheOldestQuestionOpensIntoAPill() {
    let items = StripModel.items(
        [session("a", .error, at: 0), session("b", .waiting, at: 5), session("c", .waiting, at: 3)], workspaces: places)
    #expect(StripModel.opened(items) == "c")   // a question before a failure, the oldest first
    #expect(
        StripModel.opened(StripModel.items([session("a", .working), session("b", .error)], workspaces: places)) == "b")
    #expect(
        StripModel.opened(
            StripModel.items([session("a", .working), session("c", .done, unread: true)], workspaces: places)) == "c")
    #expect(StripModel.opened(StripModel.items([session("b", .working)], workspaces: places)) == "b")   // the strip always says something
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
    func shows(_ items: [StripItem], _ comes: String?) -> Bool {
        StripModel.shows(items, mode: "needed", comesFor: comes, front: false)
    }
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
    strip.front = { false }   // behind another app, whatever another test brings forward
    strip.animates = false
    strip.start()
    #expect(!strip.isShowing)
    rig.app.sessions = [session(rig.workspace.id, .waiting, summary: "Allow npm test?")]
    #expect(try await waitFor(5) { strip.isShowing })
    #expect(strip.isShowing)
    let f = try #require(strip.frame), area = try #require(NSScreen.main?.visibleFrame)
    #expect(f.height == StripButton.stripHeight)
    #expect(f.width > 100)   // the pill's words are in it
    #expect(abs(f.midX - area.midX) < 1)
    let asked = try #require(rig.app.sessions.first)
    strip.hide(until: Date().addingTimeInterval(3600))   // a call: out of the way, whatever comes
    #expect(strip.hiddenUntil != nil)
    strip.hide(until: nil)
    #expect(try await waitFor(5) { (strip.isShowing && strip.frame?.height == StripButton.stripHeight) })
    strip.later(asked.id)   // put off: it stops calling
    #expect(try await waitFor(5) { !(strip.isShowing) })
    #expect(!strip.isShowing)
    var again = asked
    again.statusAt = Date()   // the agent asks something else
    rig.app.sessions = [again]
    #expect(try await waitFor(5) { strip.isShowing })
    #expect(strip.isShowing)
    rig.app.sessions = []
    #expect(try await waitFor(5) { !(strip.isShowing) })
    #expect(!strip.isShowing)
}

@MainActor @Test func thePillSaysWhatACommandIsAndTheCardKeepsItWhole() {
    #expect(
        StripModel.brief("Allow SP=/private/tmp/x FOO=1 swift build --product KelpApp?")
            == "Allow swift build --product KelpApp?")
    #expect(StripModel.brief("Allow npm test?") == "Allow npm test?")
    #expect(StripModel.brief("Allow A=1?") == "Allow A=1?")   // nothing else to say
    #expect(StripModel.brief("Which layout, a=1 or b=2?") == "Which layout, a=1 or b=2?")   // a question, not a command
}

private let screenArea = NSRect(x: 0, y: 0, width: 2000, height: 1200)

@MainActor @Test func theStripStandsAboveTheDockUntilItIsPut() {
    let f = StripModel.frame(NSSize(width: 200, height: 40), in: screenArea, at: .bottom)
    #expect(f.midX == 1000 && f.minY == 8)
}

@MainActor @Test func aStripLetGoGoesToTheNearestCorner() {
    func near(_ x: CGFloat, _ y: CGFloat) -> StripCorner {
        StripModel.corner(nearest: NSRect(x: x, y: y, width: 120, height: 40), in: screenArea)
    }
    #expect(near(40, 900) == .topLeft)
    #expect(near(1800, 1100) == .topRight)
    #expect(near(100, 200) == .bottomLeft)
    #expect(near(1700, 30) == .bottomRight)
    #expect(near(950, 20) == .bottom)
    #expect(near(900, 1150) == .top)
}

@MainActor @Test func aStripInACornerGrowsAwayFromIt() {
    let tile = StripModel.frame(NSSize(width: 40, height: 40), in: screenArea, at: .topRight)
    let pill = StripModel.frame(NSSize(width: 300, height: 40), in: screenArea, at: .topRight)
    #expect(tile.maxX == pill.maxX && tile.maxY == pill.maxY && pill.maxX == 1992 && pill.maxY == 1192)
    let left = StripModel.frame(NSSize(width: 300, height: 40), in: screenArea, at: .bottomLeft)
    #expect(left.minX == 8 && left.minY == 8)
}

@MainActor @Test func aClickAnywhereOnATileReachesItsButton() {
    let button = StripButton(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
    let rig = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
    rig.addSubview(button)
    for x in [6, 16, 60, 150] as [CGFloat] { #expect(rig.hitTest(NSPoint(x: x, y: 16)) === button) }   // the icon, the mark, the words
    #expect(rig.hitTest(NSPoint(x: 260, y: 16)) !== button)
    #expect(button.layer?.masksToBounds == false)   // the mark stands past the round corner of a closed tile
}

@MainActor @Test func everyStateHasWordsForThePillAndTheTip() {
    var working = session("a", .working)
    working.title = "Fix the login race"
    #expect(StripModel.items([working], workspaces: places).first?.words == "Working")   // the pill says it works; the tip, at what
    #expect(StripModel.items([working], workspaces: places).first?.agents == ["Working · Fix the login race"])
    #expect(StripModel.items([working, session("a", .working)], workspaces: places).first?.words == "Working: 2")
    #expect(StripModel.items([session("a", .working)], workspaces: places).first?.words == "Working")
    #expect(
        StripModel.items([session("a", .done, unread: true, summary: "Release notes updated")], workspaces: places)
            .first?.words == "Done: Release notes updated")
}

@MainActor @Test func finishedWorkStaysAWhileOnceReadInKelp() {
    let now = Date()
    let read = session("a", .done, summary: "Release notes updated", at: now.timeIntervalSince1970 - 120)
    #expect(StripModel.items([read], workspaces: places, now: now).first?.cell == .done)   // read two minutes ago: still there
    let old = session("a", .done, at: now.timeIntervalSince1970 - StripModel.recent - 1)
    #expect(StripModel.items([old], workspaces: places, now: now).isEmpty)
    #expect(
        StripModel.items([session("a", .idle, at: now.timeIntervalSince1970)], workspaces: places, now: now).isEmpty)
}

/// A summary's Markdown link shows its words, not its brackets, and stays a link.
@MainActor @Test func cardSummaryShowsLinksByTheirWords() {
    let s = CardView.linked("Plan ready: [Kelp plan](https://claude.ai/artifact/x) *as is*")
    #expect(String(s.characters) == "Plan ready: Kelp plan as is")
    #expect(s.runs.compactMap(\.link) == [URL(string: "https://claude.ai/artifact/x")])
    #expect(String(CardView.linked("a [b").characters) == "a [b")
}

/// Allow answers the question the card shows: a second one asked meanwhile isn't approved unseen.
@MainActor @Test func theCardAnswersTheQuestionItShows() {
    let app = AppModel()
    var s = session("a", .waiting, summary: "Allow npm test?")
    app.sessions = [s]
    let card = StripCard(s, app: app, fullScreen: false) { _ in }
    s.summary = "Allow rm -rf build?"
    app.sessions = [s]
    #expect(card.question == "Allow npm test?")
}

/// News under the pointer doesn't move the tiles: the pill stays where it was until the pointer leaves.
@MainActor @Test func theStripStandsStillUnderThePointer() async throws {
    let rig = try await AppRig()
    _ = NSApplication.shared
    let strip = AgentStrip(app: rig.app)
    strip.front = { false }   // behind another app, whatever another test brings forward
    strip.animates = false
    var other = rig.workspace
    other.id = "other-workspace"
    rig.app.worktrees.append(other)
    strip.start()
    rig.app.sessions = [session(rig.workspace.id, .waiting, summary: "Allow npm test?", at: 5)]
    #expect(try await waitFor(5) { strip.isShowing })
    let before = try #require(strip.frame)
    strip.hoverStrip(true)
    // An older question elsewhere: it would open into the pill.
    rig.app.sessions.append(session(other.id, .waiting, summary: "Which port, 3000 or 8080?", at: 1))
    try await Task.sleep(for: .milliseconds(300))
    #expect(strip.frame == before)
    strip.hoverStrip(false)
    #expect(try await waitFor(5) { strip.frame != before })
}

/// The card answers what the agent waits on: a permission, one of its question's answers, or a line at its prompt.
@MainActor @Test func theCardAnswersWhatTheAgentWaitsOn() {
    var choosing = session("a", .waiting, summary: "Which layout?")
    choosing.choices = ["Grid", "List"]
    #expect(StripCardKind.of(session("a", .waiting, summary: "Allow npm test?")) == .permission)
    #expect(StripCardKind.of(choosing) == .choices(["Grid", "List"]))
    #expect(StripCardKind.of(session("a", .error, summary: "Build failed")) == .reply)
    #expect(StripCardKind.of(session("a", .done, summary: "Release notes updated")) == .reply)
    #expect(StripCardKind.of(session("a", .waiting, summary: "Which layout?")) == .look)   // a menu it can't answer
}

@MainActor @Test func aPermissionShowsWhatItAllowsWhole() {
    #expect(
        StripModel.permission("Allow SP=/tmp/x swift build?") == ("Allow this command?", "SP=/tmp/x swift build"))
    #expect(StripModel.permission("Allow editing Sources/App.swift?") == ("Allow editing?", "Sources/App.swift"))
    #expect(StripModel.permission("Allow searching the web for “swift 6”?") == ("Allow a web search?", "swift 6"))
    #expect(StripModel.permission("Allow github: create_issue?") == ("Allow github: create_issue?", nil))
    #expect(StripModel.permission("Allow Bash?") == ("Allow Bash?", nil))
}

/// A tile's menu starts with its own agent: what it says, then what can be done to it from here; the strip's own below.
@MainActor @Test func aTilesMenuIsAboutItsAgentFirst() async throws {
    let rig = try await AppRig()
    let failed = session(rig.workspace.id, .error, summary: "Build failed")
    rig.app.sessions = [failed]
    let strip = AgentStrip(app: rig.app)
    let item = try #require(
        StripModel.items(rig.app.sessions, workspaces: [(rig.workspace.id, "kelp", nil)]).first)
    let titles = strip.menu(for: item).items.map(\.title)
    #expect(titles.prefix(5) == ["kelp — Build failed", "Open in Kelp", "Continue", "Later", "Mute Notifications"])
    #expect(titles.contains("Hide Strip") && titles.contains("Strip Settings…"))
}

/// A thrown strip flies on the way it went; a slow drag stays where it was let go.
@MainActor @Test func aThrowLandsWhereItWasHeading() {
    let frame = NSRect(x: 900, y: 8, width: 200, height: 40)
    #expect(StripModel.projected(frame, velocity: CGVector(dx: 100, dy: 0)) == frame)
    let thrown = StripModel.projected(frame, velocity: CGVector(dx: -3000, dy: 3000))
    #expect(thrown.minX < frame.minX && thrown.minY > frame.minY)
    #expect(StripModel.corner(nearest: thrown, in: screenArea) == .topLeft || thrown.minX < 0)
}

/// Swipes step along the six places, behind a side from its corner, and back out of it.
@MainActor @Test func aSwipeStepsToTheNextPlace() {
    #expect(StripModel.swipe(dx: 60, dy: 3, natural: true) == .right)
    #expect(StripModel.swipe(dx: 60, dy: 3, natural: false) == .left)
    #expect(StripModel.swipe(dx: 10, dy: 5, natural: true) == nil)
    #expect(StripModel.swipe(dx: 2, dy: -70, natural: true) == .up)
    #expect(StripModel.swiped(from: .bottom, edge: nil, .right) == .corner(.bottomRight))
    #expect(StripModel.swiped(from: .bottomRight, edge: nil, .right) == .edge(.right))
    #expect(StripModel.swiped(from: .bottomLeft, edge: nil, .up) == .corner(.topLeft))
    #expect(StripModel.swiped(from: .top, edge: nil, .up) == nil)
    #expect(StripModel.swiped(from: .bottomLeft, edge: .left, .right) == .corner(.bottomLeft))
    #expect(StripModel.swiped(from: .bottomLeft, edge: .left, .left) == nil)
}
