import SwiftUI
import Core

/// How much of each agent's plan is used: a line per agent that reports it — name, a bar and percentage for its 5-hour
/// window (or its fullest limit) with the week as a thin line under it, and when the 5 hours reset — and the details
/// (each limit with its bar, when it resets) on hover.
/// The numbers come from the agents' own /usage screens (Claude Code, Grok, Antigravity — the daemon reads them) and
/// Codex's app server (or its session logs, when newer); agents that don't report limits aren't listed.
struct UsageView: View {
    struct Line: Equatable { var label: String; var used: Double; var resets: String?; var session = false }   // used: 0...1
    struct Row: Identifiable, Equatable {
        var id: String, name: String, fullName: String
        var lines: [Line] = []
        /// When the numbers were read (nil: unknown); past half an hour they're dimmed and say how old they are.
        var readAt: Date?
        var stale: Bool { readAt.map { Date().timeIntervalSince($0) > 1800 } ?? false }
        /// The 5-hour window when the agent has one (what a small plan runs into within a day), else the fullest limit.
        var main: Line? { lines.first(where: \.session) ?? lines.max { $0.used < $1.used } }
        /// The fullest of the rest (the week), a thin line under the main bar.
        var other: Line? { lines.filter { $0 != main }.max { $0.used < $1.used } }
    }
    let app: AppModel
    init(app: AppModel) { self.app = app }
    @State private var rows: [Row] = []
    @State private var hovered: String?

    var body: some View {
        // The loader hangs off a container that always exists: on an EmptyView `.task` never runs.
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                Divider()
                bars.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        // Watched while shown: the daemon says when a plan read or the token count changed.
        .onAppear { app.watch(.limits); load() }
        .onDisappear { app.unwatch(.limits) }
        .onChange(of: app.limits) { load() }
        .onChange(of: AgentAvailability.shared.ids) { load() }
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { r in
                let main = r.main ?? Line(label: "", used: 0)
                HStack(spacing: 8) {
                    column(r.name, rows.map(\.name), .leading)
                    VStack(spacing: 2) {
                        Bar(used: main.used)
                        if let o = r.other { Bar(used: o.used, height: 2) }
                    }
                    column(Self.percent(main.used), ["100%"], .trailing).monospacedDigit().foregroundStyle(UsageView.tint(main.used))
                    if !sessionResets.isEmpty {
                        column(main.session ? main.resets ?? "" : "", sessionResets, .leading).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .opacity(r.stale ? 0.45 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
                .onTapGesture { hovered = r.id }   // trackpads, and anyone who'd rather click
                .popover(isPresented: Binding(get: { hovered == r.id }, set: { if !$0, hovered == r.id { hovered = nil } }), arrowEdge: .top) {
                    Details(row: r)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(r.lines.map { String(localized: "\(r.fullName) \($0.label): \(Int(($0.used * 100).rounded()))% used") }.joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// When each 5-hour window frees up, shown without hovering: the question once it's full.
    private var sessionResets: [String] { rows.compactMap { $0.main?.session == true ? $0.main?.resets : nil } }

    /// `text` as wide as the widest of `all`, so the columns line up from row to row.
    private func column(_ text: String, _ all: [String], _ alignment: Alignment) -> some View {
        ZStack(alignment: alignment) {
            ForEach(all, id: \.self) { Text($0).hidden() }
            Text(text)
        }
        .fixedSize()   // the bar gives way, not the text
    }

    private static func percent(_ used: Double) -> String { "\(Int((used * 100).rounded()))%" }

    /// How full a limit is (a bar can't be mistaken for the "working" spinner); orange from 70 %, red from 90 %.
    private struct Bar: View {
        let used: Double
        var height: CGFloat = 4
        var body: some View {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(UsageView.tint(used)).frame(width: max(height, g.size.width * min(used, 1)))
                }
            }
            .frame(height: height)
        }
    }

    private struct Details: View {
        let row: Row
        /// Each limit gets its own bar, so the one that's running out shows at a glance.
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.fullName).font(.headline)
                    if let at = row.readAt {
                        Text(row.stale ? String(localized: "Read \(shortAgo(at)) ago; not since, so these may be out of date.")
                             : Date().timeIntervalSince(at) < 60 ? String(localized: "Read just now") : String(localized: "Read \(shortAgo(at)) ago"))
                            .font(.caption).foregroundStyle(row.stale ? .orange : .secondary)
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
                        Bar(used: l.used)
                        if let r = l.resets { Text("Resets \(r)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .font(.callout)
            .frame(width: 220, alignment: .leading)
            .padding(12)
        }
    }

    static func tint(_ u: Double, quiet: Color = .secondary) -> Color { u >= 0.9 ? .red : u >= 0.7 ? .orange : quiet }

    private func load() {
        guard let u = app.limits else { return }
        let next = AgentCatalog.installed(AgentCatalog.all).compactMap { a -> Row? in
            var r = Row(id: a.id, name: Self.short(a.name), fullName: a.name)
            r.readAt = u.plansReadAt?[a.id].map { Date(timeIntervalSince1970: $0) }
            switch a.id {
            case "claude": r.lines = Self.claude(u)
            // Codex logs its limits only when it's used: an old reading is dimmed and says how old it is.
            case "codex": r.lines = Self.codex(u); r.readAt = u.codex.first.map { Date(timeIntervalSince1970: $0.observedAt) }
            default: r.lines = Self.lines(u.plans?[a.id] ?? [])
            }
            return r.lines.isEmpty ? nil : r
        }
        if next != rows { rows = next }
    }

    /// "Claude Code" → "Claude", "Cursor Agent" → "Cursor": room for three in a sidebar.
    static func short(_ name: String) -> String {
        [" Code", " CLI", " Agent"].reduce(name) { $0.hasSuffix($1) ? String($0.dropLast($1.count)) : $0 }
    }

    /// Readings as the daemon passes them: kind ("session", "week", "week · Fable", "Gemini week"), percent, resets.
    private static func lines(_ readings: [UsageGet.Limit]) -> [Line] {
        readings.map { l in
            let kind = l.kind
            let label = kind == "session" ? String(localized: "5 hours") : kind == "week" ? String(localized: "Week")
                : kind.hasPrefix("week · ") ? String(localized: "Week, ") + kind.dropFirst(7) : kind.prefix(1).uppercased() + kind.dropFirst()
            return Line(label: label, used: l.percent / 100, resets: l.resets, session: kind == "session")
        }
    }

    /// Claude Code's /usage, or the percentages a session printed.
    private static func claude(_ u: UsageGet.Result) -> [Line] {
        lines(u.plans?["claude"] ?? u.claudeLimits ?? [])
    }

    private static func codex(_ u: UsageGet.Result) -> [Line] {
        guard let x = u.codex.first else { return [] }
        let now = Date().timeIntervalSince1970
        return [(String(localized: "5 hours"), x.primaryUsedPercent, x.primaryResetsAt, true),
                (String(localized: "Week"), x.secondaryUsedPercent, x.secondaryResetsAt, false)].compactMap { label, used, reset, session in
            guard let p = used else { return nil }
            let t = reset ?? 0, expired = t > 0 && t < now
            return Line(label: label, used: expired ? 0 : p / 100, resets: t > now ? Self.at(t) : nil, session: session)
        }
    }

    /// A clock time, as Claude Code gives its own: "3:12 PM" within half a day (the 5-hour window, short enough for
    /// the sidebar), "Saturday 3:12 PM" later.
    private static func at(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        return d.timeIntervalSinceNow < 12 * 3600 ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}
