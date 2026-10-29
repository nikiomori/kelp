import AppKit
import SwiftUI
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// "routines:<project>" — the project's routines over this week: a row a routine, a column a day, a mark a run (done,
/// asked, failed, running, missed) and, ahead, when it's due. Under the week, the chosen routine: its prompt, when it
/// repeats, and how the chosen run went.
@MainActor
final class RoutinesTab: KelpKit.TabContent {   // not SwiftUI's
    let uri: String
    let view: NSView
    var title: String { String(localized: "Routines") }
    var icon: NSImage? { .symbol("clock.arrow.circlepath") }
    init(uri: String, app: AppModel) {
        self.uri = uri
        view = NSHostingView(rootView: RoutinesView(app: app, repoId: TabURI.body(uri)))
    }
    func focus() {}
}

struct RoutinesView: View {
    let app: AppModel, repoId: String
    @State private var chosen: String?   // routine
    @State private var picked: String?   // run

    var routines: [Routine] { app.routines?.routines.filter { $0.repoId == repoId } ?? [] }
    var runs: [Routine.Run] { app.routines?.runs ?? [] }

    var body: some View {
        TimelineView(.everyMinute) { t in
            let week = RoutineWeek(now: t.date), list = routines
            VStack(spacing: 0) {
                header(week, list)
                Divider()
                if list.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No Routines"), systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("An agent on a schedule: triage new issues every morning, run the tests every night.")
                    } actions: {
                        Button(String(localized: "New Routine…")) { newRoutine() }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            WeekGrid(week: week, routines: list, runs: runs, chosen: $chosen, picked: $picked, app: app)
                            Divider()
                            if let r = list.first(where: { $0.id == chosen }) ?? list.first {
                                RoutineDetail(app: app, routine: r, runs: runs.filter { $0.routineId == r.id }, picked: picked, week: week)
                            }
                        }
                    }
                }
            }
        }
    }

    private func header(_ week: RoutineWeek, _ list: [Routine]) -> some View {
        HStack(spacing: Metrics.gapWide) {
            let on = list.filter(\.enabled).count
            let span = week.days.first.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
            let last = week.days.last.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
            Text("\(list.count) routines · \(on) on · this week, \(span) – \(last)").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "New Routine…")) { newRoutine() }.controlSize(.small)
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: Metrics.contentBar)
    }

    private func newRoutine() {
        let app = self.app, repo = repoId
        Task {
            guard let r = await RoutineSheet.run(app, repoId: repo), let saved = await app.call(RoutineSet(routine: r)) else { return }
            chosen = saved.id
        }
    }
}

/// The week: names on the left, a column a day (today's shaded), a mark a run.
struct WeekGrid: View {
    let week: RoutineWeek, routines: [Routine], runs: [Routine.Run]
    @Binding var chosen: String?
    @Binding var picked: String?
    let app: AppModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: 220, height: 1)
                ForEach(week.days, id: \.self) { day in
                    let today = week.isToday(day)
                    Text(day.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.caption.weight(today ? .semibold : .regular)).foregroundStyle(today ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity, minHeight: Metrics.rowSection)
                        .background(today ? Color(nsColor: .fillRest) : .clear)
                }
                Color.clear.frame(width: Metrics.iconButton + Metrics.inset, height: 1)
            }
            ForEach(routines) { r in
                GridRow {
                    name(r)
                    ForEach(week.days, id: \.self) { day in cell(r, day) }
                    Button { run(r) } label: {
                        Image(systemName: runs.contains { $0.routineId == r.id && [.running, .asked].contains($0.outcome) } ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless).help(String(localized: "Run Now")).frame(width: Metrics.iconButton + Metrics.inset)
                }
                .frame(minHeight: 44)
                .background((chosen ?? routines.first?.id) == r.id ? Color(nsColor: .fillSelected) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { chosen = r.id; picked = nil }
                Divider().gridCellUnsizedAxes(.horizontal)
            }
        }
    }

    private func name(_ r: Routine) -> some View {
        HStack(spacing: Metrics.gapWide) {
            Toggle("", isOn: Binding(get: { r.enabled }, set: { on in
                var x = r; x.enabled = on
                Task { await app.call(RoutineSet(routine: x)) }
            }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(r.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(RoutineWeek.schedule(r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .frame(width: 220, alignment: .leading)
        .opacity(r.enabled ? 1 : 0.55)
    }

    private func cell(_ r: Routine, _ day: Date) -> some View {
        let marks = week.marks(r, runs: runs, day: day)
        return HStack(spacing: 2) {
            ForEach(marks.prefix(marks.count > 3 ? 2 : 3)) { m in
                RunMark(mark: m, picked: m.run != nil && m.run?.id == picked).onTapGesture {
                    chosen = r.id
                    picked = m.run?.id
                }
            }
            if marks.count > 3 { Text("+\(marks.count - 2)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(week.isToday(day) ? Color(nsColor: .fillRest) : .clear)
    }

    private func run(_ r: Routine) {
        let app = self.app
        if let open = runs.first(where: { $0.routineId == r.id && [.running, .asked].contains($0.outcome) }), let s = open.sessionId {
            Task { await app.call(SessionKill(id: s)) }
        } else {
            Task { if let run = await app.call(RoutineRun(id: r.id)) { picked = run.id; chosen = r.id } }
        }
    }
}

/// One run, or a time it's due: ✓ done, ● asked, ! failed, spinner running, dashed missed; ahead, a ring (the next one
/// in the accent colour). Its time under it.
struct RunMark: View {
    let mark: RoutineWeek.Mark, picked: Bool

    var body: some View {
        VStack(spacing: 1) {
            symbol.frame(height: 16)
            Text(mark.at.formatted(date: .omitted, time: .shortened)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 3).padding(.vertical, 2)
        .background(picked ? Color(nsColor: .fillSelected) : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusXS))
        .help(mark.run?.summary ?? "")
    }

    @ViewBuilder private var symbol: some View {
        switch mark.kind {
        case .run(.running): ProgressView().controlSize(.mini)
        case .run(.done): Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        case .run(.asked): Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.textOrange)
        case .run(.failed): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.textRed)
        case .run(.missed): Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .next: Image(systemName: "circle").foregroundStyle(Color.accentColor)
        case .planned: Image(systemName: "circle").foregroundStyle(.quaternary)
        }
    }
}
