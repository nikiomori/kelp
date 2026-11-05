import AppKit
import SwiftUI
import Core
import DesignKit
import WorkbenchKit
import KelpKit

/// "subagent:<session>/<id>": what a subagent did, step by step, and what it reported. It has no terminal, and Claude Code
/// keeps all of this beside its parent's conversation, so the tab only reads, again when a step comes (`WatchTopic.subagents`).
@MainActor
@Observable
final class SubagentJournal {
    let session: String, id: String
    var journal: SessionSubagentJournal.Journal?
    var loaded = false
    var failed: String?

    init(session: String, id: String) { self.session = session; self.id = id }
}

@MainActor
final class SubagentTab: KelpKit.TabContent {   // not SwiftUI's
    let uri: String
    let view: NSView
    private let model: SubagentJournal
    var title: String { model.journal?.task ?? String(localized: "Subagent") }
    var icon: NSImage? { .symbol("list.bullet.rectangle") }

    init(uri: String, app: AppModel) {
        self.uri = uri
        let parts = TabURI.body(uri).split(separator: "/", maxSplits: 1).map(String.init)
        model = SubagentJournal(session: parts.first ?? "", id: parts.last ?? "")
        let host = NSHostingView(rootView: SubagentJournalView(model: model, app: app, watched: Watched(.subagents, in: app))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        host.sizingOptions = []   // a tab fills the space it's given
        view = host
    }
    func focus() {}
}

struct SubagentJournalView: View {
    let model: SubagentJournal, app: AppModel
    let watched: Watched

    /// What brings a new read: another step, or its end, whose report comes last.
    private struct Change: Equatable { var touched: Date?, working: Bool }

    private var run: Subagent? { app.session(model.session)?.subagentRuns?.first { $0.id == model.id } }
    private var working: Bool { run.map { $0.ended == nil } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            if let j = model.journal {
                header(j)
                Divider()
                steps(j)
            } else if let failed = model.failed {
                message(String(localized: "Can’t read this subagent"), failed)
            } else if model.loaded {
                message(String(localized: "Nothing to show"), String(localized: "Claude Code kept no record of this subagent."))
            }
        }
        .onAppear { watched.key = model.session }
        .onDisappear { watched.key = nil }
        .task(id: Change(touched: app.subagentSteps[model.session]?[model.id]?.touched, working: working)) { await load() }
    }

    private func load() async {
        let (value, error) = await app.tryCall(SessionSubagentJournal(id: model.session, subagent: model.id))
        model.journal = value ?? nil
        model.failed = error
        model.loaded = true
    }

    private func header(_ j: SessionSubagentJournal.Journal) -> some View {
        HStack(spacing: Metrics.gap) {
            Text(j.task ?? (j.kind.isEmpty ? String(localized: "Subagent") : j.kind)).font(.ui(12, weight: .medium)).lineLimit(1)
            Text(facts(j)).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if working, let run { Text(run.started, style: .timer).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary) }
            Button("Go to Agent") { app.workbench.focus(session: model.session) }.buttonStyle(PointerButtonStyle()).font(.ui(11))
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: TextSize.of(Metrics.contentBar))
    }

    private func facts(_ j: SessionSubagentJournal.Journal) -> String {
        var parts = [j.model, String(localized: "\(j.steps.count) steps")].compactMap { $0 }
        if let c = j.context { parts.append(String(localized: "\(c / 1000)k context")) }
        return parts.joined(separator: " · ")
    }

    private func steps(_ j: SessionSubagentJournal.Journal) -> some View {
        let start = run?.started ?? j.steps.first?.at ?? Date()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(j.steps.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.gap) {
                        Text(Self.clock(s.at.timeIntervalSince(start))).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                        Text(s.tool).font(.ui(12)).foregroundStyle(.secondary).frame(width: 72, alignment: .leading).lineLimit(1)
                        Text(s.detail).font(.uiMono(11)).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(minHeight: Metrics.row, alignment: .leading)
                }
                if let report = j.report, !working { Report(text: report).padding(.top, Metrics.inset) }
            }
            .textSelection(.enabled)
            .padding(Metrics.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func message(_ title: String, _ text: String) -> some View {
        VStack(spacing: Metrics.gap) {
            Text(title).font(.ui(13, weight: .semibold))
            Text(text).font(.ui(13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func clock(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }

    /// What it reported. Limit: Markdown's inline marks and headings; a table or a list stands as written.
    private struct Report: View {
        let text: String
        var body: some View {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, p in
                    if p.hasPrefix("#") {
                        Text(p.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)).font(.ui(13, weight: .semibold))
                    } else {
                        Text(LocalizedStringKey(p)).font(.ui(13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Metrics.inset)
            .frame(maxWidth: 760, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous).fill(Color(nsColor: .fillRest)))
        }
    }
}
