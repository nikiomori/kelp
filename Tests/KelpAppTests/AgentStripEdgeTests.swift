import AppKit
import Core
import TestSupport
import Testing

@testable import BuiltinAgents
@testable import KelpKit

private let area = NSRect(x: 0, y: 0, width: 2000, height: 1200)

private func item(_ cell: DockFace.Cell, _ session: String, at: TimeInterval = 0) -> StripItem {
    StripItem(
        workspace: session, name: session, cell: cell, session: session, words: "Allow npm test?",
        since: Date(timeIntervalSince1970: at))
}

@MainActor @Test func aStripLetGoPastASideHidesBehindIt() {
    func edge(_ x: CGFloat) -> StripEdge? {
        StripModel.edge(dropped: NSRect(x: x, y: 300, width: 120, height: 40), in: area)
    }
    #expect(edge(1930) == .right)   // 50 of 120 past: more than a third
    #expect(edge(1900) == nil)   // 20 past: it goes to a corner
    #expect(edge(-50) == .left)
    #expect(edge(8) == nil)
}

@MainActor @Test func aSideWithAnotherScreenPastItIsNoEdge() {
    let other = NSRect(x: 2000, y: 0, width: 1600, height: 1000)
    #expect(!StripModel.outer(.right, of: area, among: [other]))
    #expect(StripModel.outer(.left, of: area, among: [other]))
    #expect(StripModel.outer(.right, of: area, among: [NSRect(x: 2000, y: 1300, width: 800, height: 600)]))   // above it, not beside
}

@MainActor @Test func aHiddenStripLeavesItsSliverAndComesAllOut() {
    let size = NSSize(width: 140, height: 40)
    let hid = StripModel.tucked(size, in: area, edge: .right, y: 300, out: false)
    #expect(hid.minX == 2000 - StripModel.sliver && hid.minY == 300)
    let out = StripModel.tucked(size, in: area, edge: .right, y: 300, out: true)
    #expect(out.maxX == 2000 - StripModel.margin && out.minY == 300)
    #expect(StripModel.tucked(size, in: area, edge: .left, y: 300, out: false).maxX == StripModel.sliver)
    #expect(StripModel.tucked(size, in: area, edge: .left, y: 5000, out: false).maxY == 1200 - StripModel.margin)   // whole on the screen's height
}

@MainActor @Test func aPointerPushedToTheEdgeKeepsTheStripOut() {
    let out = StripModel.tucked(NSSize(width: 140, height: 40), in: area, edge: .right, y: 300, out: true)
    #expect(StripModel.inGap(NSPoint(x: 1999, y: 320), beside: out, edge: .right))
    #expect(!StripModel.inGap(NSPoint(x: 1999, y: 200), beside: out, edge: .right))   // below it
    #expect(!StripModel.inGap(NSPoint(x: out.minX - 2, y: 320), beside: out, edge: .right))   // off its inner side
    let left = StripModel.tucked(NSSize(width: 140, height: 40), in: area, edge: .left, y: 300, out: true)
    #expect(StripModel.inGap(NSPoint(x: 0, y: 320), beside: left, edge: .left))
}

/// News comes out once each, a question first; finished work only when Comes Up For takes it in, work going on never.
@MainActor @Test func newsComesOutOnceAsLoudAsWhatBringsTheStripUp() {
    let ask = item(.asks, "a", at: 5), fail = item(.failed, "b", at: 1), done = item(.done, "c")
    #expect(StripModel.news([fail, ask, done], told: []).map(\.session) == ["a", "b"])   // a question before a failure
    #expect(StripModel.news([fail, ask], told: [StripModel.newsKey(ask)]).map(\.session) == ["b"])
    #expect(StripModel.news([done, item(.working, "d")], told: []).isEmpty)
    #expect(
        StripModel.news([done, item(.working, "d")], told: [], upTo: StripModel.loudest("all")).map(\.session) == ["c"])
    #expect(StripModel.news([fail], told: [], upTo: StripModel.loudest("questions")).isEmpty)
    var again = ask
    again.since = Date(timeIntervalSince1970: 9)   // the agent asks something else
    #expect(StripModel.news([again], told: [StripModel.newsKey(ask)]).map(\.session) == ["a"])
    #expect(StripModel.stays(.done) < StripModel.stays(.failed) && StripModel.stays(.failed) < StripModel.stays(.asks))
}

/// Where the strip stands is one value on this Mac: the tests that save it go one at a time.
@MainActor @Suite(.serialized) struct StripPlaceTests {
    private func session(_ place: String, _ status: AgentStatus, summary: String = "") -> Session {
        var s = Session(cwd: "/", command: "x", agent: "claude", status: status, summary: summary)
        s.worktreeId = place
        return s
    }

    @Test func aDroppedStripGoesToItsCornerAndStaysThere() async throws {
        let rig = try await AppRig()
        _ = NSApplication.shared
        let strip = AgentStrip(app: rig.app)
        strip.front = { false }   // behind another app, whatever another test brings forward
        strip.animates = false
        defer { StripPlace.save(nil) }
        strip.start()
        rig.app.sessions = [session(rig.workspace.id, .working)]
        try await settled(strip) { strip.isShowing }
        let area = try #require(NSScreen.main?.visibleFrame)
        strip.panelForTests?.setFrameOrigin(NSPoint(x: area.minX + 90, y: area.maxY - 160))
        strip.dropped()
        try await settled(strip)
        let tile = try #require(strip.frame)
        #expect(abs(tile.minX - (area.minX + 8)) < 1 && abs(tile.maxY - (area.maxY - 8)) < 1)
        #expect(StripPlace.load()?.corner == .topLeft)
        rig.app.sessions = [session(rig.workspace.id, .waiting, summary: "Allow npm test?")]
        try await settled(strip) { strip.frame != tile }
        let pill = try #require(strip.frame)
        #expect(abs(pill.minX - tile.minX) < 1 && abs(pill.maxY - tile.maxY) < 1)
    }

    @Test func aHiddenPlaceIsKept() {
        defer { StripPlace.save(nil) }
        let place = StripPlace(corner: .bottomRight, display: 7, edge: .right, y: 312)
        StripPlace.save(place)
        #expect(StripPlace.load() == place)
    }

    @Test func aStripDroppedPastTheRightSideHidesThere() async throws {
        let rig = try await AppRig()
        _ = NSApplication.shared
        let strip = AgentStrip(app: rig.app)
        strip.front = { false }   // behind another app, whatever another test brings forward
        strip.animates = false
        defer { StripPlace.save(nil) }
        strip.start()
        rig.app.sessions = [session(rig.workspace.id, .working)]
        try await settled(strip) { strip.isShowing }
        let screen = try #require(NSScreen.main)
        let others = NSScreen.screens.filter { $0 != screen }.map(\.frame)
        guard StripModel.outer(.right, of: screen.frame, among: others) else { return }   // a screen past it on this Mac
        let area = screen.visibleFrame
        let width = try #require(strip.frame).width
        strip.panelForTests?.setFrameOrigin(NSPoint(x: area.maxX - width / 2, y: area.minY + 300))
        strip.dropped()
        try await settled(strip)
        let hid = try #require(strip.frame)
        #expect(abs(hid.minX - (area.maxX - StripModel.sliver)) < 1)
        #expect(abs(hid.minY - (area.minY + 300)) < 1)
        #expect(StripPlace.load()?.edge == .right)
    }

    /// A call takes the strip behind the nearer side and back where it stood after, without keeping that place.
    @Test func aCallTakesTheStripBehindTheEdgeAndBack() async throws {
        let rig = try await AppRig()
        _ = NSApplication.shared
        StripPlace.save(nil)
        let strip = AgentStrip(app: rig.app)
        strip.front = { false }   // behind another app, whatever another test brings forward
        strip.animates = false
        defer { StripPlace.save(nil) }
        strip.start()
        rig.app.sessions = [session(rig.workspace.id, .working)]
        try await settled(strip) { strip.isShowing }
        let before = try #require(strip.frame)
        strip.call(true)
        try await settled(strip)
        guard strip.place?.edge != nil else { return }   // a screen stands past both sides on this Mac
        #expect(try #require(strip.frame) != before)
        #expect(StripPlace.load() == nil)   // the place the person chose stays theirs
        strip.call(false)
        try await settled(strip)
        #expect(strip.place == nil)
        #expect(strip.frame == before)
    }

    /// Two fingers swept over the strip move it to the next place that way; the coasting after doesn't count.
    @Test func aSwipeOverTheStripMovesIt() async throws {
        let rig = try await AppRig()
        _ = NSApplication.shared
        StripPlace.save(nil)
        let strip = AgentStrip(app: rig.app)
        strip.front = { false }   // behind another app, whatever another test brings forward
        strip.animates = false
        defer { StripPlace.save(nil) }
        strip.start()
        rig.app.sessions = [session(rig.workspace.id, .working)]
        try await settled(strip) { strip.isShowing }
        func scroll(_ phase: CGScrollPhase, dx: Int32) throws -> NSEvent {
            let e = try #require(
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return try #require(NSEvent(cgEvent: e))
        }
        for (phase, dx) in [(CGScrollPhase.began, 30), (.changed, 30), (.changed, 30), (.ended, 0)]
            as [(CGScrollPhase, Int32)]
        {
            strip.row.scrollWheel(with: try scroll(phase, dx: dx))
        }
        try await settled(strip)
        #expect(strip.place?.corner == .bottomLeft || strip.place?.corner == .bottomRight)
    }

    /// Once `first` holds, until the strip stops moving: its animation's end, not a guess at how long one takes (a loaded
    /// machine runs them late). Gives up after 15 s, a failure there.
    private func settled(_ strip: AgentStrip, after first: () -> Bool = { true }) async throws {
        let end = Date().addingTimeInterval(15)
        try await waitFor(15) { first() }
        var last = strip.frame, still = 0   // the same frame at four looks in a row, 150 ms
        try await waitFor(max(0, end.timeIntervalSinceNow)) {
            if strip.frame == last {
                still += 1
            } else {
                still = 0
                last = strip.frame
            }
            return still >= 4
        }
    }
}
