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
    func agentLines(_ plans: [String: Plan]) -> [Line] {
        let used = (usage?.agents ?? []).filter { $0.tokens > 0 }
        let rest = app.catalog.installed(app.catalog.all).map(\.id).filter { id in
            plans[id] != nil && !used.contains { $0.id == id }
        }
        return used.map { Line(id: $0.id, usage: $0, plan: plans[$0.id]) }
            + rest.map { Line(id: $0, usage: nil, plan: plans[$0]) }
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

    func kpis(_ lines: [Line]) -> some View {
        let shown = series, cost = shown.reduce(0) { $0 + $1.cost }, tokens = shown.reduce(0) { $0 + $1.tokens }
        let cached = shown.reduce(0) { $0 + $1.cacheRead }, ids = Set(shown.map(\.id))
        let active = Set((usage?.days ?? []).filter { ids.contains($0.agent) && $0.tokens > 0 }.map(\.day)).count
        return HStack(spacing: 32) {
            stat(money(cost, tokens), String(localized: "at API prices"))
            stat(count(tokens), String(localized: "tokens · \(percent(cached, of: tokens)) from cache"))
            stat(money(cost / Double(max(1, active)), 0), String(localized: "per active day"))
            if sel != nil {
                stat("\(active)", String(localized: "active days"))
            } else {
                stat(
                    String(localized: "\(lines.filter { $0.usage != nil }.count) of \(lines.count)"),
                    String(localized: "agents used"))
            }
        }
    }

    func table(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            columns(Text("Agent"), Text("Plan"), Text("Last \(range) days"), Text("Tokens"), Text("At API prices"))
                .font(.ui(11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
            Divider()
            ForEach(lines) { row($0) }
        }
    }

    /// agent | plan | the span | tokens | cost, the same widths in every row.
    private func columns(
        _ agent: some View, _ plan: some View, _ span: some View, _ tokens: some View, _ cost: some View
    ) -> some View {
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
        let content = cells(l)
            .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
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

    @ViewBuilder private func cells(_ l: Line) -> some View {
        if usage == nil {   // its logs still being read: grey where the figures will be
            columns(agentCell(l), planCell(l.plan), Self.reading, Self.reading, Self.reading)
        } else {
            columns(agentCell(l), planCell(l.plan), spanCell(l), tokensCell(l.usage), costCell(l.usage))
        }
    }

    /// A figure not read yet.
    private static var reading: some View { Text(verbatim: "0000").font(.ui(11)).redacted(reason: .placeholder) }

    private func agentCell(_ l: Line) -> some View {
        HStack(spacing: 8) {
            if let icon = app.catalog.icon(l.id) { Image(nsImage: icon) }
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(app.catalog.name(l.id)).lineLimit(1)
                if let models = l.usage?.models.prefix(2), !models.isEmpty {
                    Text(models.map { Self.model($0.name) }.joined(separator: " · ")).font(.ui(11)).foregroundStyle(
                        .secondary
                    ).lineLimit(1)
                }
            }
        }
    }

    /// Its fullest limit with a bar, when that resets and the next fullest; every limit on hover. An old reading is faded and says so.
    @ViewBuilder private func planCell(_ plan: Plan?) -> some View {
        if let plan, let top = plan.limits.first {
            let stale = plan.readAt.map { Date().timeIntervalSince($0) > 1800 } ?? false
            let note =
                stale
                ? String(localized: "Read \(shortAgo(plan.readAt)) ago")
                : ([top.label + (top.resets.map { String(localized: " · resets \($0)") } ?? "")]
                    + plan.limits.dropFirst().prefix(1).map { "\($0.label) \(UsageView.percent($0.used))" }).joined(
                        separator: " · ")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(UsageView.tint(top.used)).frame(
                                width: max(4, proxy.size.width * min(top.used, 1)))
                        }
                    }
                    .frame(height: 4)
                    Text(UsageView.percent(top.used)).monospacedDigit().foregroundStyle(
                        top.used >= 0.9 ? Color.textRed : top.used >= 0.7 ? .textOrange : .primary)
                }
                Text(note).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.ui(11))
            .opacity(stale ? 0.55 : 1)
            .help(
                plan.limits.map { limit in
                    "\(limit.label): \(UsageView.percent(limit.used))"
                        + (limit.resets.map { String(localized: ", resets \($0)") } ?? "")
                }
                .joined(separator: "\n"))
        } else {
            Text("—").font(.ui(11)).foregroundStyle(.tertiary)
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
            .font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func tokensCell(_ agentUsage: UsageAgents.Agent?) -> some View {
        VStack(alignment: .trailing, spacing: Metrics.lineGap) {
            Text(agentUsage.map { count($0.tokens) } ?? "—").monospacedDigit()
            if let agentUsage, agentUsage.cacheRead > 0 {
                Text("\(percent(agentUsage.cacheRead, of: agentUsage.tokens)) from cache").font(.ui(11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func costCell(_ agentUsage: UsageAgents.Agent?) -> some View {
        VStack(alignment: .trailing, spacing: Metrics.lineGap) {
            Text(agentUsage.map { money($0.cost, $0.tokens) } ?? "—").monospacedDigit()
            if let agentUsage, agentUsage.cost == 0 {
                Text("no list price").font(.ui(11)).foregroundStyle(.secondary)
            } else if let agentUsage, usage?.ownPrice?.contains(agentUsage.id) == true {
                Text("as it reports").font(.ui(11)).foregroundStyle(.secondary)
            }
        }
    }
}
