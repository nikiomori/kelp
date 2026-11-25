import Core
import DesignKit
import KelpKit
import SwiftUI

/// The overview's 7 Days: how long the agents worked and how long they waited for the user, by day and by project, and
/// the longest waits, each opening its chat.
struct OverviewWeek: View {
    let model: OverviewModel

    var body: some View {
        let lines = model.lines.filter { model.project(of: $0.key) != nil }
        let days = WeekSums.days(lines, days: 7, now: Date())
        VStack(alignment: .leading, spacing: Metrics.blockGap) {
            if let failed = model.failed { FailureLine(failed) { Task { await model.load(since: model.since) } } }
            OverviewPlate(stats: stats(lines))
            HStack(alignment: .top, spacing: Metrics.blockGap + 8) {
                VStack(alignment: .leading, spacing: Metrics.gapWide) {
                    heading(String(localized: "By Day"), String(localized: "below, worked; hatched, waited for you"))
                    bars(days)
                }
                .frame(width: 560, alignment: .leading)
                VStack(alignment: .leading, spacing: Metrics.gapWide) {
                    heading(String(localized: "By Project"), nil)
                    projects(WeekSums.projects(lines, project: model.project(of:)))
                    heading(String(localized: "Longest Waits"), String(localized: "a click opens the chat"))
                        .padding(.top, Metrics.gapWide)
                    waits(DayLine.longestWaits(lines, count: 5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stats(_ lines: [String: DayLine]) -> [OverviewPlate.Stat] {
        let all = Array(lines.values)
        let worked = all.reduce(0) { $0 + $1.worked }, waited = all.reduce(0) { $0 + $1.waited }
        var stats: [OverviewPlate.Stat] = [
            .init(value: shortSpan(worked, units: 2), note: String(localized: "agents worked · chats: \(lines.count)")),
            .init(
                value: shortSpan(waited, units: 2),
                note: worked > 0
                    ? String(
                        localized: "agents waited for you · \(Int((waited / worked * 100).rounded())) % of their work")
                    : String(localized: "agents waited for you")),
            .init(value: "\(all.reduce(0) { $0 + $1.turns })", note: String(localized: "turns"))
        ]
        if let limit = model.limit {
            stats.append(.init(value: "\(Int((limit.used * 100).rounded())) %", note: limit.name, meter: limit.used))
        }
        return stats
    }

    private func heading(_ title: String, _ note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
            Text(title).font(.ui(TextSize.body, weight: .semibold))
            if let note { Text(note).font(.ui(TextSize.caption)).foregroundStyle(.secondary) }
        }
    }

    /// A column per day, as tall as the agents' hours: worked below, waited above.
    private func bars(_ days: [WeekSums.Day]) -> some View {
        let top = max(3600, days.map { $0.worked + $0.waited }.max() ?? 0), height: CGFloat = 260
        return HStack(alignment: .bottom, spacing: Metrics.gapWide) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    Text(day.worked + day.waited > 0 ? shortSpan(day.worked + day.waited) : " ")
                        .font(.ui(TextSize.caption).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Canvas { context, size in
                        let waited = size.height * CGFloat(day.waited / top),
                            worked = size.height * CGFloat(day.worked / top)
                        DayPaint.hatch(
                            context, CGRect(x: 0, y: size.height - worked - waited, width: size.width, height: waited))
                        context.fill(
                            Path(CGRect(x: 0, y: size.height - worked, width: size.width, height: worked)),
                            with: .color(DayPaint.worked))
                    }
                    .frame(width: 34, height: height * CGFloat((day.worked + day.waited) / top))
                    Text(day.day.formatted(.dateTime.day().month(.abbreviated))).font(.ui(TextSize.row))
                    Text("\(day.chats) chats").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(height: height + 60, alignment: .bottom)
        .overlay(alignment: .bottom) { Divider().offset(y: -40) }
    }

    private func projects(_ rows: [WeekSums.Project]) -> some View {
        let widths: [CGFloat] = [160, 60, 100, 120]
        func row(_ cells: [String]) -> some View {
            HStack(spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                    Text(cell).lineLimit(1).frame(width: widths[i], alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.inset)
        }
        return VStack(spacing: 0) {
            row([
                String(localized: "Project"), String(localized: "Chats"), String(localized: "Worked"),
                String(localized: "Waited for You")
            ])
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary).padding(.vertical, 5)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, project in
                row([
                    project.name, "\(project.chats)", shortSpan(project.worked, units: 2),
                    shortSpan(project.waited, units: 2)
                ])
                .font(.ui(TextSize.row).monospacedDigit()).padding(.vertical, 5)
                .background(i % 2 == 0 ? DayPaint.zebra : .clear)
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.radiusMD).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMD).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func waits(_ waits: [(session: String, span: DayLine.Span)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(waits.enumerated()), id: \.offset) { i, wait in
                Button {
                    model.app.workbench.focus(session: wait.session)
                } label: {
                    HStack(spacing: Metrics.gapWide) {
                        Text(model.app.session(wait.session)?.displayTitle ?? wait.session).lineLimit(1)
                        Spacer()
                        Text(wait.span.from.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .foregroundStyle(.secondary)
                        Text(shortSpan(wait.span.length, units: 2)).monospacedDigit().frame(
                            width: 70, alignment: .trailing)
                    }
                    .font(.ui(TextSize.row))
                    .padding(.horizontal, Metrics.inset).padding(.vertical, 5)
                    .background(i % 2 == 1 ? DayPaint.zebra : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PointerButtonStyle(flush: true))
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.radiusMD).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMD).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
