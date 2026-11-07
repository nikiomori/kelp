import Agents
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

/// Settings: every section comes from an extension's settings schema (plus custom views), searchable, like VS Code.
@MainActor
enum SettingsWindow {
    private(set) static var window: NSWindow?
    /// Workbench language as the window first opened, which is what this launch runs in unless it changed before that.
    private(set) static var language: String?
    static func show(_ app: AppModel, section: String? = nil, group: String? = nil) {
        if let section { UserDefaults.standard.set(section, forKey: "settings.section") }
        UserDefaults.standard.set(group ?? "", forKey: "settings.group")
        let fresh = window == nil
        if fresh {
            language = app.settings[SettingKeys.language]
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            created.title = String(localized: "Settings")
            created.isReleasedWhenClosed = false
            created.animationBehavior = .documentWindow   // the system's own open and close
            created.toolbarStyle = .unified
            // ⌘, brings it back, so no minimize or zoom (HIG › Settings)
            created.standardWindowButton(.zoomButton)?.isEnabled = false
            let host = NSHostingController(rootView: SettingsView().environment(app))
            host.sizingOptions = [.minSize]
            created.contentViewController = host
            created.setContentSize(NSSize(width: 860, height: 600))
            created.setFrameAutosaveName("settings")
            if created.frame.origin == .zero { created.center() }
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        // AppKit hands a new window's first text field the focus: Font size opened with its value selected, so typing changed it.
        if fresh { DispatchQueue.main.async { window?.makeFirstResponder(nil) } }
    }
}

struct SettingsView: View {
    @AppStorage("settings.section") private var selection = "appearance"
    @State private var query = ""
    @Environment(AppModel.self) private var app
    private var registry: ExtensionRegistry { app.extensions }

    var body: some View {
        NavigationSplitView {
            // Nothing is selected while search fills the pane; picking a section ends the search.
            List(
                selection: Binding(
                    get: { query.isEmpty ? current : nil }, set: { if let section = $0 { open(section) } })
            ) {
                Section {
                    ForEach(sections) { section in
                        Label {
                            Text(loc(section.title))
                        } icon: {
                            SettingsIcon(symbol: section.icon, id: section.id)
                        }.tag(Optional(section.id))
                    }
                }
                Section {
                    Label {
                        Text("Extensions")
                    } icon: {
                        SettingsIcon(symbol: "puzzlepiece.extension", id: "extensions")
                    }.tag(Optional("extensions"))
                }
            }
            .toolbar(removing: .sidebarToggle)   // a settings window keeps its sections in view (HIG › Settings)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            Group {
                if !query.isEmpty {
                    SearchResults(query: query, open: open)
                } else if current == "extensions" {
                    ExtensionsSettings()
                } else if let section = registry.all.settings.first(where: { $0.id == current }) {
                    if section.fillsPane { section.custom?() } else { SectionForm(section: section) }
                } else {
                    ContentUnavailableView("Pick a section", systemImage: "gearshape")
                }
            }
            .navigationTitle(title)
            .toolbar {
                Button {
                    app.workbench.showFile(Paths.root.appendingPathComponent("settings.json"))
                } label: {
                    Label("Open settings.json", systemImage: "curlybraces")
                }
                .help("Edit settings.json in the editor")
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
        .frame(minWidth: 720, minHeight: 480)
    }

    private var sections: [SettingsSection] { registry.all.settings.sorted { $0.order < $1.order } }
    /// The section remembered, or the first when it's gone (its extension turned off, an old name): never a blank pane.
    private var current: String {
        selection == "extensions" || sections.contains { $0.id == selection }
            ? selection : sections.first?.id ?? selection
    }

    private var title: String {
        if !query.isEmpty { return String(localized: "Search") }
        return loc(
            registry.all.settings.first { $0.id == current }?.title
                ?? (current == "extensions" ? "Extensions" : "Settings"))
    }

    private func open(_ section: String) {
        selection = section
        query = ""
    }
}

/// A section's symbol on a coloured tile, as System Settings shows its panes: the one place colour tells things apart without
/// meaning a state, so a section is found by eye. Sections extensions add are grey.
private struct SettingsIcon: View {
    let symbol: String, id: String
    var body: some View {
        Image(systemName: symbol).font(.symbol(Metrics.iconSmall)).foregroundStyle(.white)
            .frame(width: Metrics.iconMenu, height: Metrics.iconMenu)
            .background(
                Self.tint[id, default: .gray], in: RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous))
    }
    /// Grey is General's alone. Terminal is a terminal's near-black, lifted in dark mode, where dark grey sank into the sidebar.
    static let tint: [String: Color] = [
        "general": .gray, "appearance": .blue, "agents": .purple, "catalog": .mint, "notifications": .pink,
        "terminal": Color(nsColor: .dynamic(light: .darkGray, dark: NSColor(white: 0.42, alpha: 1))),
        "editor": .teal, "git": .orange, "integrations": .green, "keyboard": .indigo, "extensions": .brown
    ]
}

private struct SectionForm: View {
    let section: SettingsSection
    /// A group a menu sent us to (`SettingsWindow.show`): scrolled to, then forgotten.
    @AppStorage("settings.group") private var target = ""
    /// The Editor's rows for one language's files ("" all of them): settings.json's `"[markdown]": { … }`.
    @State private var language = ""
    @Environment(AppModel.self) private var app
    private var store: SettingsStore { app.settings }

    var body: some View {
        let groups = section.groups
        ScrollViewReader { scroller in
            Form {
                if section.id == "editor" { LanguagePicker(language: $language) }
                ForEach(groups.indices, id: \.self) { index in
                    let rows = groups[index].1.filter {
                        (language.isEmpty || $0.perLanguage == true) && store.meets($0.requires)
                    }
                    if rows.isEmpty {
                        EmptyView()
                    } else if let title = groups[index].0 {
                        Section(loc(title)) {
                            SettingPreview(section: section.id, group: title)
                            section.previews[title]?()
                            ForEach(rows) { row($0) }
                        }.id(title)
                    } else {
                        Section {
                            SettingPreview(section: section.id, group: nil)
                            ForEach(rows) { row($0) }
                        }
                    }
                }
                section.custom?()
            }
            .formStyle(.grouped)
            .onAppear { go(scroller) }
            .onChange(of: target) { _, _ in go(scroller) }
        }
    }

    private func row(_ spec: SettingSpec) -> SettingRow {
        SettingRow(spec: spec, language: language.isEmpty ? nil : language)
    }

    private func go(_ scroller: ScrollViewProxy) {
        guard !target.isEmpty else { return }
        let group = target
        target = ""
        DispatchQueue.main.async { scroller.scrollTo(group, anchor: .top) }   // once the form has its rows
    }
}

private struct SearchResults: View {
    let query: String
    let open: (String) -> Void
    @Environment(AppModel.self) private var app
    var body: some View {
        let found = SettingsSearch.find(query, in: app.extensions.all.settings + [Self.extensions])
        let keys = KeyBindings.entries().contains { KeyBindings.matches($0, query) }
        Form {
            if found.isEmpty, !keys { Text("No settings match “\(query)”.").foregroundStyle(.secondary) }
            ForEach(found) { result in
                Section(result.title) {
                    ForEach(result.specs) { spec in SettingRow(spec: spec) { open(result.section.id) } }
                    ForEach(result.screens, id: \.self) { word in
                        // The word goes along: the Agent Catalog opens on the agent it names (it has no search of its own).
                        LabeledContent(word) {
                            Button("Open") {
                                UserDefaults.standard.set(word, forKey: "settings.group")
                                open(result.section.id)
                            }
                        }
                    }
                }
            }
            if keys { KeyboardSettings(query: query) }
        }
        .formStyle(.grouped)
    }

    /// The window's own page, not a section an extension gave.
    private static let extensions = SettingsSection(
        id: "extensions", title: "Extensions", icon: "puzzlepiece.extension", specs: [],
        keywords: ["Extensions", "Library"])
}

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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(spec.key, forType: .string)
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
        case "boolean":
            Toggle(isOn: Binding(get: { bool() ?? false }, set: { put(.bool($0)) })) { label }
        case "number" where spec.options?.isEmpty == false:
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
        case "number":
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
        case "enum" where SettingPictures.keys.contains(spec.key):
            VStack(alignment: .leading, spacing: Metrics.gapWide) {
                TileHeading(title: { title }, about: spec.description.map(loc))
                PictureGrid(
                    key: spec.key, options: Self.shown(Self.options(spec, app), string() ?? ""),
                    selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) }),
                    label: { Self.label(spec.key, $0, app) })
            }
            .padding(.vertical, Metrics.lineGap)
        case "enum" where Self.segmented.contains(spec.key):
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
        case "enum":
            Picker(selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) })) {
                ForEach(Self.shown(Self.options(spec, app), string() ?? ""), id: \.self) {
                    Text(Self.label(spec.key, $0, app)).tag($0)
                }
            } label: {
                label
            }
        case "panels":
            InspectorPanelsRow(title: AnyView(title), about: spec.description.map(loc))
        case "theme":
            ThemeGallery(
                selection: Binding(get: { string() ?? "auto" }, set: { put(.string($0)) }),
                heading: AnyView(TileHeading(title: { title }, about: spec.description.map(loc))))
        case "color":
            ColorPicker(
                selection: Binding(
                    get: { Color(hex: string() ?? "") ?? .accentColor },
                    set: { put(.string($0.hex)) })
            ) { label }
        case "font":
            // A plain picker, like the enum rows: in a fixed-width frame it ended short of the other rows' trailing edge.
            Picker(selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) })) {
                Text("Default").tag("")
                ForEach(Self.shown(Self.monospaced, string() ?? ""), id: \.self) { Text($0).tag($0) }
            } label: {
                label
            }
        default:
            LabeledContent {
                SettingTextField(key: spec.key, language: language, placeholder: spec.placeholder.map(loc)).frame(
                    width: 220)
            } label: {
                label
            }
        }
    }

    /// Two or three short choices seen side by side, as macOS shows them, instead of behind a menu.
    static let segmented: Set<String> = [
        SettingKeys.onWaiting.key, SettingKeys.onFinish.key, SettingKeys.onError.key, SettingKeys.keepAwake.key,
        SettingKeys.usageLimits.key, SettingKeys.sidebarOrder.key, SettingKeys.markdownMode.key,
        SettingKeys.inspectorIcons.key, SettingKeys.inspectorIconsPosition.key
    ]

    /// What a picker lists: the choices, and a value from outside them (settings.json by hand, an agent that isn't
    /// installed), which would otherwise leave the picker blank.
    static func shown(_ options: [String], _ current: String) -> [String] {
        current.isEmpty || options.contains(current) ? options : options + [current]
    }

    /// Choices that depend on what's installed are computed when shown.
    static func options(_ spec: SettingSpec, _ app: AppModel) -> [String] {
        switch spec.key {
        case SettingKeys.theme.key: return ["auto", "ghostty"] + app.themes.themes.map(\.id)
        case SettingKeys.iconTheme.key: return app.fileIcons.themes.map(\.id)
        case SettingKeys.defaultAgent.key: return app.catalog.installed(app.catalog.all).map(\.id)
        default: return spec.options ?? []
        }
    }

    /// Option values made readable (agent ids → names, theme ids → names).
    static func label(_ key: String, _ value: String, _ app: AppModel) -> String {
        switch key {
        case SettingKeys.defaultAgent.key: return app.catalog.name(value)
        case SettingKeys.theme.key:
            return value == "auto"
                ? String(localized: "Match System")
                : value == "ghostty"
                    ? String(localized: "Ghostty config")
                    : app.themes.themes.first { $0.id == value }?.name ?? value
        case SettingKeys.iconTheme.key: return app.fileIcons.themes.first { $0.id == value }?.label ?? value
        case SettingKeys.dockStripComesFor.key:
            return [
                "questions": String(localized: "Questions"), "failures": String(localized: "Questions and Failures"),
                "all": String(localized: "Anything New")
            ][value] ?? value
        case SettingKeys.dockStrip.key:
            return [
                "needed": String(localized: "When Needed"), "always": String(localized: "Always"),
                "off": String(localized: "Never")
            ][value] ?? value
        case SettingKeys.dockIcon.key:
            return [
                "agents": String(localized: "Agents"), "usage": String(localized: "Plan Usage"),
                "icon": String(localized: "App Icon")
            ][value] ?? value
        case SettingKeys.terminalOpacity.key: return value == "theme" ? String(localized: "From Theme") : "\(value)%"
        case SettingKeys.artifactsWhere.key:
            return [
                "agent": String(localized: "Agent’s Own When It Has One"),
                "local": String(localized: "Always on This Mac")
            ][value] ?? value
        case SettingKeys.skillBrowser.key:
            return [
                "auto": String(localized: "In Web Projects"), "on": String(localized: "Always"),
                "off": String(localized: "Never")
            ][value] ?? value
        case SettingKeys.keepAwake.key:
            return [
                "agents": String(localized: "While Agents Work"), "always": String(localized: "Always"),
                "off": String(localized: "Never")
            ][value] ?? value
        // Each language in its own words, so it can be found whichever language Kelp is in.
        case SettingKeys.language.key:
            return ["en": "English", "ru": "Русский"][value] ?? String(localized: "Match System")
        case SettingKeys.rowHeight.key where value == "system": return String(localized: "Match System")
        case SettingKeys.agentDetail.key where value == "needsYou": return String(localized: "When They Need You")
        case SettingKeys.agentIcons.key where value == "others": return String(localized: "Other Agents Only")
        case SettingKeys.projectColor.key:
            return value == "card" ? String(localized: "Filled Card") : String(localized: "On the Icon")
        case SettingKeys.serverLook.key:
            let said = [
                "stripes": String(localized: "Stripes"), "sparse": String(localized: "Sparse Stripes"),
                "fade": String(localized: "Stripes by the Icon"), "icon": String(localized: "Under the Icon")
            ]
            return said[value] ?? value
        case SettingKeys.ciBranchChip.key:
            let said = [
                "icon": String(localized: "In Place of the Branch Icon"), "end": String(localized: "After the Counts"),
                "off": String(localized: "Off")
            ]
            return said[value] ?? value
        case SettingKeys.inspectorIconsPosition.key:
            return value == "bottom" ? String(localized: "Under the Panel") : String(localized: "Beside the Tabs")
        case SettingKeys.usageLimits.key:
            return value == "all" ? String(localized: "All Agents") : String(localized: "Fullest Limit")
        case SettingKeys.alertAt.key: return value == "off" ? String(localized: "Off") : "\(value)%"
        case SettingKeys.sidebarOrder.key:
            return value == "active" ? String(localized: "Agents First") : String(localized: "As You Arrange Them")
        case SettingKeys.onFinish.key, SettingKeys.onWaiting.key, SettingKeys.onError.key:
            return [
                "sound": String(localized: "Banner + Sound"), "banner": String(localized: "Banner"),
                "off": String(localized: "Off")
            ][value] ?? value
        case SettingKeys.quietUnder.key:
            return value == "0" ? String(localized: "Off") : String(localized: "\(value) Seconds")
        case SettingKeys.hibernateMinutes.key:
            let minutes = Int(value) ?? -1
            return minutes == 0
                ? String(localized: "Never")
                : minutes == 60
                    ? String(localized: "After 1 Hour")
                    : minutes > 0 && minutes % 60 == 0
                        ? String(localized: "After \(minutes / 60) Hours") : String(localized: "After \(value) Minutes")
        case SettingKeys.remindAfter.key:
            return value == "off" ? String(localized: "Off") : String(localized: "After \(value) Minutes")
        default: return loc(value.prefix(1).uppercased() + value.dropFirst())
        }
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
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
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
    var hex: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02x%02x%02x", Int(color.redComponent * 255), Int(color.greenComponent * 255),
            Int(color.blueComponent * 255))
    }
}
