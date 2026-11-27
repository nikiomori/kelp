import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// The overview's figures on one plate, with a rule between neighbours, as the Usage tab's.
struct OverviewPlate: View {
    struct Stat: Identifiable {
        var value: String
        var orange = false
        var added: Int?, removed: Int?
        var note: String
        var meter: Double?
        var id: String { value + note }
        init(
            value: String, orange: Bool = false, added: Int? = nil, removed: Int? = nil, note: String,
            meter: Double? = nil
        ) {
            (self.value, self.orange, self.added, self.removed, self.note, self.meter) =
                (value, orange, added, removed, note, meter)
        }
    }
    let stats: [Stat]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { i, stat in
                if i > 0 { Divider() }
                VStack(alignment: .leading, spacing: 2) {
                    figure(stat).font(.ui(TextSize.title, weight: .semibold).monospacedDigit()).lineLimit(1)
                    Text(stat.note).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(2)
                    if let used = stat.meter { Meter(used: used).frame(width: 110).padding(.top, 4) }
                }
                .padding(Metrics.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous).fill(Color(nsColor: .fillRest)))
    }

    @ViewBuilder private func figure(_ stat: Stat) -> some View {
        if let added = stat.added, let removed = stat.removed {
            Text("+\(added)").foregroundStyle(Color.textGreen)
                + Text(verbatim: " −\(removed)").foregroundStyle(Color.textRed)
        } else {
            Text(stat.value).foregroundStyle(stat.orange ? Color.textOrange : .primary)
        }
    }
}

/// A plan's bar: grey, orange when it is nearly used up.
struct Meter: View {
    let used: Double
    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule().fill(used >= Insight.nearLimit ? Color.orange : Color.secondary)
                    .frame(width: box.size.width * min(1, max(0, used)))
            }
        }
        .frame(height: 4)
    }
}

/// The board: one column per stage, each chat a card. A chat that asks stands first in its column and glows, rather
/// than moving to a column of its own, so a card moves only as its work does.
struct OverviewBoard: View {
    let cards: [OverviewCard]
    let hours: (from: Date, to: Date)
    let app: AppModel
    let answer: (Session) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.gapWide + 2) {
            ForEach(OverviewStage.allCases, id: \.self) { stage in
                let mine = cards.filter { $0.stage == stage }
                VStack(alignment: .leading, spacing: Metrics.gapWide) {
                    HStack(spacing: Metrics.gap) {
                        Text(stage.title).font(.ui(TextSize.row, weight: .semibold))
                        Count(mine.count)
                    }
                    .padding(.horizontal, 4)
                    ForEach(mine) { OverviewCardView(card: $0, hours: hours, app: app, answer: answer) }
                }
                .padding(Metrics.gapWide)
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous).fill(Color(nsColor: .fillRest))
                )
            }
        }
    }
}

/// A section's count: digits on a grey capsule, as `CountCapsule` draws it in panels.
struct Count: View {
    let n: Int
    init(_ n: Int) { self.n = n }
    var body: some View {
        Text("\(n)").font(.ui(TextSize.micro, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Color(nsColor: .fillSelected)))
    }
}

/// One chat's card: what it said, its day, its figures, its pull request. A click opens the chat; under the pointer it
/// offers Answer (when it asks), Open Chat and Changes.
struct OverviewCardView: View {
    let card: OverviewCard
    let hours: (from: Date, to: Date)
    let app: AppModel
    let answer: (Session) -> Void
    @State private var hovered = false

    private var s: Session { card.session }
    private var asks: Bool { s.status == .waiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Metrics.gap) {
                StatusIcon(status: s.status, of: s).frame(width: 12, height: 12)
                if let icon = app.catalog.icon(s.agent) {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                }
                Text(s.displayTitle).font(.ui(TextSize.body, weight: .medium))
                    .foregroundStyle(asks ? Color.textOrange : .primary).lineLimit(1)
                Spacer(minLength: 4)
                if let pr = card.pr { prMark(pr) }
            }
            Text(
                [card.project, card.branch].compactMap { $0 }.filter { !$0.isEmpty && $0 != "main" }.joined(
                    separator: " · ")
            )
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            // The task the chat was started for, the person's line (☐), as the Tasks tab lists it.
            if let task = TaskActions.task(of: s, in: app) {
                Label(task.title, systemImage: task.state == .done ? "checkmark.square" : "square")
                    .font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            says.font(.ui(TextSize.row)).lineLimit(1)
            if !card.line.spans.isEmpty { time }
            figures
            if hovered { actions.transition(.opacity) }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous).fill(
                Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous)
                .strokeBorder(asks ? Color.orange : Color(nsColor: .separatorColor), lineWidth: asks ? 1.5 : 1)
        )
        .shadow(color: asks ? Color(nsColor: .fillTint(.systemOrange)) : .clear, radius: Metrics.gap)
        .opacity(card.stage == .done ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { on in withAnimation(Motion.reduced ? nil : .easeOut(duration: Motion.fast)) { hovered = on } }
        .onTapGesture { app.workbench.focus(session: s.id) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var says: some View {
        let summary = s.summary.isEmpty ? s.status.words : s.summary
        if asks {
            Text("Asks: ").foregroundStyle(Color.textOrange).fontWeight(.medium) + Text(summary)
        } else if s.status == .error {
            Text("Failed: ").foregroundStyle(Color.textRed).fontWeight(.medium)
                + Text(summary).foregroundStyle(.secondary)
        } else if s.status == .working, let running = s.running {
            Text(running).font(.ui(TextSize.caption).monospaced()).foregroundStyle(.secondary)
        } else if let hit = s.limitHit {
            Text(String(localized: "Limit · \(hit.resets ?? "")")).foregroundStyle(.secondary)
        } else {
            Text(summary).foregroundStyle(.secondary)
        }
    }

    private var time: some View {
        HStack(spacing: Metrics.gapWide) {
            DayBar(line: card.line, from: hours.from, to: hours.to).frame(width: 128, height: 5)
            Text(shortSpan(card.line.worked, units: 2)).monospacedDigit()
            if let waits = card.line.waitsNow {
                Text("waits \(shortSpan(waits))").foregroundStyle(Color.textOrange).fontWeight(.semibold)
            }
        }
        .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
    }

    private var figures: some View {
        HStack(spacing: Metrics.gapWide + 2) {
            if card.added + card.removed > 0 {
                Text("+\(card.added)").foregroundStyle(Color.textGreen)
                    + Text(verbatim: " −\(card.removed)").foregroundStyle(Color.textRed)
            }
            if let files = card.turn?.files.count, files > 0 { Text("\(files) files") }
            if card.line.turns > 0 { Text("\(card.line.turns) turns") }
            if let subagents = s.subagentRuns?.count, subagents > 0 {
                Label("\(subagents)", systemImage: "person.2").labelStyle(.titleAndIcon)
            }
            if let context = card.context {
                HStack(spacing: 4) {
                    ContextPie(share: context).frame(width: 11, height: 11)
                    Text(verbatim: "\(Int((context * 100).rounded())) %")
                }
            }
        }
        .font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: Metrics.gap) {
            if asks { Button(String(localized: "Answer…")) { answer(s) }.buttonStyle(.borderedProminent) }
            Button(String(localized: "Open Chat")) { app.workbench.focus(session: s.id) }
            if !(card.turn?.files.isEmpty ?? true) {
                Button(String(localized: "Changes")) {
                    app.workbench.open(
                        TabURI.diff(card.folder, source: .turn, session: s.id), workspace: s.worktreeId ?? card.folder)
                }
            }
        }
        .controlSize(.small)
    }

    private func prMark(_ pr: GitHub.PullRequest) -> some View {
        HStack(spacing: 4) {
            Text("#\(pr.number)").font(.ui(TextSize.caption, weight: .semibold))
                .foregroundStyle(
                    pr.state == "MERGED" ? Color.textPurple : pr.state == "OPEN" ? Color.textGreen : .secondary)
            if pr.state == "OPEN", pr.checks.failed + pr.checks.passed + pr.checks.pending > 0 {
                Image(systemName: pr.checks.failed > 0 ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(pr.checks.failed > 0 ? Color.red : Color.secondary).font(.ui(TextSize.caption))
                    .accessibilityLabel(pr.checks.failed > 0 ? Text("CI failed") : Text("CI passed"))
            }
        }
    }
}

/// How full a conversation is, as the tab's context mark draws it: grey, orange when it is time to compact.
struct ContextPie: View {
    let share: Double
    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2, c = CGPoint(x: size.width / 2, y: size.height / 2)
            let color = share >= Insight.fullContext ? Color.orange : Color.secondary
            context.stroke(
                Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)),
                with: .color(Color(nsColor: .tertiaryLabelColor)))
            var wedge = Path()
            wedge.move(to: c)
            wedge.addArc(
                center: c, radius: r - 0.5, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, share)),
                clockwise: false)
            context.fill(wedge, with: .color(color))
        }
    }
}

/// Needs Attention, beside the board: what holds the work up now, each line taking the user to its chat.
struct InsightsColumn: View {
    let insights: [Insight]
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.gap) {
                Text("Needs Attention").font(.ui(TextSize.row, weight: .semibold))
                Count(insights.count)
            }
            .padding(Metrics.inset)
            Divider()
            ForEach(insights) { line in
                Button {
                    if let id = line.session { app.workbench.focus(session: id) }
                } label: {
                    HStack(alignment: .top, spacing: Metrics.gapWide) {
                        symbol(line.kind).frame(width: 12, height: 12).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title).font(.ui(TextSize.row, weight: .medium)).foregroundStyle(color(line.kind))
                            Text(line.detail).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metrics.inset).padding(.vertical, Metrics.gapWide)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PointerButtonStyle(flush: true))
                Divider()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous).fill(
                Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous).strokeBorder(
                Color(nsColor: .separatorColor)))
    }

    @ViewBuilder private func symbol(_ kind: Insight.Kind) -> some View {
        switch kind {
        case .asks: StatusIcon(status: .waiting)
        case .failed: StatusIcon(status: .error)
        case .sameFile: Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
        case .review: Image(systemName: "eye").foregroundStyle(.secondary)
        case .context: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
        case .limit: Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    private func color(_ kind: Insight.Kind) -> Color {
        switch kind {
        case .asks: .textOrange
        case .failed: .textRed
        default: .primary
        }
    }
}
