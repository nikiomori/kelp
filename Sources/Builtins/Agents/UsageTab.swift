import AppKit
import SwiftUI
import Charts
import Core
import DesignKit
import KelpKit

/// "usage:" — what the agents used, a row each: how full its plan is, its days over the span on its own scale, its tokens
/// and what they'd cost at API prices (a subscription bills differently), from its own logs on this Mac. A click on a row
/// narrows the chart and the tables under it to that agent. Window › Usage (⌥⌘U).
@MainActor
final class UsageTab: KelpKit.TabContent {   // not SwiftUI's
    let uri = "usage:"
    let view: NSView
    var title: String { String(localized: "Usage") }
    var icon: NSImage? { .symbol("chart.bar") }
    init(app: AppModel) { view = NSHostingView(rootView: UsageReportView(app: app)) }
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
    @State private var range = 30
    @State private var byCost = true
    @State private var selected: String?
    @State private var hovered: String?
    @State private var usage: UsageAgents.Result?
    @State private var loading = true
    @State private var slow = false
    @State private var failed: String?

    /// The agents whose tokens the daemon reads (`usage.agents`): one that reports a plan but isn't here keeps no counts.
    static let counted: Set = ["claude", "codex", "grok", "antigravity", "kimi", "copilot", "opencode", "kilo", "pi", "omp", "qwen", "gemini"]
    /// Each agent's colour in the charts, the same in every span.
    static let colors: [String: Color] = ["claude": .blue, "grok": .orange, "codex": .purple, "copilot": .teal, "antigravity": .indigo,
                                          "opencode": .green, "kilo": .pink, "pi": .mint, "omp": .yellow, "kimi": .brown, "qwen": .cyan, "gemini": .red]
    /// Agents whose own figure is the cost (the rest are priced from list prices).
    static let ownPrice: Set = ["grok", "pi", "omp", "opencode", "kilo"]

    var body: some View {
        let lines = agentLines(app.plans)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let failed { Text("Couldn't read the usage: \(failed)").foregroundStyle(.secondary) }
                if usage != nil, !lines.isEmpty {   // not "nothing used" while the first reading is under way
                    kpis(lines)
                    table(lines)
                }
                if let usage, !usage.days.isEmpty {
                    detail(usage)
                    HStack(alignment: .top, spacing: 28) {
                        groups(String(localized: "By Model"), (sel.flatMap(agent)?.models ?? usage.models), model: true)
                        groups(String(localized: "By Project"), sel.flatMap(agent)?.projects ?? usage.projects, model: false)
                    }
                } else if !loading, failed == nil {
                    Text("No agent conversations in this time.").foregroundStyle(.secondary)
                }
                Text("""
                    Read from each agent's own logs on this Mac: Claude Code (every account profile), Codex, Grok, Antigravity, Kimi Code, \
                    Copilot, OpenCode, Kilo Code, pi, oh-my-pi, Qwen Code and Gemini CLI. Cursor, Amp and fx keep no token counts on \
                    disk; Droid, Goose, Hermes and Kiro keep only a session's. Tokens include reads from the cache, which cost a tenth \
                    of fresh input. Prices are list prices (Grok's, pi's and OpenCode's as they report them); a subscription bills \
                    differently, and "—" is a model without one.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 1000, alignment: .leading)
        }
        .watchingPlans(app)
        .task(id: range) { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Agents").font(.title3.weight(.semibold))
            Text("Last \(range) days · from each agent's own logs on this Mac").font(.caption).foregroundStyle(.secondary)
            if loading {
                ProgressView().controlSize(.small)
                if slow { Text("Reading the agents' logs — the first time takes a minute.").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Picker("", selection: $range) {
                Text("7 Days").tag(7)
                Text("30 Days").tag(30)
                Text("90 Days").tag(90)
            }
                .pickerStyle(.segmented).fixedSize()
        }
    }

    // MARK: The agents

    /// The agents that used anything in the span, the most expensive first, then those that only report a plan.
    private func agentLines(_ plans: [String: Plan]) -> [Line] {
        let used = (usage?.agents ?? []).filter { $0.tokens > 0 }
        let rest = app.catalog.installed(app.catalog.all).map(\.id).filter { id in plans[id] != nil && !used.contains { $0.id == id } }
        return used.map { Line(id: $0.id, usage: $0, plan: plans[$0.id]) } + rest.map { Line(id: $0, usage: nil, plan: plans[$0]) }
    }

    /// The chosen agent while it has anything in the span.
    private var sel: String? { selected.flatMap { s in agent(s) == nil ? nil : s } }
    private func agent(_ id: String) -> UsageAgents.Agent? { usage?.agents.first { $0.id == id && $0.tokens > 0 } }
    private var series: [UsageAgents.Agent] { (usage?.agents ?? []).filter { $0.tokens > 0 && (sel == nil || $0.id == sel) } }
    private func value(_ d: UsageAgents.Day) -> Double { byCost ? d.cost : Double(d.tokens) }
    private func color(_ id: String) -> Color { Self.colors[id] ?? .gray }

    private func kpis(_ lines: [Line]) -> some View {
        let s = series, cost = s.reduce(0) { $0 + $1.cost }, tokens = s.reduce(0) { $0 + $1.tokens }
        let cached = s.reduce(0) { $0 + $1.cacheRead }, ids = Set(s.map(\.id))
        let active = Set((usage?.days ?? []).filter { ids.contains($0.agent) && $0.tokens > 0 }.map(\.day)).count
        return HStack(spacing: 32) {
            stat(money(cost, tokens), String(localized: "at API prices"))
            stat(count(tokens), String(localized: "tokens · \(percent(cached, of: tokens)) from cache"))
            stat(money(cost / Double(max(1, active)), 0), String(localized: "per active day"))
            if sel != nil { stat("\(active)", String(localized: "active days")) }
            else { stat(String(localized: "\(lines.filter { $0.usage != nil }.count) of \(lines.count)"), String(localized: "agents used")) }
        }
    }

    private func table(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            columns(Text("Agent"), Text("Plan"), Text("Last \(range) days"), Text("Tokens"), Text("At API prices"))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
            Divider()
            ForEach(lines) { row($0) }
        }
    }

    /// agent | plan | the span | tokens | cost, the same widths in every row.
    private func columns(_ agent: some View, _ plan: some View, _ span: some View, _ tokens: some View, _ cost: some View) -> some View {
        HStack(spacing: 16) {
            agent.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            plan.frame(width: 170, alignment: .leading)
            span.frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            tokens.frame(width: 88, alignment: .trailing)
            cost.frame(width: 88, alignment: .trailing)
        }
    }

    /// A row narrows what's under the table to its agent (again: back to all); one with nothing counted isn't a button.
    @ViewBuilder private func row(_ l: Line) -> some View {
        let on = sel == l.id
        let content = columns(agentCell(l), planCell(l.plan), spanCell(l), tokensCell(l.usage), costCell(l.usage))
            .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        if l.usage == nil { content }
        else {
            Button { selected = on ? nil : l.id } label: { content }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                    .fill(Color(nsColor: on ? .fillSelected : hovered == l.id ? .fillHover : .clear)))
                .onHover { hovered = $0 ? l.id : (hovered == l.id ? nil : hovered) }
                .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovered)
                .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    private func agentCell(_ l: Line) -> some View {
        HStack(spacing: 8) {
            if let icon = app.catalog.icon(l.id) { Image(nsImage: icon) }
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(app.catalog.name(l.id)).lineLimit(1)
                if let models = l.usage?.models.prefix(2), !models.isEmpty {
                    Text(models.map { Self.model($0.name) }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    /// Its fullest limit with a bar, when that resets and the next fullest; every limit on hover. An old reading is faded and says so.
    @ViewBuilder private func planCell(_ plan: Plan?) -> some View {
        if let plan, let top = plan.limits.first {
            let stale = plan.readAt.map { Date().timeIntervalSince($0) > 1800 } ?? false
            let note = stale ? String(localized: "Read \(shortAgo(plan.readAt)) ago")
                : ([top.label + (top.resets.map { String(localized: " · resets \($0)") } ?? "")]
                   + plan.limits.dropFirst().prefix(1).map { "\($0.label) \(percent($0.used))" }).joined(separator: " · ")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(tint(top.used, quiet: .secondary)).frame(width: max(4, g.size.width * min(top.used, 1)))
                        }
                    }
                    .frame(height: 4)
                    Text(percent(top.used)).monospacedDigit().foregroundStyle(top.used >= 0.9 ? Color.textRed : top.used >= 0.7 ? .textOrange : .primary)
                }
                Text(note).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption)
            .opacity(stale ? 0.55 : 1)
            .help(plan.limits.map { l in "\(l.label): \(percent(l.used))" + (l.resets.map { String(localized: ", resets \($0)") } ?? "") }
                .joined(separator: "\n"))
        } else {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// Its days on its own scale, so a small agent's pattern shows beside a big one's (tokens when it costs nothing).
    @ViewBuilder private func spanCell(_ l: Line) -> some View {
        if let usage, let a = l.usage {
            Chart(usage.days.filter { $0.agent == l.id }, id: \.self) { d in
                BarMark(x: .value("Day", Self.date(d.day), unit: .day), y: .value("Used", a.cost > 0 ? value(d) : Double(d.tokens)))
                    .foregroundStyle(color(l.id))
            }
            .chartXScale(domain: span(usage)).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .frame(height: 26)
            .overlay(alignment: .bottom) { Rectangle().fill(.quaternary).frame(height: 1) }
        } else {
            Text(Self.counted.contains(l.id) ? String(localized: "Not used in this time") : String(localized: "Keeps no token counts on this Mac"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func tokensCell(_ a: UsageAgents.Agent?) -> some View {
        VStack(alignment: .trailing, spacing: Metrics.lineGap) {
            Text(a.map { count($0.tokens) } ?? "—").monospacedDigit()
            if let a, a.cacheRead > 0 { Text("\(percent(a.cacheRead, of: a.tokens)) from cache").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func costCell(_ a: UsageAgents.Agent?) -> some View {
        VStack(alignment: .trailing, spacing: Metrics.lineGap) {
            Text(a.map { money($0.cost, $0.tokens) } ?? "—").monospacedDigit()
            if let a, a.cost == 0 { Text("no list price").font(.caption).foregroundStyle(.secondary) }
            else if let a, Self.ownPrice.contains(a.id) { Text("as it reports").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Under the table

    /// Cost or tokens a day, stacked by agent (or the chosen one's alone).
    private func detail(_ usage: UsageAgents.Result) -> some View {
        let ids = series.map(\.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                let who = sel.map { app.catalog.name($0) } ?? String(localized: "All agents")
                Text(byCost ? String(localized: "\(who) · cost per day") : String(localized: "\(who) · tokens per day"))
                    .font(.system(size: TextSize.of(13), weight: .semibold))
                if sel != nil { Button("Show All") { selected = nil }.controlSize(.small) }
                Spacer()
                Picker("", selection: $byCost) {
                    Text("Cost").tag(true)
                    Text("Tokens").tag(false)
                }
                    .pickerStyle(.segmented).fixedSize()
            }
            Chart(usage.days.filter { ids.contains($0.agent) }, id: \.self) { d in
                BarMark(x: .value("Day", Self.date(d.day), unit: .day), y: .value(byCost ? "Cost" : "Tokens", value(d)))
                    .foregroundStyle(by: .value("Agent", app.catalog.name(d.agent)))
            }
            .chartForegroundStyleScale(domain: ids.map { app.catalog.name($0) }, range: ids.map(color))
            .chartXScale(domain: span(usage))
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel { if let x = v.as(Double.self) { Text(byCost ? money(x, 0) : count(Int(x))) } }
                }
            }
            .frame(height: 180)
        }
    }

    /// The span's days, the first to today's.
    private func span(_ usage: UsageAgents.Result) -> ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: usage.since))
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return start...max(start, end)
    }

    /// A model's dot is its agent's colour (the chosen agent's when there is one).
    private func groups(_ title: String, _ rows: [UsageReport.Group], model: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: TextSize.of(13), weight: .semibold))
            ForEach(rows.prefix(8), id: \.name) { r in
                HStack(spacing: 8) {
                    if model, let owner = sel ?? series.first(where: { $0.models.contains { $0.name == r.name } })?.id {
                        Circle().fill(color(owner)).frame(width: 6, height: 6)
                    }
                    Text(model ? Self.model(r.name) : r.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(count(r.tokens)).foregroundStyle(.secondary).monospacedDigit()
                    Text(money(r.cost, r.tokens)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }.font(.callout)
                Divider()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        loading = true; slow = false
        let hint = Task { try? await Task.sleep(for: .seconds(3)); if loading { slow = true } }
        defer { hint.cancel() }
        let read = await app.tryCall(UsageAgents(days: range))
        failed = read.error
        if let r = read.value { usage = r }
        loading = false
    }

    // MARK: Formats

    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5", as Claude Code names them; the other
    /// agents' models as they write them.
    static func model(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        var words: [String] = []
        for p in id.dropFirst(7).split(separator: "-").map(String.init) where !(p.count == 8 && Int(p) != nil) {   // not a snapshot's date
            if Int(p) != nil, let prev = words.last, prev.last?.isNumber == true { words[words.count - 1] += "." + p }
            else { words.append(p.prefix(1).uppercased() + p.dropFirst()) }
        }
        return words.joined(separator: " ")
    }

    static func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day) ?? Date()
    }
    /// "—" for tokens with no price (a model without a list price).
    private func money(_ v: Double, _ tokens: Int) -> String {
        v == 0 && tokens > 0 ? "—" : v.formatted(.currency(code: "USD").precision(.fractionLength(v < 10 ? 2 : 0)))
    }
    private func count(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }
    private func percent(_ part: Int, of whole: Int) -> String { percent(Double(part) / Double(max(1, whole))) }
    private func percent(_ used: Double) -> String { "\(Int((used * 100).rounded()))%" }
    private func tint(_ u: Double, quiet: Color) -> Color { u >= 0.9 ? .red : u >= 0.7 ? .orange : quiet }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
