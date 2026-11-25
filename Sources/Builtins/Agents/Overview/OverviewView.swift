import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The "overview:" tab (Window › Agents Overview): every chat of the day at once. A summary plate says who asks now,
/// how long the agents worked and how long they waited for the user, what changed and how much of the plan is used.
/// Under it the board puts each chat in the stage of its work (`OverviewStage`), and the day draws each chat's work
/// and waits over the hours. Beside them, Needs Attention lists what holds the work up (`Insight`). "7 Days" sums the
/// week instead: by day, by project, and the longest waits.
struct OverviewView: View {
    let app: AppModel
    @State private var model: OverviewModel
    @State private var week = false
    @State private var quickLook = QuickLook()

    /// Whether the tab reads the history and turns from the daemon; a picture of a made-up day doesn't.
    private let reads: Bool

    init(app: AppModel, model: OverviewModel? = nil, week: Bool = false) {
        self.app = app
        reads = model == nil
        _model = State(initialValue: model ?? OverviewModel(app: app))
        _week = State(initialValue: week)
    }

    var body: some View {
        let cards = model.cards
        VStack(spacing: 0) {
            bar(cards)
            Divider()
            ScrollView {
                // Redrawn each minute, because the day's lines grow and the waits get longer while nothing else
                // changes.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Group {
                        if week { OverviewWeek(model: model) } else { today(cards) }
                    }
                    .padding(.horizontal, Metrics.pageInset).padding(.vertical, Metrics.pageTop)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .fontDesign(app.themes.chromeDesign)
        .watchingPlans(app)
        // The history and the turns are read again whenever a chat's status changes, the last read cancelled.
        .task(id: "\(week)|\(stamp)") { if reads { await model.load(since: start) } }
        .onAppear { model.follow(cards) }
        .onChange(of: cards.map(\.id)) { model.follow(cards) }
        .onDisappear {
            model.stop()
            quickLook.close()
        }
    }

    /// Changes whenever a chat's status does.
    private var stamp: String { app.sessions.map { "\($0.id)\($0.status.rawValue)" }.joined() }
    private var start: Date {
        let today = model.today
        return week ? Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today : today
    }

    private func bar(_ cards: [OverviewCard]) -> some View {
        ContentBar {
            Text("Agents Overview").font(.ui(TextSize.body, weight: .semibold))
            Text(facts(cards)).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Segments(
                labels: [String(localized: "Today"), String(localized: "7 Days")], name: String(localized: "Period"),
                selection: Binding {
                    week ? 1 : 0
                } set: {
                    week = $0 == 1
                }
            )
            .fixedSize()
        }
    }

    private func facts(_ cards: [OverviewCard]) -> String {
        if week { return String(localized: "\(model.lines.count) chats in 7 days") }
        let projects = Set(cards.map(\.project)).count
        return String(localized: "chats today: \(cards.count) · projects: \(projects)")
    }

    @ViewBuilder private func today(_ cards: [OverviewCard]) -> some View {
        if cards.isEmpty, model.loaded {
            EmptyState(String(localized: "No Chats Today"), symbol: "rectangle.3.group", lifted: false) {
                Text("Chats you start or talk to today show up here.")
            }
            .padding(.top, Metrics.blockGap)
        } else {
            let insights = model.insights(cards)
            HStack(alignment: .top, spacing: Metrics.blockGap) {
                VStack(alignment: .leading, spacing: Metrics.blockGap) {
                    if let failed = model.failed {
                        FailureLine(failed) { Task { await model.load(since: start) } }
                    }
                    OverviewPlate(stats: todayStats(cards))
                    section(
                        String(localized: "Stages"),
                        String(localized: "the column is where the work is; the mark is what the agent does"))
                    let hours = model.hours(cards)
                    OverviewBoard(cards: cards, hours: hours, app: app) { quickLook.show($0, app: app) }
                    section(String(localized: "Day"), nil, legend: true)
                    OverviewDay(cards: cards.filter { !$0.line.spans.isEmpty }, hours: hours, app: app)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !insights.isEmpty {
                    InsightsColumn(insights: insights, app: app).frame(width: 260)
                }
            }
        }
    }

    private func section(_ title: String, _ note: String?, legend: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
            Text(title).font(.ui(TextSize.body, weight: .semibold))
            if let note { Text(note).font(.ui(TextSize.caption)).foregroundStyle(.secondary) }
            if legend { DayLegend() }
        }
        .padding(.bottom, -Metrics.blockGap + Metrics.gapWide)
    }

    /// The plate's figures for today.
    private func todayStats(_ cards: [OverviewCard]) -> [OverviewPlate.Stat] {
        let asking = cards.filter { $0.session.status == .waiting },
            working = cards.filter { $0.session.status == .working }
        let longest = asking.max { ($0.line.waitsNow ?? 0) < ($1.line.waitsNow ?? 0) }
        let lines = cards.map(\.line), now = Date()
        let peak = DayLine.atOnce(lines, from: model.since, to: now, step: 300).max() ?? 0
        let worked = lines.reduce(0) { $0 + $1.worked }, waited = lines.reduce(0) { $0 + $1.waited }
        let longestWait = lines.flatMap { $0.spans.filter { $0.kind != .worked } }.map(\.length).max() ?? 0
        let added = cards.reduce(0) { $0 + $1.added }, removed = cards.reduce(0) { $0 + $1.removed }
        let files = Set(cards.flatMap { c in (c.turn?.files ?? []).map { c.folder + "/" + $0.path } }).count
        let prs = cards.compactMap(\.pr)
        let open = Set(prs.filter { $0.state == "OPEN" }.map(\.number)).count
        let merged = Set(prs.filter { $0.state == "MERGED" }.map(\.number)).count
        let failed = prs.first { $0.state == "OPEN" && $0.checks.failed > 0 }
        let shared = Insight.sharedFile(model.insightChats(cards))
        var stats: [OverviewPlate.Stat] = [
            .init(
                value: String(localized: "\(asking.count) asking · \(working.count) working"), orange: !asking.isEmpty,
                note: longest.map {
                    String(localized: "“\($0.session.displayTitle)” has waited \(shortSpan($0.line.waitsNow ?? 0))")
                } ?? String(localized: "no one waits for you")),
            .init(
                value: shortSpan(worked, units: 2),
                note: String(localized: "agents worked today · up to \(peak) at once")),
            .init(
                value: shortSpan(waited, units: 2),
                note: String(localized: "agents waited for you · longest \(shortSpan(longestWait, units: 2))")),
            .init(
                value: "", added: added, removed: removed,
                note: shared.map { String(localized: "2 chats edit \(($0.file as NSString).lastPathComponent)") }
                    ?? String(localized: "files in the last turns: \(files)")),
            .init(
                value: String(localized: "\(open) PR · \(merged) merged"),
                note: failed.map { String(localized: "CI failed in #\($0.number)") }
                    ?? String(localized: "pull requests of today’s chats"))
        ]
        if let limit = model.limit {
            stats.append(
                .init(
                    value: "\(Int((limit.used * 100).rounded())) %",
                    note: limit.name + (limit.resets.map { " · \($0)" } ?? ""),
                    meter: limit.used))
        }
        return stats
    }
}

/// Answers an asking chat from the overview with the card the Dock strip shows (`StripCard`), by the pointer. A click
/// elsewhere in Kelp, ⎋ or an answer closes it.
@MainActor
final class QuickLook {
    private var card: StripCard?
    private var monitor: Any?

    func show(_ s: Session, app: AppModel) {
        close()
        let made = StripCard(s, app: app, fullScreen: false) { [weak self] _ in self?.close() }
        card = made
        let at = NSEvent.mouseLocation
        made.show(by: NSRect(x: at.x, y: at.y, width: 1, height: 1), in: NSScreen.main?.visibleFrame, at: .bottomLeft)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if !(event.window is StripPanel) { self?.close() }
            return event
        }
    }

    func close() {
        card?.close()
        card = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
