import AppKit
import SwiftUI
import Core
import DesignKit
import KelpKit

/// The chosen routine under the week: what it tells the agent, when it repeats (changed here at once), where it runs,
/// and how the chosen run (else the last one) went.
struct RoutineDetail: View {
    let app: AppModel, routine: Routine, runs: [Routine.Run], picked: String?, week: RoutineWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: Metrics.gapWide) {
                if let icon = app.catalog.icon(routine.agent, size: 28) { Image(nsImage: icon) }
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    Text(routine.name).font(.headline)
                    Text([app.catalog.name(routine.agent), routine.model].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Run Now")) { Task { await app.call(RoutineRun(id: routine.id)) } }
                    .disabled(runs.contains { [.running, .asked].contains($0.outcome) })
                Button(String(localized: "Edit…")) { edit() }
                Button(String(localized: "Delete…")) { delete() }
            }
            Text(routine.prompt).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.gapWide).background(Color(nsColor: .fillRest), in: RoundedRectangle(cornerRadius: Metrics.radiusSM))
            Form { RepeatFields(routine: Binding(get: { routine }, set: { save($0) })) }.formStyle(.columns).frame(maxWidth: 420)
            facts
            if let run = runs.first(where: { $0.id == picked }) ?? runs.first { RunResult(app: app, run: run) }
        }
        .padding(Metrics.inset + 4)
    }

    /// Next run, where it runs, what a missed one does.
    private var facts: some View {
        let next = routine.enabled
            ? routine.next(after: week.now).map { String(localized: "Next: \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") }
            : String(localized: "Off")
        let place = app.worktree(routine.worktreeId).map { String(localized: "Runs in its workspace “\($0.displayName)”") }
            ?? String(localized: "Runs in a workspace of its own, made at its first run")
        let wake = routine.onWake ? String(localized: "Missed while the Mac slept: runs once it wakes")
            : String(localized: "Missed while the Mac slept: skipped")
        return Text([next, place, wake, String(localized: "Asks for permission as usual")].compactMap { $0 }.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func save(_ r: Routine) { Task { await app.call(RoutineSet(routine: r)) } }

    private func edit() {
        let app = self.app, r = routine
        Task { if let changed = await RoutineSheet.run(app, repoId: r.repoId, editing: r) { await app.call(RoutineSet(routine: changed)) } }
    }

    private func delete() {
        let app = self.app, r = routine
        Task {
            let a = NSAlert()
            a.messageText = String(localized: "Delete “\(r.name)”?")
            a.informativeText = String(localized: "It stops running. Its workspace and the tabs of its runs stay.")
            a.addButton(withTitle: String(localized: "Delete")).hasDestructiveAction = true
            a.addButton(withTitle: String(localized: "Cancel"))
            if await runSheet(a) == .alertFirstButtonReturn { await app.call(RoutineDelete(id: r.id)) }
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
                Text(headline).font(.callout.weight(.medium))
                Spacer()
                if let s = run.sessionId, app.session(s) != nil {
                    Button(run.outcome == .asked ? String(localized: "Answer") : String(localized: "Open Run")) { app.workbench.focus(session: s) }
                }
            }
            if !run.summary.isEmpty {
                Text(prefix + run.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if run.late {
                Text("Ran late: the Mac was asleep or Kelp wasn't running at \(run.due.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
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
        let state = switch run.outcome {
        case .running: String(localized: "Running")
        case .asked: String(localized: "Needs you")
        case .done: String(localized: "Done")
        case .failed: String(localized: "Failed")
        case .missed: String(localized: "Missed")
        }
        let when = run.due.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let units = Duration.UnitsFormatStyle.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1)
        let took = run.ended.map { " · " + Duration.seconds($0.timeIntervalSince(run.started)).formatted(units) } ?? ""
        return "\(state) · \(when)\(took)"
    }
}
