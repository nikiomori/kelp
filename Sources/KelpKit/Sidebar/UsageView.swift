import AppKit
import SwiftUI
import Core
import DesignKit

/// How much of the agents' plans is used: the fullest limit of all (or each agent's fullest, by setting) with the agent's
/// icon and name over a bar the width of the row, its percentage, the time it resets if that's within 12 hours, and a tick
/// where an even pace would have the bar by now. On hover, that agent's limits each with its bar and reset; with one row
/// shown, every agent's.
/// The numbers come from the agents' own /usage screens (Claude Code, Grok, Antigravity, Kimi, Copilot, Cursor — the daemon reads them) and
/// Codex's app server (or its session logs, when newer); agents that don't report limits aren't listed.
struct UsageView: View {
    struct Line: Equatable { // used: 0...1
        var label: String
        var used: Double
        var resets: String?
        var resetAt: Date?
        /// How long its window is (nil: not known, so no pace tick).
        var window: TimeInterval?
        var kind = ""

        /// How much of the window has gone, which is where the bar would be now at an even pace; nil when that can't be told.
        func pace(now: Date = Date()) -> Double? {
            guard let resetAt, let window, window > 0 else { return nil }
            let left = resetAt.timeIntervalSince(now)
            return left > 0 && left <= window ? 1 - left / window : nil
        }

        /// The reset beside the bar: only one within 12 hours says when work can go on today; later ones are in the card.
        func soon(now: Date = Date()) -> String? {
            guard let resetAt, let resets else { return nil }
            let left = resetAt.timeIntervalSince(now)
            return left > 0 && left < 12 * 3600 ? resets : nil
        }
    }
    struct Row: Identifiable, Equatable {
        var id: String, name: String, fullName: String
        var lines: [Line] = []
        /// When the numbers were read (nil: unknown); past half an hour they say how old they are (Codex reads its limits
        /// only when it's used).
        var readAt: Date?
        var stale: Bool { readAt.map { Date().timeIntervalSince($0) > 1800 } ?? false }
        var main: Line? { lines.max { $0.used < $1.used } }
    }
    let app: AppModel
    /// The line over it, against the sidebar's rows; Settings' preview of it has none.
    private let ruled: Bool
    init(app: AppModel, ruled: Bool = true) { self.app = app; self.ruled = ruled }
    @State private var rows: [Row] = []
    @State private var hovered: String?

    /// The agents that have used anything of their plans: a row at 0% says nothing.
    private var used: [Row] { rows.filter { ($0.main?.used ?? 0) > 0 } }
    private var fullest: [Row] { used.max { ($0.main?.used ?? 0) < ($1.main?.used ?? 0) }.map { [$0] } ?? [] }
    private var all: Bool { app.settings.string("usage.limits") != "fullest" }
    /// The rows on show (Settings › Agents, or the footer's right-click): nothing once plan limits are turned off.
    private var shown: [Row] {
        guard app.settings.bool("usage.readPlans") != false else { return [] }
        return all ? used.sorted { ($0.main?.used ?? 0) > ($1.main?.used ?? 0) } : fullest
    }

    var body: some View {
        // The loader hangs off a container that always exists: on an EmptyView `.task` never runs.
        VStack(alignment: .leading, spacing: 0) {
            if !shown.isEmpty {
                if ruled { Divider() }
                // A minute at a time: a reading ages while nothing else changes.
                // The reset times only while the bars keep their room; a narrow sidebar has them on hover.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    let resets = app.settings.bool("usage.resets") != false
                    ViewThatFits(in: .horizontal) { bars(resets: resets); bars(resets: false) }.padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
        .fontDesign(app.themes.chromeDesign)
        // Watched while shown: the daemon says when a plan read or the token count changed.
        .onAppear { app.watch(.limits); load() }
        .onDisappear { app.unwatch(.limits) }
        .onChange(of: app.latest(LimitsEvent.self)?.usage) { load() }
        .onChange(of: app.availability.ids) { load() }
    }

    private func bars(resets: Bool) -> some View {
        let pace = app.settings.bool("usage.pace") != false
        return VStack(alignment: .leading, spacing: Metrics.gapWide) {
            ForEach(shown) { r in
                let main = r.main ?? Line(label: "", used: 0)
                HStack(spacing: Metrics.gapWide) {
                    // The agent's icon over both lines, in colour as in the sidebar's rows above.
                    if let icon = app.catalog.icon(r.id) { Image(nsImage: icon).frame(width: 16, height: 16) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Metrics.gap) {
                            Text(r.name).lineLimit(1)
                            Spacer(minLength: Metrics.gapWide)
                            // An old reading says how old in place of its reset, which it can no longer vouch for; the
                            // row is dimmed and its share marked "~", so the age doesn't read as a reset time.
                            if r.stale, let read = r.readAt {
                                Text(String(localized: "\(shortAgo(read)) ago")).fixedSize().monospacedDigit().foregroundStyle(.secondary)
                            } else if resets, let at = main.soon() { Text(at).fixedSize().monospacedDigit().foregroundStyle(.secondary) }
                            Text((r.stale ? "~" : "") + Self.percent(main.used)).fixedSize()
                                .monospacedDigit().foregroundStyle(UsageView.tint(main.used, quiet: .primary))
                        }
                        Bar(used: main.used, pace: pace ? main.pace() : nil)
                    }
                }
                .font(.ui(11))
                .opacity(r.stale ? 0.45 : 1)
                // Under the pointer the row greys in (faded, as a list row does), past its edges so nothing moves.
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusXS).fill(hovered == r.id ? Color(nsColor: .fillHover) : .clear))
                .padding(.horizontal, -4).padding(.vertical, -2)
                .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovered)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
                .onTapGesture { hovered = r.id }   // trackpads, and anyone who'd rather click
                .popover(isPresented: Binding(get: { hovered == r.id }, set: { if !$0, hovered == r.id { hovered = nil } }), arrowEdge: .top) {
                    // A row per agent: the card is about the one under the pointer. One row: it's the only way to the others.
                    let cards = all ? [r] : used
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(cards) { u in
                            if u.id != cards.first?.id { Divider() }
                            Details(row: u, forecast: app.forecast, pace: pace)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(used.flatMap { u in
                    u.lines.map { String(localized: "\(u.fullName) \($0.label): \(Int(($0.used * 100).rounded()))% used") }
                }.joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func percent(_ used: Double) -> String { "\(Int((used * 100).rounded()))%" }

    /// How full a limit is (a bar can't be mistaken for the "working" spinner); orange from 70 %, red from 90 %. `pace`: a
    /// tick where an even pace would have it now, cut out of the bar on both sides so it shows on the fill as on the track.
    private struct Bar: View {
        let used: Double
        var pace: Double?
        var height: CGFloat = 3
        var body: some View {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(UsageView.tint(used)).frame(width: max(height, w * min(used, 1)))
                }
                .frame(height: height)
                // An overlay, so the taller tick doesn't make the bar thicker than one without it.
                // On whole points, so it's one sharp line; flattening the bar to cut a gap round it lost the
                // popover's vibrancy (the track went black).
                .overlay(alignment: .leading) {
                    if let p = pace { Rectangle().fill(.primary).frame(width: 1, height: height + 4).offset(x: (w * p).rounded()) }
                }
            }
            .frame(minWidth: 48, maxWidth: .infinity)   // a bar, not a dot, when the text beside it is long
            .frame(height: height)
        }
    }

    private struct Details: View {
        let row: Row
        let forecast: LimitForecast
        let pace: Bool
        /// Each limit gets its own bar, so the one that's running out shows at a glance.
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.fullName).font(.ui(13, weight: .semibold))
                    if let at = row.readAt {
                        Text(row.stale ? String(localized: "Read \(shortAgo(at)) ago; not since, so these may be out of date.")
                             : Date().timeIntervalSince(at) < 60 ? String(localized: "Read just now") : String(localized: "Read \(shortAgo(at)) ago"))
                            .font(.ui(11)).foregroundStyle(row.stale ? Color.textOrange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(row.lines, id: \.label) { l in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(l.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(UsageView.percent(l.used)).monospacedDigit().fontWeight(.semibold).foregroundStyle(UsageView.tint(l.used, quiet: .primary))
                        }
                        let even = pace ? l.pace() : nil
                        Bar(used: l.used, pace: even)
                        // One line: when it resets at the left, the tick's value at the right (it wrapped as one sentence).
                        if l.resets != nil || even != nil {
                            HStack {
                                if let r = l.resets { Text("Resets \(r)").lineLimit(1) }
                                Spacer(minLength: Metrics.gapWide)
                                if let e = even { Text("Even pace \(UsageView.percent(e))").fixedSize().monospacedDigit() }
                            }
                            .font(.ui(11)).foregroundStyle(.secondary)
                        }
                        if !row.stale, let eta = forecast.warning(LimitForecast.key(row.id, l.kind), resetAt: l.resetAt, window: l.window) {
                            Text("At this pace it's full in \(LimitForecast.duration(eta)), before it resets.").font(.ui(11)).foregroundStyle(Color.textOrange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !row.stale, LimitForecast.unusedNearReset(percent: l.used * 100, resetAt: l.resetAt, window: l.window) {
                            Text("Over half left; what isn't used by the reset is lost.").font(.ui(11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(.ui(12))
            .frame(width: 276, alignment: .leading)   // 300 with its padding, as the design's popovers are
            .padding(12)
        }
    }

    static func tint(_ u: Double, quiet: Color = .secondary) -> Color { u >= 0.9 ? .red : u >= 0.7 ? .orange : quiet }

    private func load() {
        guard app.latest(LimitsEvent.self)?.usage != nil else { return }
        let next = Self.rows(app)
        if next != rows { rows = next }
    }

    static func rows(_ app: AppModel) -> [Row] {
        guard let u = app.latest(LimitsEvent.self)?.usage else { return [] }
        return app.catalog.installed(app.catalog.all).compactMap { a -> Row? in
            var r = Row(id: a.id, name: Self.short(a.name), fullName: a.name)
            r.readAt = u.plansReadAt?[a.id].map { Date(timeIntervalSince1970: $0) }
            switch a.id {
            case "claude":
                r.lines = Self.claude(u)
                if r.readAt == nil { r.readAt = u.claudeLimits?.compactMap(\.observedAt).max().map { Date(timeIntervalSince1970: $0) } }
            // Codex logs its limits only when it's used: an old reading says how old it is.
            case "codex": r.lines = Self.codex(u); r.readAt = u.codex.first.map { Date(timeIntervalSince1970: $0.observedAt) }
            default: r.lines = Self.lines(u.plans?[a.id] ?? [])
            }
            return r.lines.isEmpty ? nil : r
        }
    }

    /// "Claude Code" → "Claude", "Cursor Agent" → "Cursor", "GitHub Copilot" → "Copilot": room for three in a sidebar.
    static func short(_ name: String) -> String {
        let n = name.hasPrefix("GitHub ") ? String(name.dropFirst(7)) : name
        return [" Code", " CLI", " Agent"].reduce(n) { $0.hasSuffix($1) ? String($0.dropLast($1.count)) : $0 }
    }

    /// Readings as the daemon passes them: kind ("session", "week", "week · Fable", "Gemini week"), percent, resets.
    private static func lines(_ readings: [UsageGet.Limit]) -> [Line] {
        readings.map { l in
            Line(label: label(l.kind), used: l.percent / 100, resets: l.resets.map { ResetTime.shown($0) },
                 resetAt: l.resets.flatMap { ResetTime.parse($0) }, window: window(l.kind), kind: l.kind)
        }
    }

    private static func label(_ kind: String) -> String {
        kind == "session" ? String(localized: "5 hours") : kind == "week" ? String(localized: "Week")
            : kind == "month" ? String(localized: "Month")
            : kind.hasPrefix("week · ") ? String(localized: "Week, \(String(kind.dropFirst(7)))") : kind.prefix(1).uppercased() + kind.dropFirst()
    }

    static func window(_ kind: String) -> TimeInterval? { UsageGet.window(kind) }

    /// Claude Code's /usage, or the percentages a session printed.
    private static func claude(_ u: UsageGet.Result) -> [Line] {
        lines(u.plans?["claude"] ?? u.claudeLimits ?? [])
    }

    private static func codex(_ u: UsageGet.Result) -> [Line] {
        guard let x = u.codex.first else { return [] }
        let now = Date().timeIntervalSince1970
        // The window's own length names it: the free plan's only window is a month, not 5 hours.
        return [(x.primaryUsedPercent, x.primaryResetsAt, x.primaryWindowMinutes, true),
                (x.secondaryUsedPercent, x.secondaryResetsAt, x.secondaryWindowMinutes, false)].compactMap { used, reset, minutes, primary in
            guard let p = used else { return nil }
            let kind = UsageGet.Codex.kind(minutes: minutes, primary: primary)
            let t = reset ?? 0, expired = t > 0 && t < now
            let at = t > now ? Date(timeIntervalSince1970: t) : nil
            return Line(label: label(kind), used: expired ? 0 : p / 100, resets: at.map { ResetTime.shown($0) }, resetAt: at,
                        window: minutes.map { $0 * 60 } ?? window(kind), kind: kind)
        }
    }
}

extension AppModel {
    /// Each agent's plan limits as the sidebar reads them, the fullest first, and when they were read: the Usage tab's
    /// Plan column (kept coming with `watchingPlans`).
    package var plans: [String: (limits: [(label: String, used: Double, resets: String?)], readAt: Date?, note: (text: String, color: NSColor)?)] {
        let notes = planNotes
        return Dictionary(UsageView.rows(self).map { r in
            let limits = r.lines.sorted { $0.used > $1.used }.map { (label: $0.label, used: $0.used, resets: $0.resets) }
            return (r.id, (limits, r.readAt, notes[r.id].map { ($0.text, $0.color) }))
        }, uniquingKeysWith: { a, _ in a })
    }

    /// What's said beside an agent where agents are chosen; nothing once plan limits are turned off.
    var planNotes: [String: PlanNote] {
        guard settings.bool("usage.readPlans") != false else { return [:] }
        return Dictionary(UsageView.rows(self).compactMap { r in
            PlanNote(fullest: r.main.map { (label: $0.label, used: $0.used, resets: $0.resets) }, readAt: r.readAt).map { (r.id, $0) }
        }, uniquingKeysWith: { a, _ in a })
    }
}

extension View {
    /// Keeps the agents' plan limits coming while this is shown (`AppModel.plans`).
    package func watchingPlans(_ app: AppModel) -> some View { onAppear { app.watch(.limits) }.onDisappear { app.unwatch(.limits) } }
}

/// The sidebar's foot: a right-click sets what it shows.
final class UsageFooter: NSHostingView<UsageView> {
    var app: AppModel?
    static func make(_ app: AppModel) -> UsageFooter {
        let f = UsageFooter(rootView: UsageView(app: app))
        f.app = app
        f.sizingOptions = [.intrinsicContentSize]
        return f
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let app else { return nil }
        let m = NSMenu()
        m.addChoices("usage.limits", app, heading: String(localized: "Show"))
        m.addToggle("usage.resets", app, title: String(localized: "Reset Time"))
        m.addToggle("usage.pace", app, title: String(localized: "Pace Mark"))
        m.addItem(.separator())
        m.add(String(localized: "Open Usage")) { app.extensions.run("agents.usage") }
        m.addChoiceMenu("usage.alertAt", app, title: String(localized: "Warn At"), tryOn: false)
        m.addItem(.separator())
        m.add(String(localized: "Hide Plan Limits")) {
            app.settings.set("usage.readPlans", .bool(false))
            Banner.show(String(localized: "Plan limits are hidden. Settings › Agents brings them back."))
        }
        m.addSettingsLink(String(localized: "Limits Settings…"), section: "agents", group: "Plan limits", app)
        return m
    }
}
