import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// "subagent:<session>/<id>": what a subagent did, step by step, and what it reported. It has no terminal, and Claude Code
/// keeps all of this beside its parent's conversation, so the tab only reads, again when a step comes (`WatchTopic.subagents`).
@MainActor
@Observable
final class SubagentJournal {
    let session: String, id: String
    var journal: SessionSubagentJournal.Journal?
    var loaded = false
    var failed: String?

    init(session: String, id: String) {
        self.session = session
        self.id = id
    }
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
        let host = NSHostingView(
            rootView: SubagentJournalView(model: model, app: app, watched: Watched(.subagents, in: app))
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
            if let journal = model.journal {
                header(journal)
                Divider()
                steps(journal)
            } else if let failed = model.failed {
                message(String(localized: "Can’t read this subagent"), failed)
            } else if model.loaded {
                message(
                    String(localized: "Nothing to show"),
                    String(localized: "Claude Code kept no record of this subagent."))
            }
        }
        .onAppear { watched.key = model.session }
        .onDisappear { watched.key = nil }
        .task(
            id: Change(
                touched: app.latest(SubagentsEvent.self, model.session)?.steps[model.id]?.touched, working: working)
        ) { await load() }
    }

    private func load() async {
        let (value, error) = await app.tryCall(SessionSubagentJournal(id: model.session, subagent: model.id))
        model.journal = value ?? nil
        model.failed = error
        model.loaded = true
    }

    private func header(_ journal: SessionSubagentJournal.Journal) -> some View {
        HStack(spacing: Metrics.gap) {
            Text(journal.task ?? (journal.kind.isEmpty ? String(localized: "Subagent") : journal.kind)).font(
                .ui(12, weight: .medium)
            )
            .lineLimit(1)
            Text(facts(journal)).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if working, let run {
                Text(run.started, style: .timer).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("Go to Agent") { app.workbench.focus(session: model.session) }.buttonStyle(PointerButtonStyle())
                .font(.ui(11))
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: TextSize.of(Metrics.contentBar))
    }

    private func facts(_ journal: SessionSubagentJournal.Journal) -> String {
        var parts = [journal.model, String(localized: "\(journal.steps.count) steps")].compactMap { $0 }
        if let context = journal.context { parts.append(String(localized: "\(context / 1000)k context")) }
        return parts.joined(separator: " · ")
    }

    private func steps(_ journal: SessionSubagentJournal.Journal) -> some View {
        let start = run?.started ?? journal.steps.first?.at ?? Date()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(journal.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.gap) {
                        Text(Self.clock(step.at.timeIntervalSince(start))).font(.ui(11).monospacedDigit())
                            .foregroundStyle(
                                .secondary
                            )
                            .frame(width: 48, alignment: .trailing)
                        Text(step.tool).font(.ui(12)).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                            .lineLimit(1)
                        Text(step.detail).font(.uiMono(11)).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(minHeight: Metrics.row, alignment: .leading)
                }
                if let report = journal.report, !working { Report(text: report).padding(.top, Metrics.inset) }
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

    static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(max(0, seconds))).formatted(.time(pattern: .minuteSecond))
    }

    /// What it reported. Limit: Markdown's inline marks and headings; a table or a list stands as written.
    private struct Report: View {
        let text: String
        var body: some View {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    if paragraph.hasPrefix("#") {
                        Text(paragraph.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)).font(
                            .ui(13, weight: .semibold))
                    } else {
                        Text(LocalizedStringKey(paragraph)).font(.ui(13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Metrics.inset)
            .frame(maxWidth: 760, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous).fill(Color(nsColor: .fillRest)))
        }
    }
}
