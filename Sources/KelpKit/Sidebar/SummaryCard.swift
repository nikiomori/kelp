import AppKit
import Core
import DesignKit
import SwiftUI

/// Under a count in the row over the projects, when the pointer rests on it: the chats it counts, each with its
/// project, what it does now and for how long. A row opens its chat. It comes and goes as a row's hover card does.
@MainActor
final class SummaryCard {
    private let app: AppModel
    private let popover = NSPopover()
    private let pending = Debounce()
    private var warmUntil = Date.distantPast
    /// The count whose card is up.
    private(set) var kind: SummaryKind?
    /// It opened or closed: the rows it lists light up while it's there.
    var changed: () -> Void = {}

    init(app: AppModel) {
        self.app = app
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    /// The pointer came onto a count (`segment`) or left it (nil).
    func hover(_ segment: SummarySegment?, _ counts: SummaryCounts) {
        guard let segment else {
            pending.after(Motion.hoverClose) { [weak self] in self?.closeUnlessInside() }
            return
        }
        let warm = popover.isShown || Date() < warmUntil
        pending.after(warm ? Motion.hoverOpenWarm : Motion.hoverOpen) { [weak self, weak segment] in
            if let segment, segment.hovering { self?.show(segment, counts) }
        }
    }

    /// What it lists changed while it's up.
    func refresh(_ counts: SummaryCounts) {
        guard let kind, popover.isShown else { return }
        guard !counts[kind].isEmpty else { return close() }
        (popover.contentViewController as? NSHostingController<SummaryCardView>)?.rootView = view(kind, counts)
    }

    func close() {
        pending.cancel()
        if popover.isShown {
            warmUntil = Date().addingTimeInterval(0.8)
            popover.close()
        }
        if kind != nil {
            kind = nil
            changed()
        }
    }

    private func show(_ segment: SummarySegment, _ counts: SummaryCounts) {
        guard segment.window != nil, !counts[segment.kind].isEmpty else { return close() }
        let host = NSHostingController(rootView: view(segment.kind, counts))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: segment.bounds, of: segment, preferredEdge: .minY)
        kind = segment.kind
        changed()
    }

    /// The pointer went into the card, whose rows are for clicking: it stays until the pointer leaves.
    private func closeUnlessInside() {
        guard popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) == true else {
            return close()
        }
        pending.after(Motion.hoverClose) { [weak self] in self?.closeUnlessInside() }
    }

    private func view(_ kind: SummaryKind, _ counts: SummaryCounts) -> SummaryCardView {
        SummaryCardView(
            heading: Self.heading(kind), rows: counts[kind].map { row($0, kind) },
            foot: String(localized: "Click: the next one")
        ) { [weak self] id in
            self?.close()
            self?.app.workbench.focus(session: id)
        }
    }

    private static func heading(_ kind: SummaryKind) -> String {
        switch kind {
        case .working: String(localized: "Working")
        case .limit: String(localized: "At a limit")
        case .quiet: String(localized: "No news")
        case .done: String(localized: "Done, not looked at")
        }
    }

    private func row(_ s: Session, _ kind: SummaryKind) -> SummaryCardView.Row {
        let place = app.worktree(s.worktreeId).flatMap { app.projectName($0.repoId) }
        let now: String
        switch kind {
        case .working:
            let subagents = s.runningSubagents.count
            now =
                s.running.map { String(localized: "Running \($0)") }
                ?? (subagents > 0 ? String(localized: "\(subagents) subagents") : nil)
                ?? (s.summary.isEmpty ? s.statusWords : s.summary)
        case .limit:
            let line = app.extensions.all.plans?.rowLine(s).map { "\($0.word) \($0.text)" }
            now = line ?? String(localized: "At its limit")
        case .quiet:
            now = String(localized: "No news for \(shortSpan(Date().timeIntervalSince(SummaryCounts.since(s, kind))))")
        case .done:
            now = s.summary.isEmpty ? s.statusWords : s.summary
        }
        return SummaryCardView.Row(
            id: s.id, icon: app.catalog.icon(s.agent, size: 14), title: app.catalog.displayName(s),
            line: [place, now].compactMap { $0 }.joined(separator: " · "),
            time: kind == .limit ? "" : shortAgo(SummaryCounts.since(s, kind)))
    }
}

struct SummaryCardView: View {
    struct Row: Identifiable {
        let id: String
        let icon: NSImage?
        let title: String, line: String, time: String
    }
    let heading: String
    let rows: [Row]
    let foot: String
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.lineGap) {
            Text(heading).font(.ui(TextSize.caption, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.bottom, 4)
            ForEach(rows) { row in
                Button { open(row.id) } label: { line(row) }.buttonStyle(PointerButtonStyle())
            }
            Divider().padding(.vertical, 4)
            Text(foot).font(.ui(TextSize.caption)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
        .padding(Metrics.gapWide)
        .frame(width: 300)
    }

    private func line(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: Metrics.gapWide) {
            if let icon = row.icon { Image(nsImage: icon).padding(.top, 1) }
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(row.title).font(.ui(TextSize.row)).lineLimit(1)
                Text(row.line).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Metrics.gapWide)
            Text(row.time).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
