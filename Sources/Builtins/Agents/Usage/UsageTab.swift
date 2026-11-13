import AppKit
import Charts
import Core
import DesignKit
import KelpKit
import SwiftUI

/// "usage:" — the agents' plans now, each limit with when it runs out at its pace; then what they used over a span, a row
/// each: its days on its own scale, its share of the cost, its tokens and what they'd cost at API prices (a subscription
/// bills differently), from its own logs on this Mac. A click on a row or a project narrows what's under it to that one.
/// Window › Usage (⌥⌘U).
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
    /// An agent's row: what it used in the span (nil: nothing counted).
    struct Line: Identifiable {
        let id: String
        let usage: UsageAgents.Agent?
    }
    @State var range = 30
    @State var byCost = true
    @State var selected: String?
    /// The project the page is narrowed to (a name from the span's projects).
    @State var project: String?
    @State var hovered: String?
    @State var showFree = false
    @State var allModels = false
    @State var allProjects = false
    /// The day under the pointer in the chart.
    @State var day: Date?
    @State var usage: UsageAgents.Result?
    @State private var loading = true
    @State private var failed: String?
    @State private var showSources = false
    /// The last year's days, for the months (read once a project, after the span's).
    @State private var year: [UsageAgents.Day] = []
    @State private var yearFor: String?

    /// The charts' colours, by an agent's place among those the daemon counts: the same in every span.
    static let palette: [Color] = [
        .blue, .purple, .orange, .brown, .mint, .yellow, .cyan, .red, .teal, .green, .pink, .indigo
    ]

    var body: some View {
        let lines = agentLines(UsageView.plans(app).keys)
        // As wide as the pane up to 1400, and the table's own width at least: a narrower pane scrolls sideways, from the left.
        GeometryReader { pane in
            ScrollView([.vertical, .horizontal]) {
                page(lines).padding([.horizontal, .bottom], 24).frame(
                    width: min(max(pane.size.width, 700), 1400), alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
        }
        .watchingPlans(app)
        .task(id: "\(range)|\(project ?? "")") { await load() }
    }

    private func page(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            // The plans first: whether work can go on now. They don't depend on the span, so they stand over its picker.
            PlanCards(app: app, unplanned: unplanned)
            VStack(alignment: .leading, spacing: 18) {
                period
                if let failed { Text("Couldn't read the usage: \(failed)").foregroundStyle(.secondary) }
                // The figures fill in as the logs are read.
                if usage != nil, !lines.isEmpty { kpis() }
                if !lines.isEmpty { table(lines) }
            }
            if let usage, !usage.days.isEmpty {
                detail(usage)
                if !year.isEmpty { months }
                HStack(alignment: .top, spacing: 36) {
                    groups(
                        String(localized: "By Model"), sel.flatMap(agent)?.models ?? usage.models, all: $allModels,
                        model: true)
                    groups(
                        String(localized: "By Project"), sel.flatMap(agent)?.projects ?? usage.projects,
                        all: $allProjects, model: false)
                }
            } else if !loading, failed == nil {
                Text("No agent conversations in this time.").foregroundStyle(.secondary)
            }
            if usage != nil { footnote }
        }
    }

    /// Where the figures come from, in the band other tabs give their bar: banners start under it.
    private var header: some View {
        HStack(spacing: Metrics.gapWide) {
            Text("From each agent's own logs and /usage on this Mac").font(.ui(TextSize.caption)).foregroundStyle(
                .secondary)
            Spacer()
        }
        .frame(height: TextSize.of(Metrics.contentBar))
    }

    /// The span, what the page is narrowed to, and the span's picker.
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
                .controlSize(.small)
            }
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Picker("", selection: $range) {
                Text("7 Days").tag(7)
                Text("30 Days").tag(30)
                Text("90 Days").tag(90)
            }
            .pickerStyle(.segmented).controlSize(.small).fixedSize()
        }
    }

    /// One line; the agents read and left out on request.
    private var footnote: some View {
        HStack(spacing: 4) {
            Text("Prices are API list prices: a plan bills differently.")
            Button("Which agents are counted") { showSources.toggle() }
                .buttonStyle(.link)
                .popover(isPresented: $showSources, arrowEdge: .top) {
                    Text(Self.sources)
                        .font(.ui(TextSize.caption)).fixedSize(horizontal: false, vertical: true)
                        .frame(width: 340, alignment: .leading).padding(12)
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

    /// Cost or tokens a day over the span stacked by agent (the chosen one's alone), the span's average dashed across it,
    /// and the day under the pointer by agent.
    private func detail(_ usage: UsageAgents.Result) -> some View {
        let ids = series.map(\.id)
        // Only those with a bar, in the legend too: a free agent has none in Cost (and a mark outside the colour scale's
        // domain traps in Charts).
        let drawn = ids.filter { id in usage.days.contains { $0.agent == id && value($0) > 0 } }
        let records = usage.days.filter { drawn.contains($0.agent) }
        let average = records.reduce(0) { $0 + value($1) } / Double(range)
        let pointed = day.map { Calendar.current.startOfDay(for: $0) }
        return VStack(alignment: .leading, spacing: Metrics.gapWide) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
                Text("Per day").font(.ui(TextSize.body, weight: .semibold))
                Text("the dashed line is the average").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $byCost) {
                    Text("Cost").tag(true)
                    Text("Tokens").tag(false)
                }
                .pickerStyle(.segmented).controlSize(.small).fixedSize()
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
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) · \(amount(total))")
                .fontWeight(.semibold)
            ForEach(records.sorted { value($0) > value($1) }, id: \.self) { record in
                HStack(spacing: 6) {
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

    /// The last 12 months, a bar each, for the agents (the chosen one); what it all came to over them.
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

    /// The span's days, the first to today's.
    func span(_ usage: UsageAgents.Result) -> ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: usage.since))
        let end =
            Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return start...max(start, end)
    }

    /// Eight rows with their share of the first, then the rest on request. A model's dot is its agent's colour; a project
    /// narrows the page to it (again: back to all).
    private func groups(_ title: String, _ rows: [UsageReport.Group], all: Binding<Bool>, model: Bool) -> some View {
        let top = rows.first.map { $0.cost > 0 ? $0.cost : Double($0.tokens) } ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(TextSize.body, weight: .semibold))
            ForEach(all.wrappedValue ? rows : Array(rows.prefix(8)), id: \.name) { group in
                let content = HStack(spacing: 8) {
                    if model {
                        let owner = sel ?? series.first(where: { $0.models.contains { $0.name == group.name } })?.id
                        Circle().fill(owner.map(color) ?? .clear).frame(width: 6, height: 6)
                    }
                    Text(model ? Self.model(group.name) : group.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    MeterBar(
                        share: (group.cost > 0 ? group.cost : Double(group.tokens)) / max(top, 1),
                        tint: Color(nsColor: .tertiaryLabelColor), height: 3
                    )
                    .frame(width: 120)
                    Text(count(group.tokens)).foregroundStyle(.secondary).monospacedDigit().frame(
                        width: 56, alignment: .trailing)
                    Text(money(group.cost, group.tokens)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }
                .font(.ui(TextSize.row)).padding(.vertical, 3).padding(.horizontal, 4).contentShape(Rectangle())
                if model {
                    content
                } else {
                    Button {
                        project = project == group.name ? nil : group.name
                    } label: {
                        content
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusXS).fill(
                            Color(
                                nsColor: project == group.name
                                    ? .fillSelected : hovered == "project:" + group.name ? .fillHover : .clear))
                    )
                    .onHover { hovered = $0 ? "project:" + group.name : nil }
                }
                Divider()
            }
            if rows.count > 8 {
                Button(
                    all.wrappedValue
                        ? String(localized: "Show Fewer") : String(localized: "Show All \(rows.count)")
                ) { all.wrappedValue.toggle() }
                .buttonStyle(.link).font(.ui(TextSize.caption))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        loading = true
        let read = await app.tryCall(UsageAgents(days: range, project: project))
        failed = read.error
        if let fresh = read.value { usage = fresh }
        loading = false
        // The months once the span's figures are in: both wait on the same logs, and the table is what's asked for first.
        let key = project ?? ""
        if yearFor != key {
            year = await app.quiet(UsageAgents(days: 371, project: project), timeout: 330)?.days ?? []
            yearFor = key
        }
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
    /// Dollars, with cents under ten.
    nonisolated static func dollars(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(v < 10 ? 2 : 0)))
    }
    /// "—" for tokens with no price (a model without a list price).
    func money(_ v: Double, _ tokens: Int) -> String { v == 0 && tokens > 0 ? "—" : Self.dollars(v) }
    /// A chart's figure: dollars or tokens, as the chart shows.
    func amount(_ v: Double) -> String { byCost ? Self.dollars(v) : count(Int(v)) }
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
