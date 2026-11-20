// The agents in the usage report: their lines, the totals over them, and the table's columns and cells.
import AppKit
import Charts
import Core
import DesignKit
import KelpKit
import SwiftUI

extension UsageReportView {
    // MARK: The agents

    /// The agents that used anything in the span, the most expensive first, then those that only report a plan.
    func agentLines(_ planned: some Collection<String>) -> [Line] {
        let used = (usage?.agents ?? []).filter { $0.tokens > 0 }
        let rest = app.catalog.installed.map(\.id).filter { id in
            planned.contains(id) && !used.contains { $0.id == id }
        }
        return used.map { Line(id: $0.id, usage: $0) } + rest.map { Line(id: $0, usage: nil) }
    }

    /// The agents used in the span that report no plan limits, by name.
    var unplanned: [String] {
        let planned = UsageView.rows(app).map(\.id)
        return (usage?.agents ?? []).filter { $0.tokens > 0 && !planned.contains($0.id) }.map {
            app.catalog.name($0.id)
        }
    }

    /// The chosen agent, as long as it used anything in the span.
    var sel: String? { selected.flatMap { s in agent(s) == nil ? nil : s } }
    func agent(_ id: String) -> UsageAgents.Agent? { usage?.agents.first { $0.id == id && $0.tokens > 0 } }
    var series: [UsageAgents.Agent] {
        (usage?.agents ?? []).filter { $0.tokens > 0 && (sel == nil || $0.id == sel) }
    }
    func value(_ day: UsageAgents.Day) -> Double { byCost ? day.cost : Double(day.tokens) }
    func color(_ id: String) -> Color {
        usage?.counted?.firstIndex(of: id).map { Self.palette[$0 % Self.palette.count] } ?? .gray
    }

    /// The headline figures: the span's cost against the span before it, the cost per active day, the tokens, and what
    /// kind of token the cost went on.
    func kpis() -> some View {
        let shown = series, cost = shown.reduce(0) { $0 + $1.cost }, tokens = shown.reduce(0) { $0 + $1.tokens }
        let cached = shown.reduce(0) { $0 + $1.cacheRead }, ids = Set(shown.map(\.id))
        let active = Set((usage?.days ?? []).filter { ids.contains($0.agent) && $0.tokens > 0 }.map(\.day)).count
        let before = usage?.previous.map { $0.filter { ids.contains($0.name) }.reduce(0) { $0 + $1.cost } }
        let costs = shown.compactMap(\.costs)
        // The figures stand on one plate with a rule between neighbours, because together they answer one question.
        return HStack(alignment: .top, spacing: 0) {
            stat(money(cost, tokens), Self.change(cost, before: before, days: range))
            Divider()
            stat(
                money(cost / Double(max(1, active)), 0),
                String(localized: "per active day · \(active) of \(range) days"))
            Divider()
            stat(count(tokens), String(localized: "tokens · \(percent(cached, of: tokens)) read from cache"))
            if let first = costs.first {
                Divider()
                CostSplit(costs: costs.dropFirst().reduce(first, +)).padding(Metrics.inset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // across the page, as the table under it
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous).fill(Color(nsColor: .fillRest)))
    }

    /// One of the plate's figures: a number over what it counts, inset from the plate's edge and the rules.
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ui(TextSize.title, weight: .semibold).monospacedDigit())
            Text(label).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
        }
        .padding(Metrics.inset)
    }

    /// Returns the line under the cost, such as "at API prices · +139% on the 30 days before ($5,058)".
    nonisolated static func change(_ cost: Double, before: Double?, days: Int) -> String {
        let label = String(localized: "at API prices")
        guard let before, cost > 0 || before > 0 else { return label }
        guard before > 0 else { return label + String(localized: " · nothing the \(days) days before") }
        let change = Int(((cost / before - 1) * 100).rounded())
        return label
            + String(localized: " · \(change > 0 ? "+" : "")\(change)% on the \(days) days before (\(dollars(before)))")
    }

    /// The agents in the span as the system's table (`UsageAgentTable`): the ones with a cost, then those with no list
    /// price (two or more fold into one row that names them), then those with nothing counted. A chosen row narrows
    /// what's under the table to that agent.
    func table(_ lines: [Line]) -> some View {
        let sorted = Self.sorted(
            lines, by: agentOrder, names: Dictionary(lines.map { ($0.id, app.catalog.name($0.id)) }) { a, _ in a })
        let paid = sorted.filter { ($0.usage?.cost ?? 0) > 0 }
        let free = sorted.filter { $0.usage != nil && $0.usage?.cost == 0 }
        let rest = sorted.filter { $0.usage == nil }
        let total = paid.reduce(0) { $0 + ($1.usage?.cost ?? 0) }
        var items = paid.map { UsageAgentTable.Item(id: $0.id) }
        var cells = Dictionary(sorted.map { ($0.id, self.cells($0, total: total)) }) { a, _ in a }
        if free.count > 1 {
            items.append(.init(id: Self.freeRow, children: free.map { .init(id: $0.id) }, picks: false))
            cells[Self.freeRow] = freeCells(free)
        } else {
            items += free.map { .init(id: $0.id) }
        }
        items += rest.map { .init(id: $0.id, picks: false) }
        let figures = sorted.map { "\($0.id):\($0.usage?.cost ?? -1):\($0.usage?.tokens ?? -1)" }.joined(separator: ",")
        return UsageAgentTable(
            items: items, cells: cells,
            stamp: "\(range) \(byCost) \(usage == nil) \(usage?.since ?? 0) \(project ?? "") \(agentOrder) \(figures)",
            spanTitle: String(localized: "Last \(range) days"), selected: $selected, order: $agentOrder)
    }
    private static let freeRow = "\u{1F}free"

    /// The agents by the column the table's header names. An agent with nothing counted sorts as nothing; equal ones
    /// keep the order they came in, the most expensive first.
    nonisolated static func sorted(_ lines: [Line], by order: AgentOrder, names: [String: String]) -> [Line] {
        let before: (Line, Line) -> Bool =
            switch order.by {
            case .agent:
                { (names[$0.id] ?? $0.id).localizedStandardCompare(names[$1.id] ?? $1.id) == .orderedAscending }
            case .tokens: { ($0.usage?.tokens ?? -1) < ($1.usage?.tokens ?? -1) }
            case .cost: { ($0.usage?.cost ?? -1) < ($1.usage?.cost ?? -1) }
            }
        let places = Dictionary(lines.enumerated().map { ($1.id, $0) }) { a, _ in a }
        return lines.sorted { left, right in
            let (first, second) = order.ascending ? (left, right) : (right, left)
            if before(first, second) { return true }
            return before(second, first) ? false : (places[left.id] ?? 0) < (places[right.id] ?? 0)
        }
    }

    /// A row's cells in the columns' order. While the logs are still read, grey placeholders stand in for the figures.
    private func cells(_ line: Line, total: Double) -> [AnyView] {
        guard usage != nil else {
            return [cell(agentCell(line))] + (0..<4).map { cell(Self.reading, trailing: $0 > 1) }
        }
        return [
            cell(agentCell(line)), cell(spanCell(line)), cell(shareCell(line.usage, total: total)),
            cell(tokensCell(line.usage), trailing: true), cell(costCell(line.usage), trailing: true)
        ]
    }

    /// The agents with no list price as one row: their icons, their names and their tokens added up.
    private func freeCells(_ free: [Line]) -> [AnyView] {
        let tokens = free.reduce(0) { $0 + ($1.usage?.tokens ?? 0) }
        let names = free.map { app.catalog.name($0.id) }.joined(separator: ", ")
        let agents = HStack(spacing: 8) {
            HStack(spacing: -4) {
                ForEach(free) { line in
                    if let icon = app.catalog.icon(line.id) { Image(nsImage: icon) }
                }
            }
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text("\(free.count) agents with no list price").lineLimit(1)
                Text(names).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(names)
        return [
            cell(agents), cell(Color.clear.frame(height: 1)),
            cell(Text("no list price").font(.ui(TextSize.caption)).foregroundStyle(.secondary)),
            cell(Text(count(tokens)).monospacedDigit(), trailing: true),
            cell(Text(verbatim: "—").foregroundStyle(.secondary), trailing: true)
        ]
    }

    /// A cell's view at its column's edge, in a row's text: a name, a count or a cost has no size of its own, and the
    /// captions keep theirs.
    func cell(_ view: some View, trailing: Bool = false) -> AnyView {
        AnyView(
            view.font(.ui(TextSize.row)).frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading))
    }

    /// A grey placeholder for a figure not read yet.
    private static var reading: some View {
        Text(verbatim: "0000").font(.ui(TextSize.caption)).redacted(reason: .placeholder)
    }

    private func agentCell(_ line: Line) -> some View {
        HStack(spacing: 8) {
            if let icon = app.catalog.icon(line.id) { Image(nsImage: icon) }
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(app.catalog.name(line.id)).lineLimit(1)
                if let models = line.usage?.models.prefix(2), !models.isEmpty {
                    Text(models.map { Self.model($0.name) }.joined(separator: " · ")).font(.ui(TextSize.caption))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    /// The agent's share of the span's cost, as a bar in its colour. The percent has one decimal, so an agent at
    /// 99.8 % still shows that the rest come to something.
    @ViewBuilder private func shareCell(_ agentUsage: UsageAgents.Agent?, total: Double) -> some View {
        if let agentUsage, agentUsage.cost > 0, total > 0 {
            let share = agentUsage.cost / total
            HStack(spacing: 8) {
                MeterBar(share: share, tint: color(agentUsage.id))
                Text(
                    share < 0.001
                        ? "<0.1%" : share.formatted(.percent.precision(.fractionLength(1)))
                )
                .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            .font(.ui(TextSize.caption))
        } else if agentUsage != nil {
            Text("no list price").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
        } else {
            Text(verbatim: "—").font(.ui(TextSize.caption)).foregroundStyle(.tertiary)
        }
    }

    /// The agent's days as a chart on its own scale, so a small agent's pattern shows beside a big one's. It charts
    /// tokens when the agent costs nothing.
    @ViewBuilder private func spanCell(_ line: Line) -> some View {
        if let usage, let agentUsage = line.usage {
            Chart(usage.days.filter { $0.agent == line.id }, id: \.self) { record in
                BarMark(
                    x: .value("Day", Self.date(record.day), unit: .day),
                    y: .value("Used", agentUsage.cost > 0 ? value(record) : Double(record.tokens))
                )
                .foregroundStyle(color(line.id))
            }
            .chartXScale(domain: span(usage)).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .frame(height: 26)
            .overlay(alignment: .bottom) { Rectangle().fill(.quaternary).frame(height: 1) }
        } else {
            Text(
                usage?.counted?.contains(line.id) ?? true
                    ? String(localized: "Not used in this time")
                    : String(localized: "Keeps no token counts on this Mac")
            )
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func tokensCell(_ agentUsage: UsageAgents.Agent?) -> some View {
        VStack(alignment: .trailing, spacing: Metrics.lineGap) {
            Text(agentUsage.map { count($0.tokens) } ?? "—").monospacedDigit()
            if let agentUsage, agentUsage.cacheRead > 0 {
                Text("\(percent(agentUsage.cacheRead, of: agentUsage.tokens)) from cache").font(.ui(TextSize.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func costCell(_ agentUsage: UsageAgents.Agent?) -> some View {
        VStack(alignment: .trailing, spacing: Metrics.lineGap) {
            Text(agentUsage.map { money($0.cost, $0.tokens) } ?? "—").monospacedDigit()
            if let agentUsage, agentUsage.cost > 0, usage?.ownPrice?.contains(agentUsage.id) == true {
                Text("as it reports").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows what kind of token the cost went on. Reading the cache is most of a long chat's bill, and writing the cache
/// is much of the rest.
struct CostSplit: View {
    let costs: UsageAgents.Costs

    var body: some View {
        let parts = Self.parts(costs), total = parts.reduce(0) { $0 + $1.cost }
        VStack(alignment: .leading, spacing: 6) {
            Text("Where the cost goes").foregroundStyle(.secondary)
            GeometryReader { geometry in
                let room = geometry.size.width - CGFloat(max(0, parts.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(parts, id: \.name) { part in
                        Rectangle().fill(part.color).frame(width: room * part.cost / max(total, .ulpOfOne))
                    }
                }
            }
            .frame(height: 6).clipShape(Capsule())
            // The parts sit two to a row, because four in a row were cut short at the figures' width.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                ForEach(Array(stride(from: 0, to: parts.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(parts[start..<min(start + 2, parts.count)], id: \.name) { part in
                            HStack(spacing: 4) {
                                Circle().fill(part.color).frame(width: 6, height: 6)
                                Text("\(part.name) \(Self.share(part.cost, of: total))").fixedSize()
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.ui(TextSize.caption))
        .frame(minWidth: 240, maxWidth: 380, alignment: .leading)
    }

    static func parts(_ costs: UsageAgents.Costs) -> [(name: String, cost: Double, color: Color)] {
        [
            (String(localized: "Cache reads"), costs.cacheRead, .blue),
            (String(localized: "Cache writes"), costs.cacheWrite, .cyan),
            (String(localized: "Output"), costs.output, .purple), (String(localized: "Input"), costs.input, .gray)
        ]
        .filter { $0.cost > 0 }
    }

    nonisolated static func share(_ part: Double, of total: Double) -> String {
        guard total > 0 else { return "0%" }
        let share = part / total
        return share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }
}
