import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// The chosen routine, under the week: what it tells the agent, when it repeats (changed here at once), where it runs,
/// and how the chosen run (else the last one) went.
struct RoutineDetail: View {
    let app: AppModel, routine: Routine, runs: [Routine.Run], picked: String?, week: RoutineWeek

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.inset) {
            HStack(spacing: Metrics.gapWide) {
                if let icon = app.catalog.icon(routine.agent, size: 28) { Image(nsImage: icon) }
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    Text(routine.name).font(.ui(TextSize.body, weight: .semibold))
                    Text([app.catalog.name(routine.agent), routine.model].compactMap { $0 }.joined(separator: " · "))
                        .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Run Now")) { Task { await app.call(RoutineRun(id: routine.id)) } }
                    .disabled(runs.contains(where: \.isOpen))
                Button(String(localized: "Edit…")) { RoutineActions(app: app).edit(routine) }
                Button(String(localized: "Delete…")) { RoutineActions(app: app).delete(routine) }
            }
            .controlSize(.small)   // a page's inline buttons are the system's small ones
            Text(routine.prompt).font(.ui(TextSize.row)).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading
            )
            .padding(Metrics.gapWide).background(
                Color(nsColor: .fillRest), in: RoundedRectangle(cornerRadius: Metrics.radiusMD))
            // As wide as its words: capped at 420 pt, a longer language's segments ran past both sides of the cap
            // and the labels were cut at the page's edge.
            Form { RepeatFields(routine: Binding(get: { routine }, set: { save($0) })) }.formStyle(.columns)
                .fixedSize(horizontal: true, vertical: false).controlSize(.small)   // a page's controls are small
            facts
            if let run = runs.first(where: { $0.id == picked }) ?? runs.first { RunResult(app: app, run: run) }
        }
        .padding(.horizontal, Metrics.pageInset).padding(.vertical, Metrics.pageTop)
    }

    /// The next run, where the routine runs, and what a missed run does.
    private var facts: some View {
        let next =
            routine.enabled
            ? routine.next(after: week.now).map {
                String(localized: "Next: \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
            }
            : String(localized: "Off")
        let place =
            app.worktree(routine.worktreeId).map { String(localized: "Runs in its group “\($0.displayName)”") }
            ?? String(localized: "Runs in a group of its own, made at its first run")
        let wake =
            routine.onWake
            ? String(localized: "Missed while the Mac slept: runs once it wakes")
            : String(localized: "Missed while the Mac slept: skipped")
        return Text(
            [next, place, wake, String(localized: "Asks for permission as usual")].compactMap { $0 }.joined(
                separator: " · ")
        )
        .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
    }

    private func save(_ routine: Routine) { Task { await app.call(RoutineSet(routine: routine)) } }
}

/// Run Now, on and off, Edit and Delete, from a routine's page, its row, its row's right-click and the commands.
@MainActor
struct RoutineActions {
    let app: AppModel

    /// Run Now, or Stop while a run of it is open, as the row's button says. Returns the run it started.
    func runOrStop(_ routine: Routine, runs: [Routine.Run]) async -> Routine.Run? {
        if let open = runs.first(where: { $0.routineId == routine.id && $0.isOpen }), let sessionId = open.sessionId {
            await app.call(SessionKill(id: sessionId))
            return nil
        }
        return await app.call(RoutineRun(id: routine.id))
    }

    func turn(_ routine: Routine, on: Bool) {
        var changed = routine
        changed.enabled = on
        Task { await app.call(RoutineSet(routine: changed)) }
    }

    func edit(_ routine: Routine) {
        let app = self.app
        Task {
            if let changed = await RoutineSheet.run(app, repoId: routine.repoId, editing: routine) {
                await app.call(RoutineSet(routine: changed))
            }
        }
    }

    func delete(_ routine: Routine) {
        let app = self.app
        Task {
            if await confirm(
                String(localized: "Delete “\(routine.name)”?"),
                detail: String(localized: "It stops running. Its group and the tabs of its runs stay."),
                action: String(localized: "Delete"), destructive: true)
            {
                await app.call(RoutineDelete(id: routine.id))
            }
        }
    }
}

/// "Done · Thu 9:00 · 3 min" and the agent's first line. Open Run shows the run's tab (Answer, when it asks).
struct RunResult: View {
    let app: AppModel, run: Routine.Run

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(spacing: Metrics.gap) {
                RunMark(mark: .init(id: run.id, at: run.due, kind: .run(run.outcome), run: run), picked: false)
                Text(headline).font(.ui(TextSize.row))
                Spacer()
                if let sessionId = run.sessionId, app.session(sessionId) != nil {
                    Button(run.outcome == .asked ? String(localized: "Answer") : String(localized: "Open Run")) {
                        app.workbench.focus(session: sessionId)
                    }
                    .controlSize(.small)
                }
            }
            if !run.summary.isEmpty {
                Text(prefix + run.summary).font(.ui(TextSize.row)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if run.late {
                Text(
                    "Ran late: the Mac was asleep or Kelp wasn’t running at \(run.due.formatted(date: .omitted, time: .shortened))"
                )
                .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(Metrics.inset)
        .background(Color(nsColor: .fillRest), in: RoundedRectangle(cornerRadius: Metrics.radiusMD))
    }

    private var prefix: String {
        switch run.outcome {
        case .asked: String(localized: "Asks: ")
        case .failed: String(localized: "Failed: ")
        default: ""
        }
    }

    private var headline: String {
        let state =
            switch run.outcome {
            case .running: String(localized: "Running")
            case .asked: String(localized: "Needs you")
            case .done: String(localized: "Done")
            case .failed: String(localized: "Failed")
            case .missed: String(localized: "Missed")
            }
        let when = run.due.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let units = Duration.UnitsFormatStyle.units(
            allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1)
        let took = run.ended.map { " · " + Duration.seconds($0.timeIntervalSince(run.started)).formatted(units) } ?? ""
        return "\(state) · \(when)\(took)"
    }
}

/// The routine chosen on each project's Routines tab, so the Routines commands act on the one in front, as its row's
/// right-click does.
@MainActor @Observable
final class RoutinePick {
    var chosen: [String: String] = [:]   // a project's id → its chosen routine's id

    /// The routine chosen on the Routines tab in front, else that tab's first; nil when no Routines tab is in front.
    func front(_ app: AppModel) -> Routine? {
        guard let uri = app.workbench.focusedContent?.uri, TabURI.scheme(uri) == "routines" else { return nil }
        let repoId = TabURI.body(uri)
        let list = app.latest(RoutinesEvent.self)?.routines.filter { $0.repoId == repoId } ?? []
        return list.first { $0.id == chosen[repoId] } ?? list.first
    }

    func runs(_ app: AppModel) -> [Routine.Run] { app.latest(RoutinesEvent.self)?.runs ?? [] }

    /// Whether a run of `routine` is open, so Stop and not Run Now is offered.
    func isOpen(_ routine: Routine, _ app: AppModel) -> Bool {
        runs(app).contains { $0.routineId == routine.id && $0.isOpen }
    }
}

extension Routine.Run {
    /// Whether the run is still going: running, or waiting on a question.
    var isOpen: Bool { [.running, .asked].contains(outcome) }
}
