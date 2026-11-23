import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// How much of the agents' plans is used. It shows a row for each agent (or only the fullest, by a setting) with the
/// agent's icon and name, and a bar the width of the row for each length of window the agent's limits have, such as 5
/// hours and a week (`LimitBars`; the eye beside a limit in the hover card shows or hides its bar). Each bar's percent
/// is named beside the name, with the time the first resets if that is within 12 hours, and each bar has a tick where
/// an even pace would have it by now. On hover it shows that agent's limits, each with its bar and reset. When only one
/// row is shown, the hover card lists every agent's limits. The foot's right-click menu hides an agent's row.
/// The numbers come from the agents' own /usage screens (Claude Code, Grok, Antigravity, Kimi, Copilot, Cursor; the
/// daemon reads them) and from Codex's app server (or its session logs, when they are newer). Agents that don't report
/// limits aren't listed.
struct UsageView: View {
    struct Line: Equatable {   // `used` is a share from 0 to 1
        var label: String
        var used: Double
        var resets: String?
        var resetAt: Date?
        /// How long the limit's window is, or nil when it isn't known, in which case there is no pace tick.
        var window: TimeInterval?
        var kind = ""

        /// Returns how much of the window has gone, which is where the bar would be now at an even pace, or nil when
        /// that can't be told.
        func pace(now: Date = Date()) -> Double? {
            guard let resetAt, let window, window > 0 else { return nil }
            let left = resetAt.timeIntervalSince(now)
            return left > 0 && left <= window ? 1 - left / window : nil
        }

        /// Returns the reset time shown beside the bar. Only a reset within 12 hours is shown, because it says when
        /// work can go on today. Later resets are in the card.
        func soon(now: Date = Date()) -> String? {
            guard let resetAt, let resets else { return nil }
            let left = resetAt.timeIntervalSince(now)
            return left > 0 && left < 12 * 3600 ? resets : nil
        }
    }
    struct Row: Identifiable, Equatable {
        var id: String, name: String, fullName: String
        var lines: [Line] = []
        /// When the numbers were read, or nil when that is unknown. Numbers older than half an hour say how old they
        /// are, because Codex reads its limits only when it is used.
        var readAt: Date?
        var stale: Bool { readAt.map { Date().timeIntervalSince($0) > 1800 } ?? false }
        var main: Line? { lines.max { $0.used < $1.used } }
    }
    let app: AppModel
    /// Whether to draw the divider above the view, against the sidebar's rows. The preview in Settings has none.
    private let ruled: Bool
    init(app: AppModel, ruled: Bool = true) {
        self.app = app
        self.ruled = ruled
    }
    @State private var rows: [Row] = []
    /// The row under the pointer, whose background is grey.
    @State private var hovered: String?
    /// The row whose card is up, which opens and goes by the hover card's delays.
    @State private var card = LimitCardHover()

    /// The agents that have used any of their plans and aren't hidden from the foot (`visible`).
    private var used: [Row] { Self.visible(rows, hidden: app.settings[SettingKeys.usageHiddenAgents]) }
    private var fullest: [Row] { used.max { ($0.main?.used ?? 0) < ($1.main?.used ?? 0) }.map { [$0] } ?? [] }
    private var all: Bool { app.settings[SettingKeys.usageLimits] != "fullest" }
    /// The rows shown, as chosen in Settings › Agents or the footer's right-click menu. There are none once plan limits
    /// are turned off.
    private var shown: [Row] {
        guard app.settings[SettingKeys.readPlans] else { return [] }
        return all ? used.sorted { ($0.main?.used ?? 0) > ($1.main?.used ?? 0) } : fullest
    }

    var body: some View {
        // The loader hangs off a container that always exists, because on an EmptyView it would never run.
        VStack(alignment: .leading, spacing: 0) {
            if !shown.isEmpty {
                if ruled { Divider() }
                // Redraws every minute, because a reading ages even while nothing else changes.
                // The reset times show only while the bars keep their room. A narrow sidebar shows them on hover.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    let resets = app.settings[SettingKeys.usageResets]
                    ViewThatFits(in: .horizontal) {
                        bars(resets: resets)
                        bars(resets: false)
                    }.padding(.horizontal, Metrics.inset).padding(.vertical, Metrics.gapWide)
                }
            } else if !ruled {
                // The preview in Settings is a row of the card, so it says why it's empty rather than leaving a blank
                // strip.
                Text(
                    app.settings[SettingKeys.readPlans]
                        ? String(localized: "No plan used yet: the limits show here once an agent has used some.")
                        : String(localized: "Plan limits are off.")
                ).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fontDesign(app.themes.chromeDesign)
        // The limits are watched while the view is shown, so the daemon says when a plan reading or the token count
        // changed.
        .onAppear {
            app.watch(.limits)
            load()
        }
        .onDisappear {
            app.unwatch(.limits)
            card.close()   // and with it the key monitor the card keeps
        }
        .onChange(of: app.latest(LimitsEvent.self)?.usage) { load() }
        .onChange(of: app.availability.ids) { load() }
    }

    private func bars(resets: Bool) -> some View {
        let pace = app.settings[SettingKeys.usagePace]
        return VStack(alignment: .leading, spacing: Metrics.gapWide) {
            ForEach(shown) { row in
                agentRow(row, resets: resets, pace: pace)
                    .font(.ui(TextSize.caption))
                    .opacity(row.stale ? 0.45 : 1)
                    // Under the pointer the row's background fades to grey, as a list row's does. The grey reaches past
                    // the row's edges, so nothing moves.
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(
                            hovered == row.id ? Color(nsColor: .fillHover) : .clear)
                    )
                    .padding(.horizontal, -4).padding(.vertical, -2)
                    .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovered)
                    .contentShape(Rectangle())
                    .onHover {
                        hovered = $0 ? row.id : (hovered == row.id ? nil : hovered)
                        card.hover(row.id, $0)
                    }
                    .onTapGesture { card.show(row.id) }   // trackpads, and anyone who'd rather click
                    .popover(
                        isPresented: Binding(
                            get: { card.shown == row.id }, set: { if !$0, card.shown == row.id { card.close() } }),
                        arrowEdge: .top
                    ) {
                        // With a row per agent, the card is about the agent under the pointer. With one row, the card
                        // shows every agent, because it's the only way to see the others.
                        let cards = all ? [row] : used
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(cards) { card in
                                if card.id != cards.first?.id { Divider() }
                                Details(
                                    row: card, forecast: LimitWatch.of(app).forecast, pace: pace,
                                    bars: barred(card).map(\.kind)
                                ) { line in toggle(line, of: card) }
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(   // a row per agent reads its own; one row reads them all, as its card shows
                        (all ? [row] : used).flatMap { usedRow in
                            usedRow.lines.map {
                                String(
                                    localized:
                                        "\(usedRow.fullName) \($0.label): \(Int(($0.used * 100).rounded()))% used")
                            }
                        }.joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An agent's row: its icon and name with each bar's percent, over its bars.
    private func agentRow(_ row: Row, resets: Bool, pace: Bool) -> some View {
        let bars = barred(row)
        return HStack(alignment: .top, spacing: Metrics.gapWide) {
            // The agent's icon beside the name, in colour, as in the sidebar's rows above.
            if let icon = app.catalog.icon(row.id) { Image(nsImage: icon).frame(width: 16, height: 16) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Metrics.gap) {
                    Text(row.name).lineLimit(1)
                    Spacer(minLength: Metrics.gapWide)
                    // An old reading shows its age in place of its reset time, which it can no longer vouch
                    // for. The row is dimmed and its share marked "~", so the age doesn't read as a reset time.
                    if row.stale, let read = row.readAt {
                        Text(String(localized: "\(shortAgo(read)) ago")).fixedSize().monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if resets, let at = bars.lazy.compactMap({ $0.soon() }).first {
                        Text(at).fixedSize().monospacedDigit().foregroundStyle(.secondary)
                    }
                    ForEach(bars, id: \.kind) { line in
                        share(line, stale: row.stale, first: line.kind == bars.first?.kind)
                    }
                }
                // The shortest window's bar on top, as the percents run from the left.
                ForEach(bars, id: \.kind) { line in
                    Bar(used: line.used, pace: pace ? line.pace() : nil)
                }
            }
        }
    }

    /// A bar's percent, named, so a lone weekly bar doesn't read as the 5 hours.
    private func share(_ line: Line, stale: Bool, first: Bool) -> some View {
        HStack(spacing: Metrics.gap) {
            Text(LimitBars.tag(line.kind)).fixedSize().foregroundStyle(.secondary)
            Text((stale ? "~" : "") + Self.percent(line.used)).fixedSize()
                .monospacedDigit().foregroundStyle(UsageView.textTint(line.used))
                .contentTransition(.numericText(value: line.used))   // rolls as the counts do
                .animation(Motion.reduced ? nil : .easeOut(duration: Motion.base), value: line.used)
        }
        .padding(.leading, first ? 0 : Metrics.gap)
    }

    /// Returns the limits of `row` that have a bar in the foot (`LimitBars`).
    private func barred(_ row: Row) -> [Line] {
        LimitBars.bars(
            row.lines, agent: row.id, shown: app.settings[SettingKeys.usageBarsShown],
            hidden: app.settings[SettingKeys.usageBarsHidden])
    }

    /// Shows or hides the bar of `line`, as its eye in the card asks.
    private func toggle(_ line: Line, of row: Row) {
        let next = LimitBars.toggled(
            line, in: row.lines, agent: row.id, shown: app.settings[SettingKeys.usageBarsShown],
            hidden: app.settings[SettingKeys.usageBarsHidden])
        app.settings.set(SettingKeys.usageBarsShown, next.shown)
        app.settings.set(SettingKeys.usageBarsHidden, next.hidden)
    }

    /// Returns the agents that have used any of their plans, because a row at 0% says nothing, less those hidden from
    /// the foot's menu. When every one of them is hidden, it returns them all, so the foot (and its menu, the way back)
    /// doesn't go.
    nonisolated static func visible(_ rows: [Row], hidden: [String]) -> [Row] {
        let used = rows.filter { ($0.main?.used ?? 0) > 0 }, kept = used.filter { !hidden.contains($0.id) }
        return kept.isEmpty ? used : kept
    }

    /// The one spelling of a share as a percent, "42%", for the bars, the cards and the notes (`PlanNote`, which isn't
    /// on the main actor).
    nonisolated static func percent(_ used: Double) -> String { "\(Int((used * 100).rounded()))%" }

    /// A limit's bar: orange from 70 %, red from 90 %.
    static func tint(_ share: Double) -> Color { share >= 0.9 ? .red : share >= 0.7 ? .orange : .secondary }

    /// The percent beside the bar, at the same steps but in the text shades, which keep 4.5:1 on a light window where
    /// the system's red and orange don't.
    static func textTint(_ share: Double) -> Color {
        share >= 0.9 ? .textRed : share >= 0.7 ? .textOrange : .primary
    }

    private func load() {
        guard app.latest(LimitsEvent.self)?.usage != nil else { return }
        let next = Self.rows(app)
        if next != rows { rows = next }
    }

    static func rows(_ app: AppModel) -> [Row] {
        guard let usage = app.latest(LimitsEvent.self)?.usage else { return [] }
        return app.catalog.installed.compactMap { agent -> Row? in
            var row = Row(id: agent.id, name: Self.short(agent.name), fullName: agent.name)
            row.readAt = usage.plansReadAt?[agent.id].map { Date(timeIntervalSince1970: $0) }
            switch agent.id {
            case Session.claudeAgent:
                row.lines = Self.claude(usage)
                if row.readAt == nil {
                    row.readAt = usage.claudeLimits?.compactMap(\.observedAt).max().map {
                        Date(timeIntervalSince1970: $0)
                    }
                }
            // Codex logs its limits only when it is used, so an old reading says how old it is.
            case Session.codexAgent:
                row.lines = Self.codex(usage)
                row.readAt = usage.codex.first.map { Date(timeIntervalSince1970: $0.observedAt) }
            default: row.lines = Self.lines(usage.plans?[agent.id] ?? [])
            }
            return row.lines.isEmpty ? nil : row
        }
    }

    /// Shortens an agent's name, such as "Claude Code" → "Claude", "Cursor Agent" → "Cursor" and "GitHub Copilot" →
    /// "Copilot", to make room for three in a sidebar.
    static func short(_ name: String) -> String {
        let shortName = name.hasPrefix("GitHub ") ? String(name.dropFirst(7)) : name
        return [" Code", " CLI", " Agent"].reduce(shortName) { $0.hasSuffix($1) ? String($0.dropLast($1.count)) : $0 }
    }

    /// Turns readings into lines. The daemon passes each reading with a kind ("session", "week", "week · Fable",
    /// "Gemini week"), a percent and a reset time.
    private static func lines(_ readings: [UsageGet.Limit]) -> [Line] {
        readings.map { reading in
            Line(
                label: label(reading.kind), used: reading.percent / 100,
                resets: reading.resets.map { ResetTime.shown($0) },
                resetAt: reading.resets.flatMap { ResetTime.parse($0) }, window: UsageGet.window(reading.kind),
                kind: reading.kind)
        }
    }

    nonisolated static func label(_ kind: String) -> String {
        kind == "session"
            ? String(localized: "5 hours")
            : kind == "week"
                ? String(localized: "Week")
                : kind == "month"
                    ? String(localized: "Month")
                    : kind.hasPrefix("week · ")
                        ? String(localized: "Week, \(String(kind.dropFirst(7)))")
                        : kind.prefix(1).uppercased() + kind.dropFirst()
    }

    /// The lines for Claude Code, from its /usage screen or else from the percentages a session printed.
    private static func claude(_ usage: UsageGet.Result) -> [Line] {
        lines(usage.plans?[Session.claudeAgent] ?? usage.claudeLimits ?? [])
    }

    private static func codex(_ usage: UsageGet.Result) -> [Line] {
        guard let reading = usage.codex.first else { return [] }
        let now = Date().timeIntervalSince1970
        // The window's own length names it: the free plan's only window is a month, not 5 hours.
        return [
            (reading.primaryUsedPercent, reading.primaryResetsAt, reading.primaryWindowMinutes, true),
            (reading.secondaryUsedPercent, reading.secondaryResetsAt, reading.secondaryWindowMinutes, false)
        ].compactMap { used, reset, minutes, primary in
            guard let usedPercent = used else { return nil }
            let kind = UsageGet.Codex.kind(minutes: minutes, primary: primary)
            let resetSeconds = reset ?? 0, expired = resetSeconds > 0 && resetSeconds < now
            let at = resetSeconds > now ? Date(timeIntervalSince1970: resetSeconds) : nil
            return Line(
                label: label(kind), used: expired ? 0 : usedPercent / 100, resets: at.map { ResetTime.shown($0) },
                resetAt: at,
                window: minutes.map { $0 * 60 } ?? UsageGet.window(kind), kind: kind)
        }
    }
}

extension UsageView {
    /// The note shown beside each agent where agents are chosen (`Contributions.plans`). There are none once plan
    /// limits are turned off.
    static func notes(_ app: AppModel) -> [String: PlanNote] {
        guard app.settings[SettingKeys.readPlans] else { return [:] }
        return Dictionary(
            rows(app).compactMap { row in
                PlanNote(
                    fullest: row.main.map { (label: $0.label, used: $0.used, resets: $0.resets) }, readAt: row.readAt
                )
                .map { (row.id, $0) }
            }, uniquingKeysWith: { a, _ in a })
    }
}

extension View {
    /// Keeps the agents' plan limits coming while this is shown (`UsageView.plans`).
    func watchingPlans(_ app: AppModel) -> some View {
        onAppear { app.watch(.limits) }.onDisappear { app.unwatch(.limits) }
    }
}
