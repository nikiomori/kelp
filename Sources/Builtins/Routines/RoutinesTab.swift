import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
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
        view = HostedTab(RoutinesView(app: app, repoId: TabURI.body(uri)))
    }
    func focus() {}
}

struct RoutinesView: View {
    let app: AppModel, repoId: String
    @State private var chosen: String?   // routine
    @State private var picked: String?   // run

    var routines: [Routine] { app.latest(RoutinesEvent.self)?.routines.filter { $0.repoId == repoId } ?? [] }
    var runs: [Routine.Run] { app.latest(RoutinesEvent.self)?.runs ?? [] }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let week = RoutineWeek(now: context.date), list = routines
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
                            if let routine = list.first(where: { $0.id == chosen }) ?? list.first {
                                RoutineDetail(
                                    app: app, routine: routine, runs: runs.filter { $0.routineId == routine.id },
                                    picked: picked,
                                    week: week)
                            }
                        }
                    }
                }
            }
        }
    }

    private func header(_ week: RoutineWeek, _ list: [Routine]) -> some View {
        ContentBar {
            let on = list.filter(\.enabled).count
            let span = week.days.first.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
            let last = week.days.last.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
            Text("\(list.count) routines · \(on) on · this week, \(span) – \(last)").font(.ui(TextSize.row))
                .foregroundStyle(
                    .secondary)
            Spacer()
            if !list.isEmpty { Button(String(localized: "New Routine…")) { newRoutine() } }   // else it's under No Routines
        }
    }

    private func newRoutine() {
        let app = self.app, repo = repoId
        Task {
            guard let routine = await RoutineSheet.run(app, repoId: repo),
                let saved = await app.call(RoutineSet(routine: routine))
            else { return }
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
                        .font(.ui(TextSize.caption, weight: today ? .semibold : .regular)).foregroundStyle(
                            today ? Color.accentColor : .secondary
                        )
                        .frame(maxWidth: .infinity, minHeight: Metrics.rowSection)
                        .background(today ? Color(nsColor: .fillRest) : .clear)
                }
                Color.clear.frame(width: Metrics.iconButton + Metrics.inset, height: 1)
            }
            ForEach(routines) { routine in
                GridRow {
                    name(routine)
                    ForEach(week.days, id: \.self) { day in cell(routine, day) }
                    Button {
                        run(routine)
                    } label: {
                        Image(
                            systemName: runs.contains { $0.routineId == routine.id && $0.isOpen }
                                ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless).help(String(localized: "Run Now")).frame(
                        width: Metrics.iconButton + Metrics.inset)
                }
                .frame(minHeight: 44)
                .background((chosen ?? routines.first?.id) == routine.id ? Color(nsColor: .fillSelected) : .clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    chosen = routine.id
                    picked = nil
                }
                Divider().gridCellUnsizedAxes(.horizontal)
            }
        }
    }

    private func name(_ routine: Routine) -> some View {
        HStack(spacing: Metrics.gapWide) {
            Toggle(
                "",
                isOn: Binding(get: { routine.enabled }, set: { RoutineActions(app: app).turn(routine, on: $0) })
            )
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(routine.name).font(.ui(TextSize.row, weight: .medium)).lineLimit(1)
                Text(RoutineWeek.schedule(routine)).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .frame(width: 220, alignment: .leading)
        .opacity(routine.enabled ? 1 : 0.55)
        .contextMenu {
            Button(String(localized: "Run Now")) { run(routine) }
            Button(String(localized: "Edit…")) { RoutineActions(app: app).edit(routine) }
            Button(routine.enabled ? String(localized: "Turn Off") : String(localized: "Turn On")) {
                RoutineActions(app: app).turn(routine, on: !routine.enabled)
            }
            Divider()
            Button(String(localized: "Delete…")) { RoutineActions(app: app).delete(routine) }
        }
    }

    private func cell(_ routine: Routine, _ day: Date) -> some View {
        let marks = week.marks(routine, runs: runs, day: day)
        return HStack(spacing: 2) {
            ForEach(marks.prefix(marks.count > 3 ? 2 : 3)) { mark in
                RunMark(mark: mark, picked: mark.run != nil && mark.run?.id == picked).onTapGesture {
                    chosen = routine.id
                    picked = mark.run?.id
                }
            }
            if marks.count > 3 {
                Text("+\(marks.count - 2)").font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(week.isToday(day) ? Color(nsColor: .fillRest) : .clear)
    }

    private func run(_ routine: Routine) {
        let app = self.app
        if let open = runs.first(where: { $0.routineId == routine.id && $0.isOpen }),
            let sessionId = open.sessionId
        {
            Task { await app.call(SessionKill(id: sessionId)) }
        } else {
            Task {
                if let run = await RoutineActions(app: app).runNow(routine) {
                    picked = run.id
                    chosen = routine.id
                }
            }
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
            Text(mark.at.formatted(date: .omitted, time: .shortened)).font(.ui(TextSize.caption).monospacedDigit())
                .foregroundStyle(
                    .secondary
                ).lineLimit(1)
        }
        .padding(.horizontal, 3).padding(.vertical, 2)
        .background(
            picked ? Color(nsColor: .fillSelected) : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusXS)
        )
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
