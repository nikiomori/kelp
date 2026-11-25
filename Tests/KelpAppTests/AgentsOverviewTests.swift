import Core
import Foundation
import Testing

@testable import BuiltinAgents

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
