import AppKit
import Core
import Foundation
import SwiftUI
import Testing

@testable import BuiltinAgents
@testable import KelpKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
private func pr(_ state: String, failed: Int = 0) -> GitHub.PullRequest {
    .init(
        number: 7, title: "x", url: "", author: "", headRefName: "b", isDraft: false, state: state,
        checks: .init(failed: failed))
}

/// A card's column says where its work stands: a live, asking or limited agent is at work whatever its branch, then
/// the pull request decides, then whether its last turn's files are committed.
@Test(arguments: [
    (OverviewStage.Facts(status: .working, pr: pr("OPEN")), OverviewStage.working),
    (.init(status: .waiting, turnFiles: ["a"], dirty: ["a"]), .working),
    (.init(status: .done, limited: true, turnFiles: ["a"], dirty: ["a"]), .working),
    (.init(status: .done, turnFiles: ["a"], dirty: ["a"]), .review),
    (.init(status: .paused, turnFiles: ["a", "b"], dirty: ["b"]), .review),
    (.init(status: .done, turnFiles: ["a"], dirty: ["c"]), .done),
    (.init(status: .done), .working),
    (.init(status: .idle, pr: pr("OPEN"), turnFiles: ["a"], dirty: ["a"]), .pullRequest),
    (.init(status: .done, pr: pr("MERGED")), .done),
    (.init(status: .done, pr: pr("CLOSED"), turnFiles: ["a"], dirty: ["a"]), .review),
    (.init(status: .exited, turnFiles: ["a"], dirty: ["a"]), .done)
])
func aCardsStageFollowsItsWork(facts: OverviewStage.Facts, stage: OverviewStage) {
    #expect(OverviewStage.of(facts) == stage)
}

/// A chat's day: worked while working, waited for the user between two turns unless away for hours, and waits now only
/// while it asks.
@Test func aDayLineReadsWorkAndWaits() {
    let line = DayLine.of(
        [
            .init(at: at(0), status: .idle), .init(at: at(10), status: .working), .init(at: at(40), status: .done),
            .init(at: at(50), status: .working), .init(at: at(60), status: .waiting),
            .init(at: at(65), status: .working),
            .init(at: at(70), status: .done), .init(at: at(300), status: .working), .init(at: at(310), status: .waiting)
        ], now: at(330))
    #expect(line.spans.map(\.kind) == [.worked, .waited, .worked, .waited, .worked, .worked, .waitsNow])
    #expect(line.turns == 4)
    #expect(line.worked == 55 * 60)
    #expect(line.waitsNow == TimeInterval(20 * 60))
    #expect(line.waited == (10 + 5 + 20) * 60)
    // Resting after the last turn isn't waiting: the user may never come back to it.
    let rested = DayLine.of([.init(at: at(0), status: .working), .init(at: at(5), status: .done)], now: at(60))
    #expect(rested.spans.map(\.kind) == [.worked])
}

/// The week counts each span on the day it began, and each chat once a day; the projects sum their chats.
@Test func theWeekSumsDaysAndProjects() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let lines = [
        "a": DayLine(spans: [
            .init(from: at(0), to: at(60), kind: .worked), .init(from: at(60), to: at(90), kind: .waited)
        ]),
        "b": DayLine(spans: [.init(from: at(-1440), to: at(-1400), kind: .worked)])
    ]
    let days = WeekSums.days(lines, days: 3, now: at(100), calendar: calendar)
    #expect(days.count == 3)
    #expect(days.last?.worked == 3600)
    #expect(days.last?.waited == 1800)
    #expect(days.last?.chats == 1)
    #expect(days[1].worked == 40 * 60)
    let projects = WeekSums.projects(lines) { $0 == "a" ? "shop" : "docs" }
    #expect(projects.map(\.name) == ["shop", "docs"])
    #expect(DayLine.longestWaits(lines, count: 1).first?.session == "a")
    #expect(DayLine.atOnce(Array(lines.values), from: at(0), to: at(120), step: 3600) == [1, 0])
}

/// Needs Attention: each rule names its most pressing chat, and quiet rules say nothing.
@Test func insightsFollowTheirRules() {
    func chat(_ id: String, _ status: AgentStatus, _ stage: OverviewStage, since: Double = 0) -> Insight.Chat {
        .init(id: id, title: id, status: status, stage: stage, since: at(since), folder: "f")
    }
    var asking = chat("ask", .waiting, .working, since: 10), older = chat("old", .waiting, .working, since: 5)
    asking.uncommitted = ["Sources/A.swift", "B.swift"]
    older.uncommitted = ["Sources/A.swift"]
    var review = chat("rev", .done, .review, since: -100)
    review.added = 3
    var full = chat("full", .working, .working)
    full.context = 0.9
    var broken = chat("ci", .idle, .pullRequest)
    broken.failedPR = 209
    let lines = Insight.of(
        [asking, older, review, full, broken], limit: .init(name: "5h", used: 0.85, resets: "3pm"), now: at(20))
    #expect(lines.map(\.kind) == [.asks, .failed, .sameFile, .review, .context, .limit])
    #expect(lines.first?.session == "old")
    #expect(lines.first { $0.kind == .sameFile }?.title.contains("A.swift") == true)
    #expect(Insight.of([chat("calm", .done, .done)], limit: .init(name: "5h", used: 0.5, resets: nil)).isEmpty)
}

// MARK: The tab, on a made-up day

/// One chat of the made-up day.
private struct DayChat {
    var title: String, project: String, branch: String, status: AgentStatus, summary = "", agent = "claude"
    var files: [(String, Int, Int)] = [], dirty: [String] = []
    var pr: (Int, String, Int)?
    var work: [(Double, Double)] = []   // (minutes ago it started, minutes it worked)
    var running: String?
    var limit = false, subagents = 0
    var context: Int?
}

private let dayChats = [
    DayChat(
        title: "Migrate orders to the new schema", project: "shop-api", branch: "feat/orders-v2", status: .waiting,
        summary: "Delete the old orders_legacy table?",
        files: [("Sources/Orders.swift", 180, 30), ("Migrations/007.sql", 32, 10)],
        dirty: ["Sources/Orders.swift", "Migrations/007.sql"],
        work: [(470, 60), (380, 90), (240, 45), (150, 80), (60, 42)],
        context: 64),
    DayChat(
        title: "Fix the flaky CheckoutTests", project: "web-app", branch: "fix/checkout-flaky", status: .waiting,
        summary: "Allow Bash: npm run e2e -- --repeat 20", files: [("Tests/CheckoutTests.swift", 14, 3)],
        dirty: ["Tests/CheckoutTests.swift"], work: [(40, 12), (20, 17)], context: 31),
    DayChat(
        title: "Find why CI fails on main", project: "web-app", branch: "main", status: .working,
        work: [(30, 8), (12, 12)], running: "gh run view 1823 --log-failed", subagents: 2, context: 18),
    DayChat(
        title: "Update the install README", project: "docs", branch: "main", status: .working, agent: "codex",
        files: [("README.md", 36, 12)], dirty: ["README.md"], work: [(25, 25)], running: "Editing README.md"),
    DayChat(
        title: "Translate the payment page", project: "web-app", branch: "i18n/payment", status: .done,
        files: [("pay.json", 88, 30)], dirty: ["pay.json"], work: [(300, 70)], limit: true, context: 71),
    DayChat(
        title: "Cursor pagination for /orders", project: "shop-api", branch: "feat/pagination", status: .done,
        summary: "Added cursor pagination; the tests pass", files: [("Sources/Pages.swift", 148, 22)],
        dirty: ["Sources/Pages.swift"], work: [(420, 50), (330, 80), (200, 95)], context: 47),
    DayChat(
        title: "Cache for the catalog", project: "shop-api", branch: "feat/catalog-cache", status: .idle,
        summary: "Done, ready for review", files: [("Sources/Catalog.swift", 96, 18)],
        dirty: ["Sources/Catalog.swift"],
        work: [(110, 26)], context: 29),
    DayChat(
        title: "Docker image for staging", project: "shop-api", branch: "ci/docker-stage", status: .idle,
        summary: "Pushed; waiting for CI", files: [("Dockerfile", 31, 6)], pr: (209, "OPEN", 1), work: [(160, 40)]),
    DayChat(
        title: "Fixes after review of #204", project: "web-app", branch: "feat/cart-badges", status: .idle,
        summary: "Answered 2 review comments", files: [("Sources/Badge.swift", 54, 20)], pr: (211, "OPEN", 0),
        work: [(260, 52)], context: 39),
    DayChat(
        title: "Pagination in the admin", project: "shop-api", branch: "feat/admin-pages", status: .done,
        summary: "PR #205 merged", files: [("Sources/Admin.swift", 120, 31)], pr: (205, "MERGED", 0),
        work: [(520, 60)]),
    DayChat(
        title: "Typos in the docs", project: "docs", branch: "main", status: .exited, summary: "Committed to main",
        work: [(200, 12)])
]

/// A day of eleven chats in three projects, each on a branch of its own, with their git, pull requests and history.
@MainActor private func madeUpDay() -> (AppModel, OverviewModel) {
    let app = AppModel(builtins: [])
    let now = Date()
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    let projects = ["shop-api", "web-app", "docs"].map { Repo(id: $0, name: $0, path: "/tmp/ov/\($0)") }
    app.repos = projects
    let chats = dayChats
    let model = OverviewModel(app: app)
    for (i, chat) in chats.enumerated() {
        let folder = "w\(i)", path = "/tmp/ov/\(chat.project)-\(i)"
        app.worktrees.append(Worktree(id: folder, repoId: chat.project, branch: chat.branch, path: path))
        var s = Session(
            id: "s\(i)", worktreeId: folder, cwd: path, command: chat.agent, agent: chat.agent, status: chat.status,
            createdAt: ago(600), title: chat.title, summary: chat.summary)
        s.running = chat.running
        if chat.limit { s.limitHit = LimitHit(kind: "5-hour", resets: "2:20pm", at: ago(230)) }
        if chat.subagents > 0 {
            s.subagentRuns = (0..<chat.subagents).map { Subagent(id: "a\($0)", kind: "Explore", task: nil) }
        }
        var changes: [SessionHistory.Change] = []
        for (start, length) in chat.work {
            changes.append(.init(at: ago(start), status: .working))
            changes.append(.init(at: ago(start - length), status: .done))
        }
        if chat.status == .waiting { changes[changes.count - 1].status = .waiting }
        if chat.status == .working { changes.removeLast() }
        if chat.status == .exited { changes.append(.init(at: ago(150), status: .exited)) }
        s.statusAt = changes.last?.at ?? ago(10)
        app.sessions.append(s)
        model.history[s.id] = changes
        if !chat.files.isEmpty {
            model.turns[s.id] = .init(
                files: chat.files.map { .init(path: $0.0, added: $0.1, removed: $0.2) }, seconds: 60)
        }
        var git = GitEvent(
            worktree: folder, changes: chat.dirty.map { FileChange(path: $0, index: " ", worktree: "M") },
            branches: BranchInfo(current: chat.branch, head: "abc", local: [], remote: [], merging: false))
        git.stats = nil
        app.land(git)
        if let pr = chat.pr {
            app.land(
                PREvent(
                    worktree: folder,
                    pr: .init(
                        number: pr.0, title: chat.title, url: "", author: "me", headRefName: chat.branch,
                        isDraft: false,
                        state: pr.1, checks: .init(passed: pr.2 == 0 ? 4 : 3, failed: pr.2))))
        }
        if let context = chat.context {
            app.land(ContextEvent(session: s.id, usage: .init(used: context * 2000, window: 200_000)))
        }
    }
    model.loaded = true
    model.dayStart = ago(600)
    return (app, model)
}

/// The board puts each chat where its work stands, an asking chat first in its column, and says what holds work up.
/// With KELP_SHOT set it writes pictures of today and of the week.
@MainActor @Test func theOverviewSortsADayOfChats() throws {
    let (app, model) = madeUpDay()
    let cards = model.cards
    func stage(_ title: String) -> OverviewStage? { cards.first { $0.session.displayTitle == title }?.stage }
    #expect(stage("Migrate orders to the new schema") == .working)
    #expect(stage("Translate the payment page") == .working)
    #expect(stage("Cursor pagination for /orders") == .review)
    #expect(stage("Docker image for staging") == .pullRequest)
    #expect(stage("Pagination in the admin") == .done)
    #expect(stage("Typos in the docs") == .done)
    #expect(cards.first?.session.status == .waiting)
    #expect(model.insights(cards).map(\.kind).prefix(2) == [.asks, .failed])

    guard let dir = ProcessInfo.processInfo.environment["KELP_SHOT"] else { return }
    for (name, week) in [("overview-today", false), ("overview-week", true)] {
        let view = NSHostingView(
            rootView: OverviewView(app: app, model: model, week: week).frame(width: 1500, height: 1250))
        view.frame = NSRect(x: 0, y: 0, width: 1500, height: 1250)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(
            named: ProcessInfo.processInfo.environment["KELP_SHOT_DARK"] == nil ? .aqua : .darkAqua)
        window.contentView = view
        view.wantsLayer = true
        window.appearance?.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // The tab stands on the editor's card, which the picture's empty ground would leave black.
        let picture = NSImage(size: view.bounds.size)
        picture.lockFocus()
        window.appearance?.performAsCurrentDrawingAppearance {
            NSColor.textBackgroundColor.setFill()
            view.bounds.fill()
        }
        rep.draw(in: view.bounds)
        picture.unlockFocus()
        let png = picture.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(
            using: .png, properties: [:])
        try png?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
