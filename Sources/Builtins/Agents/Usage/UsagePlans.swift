// The Usage tab's Plans: each agent's limits now, a bar each, and when each runs out at the pace it's filling.
import Core
import DesignKit
import KelpKit
import SwiftUI

/// What a limit comes to at its pace: used up (back at its reset), full before it resets, or where it ends at the reset.
enum PlanOutlook: Equatable {
    case usedUp(back: Date?)
    case fullBefore(Date)
    case atReset(Double)   // percent
    case unknown

    static func of(
        _ line: UsageView.Line, agent: String, stale: Bool, forecast: LimitForecast, now: Date = Date()
    ) -> PlanOutlook {
        if line.used >= 1 { return .usedUp(back: line.resetAt.flatMap { $0 > now ? $0 : nil }) }
        guard !stale else { return .unknown }   // an old reading's pace says nothing about now
        let key = LimitForecast.key(agent, line.kind)
        if let eta = forecast.untilFull(key, resetAt: line.resetAt, window: line.window, now: now), eta > 0 {
            let full = now.addingTimeInterval(eta)
            if line.resetAt.map({ full < $0 }) ?? true { return .fullBefore(full) }
        }
        return forecast.atReset(key, resetAt: line.resetAt, window: line.window, now: now).map {
            .atReset(min(100, $0))
        }
            ?? .unknown
    }

    /// The line under the bar.
    func text(_ line: UsageView.Line, now: Date = Date()) -> String {
        let resets = line.resets.map { String(localized: " · resets \($0)") } ?? ""
        switch self {
        case .usedUp(let back?):
            let at = ResetTime.shown(back, now: now), left = LimitForecast.duration(back.timeIntervalSince(now))
            return String(localized: "Used up · back \(at), in \(left)")
        case .usedUp: return String(localized: "Used up")
        case .fullBefore(let at):
            return String(localized: "Full around \(ResetTime.shown(at, now: now)) at this pace") + resets
        case .atReset(let percent):
            return String(localized: "About \(Int(percent.rounded()))% at reset") + resets
        case .unknown: return line.resets.map { String(localized: "Resets \($0)") } ?? ""
        }
    }

    var color: Color {
        switch self {
        case .usedUp: .textRed
        case .fullBefore: .textOrange
        default: .secondary
        }
    }

    /// How soon it needs looking at: used up, then full before its reset, then the rest.
    var urgency: Int {
        switch self {
        case .usedUp: 2
        case .fullBefore: 1
        default: 0
        }
    }
}

/// A card per agent that reports plan limits, the one that needs looking at first; under them, the agents that don't.
struct PlanCards: View {
    let app: AppModel
    /// The agents used in the span that report no limits.
    let unplanned: [String]

    var body: some View {
        // A minute at a time: forecasts and "read … ago" age while nothing else changes.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let cards = Self.cards(app, now: context.date), pace = app.settings[SettingKeys.usagePace]
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.gapWide) {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
                        Text("Plans").font(.ui(TextSize.body, weight: .semibold))
                        (pace ? Text("now · the tick is where an even pace would be") : Text("now"))
                            .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(cards, id: \.row.id) { card in
                            PlanCard(app: app, row: card.row, outlooks: card.outlooks, pace: pace, now: context.date)
                        }
                    }
                    if !unplanned.isEmpty {
                        Text("\(unplanned.joined(separator: ", ")) report no plan limits.")
                            .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    typealias Card = (row: UsageView.Row, outlooks: [PlanOutlook])

    /// Each agent's limits, the fullest first, with their outlooks; the cards in order of need, old readings last.
    static func cards(_ app: AppModel, now: Date) -> [Card] {
        let forecast = LimitWatch.of(app).forecast
        let cards = UsageView.rows(app).map { row -> Card in
            var row = row
            row.lines.sort { $0.used > $1.used }
            return (
                row, row.lines.map { PlanOutlook.of($0, agent: row.id, stale: row.stale, forecast: forecast, now: now) }
            )
        }
        return ordered(cards)
    }

    nonisolated static func ordered(_ cards: [Card]) -> [Card] {
        cards.sorted { a, b in
            let rank = { (card: Card) in
                (card.row.stale ? 0 : 1, card.outlooks.map(\.urgency).max() ?? 0, card.row.main?.used ?? 0)
            }
            return rank(a) > rank(b)
        }
    }
}

private struct PlanCard: View {
    let app: AppModel
    let row: UsageView.Row
    let outlooks: [PlanOutlook]
    let pace: Bool
    let now: Date

    private var usedUp: Bool { outlooks.contains { $0.urgency == 2 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Metrics.gapWide) {
                if let icon = app.catalog.icon(row.id) { Image(nsImage: icon).frame(width: 16, height: 16) }
                Text(row.fullName).font(.ui(TextSize.body, weight: .semibold)).lineLimit(1)
                Spacer(minLength: Metrics.gap)
                if let at = row.readAt {
                    Text(
                        at.timeIntervalSince(now) > -60
                            ? String(localized: "read just now")
                            : String(localized: "read \(shortAgo(at, now: now)) ago")
                    )
                    .font(.ui(TextSize.caption)).foregroundStyle(row.stale ? Color.textOrange : .secondary)
                    .lineLimit(1)
                }
            }
            ForEach(Array(zip(row.lines, outlooks).enumerated()), id: \.offset) { _, pair in
                limit(pair.0, pair.1)
            }
            if row.id == "claude", let spent = Self.claudeSpent(app) {
                Divider()
                Text(spent).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.ui(TextSize.row))
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A limit used up tints its card red, so the agent that can't go on stands out among them.
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous).fill(
                Color(nsColor: usedUp ? .fillTint(.systemRed) : .fillRest))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .strokeBorder(usedUp ? Color.red : Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .opacity(row.stale ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private func limit(_ line: UsageView.Line, _ outlook: PlanOutlook) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(line.label)
                Spacer()
                Text(UsageView.percent(line.used)).monospacedDigit().foregroundStyle(
                    line.used >= 0.9 ? Color.textRed : line.used >= 0.7 ? .textOrange : .primary)
            }
            UsageView.Bar(used: line.used, pace: pace ? line.pace(now: now) : nil, height: 4)
            let text = outlook.text(line, now: now)
            if !text.isEmpty {
                Text(text).font(.ui(TextSize.caption)).foregroundStyle(outlook.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What Claude Code's work came to lately, at list prices: it ties the percentages to the work that used them.
    static func claudeSpent(_ app: AppModel) -> String? {
        guard let claude = app.latest(LimitsEvent.self)?.usage.claude.first else { return nil }
        let week = UsageReportView.dollars(claude.week.cost), today = UsageReportView.dollars(claude.today.cost)
        guard let block = claude.block else {
            return String(localized: "Last 7 days \(week) · today \(today), at API prices")
        }
        let inBlock = UsageReportView.dollars(block.cost)
        return String(localized: "Last 7 days \(week) · today \(today) · this 5-hour block \(inBlock), at API prices")
    }
}
