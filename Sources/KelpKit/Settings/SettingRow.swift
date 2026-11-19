// One setting's row, shaped by its spec, and the controls it's made of.
import AppKit
import Core
import DesignKit
import SwiftUI

/// One settings row, shaped by its spec, that reads and writes settings.json through the daemon. It is one line. The
/// title is the control's own label, so macOS sets it, keeps it left of the control and reads it out with the control.
/// The rest of the help is behind the row's ⓘ.
struct SettingRow: View {
    let spec: SettingSpec
    /// In search results, goes back to the row's section.
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

    private var title: some View {
        HStack(spacing: Metrics.gap) {
            if let icon = spec.icon { SettingsIcon(symbol: icon.symbol, tint: icon.tint) }
            Text(loc(spec.title))
            if let help = spec.help ?? spec.description { HelpMark(text: loc(help)) }
            if changed {
                // Grey, as StateDot is: in Settings the shape tells the state, and accent isn't for marks. It grows
                // with the title beside it.
                Circle().fill(.secondary).frame(width: TextSize.of(Metrics.gap), height: TextSize.of(Metrics.gap))
                    .accessibilityLabel("Changed")
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch spec.type {
        case .boolean:
            Toggle(isOn: Binding(get: { bool() ?? false }, set: { put(.bool($0)) })) { title }
        case .number where spec.options?.isEmpty == false:
            // A number with options is a choice (minutes…), so it is a picker of those values, plus any value set by
            // hand in settings.json.
            let current = number() ?? 0
            let values: [Double] = (spec.options ?? []).compactMap { Double($0) }
            let shown: [Double] = values.contains(current) ? values : values + [current]
            Picker(selection: Binding<Double>(get: { current }, set: { put(number: $0) })) {
                ForEach(shown, id: \.self) { option in
                    Text(Self.label(spec.key, option == option.rounded() ? String(Int(option)) : String(option), app))
                        .tag(option)
                }
            } label: {
                title
            }
        case .number:
            // Bordered, with a stepper, because borderless in a grouped form the number read as a label.
            let value = Binding<Double>(get: { number() ?? 0 }, set: { put(number: spec.clamped($0)) })
            // The title and control are centred on each other. Aligned by baseline, the stepper (taller than the
            // field) left the title riding high.
            LabeledContent {
                // The stepper keeps the number in bounds, and the field's help says what the bounds are, as macOS
                // panels do.
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
            }
        case .enum where spec.look == .pictures:
            let options = Self.shown(Self.options(spec), string() ?? "")
            let grid = PictureGrid(
                key: spec.key, options: options,
                selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) }),
                label: { Self.label(spec.key, $0, app) }, inline: options.count <= PictureGrid.inRow)
            if grid.inline {
                // Two or three choices sit beside the title, as a menu would, with the title at their top edge.
                LabeledContent {
                    grid.alignmentGuide(.firstTextBaseline) { $0[.top] }
                } label: {
                    title.alignmentGuide(.firstTextBaseline) { $0[.top] }
                }
                .padding(.vertical, Metrics.gapWide)
            } else {
                VStack(alignment: .leading, spacing: Metrics.gapWide) {
                    title
                    grid
                }
                .padding(.vertical, Metrics.lineGap)
            }
        case .enum where spec.look == .segments:
            // The segments sit beside the label, as a menu would, because a segmented picker of its own goes under a
            // two-line label.
            let options = Self.shown(Self.options(spec), string() ?? "")
            LabeledContent {
                Segments(
                    labels: options.map { Self.label(spec.key, $0, app) },
                    name: loc(spec.title),
                    selection: Binding(
                        get: { options.firstIndex(of: string() ?? "") ?? -1 },
                        set: { if options.indices.contains($0) { put(.string(options[$0])) } }))
            } label: {
                title
            }
        case .enum:
            Picker(selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) })) {
                ForEach(Self.shown(Self.options(spec), string() ?? ""), id: \.self) {
                    Text(Self.label(spec.key, $0, app)).tag($0)
                }
            } label: {
                title
            }
        case .panels:
            InspectorPanelsRow(title: AnyView(title))
        case .theme:
            ThemeGallery(
                selection: Binding(get: { string() ?? "auto" }, set: { put(.string($0)) }),
                heading: AnyView(title))
        case .color:
            ColorPicker(
                selection: Binding(
                    get: { Color(hex: string() ?? "") ?? .accentColor },
                    set: { put(.string(NSColor($0).hexString)) })
            ) { title }
        case .font:
            // A plain picker, like the enum rows, because in a fixed-width frame it ended short of the other rows'
            // trailing edge.
            Picker(selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) })) {
                Text("Default").tag("")
                ForEach(Self.shown(Self.monospaced, string() ?? ""), id: \.self) { Text($0).tag($0) }
            } label: {
                title
            }
        case .string, .unknown:
            LabeledContent {
                SettingTextField(key: spec.key, language: language, placeholder: spec.placeholder.map(loc)).frame(
                    width: 220)
            } label: {
                title
            }
        }
    }

    /// Returns what a picker lists: the choices, plus a value from outside them (set by hand in settings.json, or an
    /// agent that isn't installed), which would otherwise leave the picker blank.
    static func shown(_ options: [String], _ current: String) -> [String] {
        current.isEmpty || options.contains(current) ? options : options + [current]
    }

    /// Returns a setting's options. Choices that depend on what's installed are computed when shown
    /// (`SettingSpec.choices`).
    static func options(_ spec: SettingSpec) -> [String] {
        spec.choices?.options?() ?? spec.options ?? []
    }

    /// Returns an option value made readable. It uses the name the code declaring the setting gives (themes, agents:
    /// `SettingChoices`), else the label in its declaration (`SettingSpec.labels`), else the value capitalized.
    static func label(_ key: String, _ value: String, _ app: AppModel) -> String {
        let spec = app.extensions.specs[key]
        if let name = spec?.choices?.name { return name(value) }
        return spec?.labels?[value] ?? loc(value.prefix(1).uppercased() + value.dropFirst())
    }

    static let monospaced: [String] = NSFontManager.shared.availableFontFamilies.filter { fam in
        NSFont(name: fam, size: 12)?.isFixedPitch == true || fam.contains("Mono") || fam.contains("Code")
    }
}

/// A relaunch button for Language, which takes effect at launch. It shows once the setting differs from what this
/// launch read.
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

/// A text setting, saved when editing ends (↩ or leaving the field), like a Mac preference, not on every keystroke.
/// A change arriving from elsewhere (the CLI, an agent) shows unless the field is being edited.
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
        // Bordered, as the number fields are, because borderless in a grouped form an empty field (Branch prefix)
        // didn't show at all.
        TextField("", text: $draft, prompt: placeholder.map { Text($0) })
            .textFieldStyle(.roundedBorder)
            .focused($editing)
            .onSubmit(commit)
            .onAppear { draft = store.string(key, language: language) ?? "" }
            .onDisappear(perform: commit)   // saves when the window closed while typing
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
