// The usage report's agents: their lines, the totals over them, and the table's columns and cells.
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
        let rest = app.catalog.installed(app.catalog.all).map(\.id).filter { id in
            planned.contains(id) && !used.contains { $0.id == id }
        }
        return used.map { Line(id: $0.id, usage: $0) } + rest.map { Line(id: $0, usage: nil) }
    }

    /// The agents used in the span that report no plan limits, by name.
    var unplanned: [String] {
        let planned = UsageView.plans(app).keys
        return (usage?.agents ?? []).filter { $0.tokens > 0 && !planned.contains($0.id) }.map {
            app.catalog.name($0.id)
        }
    }

    /// The chosen agent while it has anything in the span.
    var sel: String? { selected.flatMap { s in agent(s) == nil ? nil : s } }
    func agent(_ id: String) -> UsageAgents.Agent? { usage?.agents.first { $0.id == id && $0.tokens > 0 } }
    var series: [UsageAgents.Agent] {
        (usage?.agents ?? []).filter { $0.tokens > 0 && (sel == nil || $0.id == sel) }
    }
    func value(_ d: UsageAgents.Day) -> Double { byCost ? d.cost : Double(d.tokens) }
    func color(_ id: String) -> Color {
        usage?.counted?.firstIndex(of: id).map { Self.palette[$0 % Self.palette.count] } ?? .gray
    }

    /// The span's cost against the one before it, the cost a day, the tokens, and what kind of token the cost went on.
    func kpis() -> some View {
        let shown = series, cost = shown.reduce(0) { $0 + $1.cost }, tokens = shown.reduce(0) { $0 + $1.tokens }
        let cached = shown.reduce(0) { $0 + $1.cacheRead }, ids = Set(shown.map(\.id))
        let active = Set((usage?.days ?? []).filter { ids.contains($0.agent) && $0.tokens > 0 }.map(\.day)).count
        let before = usage?.previous.map { $0.filter { ids.contains($0.name) }.reduce(0) { $0 + $1.cost } }
        let costs = shown.compactMap(\.costs)
        return HStack(alignment: .top, spacing: 36) {
            stat(money(cost, tokens), Self.change(cost, before: before, days: range))
            stat(
                money(cost / Double(max(1, active)), 0),
                String(localized: "per active day · \(active) of \(range) days"))
            stat(count(tokens), String(localized: "tokens · \(percent(cached, of: tokens)) read from cache"))
            if let first = costs.first { CostSplit(costs: costs.dropFirst().reduce(first, +)) }
        }
    }

    /// "at API prices · +139% on the 30 days before ($5,058)".
    nonisolated static func change(_ cost: Double, before: Double?, days: Int) -> String {
        let label = String(localized: "at API prices")
        guard let before, cost > 0 || before > 0 else { return label }
        guard before > 0 else { return label + String(localized: " · nothing the \(days) days before") }
        let change = Int(((cost / before - 1) * 100).rounded())
        return label
            + String(localized: " · \(change > 0 ? "+" : "")\(change)% on the \(days) days before (\(dollars(before)))")
    }

    func table(_ lines: [Line]) -> some View {
        let paid = lines.filter { ($0.usage?.cost ?? 0) > 0 }
        let free = lines.filter { $0.usage != nil && $0.usage?.cost == 0 }
        let rest = lines.filter { $0.usage == nil }
        let total = paid.reduce(0) { $0 + ($1.usage?.cost ?? 0) }
        return VStack(alignment: .leading, spacing: 2) {
            columns(
                Text("Agent"), Text("Last \(range) days"), Text("Share of cost"), Text("Tokens"), Text("At API prices")
            )
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary).padding(.horizontal, Metrics.inset).padding(
                .bottom, 4)
            Divider()
            ForEach(paid) { row($0, total: total) }
            // Two or more with no list price fold into one row that names them; a click opens them.
            if free.count > 1 { freeRow(free) }
            if free.count == 1 || showFree { ForEach(free) { row($0, total: total) } }
            ForEach(rest) { row($0, total: total) }
        }
    }

    /// agent | the span | share | tokens | cost, the same widths in every row.
    private func columns(
        _ agent: some View, _ span: some View, _ share: some View, _ tokens: some View, _ cost: some View
    ) -> some View {
        HStack(spacing: 16) {
            agent.frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
            span.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            share.frame(width: 170, alignment: .leading)
            tokens.frame(width: 96, alignment: .trailing)
            cost.frame(width: 96, alignment: .trailing)
        }
    }

    /// A row narrows what's under the table to its agent (again: back to all); one with nothing counted isn't a button.
    @ViewBuilder private func row(_ l: Line, total: Double) -> some View {
        let on = sel == l.id
        let content = cells(l, total: total)
            .padding(.horizontal, Metrics.inset).padding(.vertical, Metrics.gap).contentShape(Rectangle())
        if l.usage == nil {
            content
        } else {
            Button {
                selected = on ? nil : l.id
            } label: {
                content
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                    .fill(Color(nsColor: on ? .fillSelected : hovered == l.id ? .fillHover : .clear))
            )
            .onHover { hovered = $0 ? l.id : (hovered == l.id ? nil : hovered) }
            .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovered)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    /// The agents with no list price as one row: their icons and names, their tokens together.
    private func freeRow(_ free: [Line]) -> some View {
        let tokens = free.reduce(0) { $0 + ($1.usage?.tokens ?? 0) }
        return Button {
            showFree.toggle()
        } label: {
            columns(
                HStack(spacing: 8) {
                    Image(systemName: showFree ? "chevron.down" : "chevron.right").font(.ui(TextSize.micro))
                        .foregroundStyle(.secondary).frame(width: 10)
                    HStack(spacing: -4) {
                        ForEach(free) { line in
                            if let icon = app.catalog.icon(line.id) { Image(nsImage: icon) }
                        }
                    }
                    VStack(alignment: .leading, spacing: Metrics.lineGap) {
                        Text("\(free.count) agents with no list price").lineLimit(1)
                        Text(free.map { app.catalog.name($0.id) }.joined(separator: ", ")).font(.ui(TextSize.caption))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                },
                Color.clear.frame(height: 1),
                Text("no list price").font(.ui(TextSize.caption)).foregroundStyle(.secondary),
                Text(count(tokens)).monospacedDigit(),
                Text(verbatim: "—").foregroundStyle(.secondary)
            )
            .padding(.horizontal, Metrics.inset).padding(.vertical, Metrics.gap).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .fill(Color(nsColor: hovered == "free" ? .fillHover : .clear))
        )
        .onHover { hovered = $0 ? "free" : (hovered == "free" ? nil : hovered) }
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func cells(_ l: Line, total: Double) -> some View {
        if usage == nil {   // its logs still being read: grey where the figures will be
            columns(agentCell(l), Self.reading, Self.reading, Self.reading, Self.reading)
        } else {
            columns(agentCell(l), spanCell(l), shareCell(l.usage, total: total), tokensCell(l.usage), costCell(l.usage))
        }
    }

    /// A figure not read yet.
    private static var reading: some View {
        Text(verbatim: "0000").font(.ui(TextSize.caption)).redacted(reason: .placeholder)
    }

    private func agentCell(_ l: Line) -> some View {
        HStack(spacing: 8) {
            if let icon = app.catalog.icon(l.id) { Image(nsImage: icon) }
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(app.catalog.name(l.id)).lineLimit(1)
                if let models = l.usage?.models.prefix(2), !models.isEmpty {
                    Text(models.map { Self.model($0.name) }.joined(separator: " · ")).font(.ui(TextSize.caption))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    /// Its share of the span's cost as a bar in its colour: one agent at 99.8 % shows what the rest come to.
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

    /// Its days on its own scale, so a small agent's pattern shows beside a big one's (tokens when it costs nothing).
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

/// What kind of token the cost went on: reading the cache is most of a long chat's bill, writing it much of the rest.
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
            // Two by two: four in a row were cut short at the figures' width.
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

    static func parts(_ c: UsageAgents.Costs) -> [(name: String, cost: Double, color: Color)] {
        [
            (String(localized: "Cache reads"), c.cacheRead, .blue),
            (String(localized: "Cache writes"), c.cacheWrite, .cyan),
            (String(localized: "Output"), c.output, .purple), (String(localized: "Input"), c.input, .gray)
        ]
        .filter { $0.cost > 0 }
    }

    nonisolated static func share(_ part: Double, of total: Double) -> String {
        guard total > 0 else { return "0%" }
        let share = part / total
        return share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }
}
