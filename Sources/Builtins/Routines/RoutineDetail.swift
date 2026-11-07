import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The chosen routine under the week: what it tells the agent, when it repeats (changed here at once), where it runs,
/// and how the chosen run (else the last one) went.
struct RoutineDetail: View {
    let app: AppModel, routine: Routine, runs: [Routine.Run], picked: String?, week: RoutineWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: Metrics.gapWide) {
                if let icon = app.catalog.icon(routine.agent, size: 28) { Image(nsImage: icon) }
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    Text(routine.name).font(.ui(13, weight: .semibold))
                    Text([app.catalog.name(routine.agent), routine.model].compactMap { $0 }.joined(separator: " · "))
                        .font(.ui(11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Run Now")) { Task { await app.call(RoutineRun(id: routine.id)) } }
                    .disabled(runs.contains { [.running, .asked].contains($0.outcome) })
                Button(String(localized: "Edit…")) { RoutineActions(app: app).edit(routine) }
                Button(String(localized: "Delete…")) { RoutineActions(app: app).delete(routine) }
            }
            Text(routine.prompt).font(.ui(12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.gapWide).background(
                    Color(nsColor: .fillRest), in: RoundedRectangle(cornerRadius: Metrics.radiusSM))
            Form { RepeatFields(routine: Binding(get: { routine }, set: { save($0) })) }.formStyle(.columns).frame(
                maxWidth: 420)
            facts
            if let run = runs.first(where: { $0.id == picked }) ?? runs.first { RunResult(app: app, run: run) }
        }
        .padding(Metrics.inset + 4)
    }

    /// Next run, where it runs, what a missed one does.
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
        .font(.ui(11)).foregroundStyle(.secondary)
    }

    private func save(_ routine: Routine) { Task { await app.call(RoutineSet(routine: routine)) } }
}

/// Edit and Delete, from a routine's page and from its row's right-click.
@MainActor
struct RoutineActions {
    let app: AppModel

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
            let alert = NSAlert()
            alert.messageText = String(localized: "Delete “\(routine.name)”?")
            alert.informativeText = String(localized: "It stops running. Its group and the tabs of its runs stay.")
            alert.addButton(withTitle: String(localized: "Delete")).hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "Cancel"))
            if await runSheet(alert) == .alertFirstButtonReturn { await app.call(RoutineDelete(id: routine.id)) }
        }
    }
}

/// "Done · Thu 9:00 · 3 min" and the agent's first line; Open Run shows its tab (Answer, when it asks).
struct RunResult: View {
    let app: AppModel, run: Routine.Run

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(spacing: Metrics.gap) {
                RunMark(mark: .init(id: run.id, at: run.due, kind: .run(run.outcome), run: run), picked: false)
                Text(headline).font(.ui(12, weight: .medium))
                Spacer()
                if let sessionId = run.sessionId, app.session(sessionId) != nil {
                    Button(run.outcome == .asked ? String(localized: "Answer") : String(localized: "Open Run")) {
                        app.workbench.focus(session: sessionId)
                    }
                }
            }
            if !run.summary.isEmpty {
                Text(prefix + run.summary).font(.ui(12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if run.late {
                Text(
                    "Ran late: the Mac was asleep or Kelp wasn't running at \(run.due.formatted(date: .omitted, time: .shortened))"
                )
                .font(.ui(11)).foregroundStyle(.tertiary)
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
