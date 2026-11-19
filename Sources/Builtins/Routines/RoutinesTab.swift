import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// "routines:<project>": the project's routines over this week, with a row per routine, a column per day, and a mark
/// per run (done, asked, failed, running, missed), plus, ahead, when each routine is due. Under the week is the chosen
/// routine: its prompt, when it repeats, and how the chosen run went.
@MainActor
func routinesTab(uri: String, app: AppModel) -> KelpKit.TabContent {   // not SwiftUI's
    HostedTabContent(
        uri: uri, title: String(localized: "Routines"), icon: "clock.arrow.circlepath", app: app,
        RoutinesView(app: app, repoId: TabURI.body(uri)))
}

struct RoutinesView: View {
    let app: AppModel, repoId: String
    @State private var chosen: String?   // the chosen routine's id
    @State private var picked: String?   // the picked run's id

    var routines: [Routine] { app.latest(RoutinesEvent.self)?.routines.filter { $0.repoId == repoId } ?? [] }
    var runs: [Routine.Run] { app.latest(RoutinesEvent.self)?.runs ?? [] }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let week = RoutineWeek(now: context.date), list = routines
            VStack(spacing: 0) {
                header(week, list)
                Divider()
                if list.isEmpty {
                    EmptyState(String(localized: "No Routines"), symbol: "clock.arrow.circlepath") {
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
            // A tab kept after its project went has no name to show: the line stands alone.
            if let project = app.repo(repoId)?.name { Text(project).font(.ui(TextSize.body, weight: .semibold)) }
            Text("\(list.count) routines · \(on) on · this week, \(span) – \(last)").font(.ui(TextSize.caption))
                .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            // With no routines, the button is under No Routines instead.
            if !list.isEmpty { Button(String(localized: "New Routine…")) { newRoutine() } }
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

/// The week: names on the left, a column per day (today's shaded), and a mark per run.
struct WeekGrid: View {
    let week: RoutineWeek, routines: [Routine], runs: [Routine.Run]
    @Binding var chosen: String?
    @Binding var picked: String?
    let app: AppModel
    @State private var hovered: String?   // the routine whose row is under the pointer

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
                        .frame(maxWidth: .infinity, minHeight: TextSize.of(Metrics.rowSection))
                        .background(today ? Color(nsColor: .fillRest) : .clear)
                }
                Color.clear.frame(width: Metrics.iconButton + Metrics.inset, height: 1)
            }
            ForEach(routines) { routine in
                GridRow {
                    piece(name(routine), of: routine, .leading)
                    ForEach(week.days, id: \.self) { day in piece(cell(routine, day), of: routine) }
                    piece(runButton(routine), of: routine, .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    chosen = routine.id
                    picked = nil
                }
                .onHover { hovered = $0 ? routine.id : (hovered == routine.id ? nil : hovered) }
                Divider().gridCellUnsizedAxes(.horizontal)
            }
        }
    }

    /// One cell of a routine's row over the row's fill: the chosen row's, else the one under the pointer. A modifier on
    /// a `GridRow` goes to each cell, not to the row, so the fill is drawn in pieces that touch: the first and the last
    /// round their outer corners and stay `Metrics.gap` from the page's edges, as a list's rows do.
    private func piece(_ content: some View, of routine: Routine, _ edge: HorizontalEdge? = nil) -> some View {
        let on = (chosen ?? routines.first?.id) == routine.id
        let lead = edge == .leading ? Metrics.radiusSM : 0, trail = edge == .trailing ? Metrics.radiusSM : 0
        return content.frame(minHeight: 44).background(
            UnevenRoundedRectangle(
                topLeadingRadius: lead, bottomLeadingRadius: lead, bottomTrailingRadius: trail, topTrailingRadius: trail
            )
            .fill(Color(nsColor: on ? .fillSelected : hovered == routine.id ? .fillHover : .clear))
            .padding(.leading, edge == .leading ? Metrics.gap : 0)
            .padding(.trailing, edge == .trailing ? Metrics.gap : 0)
            // The fill comes and goes under the pointer rather than switching; the row's content doesn't move.
            .animation(.easeOut(duration: Motion.duration(Motion.fast)), value: hovered)
        )
    }

    /// Run Now, or Stop while a run is open: the button says which, as its symbol does.
    private func runButton(_ routine: Routine) -> some View {
        let open = runs.contains { $0.routineId == routine.id && $0.isOpen }
        let verb = open ? String(localized: "Stop") : String(localized: "Run Now")
        return Button {
            run(routine)
        } label: {
            Image(systemName: open ? "stop.fill" : "play.fill").font(.symbol())
        }
        .buttonStyle(PointerButtonStyle()).help(verb).accessibilityLabel(verb)
        .frame(width: Metrics.iconButton + Metrics.inset)
    }

    private func name(_ routine: Routine) -> some View {
        HStack(spacing: Metrics.gapWide) {
            Toggle(
                routine.name,   // hidden; VoiceOver reads it, so each row's switch says whose it is
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
            // The same word as the row's button: a run that is open is stopped, not run again.
            let open = runs.contains { $0.routineId == routine.id && $0.isOpen }
            Button(open ? String(localized: "Stop") : String(localized: "Run Now")) { run(routine) }
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
                // Here a click picks the mark; on the run's card it is only a sign, so the trait isn't RunMark's own.
                .accessibilityAddTraits(.isButton)
            }
            if marks.count > 3 {
                Text("+\(marks.count - 2)").font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary)
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
                if let run = await app.call(RoutineRun(id: routine.id)) {
                    picked = run.id
                    chosen = routine.id
                }
            }
        }
    }
}

/// One run, or a time a run is due: ✓ done, ● asked, ! failed, the working ring running, dashed missed. Ahead, it is a ring
/// (the next one in the accent colour). The time sits under it.
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
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(
            picked ? Color(nsColor: .fillSelected) : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusXS)
        )
        .accessibilityElement(children: .ignore).accessibilityLabel(spoken)
        .help(mark.run?.summary ?? "")
    }

    /// What VoiceOver says in place of the symbol: what the mark means and its time ("Done, 9:00"). A run still going
    /// has no result to put a time to.
    private var spoken: String {
        let word: String
        switch mark.kind {
        case .run(.running): return String(localized: "Running")
        case .run(.done): word = String(localized: "Done")
        case .run(.asked): word = String(localized: "Asked")
        case .run(.failed): word = String(localized: "Failed")
        case .run(.missed): word = String(localized: "Missed")
        case .next: word = String(localized: "Next")
        case .planned: word = String(localized: "Planned")
        }
        return "\(word), \(mark.at.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder private var symbol: some View {
        switch mark.kind {
        case .run(.running): StatusIcon(status: .working)   // the ring of work going on by itself, as on a chat
        case .run(.done): Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        case .run(.asked): Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.textOrange)
        case .run(.failed): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.textRed)
        case .run(.missed): Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .next: Image(systemName: "circle").foregroundStyle(Color.accentColor)
        case .planned: Image(systemName: "circle").foregroundStyle(.quaternary)
        }
    }
}
