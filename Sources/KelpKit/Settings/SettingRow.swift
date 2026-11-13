// One setting's row, typed by its spec, and the controls it's made of.
import AppKit
import Core
import DesignKit
import SwiftUI

/// One row, typed by its spec; reads and writes settings.json through the daemon. The description is the control's own
/// label, so macOS sets it, keeps it left of the control and reads it out with it.
struct SettingRow: View {
    let spec: SettingSpec
    /// In search results: back to the row's section.
    var reveal: (() -> Void)?
    /// The value for this language's files, kept in its block.
    var language: String?
    @Environment(AppModel.self) var app
    var store: SettingsStore { app.settings }
    init(spec: SettingSpec, language: String? = nil, reveal: (() -> Void)? = nil) {
        self.spec = spec
        self.language = language
        self.reveal = reveal
    }

    var body: some View {
        marked
        if spec.key == SettingKeys.language.key { RelaunchRow() }
    }

    private var marked: some View {
        control
            .help(spec.key)
            .contextMenu {
                Button(language == nil ? "Reset to Default" : "Use the Value for All Files") { put(nil) }.disabled(
                    !changed)
                Button("Copy Key") {
                    copyText(spec.key)
                }
                if let reveal { Button("Show in Section", action: reveal) }
            }
    }

    @ViewBuilder private var label: some View {
        title
        if let summary = spec.description { Text(loc(summary)) }
    }

    private var title: some View {
        HStack(spacing: Metrics.gap) {
            Text(loc(spec.title))
            if let help = spec.help { HelpMark(text: loc(help)) }
            if changed {
                Circle().fill(Color.accentColor).frame(width: Metrics.gap, height: Metrics.gap).accessibilityLabel(
                    "Changed")
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch spec.type {
        case .boolean:
            Toggle(isOn: Binding(get: { bool() ?? false }, set: { put(.bool($0)) })) { label }
        case .number where spec.options?.isEmpty == false:
            // A number with options is a choice (minutes…): a picker of those values, plus a hand-set one from settings.json.
            let current = number() ?? 0
            let values: [Double] = (spec.options ?? []).compactMap { Double($0) }
            let shown: [Double] = values.contains(current) ? values : values + [current]
            Picker(selection: Binding<Double>(get: { current }, set: { put(number: $0) })) {
                ForEach(shown, id: \.self) { option in
                    Text(Self.label(spec.key, option == option.rounded() ? String(Int(option)) : String(option), app))
                        .tag(option)
                }
            } label: {
                label
            }
        case .number:
            // Bordered, with a stepper: borderless in a grouped form, the number read as a label.
            let value = Binding<Double>(get: { number() ?? 0 }, set: { put(number: spec.clamped($0)) })
            // Centred on each other: by baseline the stepper, taller than the field, left the title riding high.
            LabeledContent {
                // The stepper keeps it in bounds; what they are is the field's help, as macOS panels say it.
                HStack(spacing: Metrics.gap) {
                    TextField("", value: value, format: .number).textFieldStyle(.roundedBorder).multilineTextAlignment(
                        .trailing
                    ).frame(width: 56)
                    Stepper("", value: value, in: spec.bounds ?? -.greatestFiniteMagnitude ... .greatestFiniteMagnitude)
                        .labelsHidden()
                }
                .help(
                    spec.bounds.map { String(localized: "From \(Int($0.lowerBound)) to \(Int($0.upperBound))") }
                        ?? spec.key
                )
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
            } label: {
                title.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
                if let summary = spec.description { Text(loc(summary)) }
            }
        case .enum where spec.look == .pictures:
            VStack(alignment: .leading, spacing: Metrics.gapWide) {
                TileHeading(title: { title }, about: spec.description.map(loc))
                PictureGrid(
                    key: spec.key, options: Self.shown(Self.options(spec, app), string() ?? ""),
                    selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) }),
                    label: { Self.label(spec.key, $0, app) })
            }
            .padding(.vertical, Metrics.lineGap)
        case .enum where spec.look == .segments:
            // Beside its label, as a menu would be: a segmented picker of its own goes under a two-line label.
            let options = Self.shown(Self.options(spec, app), string() ?? "")
            LabeledContent {
                Segments(
                    labels: options.map { Self.label(spec.key, $0, app) },
                    selection: Binding(
                        get: { options.firstIndex(of: string() ?? "") ?? -1 },
                        set: { if options.indices.contains($0) { put(.string(options[$0])) } }))
            } label: {
                label
            }
        case .enum:
            Picker(selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) })) {
                ForEach(Self.shown(Self.options(spec, app), string() ?? ""), id: \.self) {
                    Text(Self.label(spec.key, $0, app)).tag($0)
                }
            } label: {
                label
            }
        case .panels:
            InspectorPanelsRow(title: AnyView(title), about: spec.description.map(loc))
        case .theme:
            ThemeGallery(
                selection: Binding(get: { string() ?? "auto" }, set: { put(.string($0)) }),
                heading: AnyView(TileHeading(title: { title }, about: spec.description.map(loc))))
        case .color:
            ColorPicker(
                selection: Binding(
                    get: { Color(hex: string() ?? "") ?? .accentColor },
                    set: { put(.string(NSColor($0).hexString)) })
            ) { label }
        case .font:
            // A plain picker, like the enum rows: in a fixed-width frame it ended short of the other rows' trailing edge.
            Picker(selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) })) {
                Text("Default").tag("")
                ForEach(Self.shown(Self.monospaced, string() ?? ""), id: \.self) { Text($0).tag($0) }
            } label: {
                label
            }
        case .string, .unknown:
            LabeledContent {
                SettingTextField(key: spec.key, language: language, placeholder: spec.placeholder.map(loc)).frame(
                    width: 220)
            } label: {
                label
            }
        }
    }

    /// What a picker lists: the choices, and a value from outside them (settings.json by hand, an agent that isn't
    /// installed), which would otherwise leave the picker blank.
    static func shown(_ options: [String], _ current: String) -> [String] {
        current.isEmpty || options.contains(current) ? options : options + [current]
    }

    /// Choices that depend on what's installed are computed when shown (`SettingSpec.choices`).
    static func options(_ spec: SettingSpec, _ app: AppModel) -> [String] {
        spec.choices?.options?() ?? spec.options ?? []
    }

    /// Option values made readable: as the code declaring the setting names them (themes, agents: `SettingChoices`), else
    /// as its declaration calls them (`SettingSpec.labels`), else the value capitalized.
    static func label(_ key: String, _ value: String, _ app: AppModel) -> String {
        let spec = app.extensions.specs[key]
        if let name = spec?.choices?.name { return name(value) }
        return spec?.labels?[value] ?? loc(value.prefix(1).uppercased() + value.dropFirst())
    }

    static let monospaced: [String] = NSFontManager.shared.availableFontFamilies.filter { fam in
        NSFont(name: fam, size: 12)?.isFixedPitch == true || fam.contains("Mono") || fam.contains("Code")
    }
}

/// ⓘ beside a row's title: its whole help on hover, or in a popover on a click, so the line under the title stays one line.
struct HelpMark: View {
    let text: String
    @State private var shown = false
    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle").font(.symbol()).foregroundStyle(.secondary)
        }
        .buttonStyle(PointerButtonStyle(flush: true)).padding(.vertical, -3)   // the row stays its height
        .help(text)
        .accessibilityLabel(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text).fixedSize(horizontal: false, vertical: true).frame(width: 280, alignment: .leading).padding(
                Metrics.inset)
        }
    }
}

/// Language takes effect at launch: once it differs from what this launch read, a button to get there.
private struct RelaunchRow: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.settings[SettingKeys.language] != SettingsWindow.language {
            LabeledContent("Kelp needs to reopen for this.") {
                Button("Relaunch") {
                    guard app.workbench.editedFiles.isEmpty else {
                        Banner.show(String(localized: "Save your files, then relaunch."))
                        return
                    }
                    AppDelegate.relaunch()
                }
            }
        }
    }
}

/// A text setting is saved when the field is done (↩ or leaving it), like a Mac preference, not on every keystroke;
/// a change arriving from elsewhere (the CLI, an agent) shows unless the field is being edited.
private struct SettingTextField: View {
    let key: String
    var language: String?
    @Environment(AppModel.self) private var app
    private var store: SettingsStore { app.settings }
    var placeholder: String?
    @State private var draft = ""
    @FocusState private var editing: Bool
    init(key: String, language: String? = nil, placeholder: String? = nil) {
        self.key = key
        self.language = language
        self.placeholder = placeholder
    }

    var body: some View {
        // Bordered, as the number fields: borderless in a grouped form an empty one (Branch prefix) didn't show at all.
        TextField("", text: $draft, prompt: placeholder.map { Text($0) })
            .textFieldStyle(.roundedBorder)
            .focused($editing)
            .onSubmit(commit)
            .onAppear { draft = store.string(key, language: language) ?? "" }
            .onDisappear(perform: commit)   // the window closed while typing
            .onChange(of: editing) { _, now in if !now { commit() } }
            .onChange(of: store.string(key, language: language)) { _, stored in if !editing { draft = stored ?? "" } }
    }

    private func commit() {
        guard draft != store.string(key, language: language) ?? "" else { return }
        if let language {
            store.setOwn(key, .string(draft), language: language)
        } else {
            store.set(key, .string(draft))
        }
    }
}

extension Color {
    init?(hex: String) {
        guard let color = NSColor(hex: hex) else { return nil }
        self.init(nsColor: color)
    }
}
