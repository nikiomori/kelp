import AppKit
import Charts
import Core
import DesignKit
import KelpKit
import SwiftUI

/// "usage:" — what the agents used, a row each: how full its plan is, its days over the span on its own scale, its tokens
/// and what they'd cost at API prices (a subscription bills differently), from its own logs on this Mac. A click on a row
/// narrows the chart and the tables under it to that agent. Window › Usage (⌥⌘U).
@MainActor
final class UsageTab: KelpKit.TabContent {   // not SwiftUI's
    let uri = "usage:"
    let view: NSView
    var title: String { String(localized: "Usage") }
    var icon: NSImage? { .symbol("chart.bar") }
    init(app: AppModel) {
        let host = NSHostingView(
            rootView: UsageReportView(app: app).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        host.sizingOptions = []   // a tab fills the space it's given; it must never resize the window to its ideal size
        view = host
    }
    func focus() {}
}

struct UsageReportView: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    typealias Plan = (limits: [(label: String, used: Double, resets: String?)], readAt: Date?)
    /// An agent's row: what it used in the span (nil: nothing counted) and its plan (nil: none read).
    struct Line: Identifiable {
        let id: String
        let usage: UsageAgents.Agent?
        let plan: Plan?
    }
    @State var range = 30
    @State var byCost = true
    @State var selected: String?
    @State var hovered: String?
    @State var usage: UsageAgents.Result?
    @State private var loading = true
    @State private var failed: String?
    /// The last year of weeks, for the board of days (read once, after the span's).
    @State private var year: [UsageAgents.Day] = []

    /// The charts' colours, by an agent's place among those the daemon counts: the same in every span.
    static let palette: [Color] = [
        .blue, .purple, .orange, .brown, .mint, .yellow, .cyan, .red, .teal, .green, .pink, .indigo
    ]

    var body: some View {
        let lines = agentLines(UsageView.plans(app).mapValues { (limits: $0.limits, readAt: $0.readAt) })
        // As wide as the pane up to 1000, and the table's own width at least: a narrower pane scrolls sideways, from the left.
        GeometryReader { pane in
            ScrollView([.vertical, .horizontal]) {
                page(lines).padding([.horizontal, .bottom], 24).frame(
                    width: min(max(pane.size.width, 700), 1000), alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
        }
        .watchingPlans(app)
        .task(id: range) { await load() }
    }

    private func page(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if let failed { Text("Couldn't read the usage: \(failed)").foregroundStyle(.secondary) }
            // The plans at once (the sidebar has them already); the figures fill in as the logs are read.
            if usage != nil, !lines.isEmpty { kpis(lines) }
            if !lines.isEmpty { table(lines) }
            if let usage, !usage.days.isEmpty {
                detail(usage)
                HStack(alignment: .top, spacing: 28) {
                    groups(String(localized: "By Model"), (sel.flatMap(agent)?.models ?? usage.models), model: true)
                    groups(
                        String(localized: "By Project"), sel.flatMap(agent)?.projects ?? usage.projects, model: false)
                }
            } else if !loading, failed == nil {
                Text("No agent conversations in this time.").foregroundStyle(.secondary)
            }
            if usage != nil { footnote }
        }
    }

    /// What the tab's name doesn't say already: the span, where it's from, and whether the logs are still being read.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Last \(range) days · from each agent's own logs on this Mac").font(.ui(TextSize.caption))
                .foregroundStyle(
                    .secondary)
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Picker("", selection: $range) {
                Text("7 Days").tag(7)
                Text("30 Days").tag(30)
                Text("90 Days").tag(90)
            }
            .pickerStyle(.segmented).controlSize(.small).fixedSize()
        }
        // The band other tabs give their bar: banners start under it, so they never cover the range.
        .frame(height: TextSize.of(Metrics.contentBar))
    }

    /// Where the figures come from, under them.
    private var footnote: some View {
        Text(
            """
                Read from each agent's own logs on this Mac: Claude Code (every account profile), Codex, Grok, Antigravity, Kimi Code, \
                Copilot, OpenCode, Kilo Code, pi, oh-my-pi, Qwen Code and Gemini CLI. Cursor, Amp and fx keep no token counts on \
                disk; Droid, Goose, Hermes and Kiro keep only a session's. Tokens include reads from the cache, which cost far \
                less than fresh input. Prices are list prices (Grok's, pi's and OpenCode's as they report them); a subscription bills \
                differently, and "—" is a model without one.
            """
        )
        .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
    }

    // MARK: Under the table

    /// The last year's days as tiles, then cost or tokens a day over the span stacked by agent (the chosen one's alone).
    private func detail(_ usage: UsageAgents.Result) -> some View {
        let ids = series.map(\.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(sel.map { app.catalog.name($0) } ?? String(localized: "All agents")).font(
                    .ui(TextSize.body, weight: .semibold))
                if sel != nil { Button("Show All") { selected = nil }.controlSize(.small) }
                Spacer()
                Picker("", selection: $byCost) {
                    Text("Cost").tag(true)
                    Text("Tokens").tag(false)
                }
                .pickerStyle(.segmented).controlSize(.small).fixedSize()
            }
            if !year.isEmpty { board }
            Text(
                byCost
                    ? String(localized: "Cost per day · last \(range) days")
                    : String(localized: "Tokens per day · last \(range) days")
            )
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary).padding(.top, 8)
            Chart(usage.days.filter { ids.contains($0.agent) }, id: \.self) { record in
                BarMark(
                    x: .value("Day", Self.date(record.day), unit: .day),
                    y: .value(byCost ? "Cost" : "Tokens", value(record))
                )
                .foregroundStyle(by: .value("Agent", app.catalog.name(record.agent)))
            }
            .chartForegroundStyleScale(domain: ids.map { app.catalog.name($0) }, range: ids.map(color))
            .chartXScale(domain: span(usage))
            .chartYAxis {
                AxisMarks { axisValue in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = axisValue.as(Double.self) {
                            Text(byCost ? money(amount, 0) : count(Int(amount)))
                        }
                    }
                }
            }
            .frame(height: 180)
        }
    }

    /// The year's days by how much the agents (the chosen one) used, what it all came to over it, and each day's on hover.
    private var board: some View {
        var days: [Date: (cost: Double, tokens: Int)] = [:]
        for record in year where sel == nil || record.agent == sel {
            let dayStart = Self.date(record.day), was = days[dayStart] ?? (0, 0)
            days[dayStart] = (was.cost + record.cost, was.tokens + record.tokens)
        }
        let cost = days.values.reduce(0) { $0 + $1.cost }, tokens = days.values.reduce(0) { $0 + $1.tokens }
        let total = byCost ? money(cost, tokens) : String(localized: "\(count(tokens)) tokens")
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(total) in the last year · \(days.count) active days").font(.ui(TextSize.caption)).foregroundStyle(
                .secondary)
            ScrollView(.horizontal, showsIndicators: false) {   // a year is wider than a narrow pane: this week stays in view
                YearBoard(
                    values: days.mapValues { byCost ? $0.cost : Double($0.tokens) }, color: sel.map(color) ?? .green
                ) { day in
                    let when = day.formatted(.dateTime.month(.wide).day())
                    guard let spent = days[day] else { return String(localized: "No usage on \(when)") }
                    return String(
                        localized: "\(when): \(money(spent.cost, spent.tokens)) · \(count(spent.tokens)) tokens")
                }
            }
            .defaultScrollAnchor(.trailing)
        }
    }

    /// The span's days, the first to today's.
    func span(_ usage: UsageAgents.Result) -> ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: usage.since))
        let end =
            Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return start...max(start, end)
    }

    /// A model's dot is its agent's colour (the chosen agent's when there is one).
    private func groups(_ title: String, _ rows: [UsageReport.Group], model: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(TextSize.body, weight: .semibold))
            ForEach(rows.prefix(8), id: \.name) { group in
                HStack(spacing: 8) {
                    if model,
                        let owner = sel ?? series.first(where: { $0.models.contains { $0.name == group.name } })?.id
                    {
                        Circle().fill(color(owner)).frame(width: 6, height: 6)
                    }
                    Text(model ? Self.model(group.name) : group.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(count(group.tokens)).foregroundStyle(.secondary).monospacedDigit()
                    Text(money(group.cost, group.tokens)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }.font(.ui(TextSize.row))
                Divider()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        loading = true
        let read = await app.tryCall(UsageAgents(days: range))
        failed = read.error
        if let fresh = read.value { usage = fresh }
        loading = false
        // The board's year once the span's is in: both wait on the same logs, and the table is what's asked for first.
        if year.isEmpty { year = await app.quiet(UsageAgents(days: 371), timeout: 330)?.days ?? [] }
    }

    // MARK: Formats

    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5", as Claude Code names them; the other
    /// agents' models as they write them.
    static func model(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        var words: [String] = []
        for p in id.dropFirst(7).split(separator: "-").map(String.init) where !(p.count == 8 && Int(p) != nil) {   // not a snapshot's date
            if Int(p) != nil, let prev = words.last, prev.last?.isNumber == true {
                words[words.count - 1] += "." + p
            } else {
                words.append(p.prefix(1).uppercased() + p.dropFirst())
            }
        }
        return words.joined(separator: " ")
    }

    /// A day as the daemon writes it ("2026-10-29", local), at its start.
    static func date(_ day: String) -> Date { dayFormat.date(from: day) ?? Date() }
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    /// "—" for tokens with no price (a model without a list price).
    func money(_ v: Double, _ tokens: Int) -> String {
        v == 0 && tokens > 0 ? "—" : v.formatted(.currency(code: "USD").precision(.fractionLength(v < 10 ? 2 : 0)))
    }
    func count(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }
    func percent(_ part: Int, of whole: Int) -> String {
        UsageView.percent(Double(part) / Double(max(1, whole)))
    }
    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ui(TextSize.title, weight: .semibold).monospacedDigit())
            Text(label).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
        }
    }
}
