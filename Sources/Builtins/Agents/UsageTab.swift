import AppKit
import SwiftUI
import Charts
import Core
import DesignKit
import KelpKit

/// "usage:" — what the agents used: plan limits first, then each agent's tokens by day, agent, model and project from its
/// own logs on this Mac, priced as the API would charge (so you see what a subscription saves). Window › Usage (⌥⌘U).
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
    struct Row: Identifiable {
        let id: String
        let cost: Double
        let tokens: Int
    }
    @State private var range = 30
    @State private var days: [UsageAgents.Day] = []
    @State private var agents: [Row] = []
    @State private var models: [Row] = []
    @State private var projects: [Row] = []
    @State private var loading = true
    @State private var slow = false
    @State private var failed: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(String(localized: "Plan Limits")) {
                    UsageView(app: app)
                    Text("What each agent reports for its plan; the fullest one first. Faded numbers are older than half an hour.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Tokens").font(.title3.weight(.semibold))
                    Spacer()
                    Picker("", selection: $range) {
                        Text("7 Days").tag(7)
                        Text("30 Days").tag(30)
                        Text("90 Days").tag(90)
                    }
                        .pickerStyle(.segmented).fixedSize()
                }
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if slow { Text("Reading the agents' logs — the first time takes a minute.").foregroundStyle(.secondary) }
                    }
                }
                else if let failed { Text("Couldn't read the usage: \(failed)").foregroundStyle(.secondary) }
                else if days.isEmpty { Text("No agent conversations in this time.").foregroundStyle(.secondary) }
                else {
                    let cost = days.reduce(0) { $0 + $1.cost }, tokens = days.reduce(0) { $0 + $1.tokens }
                    HStack(spacing: 28) {
                        stat(money(cost), String(localized: "at API prices"))
                        stat(count(tokens), "tokens")
                        stat(money(cost / Double(max(1, Set(days.map(\.day)).count))), String(localized: "per active day"))
                    }
                    Chart(days, id: \.self) { d in
                        BarMark(x: .value("Day", Self.date(d.day), unit: .day), y: .value("Cost", d.cost))
                            .foregroundStyle(by: .value("Agent", app.catalog.name(d.agent)))
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let x = v.as(Double.self) { Text(money(x)) } } } }
                    .frame(height: 180)
                    table(String(localized: "By Agent"), agents.map { Row(id: app.catalog.name($0.id), cost: $0.cost, tokens: $0.tokens) })
                    HStack(alignment: .top, spacing: 28) {
                        table(String(localized: "By Model"), models)
                        table(String(localized: "By Project"), projects)
                    }
                    Text("""
                        Read from each agent's own logs on this Mac: Claude Code (every account profile), Codex, Grok, Kimi Code and Copilot. \
                        Cursor keeps no token counts on disk, and Antigravity's aren't read yet. Prices are list prices (Grok's as it reports them); \
                        a subscription bills differently, and "—" is a model without one.
                        """)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24).frame(maxWidth: 820, alignment: .leading)
        }
        .task(id: range) { await load() }
    }

    private func load() async {
        loading = true; slow = false
        let hint = Task { try? await Task.sleep(for: .seconds(3)); if loading { slow = true } }
        defer { hint.cancel() }
        let read = await app.tryCall(UsageAgents(days: range))
        let r = read.value; failed = read.error
        func rows(_ groups: [UsageReport.Group]?) -> [Row] { (groups ?? []).map { Row(id: $0.name, cost: $0.cost, tokens: $0.tokens) } }
        days = r?.days ?? []
        agents = (r?.agents ?? []).map { Row(id: $0.id, cost: $0.cost, tokens: $0.tokens) }
        models = rows(r?.models)
        projects = rows(r?.projects)
        loading = false
    }

    static func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day) ?? Date()
    }
    private func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(v < 10 ? 2 : 0))) }
    private func count(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.title3.weight(.semibold)); content() }
    }
    private func table(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: TextSize.of(13), weight: .semibold))
            ForEach(rows.prefix(8)) { r in
                HStack {
                    Text(r.id).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(count(r.tokens)).foregroundStyle(.secondary).monospacedDigit()
                    Text(r.cost == 0 && r.tokens > 0 ? "—" : money(r.cost)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }.font(.callout)
                Divider()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
