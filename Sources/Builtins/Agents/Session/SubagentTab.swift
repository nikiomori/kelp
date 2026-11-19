import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// The model of a "subagent:<session>/<id>" tab, which shows what a subagent did, step by step, and what it reported.
/// A subagent has no terminal, and Claude Code keeps all of this beside its parent's conversation. So the tab only
/// reads it, and reads it again when a new step comes (`WatchTopic.subagents`).
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

    /// What triggers a new read: another step, or the subagent's end, because its report comes last.
    private struct Change: Equatable { var touched: Date?, working: Bool }

    /// The first read has taken a second: only then does the wait show.
    @State private var slow = false

    private var run: Subagent? { app.session(model.session)?.subagentRuns?.first { $0.id == model.id } }
    private var working: Bool { run.map { $0.ended == nil } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            if let journal = model.journal {
                header(journal)
                Divider()
                steps(journal)
            } else if let failed = model.failed {
                EmptyState(String(localized: "Can’t Read This Subagent"), symbol: "exclamationmark.triangle") {
                    Text(failed)
                } actions: {
                    Button(String(localized: "Try Again")) { Task { await load() } }
                }
            } else if model.loaded {
                EmptyState(String(localized: "Nothing to Show"), symbol: "list.bullet.rectangle") {
                    Text("Claude Code kept no record of this subagent.")
                }
            } else if slow {
                // Where the empty state would stand, lifted as it is, so one gives way to the other without a jump.
                LoadingLine(String(localized: "Reading the subagent’s steps…")).offset(y: -Metrics.emptyLift)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Only the first read waits in view; later ones read again under the steps already shown.
        let wait = model.loaded ? nil : whileSlow { slow = true }
        let (value, error) = await app.tryCall(SessionSubagentJournal(id: model.session, subagent: model.id))
        wait?.cancel()
        slow = false
        model.journal = value ?? nil
        model.failed = error
        model.loaded = true
    }

    /// The tab's bar: the subagent's task, its facts in grey, and the way to its agent on the bar's plate.
    private func header(_ journal: SessionSubagentJournal.Journal) -> some View {
        ContentBar {
            Text(journal.task ?? (journal.kind.isEmpty ? String(localized: "Subagent") : journal.kind)).font(
                .ui(TextSize.body, weight: .semibold)
            )
            .lineLimit(1)
            Text(facts(journal)).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if working, let run {
                Text(run.started, style: .timer).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(
                    .secondary)
            }
            Button("Go to Agent") { app.workbench.focus(session: model.session) }.lineLimit(1).fixedSize()
        }
    }

    private func facts(_ journal: SessionSubagentJournal.Journal) -> String {
        var parts = [journal.model, String(localized: "\(journal.steps.count) steps")].compactMap { $0 }
        if let context = journal.context { parts.append(String(localized: "\(shortTokens(context)) context")) }
        return parts.joined(separator: " · ")
    }

    private func steps(_ journal: SessionSubagentJournal.Journal) -> some View {
        let start = run?.started ?? journal.steps.first?.at ?? Date()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(journal.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.gap) {
                        Text(Self.clock(step.at.timeIntervalSince(start))).font(.ui(TextSize.caption).monospacedDigit())
                            .foregroundStyle(
                                .secondary
                            )
                            .frame(width: 48, alignment: .trailing)
                        Text(step.tool).font(.ui(TextSize.row)).foregroundStyle(.secondary).frame(
                            width: 72, alignment: .leading
                        )
                        .lineLimit(1)
                        Text(step.detail).font(.uiMono(TextSize.caption)).lineLimit(1).truncationMode(.middle)
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

    static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(max(0, seconds))).formatted(.time(pattern: .minuteSecond))
    }

    /// The subagent's report. Limit: Markdown's inline marks and headings; a table or a list stands as written.
    private struct Report: View {
        let text: String
        var body: some View {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    if paragraph.hasPrefix("#") {
                        Text(paragraph.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)).font(
                            .ui(TextSize.body, weight: .semibold))
                    } else {
                        Text(LocalizedStringKey(paragraph)).font(.ui(TextSize.body)).fixedSize(
                            horizontal: false, vertical: true)
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
