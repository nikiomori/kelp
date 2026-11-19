import AppKit
import Charts
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The "usage:" tab, opened with Window › Usage (⌥⌘U). It first shows the agents' plans now, with when each limit
/// runs out at its pace. Under them is what the agents used over a span, one row for each agent, read from the agent's
/// own logs on this Mac. Each row shows the agent's days on its own scale, its share of the cost, its tokens, and what
/// they'd cost at API prices (a subscription bills differently). A click on a row or a project narrows what's under
/// it to that agent or project.
struct UsageReportView: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    /// An agent's row, with what it used in the span, or nil when nothing was counted.
    struct Line: Identifiable {
        let id: String
        let usage: UsageAgents.Agent?
    }
    @State var range = 30
    /// What the agents' table is sorted by: the most expensive first until its header is clicked.
    @State var agentOrder = AgentOrder(by: .cost, ascending: false)
    enum AgentSort: String { case agent, tokens, cost }
    struct AgentOrder: Equatable { var by: AgentSort, ascending: Bool }
    @State var byCost = true
    @State var selected: String?
    /// The project the page is narrowed to (a name from the span's projects).
    @State var project: String?
    @State var allModels = false
    @State var allProjects = false
    /// The day under the pointer in the chart.
    @State var day: Date?
    @State var usage: UsageAgents.Result?
    @State private var loading = true
    /// The read has gone on for a second: only then does the spinner show.
    @State private var slow = false
    @State private var failed: String?
    @State private var showSources = false
    /// The days of the last year, for the months view (read once per project, after the span's days).
    @State private var year: [UsageAgents.Day] = []
    @State private var yearFor: String?

    /// The charts' colours, given by an agent's place among the agents the daemon counts, so an agent keeps its colour
    /// in every span. None is orange, yellow or red: on this page those say a plan is near its limit or used up.
    static let palette: [Color] = [.blue, .purple, .brown, .mint, .cyan, .teal, .green, .pink, .indigo]
    /// The spans the picker offers, in days.
    private static let spans = [7, 30, 90]

    var body: some View {
        let lines = agentLines(UsageView.rows(app).map(\.id))
        // The bar stays put over the page. The page is as wide as the pane, up to 1400, and at least as wide as the
        // table. A narrower pane scrolls sideways, starting from the left.
        VStack(spacing: 0) {
            bar
            Divider()
            GeometryReader { pane in
                ScrollView([.vertical, .horizontal]) {
                    page(lines).padding(.horizontal, Metrics.pageInset).padding(.vertical, Metrics.pageTop).frame(
                        width: min(max(pane.size.width, 700), 1400), alignment: .leading)
                }
                .defaultScrollAnchor(.topLeading)
            }
        }
        .watchingPlans(app)
        .task(id: "\(range)|\(project ?? "")") { await load() }
    }

    private func page(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.blockGap) {
            // The plans come first, because they say whether work can go on now. They don't depend on the span, so
            // they stand above the span's picker.
            PlanCards(app: app, unplanned: unplanned)
            VStack(alignment: .leading, spacing: Metrics.inset) {
                period
                // A read that fails over figures already shown leaves them there, with one line saying so.
                if let failed, usage != nil {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
                        Text("Couldn’t read the usage: \(failed)").font(.ui(TextSize.caption))
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Try Again")) { Task { await load() } }
                            .controlSize(.small).font(.ui(TextSize.row))
                    }
                }
                // Until the first read is in, a spinner and a line saying what it waits for stand where the figures
                // will, once the read has taken a second.
                if usage == nil, slow, failed == nil {
                    LoadingLine(String(localized: "Reading the agents’ logs…"))
                        .frame(maxWidth: .infinity).padding(.vertical, Metrics.blockGap)
                }
                // The figures fill in as the logs are read.
                if usage != nil, !lines.isEmpty { kpis() }
                if !lines.isEmpty { table(lines) }
            }
            if let usage, !usage.days.isEmpty {
                detail(usage)
                if !year.isEmpty { months }
                HStack(alignment: .top, spacing: Metrics.blockGap) {
                    groups(
                        String(localized: "By Model"), sel.flatMap(agent)?.models ?? usage.models, all: $allModels,
                        model: true)
                    groups(
                        String(localized: "By Project"), sel.flatMap(agent)?.projects ?? usage.projects,
                        all: $allProjects, model: false)
                }
            } else if let failed, usage == nil {
                // With no figures yet, the failure is the page's state: the block every tab shows, with a way on.
                EmptyState(
                    String(localized: "Couldn’t Read the Usage"), symbol: "exclamationmark.triangle", lifted: false
                ) {
                    Text(failed)
                } actions: {
                    Button(String(localized: "Try Again")) { Task { await load() } }
                }
            } else if !loading, failed == nil {
                EmptyState(String(localized: "No Conversations in This Time"), symbol: "chart.bar", lifted: false)
            }
            if usage != nil { footnote }
        }
    }

    /// The tab's bar, as every page has one: its name, where the figures come from, and the span's picker at the
    /// right. Banners start under it.
    private var bar: some View {
        ContentBar {
            Text("Usage").font(.ui(TextSize.body, weight: .semibold))
            Text("From each agent's own logs and /usage on this Mac").font(.ui(TextSize.caption))
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Segments(
                labels: [String(localized: "7 Days"), String(localized: "30 Days"), String(localized: "90 Days")],
                selection: Binding {
                    Self.spans.firstIndex(of: range) ?? 1
                } set: {
                    range = Self.spans[$0]
                }
            )
            .fixedSize().accessibilityLabel(Text("Period"))
        }
    }

    /// The span and what the page is narrowed to. A read over figures already shown has a spinner beside them.
    private var period: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
            Text("Last \(range) days").font(.ui(TextSize.body, weight: .semibold))
            if let usage {
                Text((Date(timeIntervalSince1970: usage.since)..<Date()).formatted(.interval.month(.abbreviated).day()))
                    .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            }
            let only = [sel.map { app.catalog.name($0) }, project].compactMap { $0 }
            if !only.isEmpty {
                Text("Only \(only.joined(separator: " · "))").font(.ui(TextSize.caption))
                Button("Show All") {
                    selected = nil
                    project = nil
                }
                .controlSize(.small).font(.ui(TextSize.row))
            }
            if slow, usage != nil { ProgressView().controlSize(.small) }
        }
    }

    /// The footnote line. A link in it shows which agents are read and what is left out.
    private var footnote: some View {
        HStack(spacing: 4) {
            Text("Prices are API list prices: a plan bills differently.")
            Button("Which agents are counted") { showSources.toggle() }
                .buttonStyle(.link)
                .popover(isPresented: $showSources, arrowEdge: .top) {
                    Text(Self.sources)
                        .font(.ui(TextSize.caption)).fixedSize(horizontal: false, vertical: true)
                        .frame(width: 340, alignment: .leading).padding(Metrics.inset)
                }
        }
        .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
    }

    /// Whose logs are read, and what the figures leave out.
    static let sources = String(
        localized: """
            Read from each agent's own logs on this Mac: Claude Code (every account profile), Codex, Grok, Antigravity, Kimi Code, \
            Copilot, OpenCode, Kilo Code, pi, oh-my-pi, Qwen Code and Gemini CLI. Cursor, Amp and fx keep no token counts on \
            disk; Droid, Goose, Hermes and Kiro keep only a session's. Tokens include reads from the cache, which cost far \
            less than fresh input. Prices are list prices (Grok's, pi's and OpenCode's as they report them); a subscription bills \
            differently, and "—" is a model without one.
            """)

    // MARK: Under the table

    /// The chart of cost or tokens per day over the span, stacked by agent (or only the chosen agent). A dashed line
    /// marks the span's average, and the day under the pointer is broken down by agent.
    private func detail(_ usage: UsageAgents.Result) -> some View {
        let ids = series.map(\.id)
        // Only agents with a bar are drawn, in the legend too, because a free agent has none in Cost. Also, a mark
        // outside the colour scale's domain traps in Charts.
        let drawn = ids.filter { id in usage.days.contains { $0.agent == id && value($0) > 0 } }
        let records = usage.days.filter { drawn.contains($0.agent) }
        let average = records.reduce(0) { $0 + value($1) } / Double(range)
        let pointed = day.map { Calendar.current.startOfDay(for: $0) }
        return VStack(alignment: .leading, spacing: Metrics.gapWide) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
                Text("Per day").font(.ui(TextSize.body, weight: .semibold))
                Text("the dashed line is the average").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                Spacer()
                Segments(
                    labels: [String(localized: "Cost"), String(localized: "Tokens")],
                    selection: Binding {
                        byCost ? 0 : 1
                    } set: {
                        byCost = $0 == 0
                    }
                )
                .controlSize(.small).fixedSize().accessibilityLabel(Text("Show"))
            }
            Chart {
                ForEach(records, id: \.self) { record in
                    BarMark(
                        x: .value("Day", Self.date(record.day), unit: .day),
                        y: .value(byCost ? "Cost" : "Tokens", value(record))
                    )
                    .foregroundStyle(by: .value("Agent", app.catalog.name(record.agent)))
                    .opacity(pointed == nil || pointed == Self.date(record.day) ? 1 : 0.7)
                }
                if average > 0 {
                    RuleMark(y: .value("Average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("avg \(amount(average))").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                        }
                }
                if let pointed {
                    RuleMark(x: .value("Day", pointed, unit: .day)).foregroundStyle(.clear)
                        .annotation(
                            position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                        ) { breakdown(pointed, records.filter { Self.date($0.day) == pointed }) }
                }
            }
            .chartForegroundStyleScale(domain: drawn.map { app.catalog.name($0) }, range: drawn.map(color))
            .chartXScale(domain: span(usage))
            .chartXSelection(value: $day)
            .chartYAxis {
                AxisMarks { axisValue in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = axisValue.as(Double.self) { Text(self.amount(amount)) }
                    }
                }
            }
            .frame(height: 200)
        }
    }

    /// A day's figures by agent, over the chart while the pointer is on it.
    private func breakdown(_ day: Date, _ records: [UsageAgents.Day]) -> some View {
        let total = records.reduce(0) { $0 + value($1) }
        return VStack(alignment: .leading, spacing: Metrics.lineGap) {
            Text("\(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) · \(amount(total))")
                .fontWeight(.semibold).monospacedDigit()
            ForEach(records.sorted { value($0) > value($1) }, id: \.self) { record in
                HStack(spacing: Metrics.gap) {
                    Circle().fill(color(record.agent)).frame(width: 6, height: 6)
                    Text(app.catalog.name(record.agent)).foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    Text(byCost ? money(record.cost, record.tokens) : count(record.tokens)).monospacedDigit()
                }
            }
            if records.isEmpty { Text("No usage").foregroundStyle(.secondary) }
        }
        .font(.ui(TextSize.caption))
        .frame(minWidth: 180)
        .padding(Metrics.gapWide)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
    }

    /// The last 12 months, a bar for each, for all agents or only the chosen one, with the total over the 12 months.
    private var months: some View {
        var days: [Date: Double] = [:]
        var active = Set<String>()
        for record in year where (sel == nil || record.agent == sel) && record.tokens > 0 {
            days[Self.date(record.day), default: 0] += value(record)
            active.insert(record.day)
        }
        let bars = MonthBars.months(days)
        let total = bars.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: Metrics.gapWide) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
                Text("By month").font(.ui(TextSize.body, weight: .semibold))
                Text("\(amount(total)) in the last 12 months · \(active.count) active days").font(
                    .ui(TextSize.caption)
                ).foregroundStyle(.secondary)
            }
            MonthBars(months: bars, color: sel.map(color) ?? .blue, label: amount)
        }
    }

    /// The days of the span, from the first day to today.
    func span(_ usage: UsageAgents.Result) -> ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: usage.since))
        let end =
            Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return start...max(start, end)
    }

    private func load() async {
        loading = true
        let wait = whileSlow { slow = true }
        let read = await app.tryCall(UsageAgents(days: range, project: project))
        wait.cancel()
        slow = false
        failed = read.error
        if let fresh = read.value { usage = fresh }
        loading = false
        // Read the months only once the span's figures are in, because both wait on the same logs and the table is
        // what the user asked for first.
        let key = project ?? ""
        if yearFor != key {
            year = await app.quiet(UsageAgents(days: 371, project: project), timeout: 330)?.days ?? []
            yearFor = key
        }
    }

    // MARK: Formats

    /// Returns a model's name as Claude Code shows it, such as "claude-opus-5-5" → "Opus 5.5" and
    /// "claude-haiku-4-5-20251001" → "Haiku 4.5". Other agents' models stay as those agents write them.
    static func model(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        var words: [String] = []
        for part in id.dropFirst(7).split(separator: "-").map(String.init) where !(part.count == 8 && Int(part) != nil)
        {   // not a snapshot's date
            if Int(part) != nil, let prev = words.last, prev.last?.isNumber == true {
                words[words.count - 1] += "." + part
            } else {
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        return words.joined(separator: " ")
    }

    /// Parses a day as the daemon writes it ("2026-10-29", local time) into the start of that day.
    static func date(_ day: String) -> Date { dayFormat.date(from: day) ?? Date() }
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    /// Formats dollars, with cents for amounts under ten.
    nonisolated static func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 10 ? 2 : 0)))
    }
    /// Formats dollars, or "—" for tokens with no price (a model without a list price).
    func money(_ v: Double, _ tokens: Int) -> String { v == 0 && tokens > 0 ? "—" : Self.dollars(v) }
    /// Formats a chart's figure in dollars or tokens, whichever the chart shows.
    func amount(_ v: Double) -> String { byCost ? Self.dollars(v) : count(Int(v)) }
    func count(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }
    func percent(_ part: Int, of whole: Int) -> String {
        UsageView.percent(Double(part) / Double(max(1, whole)))
    }
}
