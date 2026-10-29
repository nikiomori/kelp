import AppKit
import SwiftUI
import Core
import DesignKit
import KelpKit

/// New Routine / Edit Routine: a sheet with the routine's name, agent, prompt and when it runs. A window of its own, not
/// an alert's accessory: the form grows a row for Weekly, and an alert keeps the size it opened with.
@MainActor
enum RoutineSheet {
    /// The routine as filled in; nil when cancelled.
    static func run(_ app: AppModel, repoId: String, editing: Routine? = nil) async -> Routine? {
        let agents = app.catalog.installed(app.catalog.all).map { (id: $0.id, name: $0.name) }
        let form = RoutineForm(editing ?? Routine(name: "", repoId: repoId, agent: app.catalog.defaultAgent, prompt: ""))
        let sheet = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let host = NSHostingController(rootView: RoutineFormView(form: form, agents: agents, editing: editing != nil) { [weak sheet] r in
            if let sheet { sheet.sheetParent?.endSheet(sheet, returnCode: r) }
        })
        host.sizingOptions = [.minSize, .maxSize]   // the sheet follows the form: taller for Weekly's day
        sheet.contentViewController = host
        guard await runSheet(sheet) == .OK, form.valid else { return nil }
        return form.routine
    }
}

@MainActor
@Observable
final class RoutineForm {
    var routine: Routine
    init(_ r: Routine) { routine = r }
    var valid: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty && !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct RoutineFormView: View {
    @Bindable var form: RoutineForm
    let agents: [(id: String, name: String)]
    let editing: Bool
    let end: (NSApplication.ModalResponse) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gapWide) {
            Text(editing ? String(localized: "Edit Routine") : String(localized: "New Routine")).font(.headline)
            Text("An agent on a schedule: at its time it starts with this prompt, in a workspace of its own.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            fields
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { end(.cancel) }.keyboardShortcut(.cancelAction)
                Button(editing ? String(localized: "Save") : String(localized: "Create")) { end(.OK) }
                    .keyboardShortcut(.defaultAction).disabled(!form.valid)
            }
        }
        .padding(Metrics.sheetInset)
        .frame(width: Metrics.sheetWidth)
    }

    private var fields: some View {
        Form {
            TextField(String(localized: "Name"), text: $form.routine.name, prompt: Text("Morning triage"))
            Picker(String(localized: "Agent"), selection: $form.routine.agent) {
                ForEach(agents, id: \.id) { Text($0.name).tag($0.id) }
                if !agents.contains(where: { $0.id == form.routine.agent }) { Text(form.routine.agent).tag(form.routine.agent) }
            }
            TextField(String(localized: "Model"), text: Binding(get: { form.routine.model ?? "" }, set: { form.routine.model = $0.isEmpty ? nil : $0 }),
                      prompt: Text("The agent's default"))
            LabeledContent(String(localized: "Prompt")) {
                TextEditor(text: $form.routine.prompt).font(.body).frame(height: 72)
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radiusXS).stroke(Color(nsColor: .separatorColor)))
            }
            RepeatFields(routine: $form.routine)
            Toggle(String(localized: "Missed while the Mac slept: run once it wakes"), isOn: $form.routine.onWake)
        }
        .formStyle(.columns)
    }
}

/// Repeat (Hourly · Daily · Weekdays · Weekly), at what time, on which day.
struct RepeatFields: View {
    @Binding var routine: Routine

    var body: some View {
        Picker(String(localized: "Repeat"), selection: $routine.every) {
            Text("Hourly").tag(Routine.Every.hourly)
            Text("Daily").tag(Routine.Every.daily)
            Text("Weekdays").tag(Routine.Every.weekdays)
            Text("Weekly").tag(Routine.Every.weekly)
        }
        .pickerStyle(.segmented)
        if routine.every == .weekly {
            Picker(String(localized: "Day"), selection: $routine.weekday) {
                ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
            }
        }
        if routine.every == .hourly {
            Picker(String(localized: "At minute"), selection: Binding(get: { routine.time % 60 }, set: { routine.time = $0 })) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
            }
        } else {
            DatePicker(String(localized: "At"), selection: Binding(get: { Self.date(routine.time) }, set: { routine.time = Self.minutes($0) }),
                       displayedComponents: .hourAndMinute)
        }
    }

    static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }
    static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
