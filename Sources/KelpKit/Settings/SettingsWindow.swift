import AppKit
import SwiftUI
import Core
import Agents
import DesignKit
import WorkbenchKit

/// Settings: every section comes from an extension's settings schema (plus custom views), searchable, like VS Code.
@MainActor
enum SettingsWindow {
    private(set) static var window: NSWindow?
    /// Workbench language as the window first opened, which is what this launch runs in unless it changed before that.
    private(set) static var language: String?
    static func show(_ app: AppModel, section: String? = nil, group: String? = nil) {
        if let s = section { UserDefaults.standard.set(s, forKey: "settings.section") }
        UserDefaults.standard.set(group ?? "", forKey: "settings.group")
        let fresh = window == nil
        if fresh {
            language = app.settings.string("workbench.language")
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = String(localized: "Settings")
            w.isReleasedWhenClosed = false
            w.animationBehavior = .documentWindow   // the system's own open and close
            w.toolbarStyle = .unified
            w.standardWindowButton(.zoomButton)?.isEnabled = false   // ⌘, brings it back, so no minimize or zoom (HIG › Settings)
            let host = NSHostingController(rootView: SettingsView().environment(app))
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            w.setContentSize(NSSize(width: 860, height: 600))
            w.setFrameAutosaveName("settings"); if w.frame.origin == .zero { w.center() }
            window = w
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
            List(selection: Binding(get: { query.isEmpty ? selection : nil }, set: { if let s = $0 { open(s) } })) {
                Section {
                    ForEach(sections) { s in
                        Label { Text(loc(s.title)) } icon: { SettingsIcon(symbol: s.icon, id: s.id) }.tag(Optional(s.id))
                    }
                }
                Section {
                    Label { Text("Extensions") } icon: { SettingsIcon(symbol: "puzzlepiece.extension", id: "extensions") }.tag(Optional("extensions"))
                }
            }
            .toolbar(removing: .sidebarToggle)   // a settings window keeps its sections in view (HIG › Settings)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            Group {
                if !query.isEmpty { SearchResults(query: query, open: open) }
                else if selection == "extensions" { ExtensionsSettings() }
                else if let s = registry.all.settings.first(where: { $0.id == selection }) {
                    if s.fillsPane { s.custom?() } else { SectionForm(section: s) }
                }
                else { ContentUnavailableView("Pick a section", systemImage: "gearshape") }
            }
            .navigationTitle(title)
            .toolbar {
                Button { app.workbench.showFile(Paths.root.appendingPathComponent("settings.json")) } label: {
                    Label("Open settings.json", systemImage: "curlybraces")
                }
                    .help("Edit settings.json in the editor")
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
        .frame(minWidth: 720, minHeight: 480)
    }

    private var sections: [SettingsSection] { registry.all.settings.sorted { $0.order < $1.order } }

    private var title: String {
        if !query.isEmpty { return String(localized: "Search") }
        return loc(registry.all.settings.first { $0.id == selection }?.title ?? (selection == "extensions" ? "Extensions" : "Settings"))
    }

    private func open(_ section: String) { selection = section; query = "" }
}

/// A section's symbol on a coloured tile, as System Settings shows its panes: the one place colour tells things apart without
/// meaning a state, so a section is found by eye. Sections extensions add are grey.
private struct SettingsIcon: View {
    let symbol: String, id: String
    var body: some View {
        Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            .frame(width: Metrics.iconMenu, height: Metrics.iconMenu)
            .background(Self.tint[id, default: .gray], in: RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous))
    }
    static let tint: [String: Color] = ["appearance": .blue, "agents": .purple, "catalog": .mint, "notifications": .pink,
                                        "terminal": Color(nsColor: .darkGray), "editor": .teal, "git": .orange, "integrations": .green,
                                        "keyboard": .gray, "extensions": .gray]
}

private struct SectionForm: View {
    let section: SettingsSection
    /// A group a menu sent us to (`SettingsWindow.show`): scrolled to, then forgotten.
    @AppStorage("settings.group") private var target = ""
    /// The Editor's rows for one language's files ("" all of them): settings.json's `"[markdown]": { … }`.
    @State private var language = ""

    var body: some View {
        let groups = section.groups
        ScrollViewReader { scroller in
            Form {
                if section.id == "editor" { LanguagePicker(language: $language) }
                ForEach(groups.indices, id: \.self) { i in
                    let rows = groups[i].1.filter { language.isEmpty || SettingRow.perLanguage.contains($0.key) }
                    if rows.isEmpty {
                        EmptyView()
                    } else if let title = groups[i].0 {
                        Section(loc(title)) { ForEach(rows) { row($0) } }.id(title)
                    } else {
                        Section { ForEach(rows) { row($0) } }
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
            ForEach(found) { f in
                Section(f.title) {
                    ForEach(f.specs) { spec in SettingRow(spec: spec) { open(f.section.id) } }
                    ForEach(f.screens, id: \.self) { word in
                        LabeledContent(word) { Button("Open") { open(f.section.id) } }
                    }
                }
            }
            if keys { KeyboardSettings(query: query) }
        }
        .formStyle(.grouped)
    }

    /// The window's own page, not a section an extension gave.
    private static let extensions = SettingsSection(id: "extensions", title: "Extensions", icon: "puzzlepiece.extension", specs: [],
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
        if spec.key == "workbench.language" { RelaunchRow() }
    }

    private var marked: some View {
        control
            .help(spec.key)
            .contextMenu {
                Button(language == nil ? "Reset to Default" : "Use the Value for All Files") { put(nil) }.disabled(!changed)
                Button("Copy Key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(spec.key, forType: .string) }
                if let reveal { Button("Show in Section", action: reveal) }
            }
    }

    @ViewBuilder private var label: some View {
        title
        if let d = spec.description { Text(loc(d)) }
    }

    private var title: some View {
        HStack(spacing: Metrics.gap) {
            Text(loc(spec.title))
            if let h = spec.help { HelpMark(text: loc(h)) }
            if changed { Circle().fill(Color.accentColor).frame(width: Metrics.gap, height: Metrics.gap).accessibilityLabel("Changed") }
        }
    }

    @ViewBuilder private var control: some View {
        switch spec.type {
        case "boolean":
            Toggle(isOn: Binding(get: { bool() ?? false }, set: { put(.bool($0)) })) { label }
        case "number" where spec.options?.isEmpty == false:
            // A number with options is a choice (minutes…): a picker of those values, plus a hand-set one from settings.json.
            let current = number() ?? 0
            let values = (spec.options ?? []).compactMap(Double.init)
            Picker(selection: Binding(get: { current }, set: { put($0 == $0.rounded() ? .int(Int($0)) : .double($0)) })) {
                ForEach(values.contains(current) ? values : values + [current], id: \.self) { v in
                    Text(Self.label(spec.key, v == v.rounded() ? String(Int(v)) : String(v), app)).tag(v)
                }
            } label: { label }
        case "number":
            // Bordered, with a stepper: borderless in a grouped form, the number read as a label.
            let value = Binding(get: { number() ?? 0 }, set: {
                let v = spec.clamped($0)
                put(v == v.rounded() ? .int(Int(v)) : .double(v))
            })
            // Centred on each other: by baseline the stepper, taller than the field, left the title riding high.
            LabeledContent {
                HStack(spacing: 4) {
                    if let b = spec.bounds {
                        Text("\(Int(b.lowerBound))…\(Int(b.upperBound))").font(.subheadline).foregroundStyle(.secondary).padding(.trailing, 4)
                    }
                    TextField("", value: value, format: .number).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 56)
                    Stepper("", value: value, in: spec.bounds ?? -.greatestFiniteMagnitude ... .greatestFiniteMagnitude).labelsHidden()
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
            } label: {
                title.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
                if let d = spec.description { Text(loc(d)) }
            }
        case "enum" where SettingPictures.keys.contains(spec.key):
            VStack(alignment: .leading, spacing: Metrics.gapWide) {
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    title
                    if let d = spec.description { Text(loc(d)).font(.subheadline).foregroundStyle(.secondary) }
                }
                PictureGrid(key: spec.key, options: Self.shown(Self.options(spec, app), string() ?? ""),
                            selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) }), label: { Self.label(spec.key, $0, app) })
            }
            .padding(.vertical, Metrics.lineGap)
        case "enum":
            Picker(selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) })) {
                ForEach(Self.shown(Self.options(spec, app), string() ?? ""), id: \.self) { Text(Self.label(spec.key, $0, app)).tag($0) }
            } label: { label }
        case "theme":
            ThemeGallery(selection: Binding(get: { string() ?? "auto" }, set: { put(.string($0)) }),
                         about: spec.description.map(loc), help: spec.help.map(loc))
        case "color":
            ColorPicker(selection: Binding(get: { Color(hex: string() ?? "") ?? .accentColor },
                                           set: { put(.string($0.hex)) })) { label }
        case "font":
            // A plain picker, like the enum rows: in a fixed-width frame it ended short of the other rows' trailing edge.
            Picker(selection: Binding(get: { string() ?? "" }, set: { put(.string($0)) })) {
                Text("Default").tag("")
                ForEach(Self.shown(Self.monospaced, string() ?? ""), id: \.self) { Text($0).tag($0) }
            } label: { label }
        default:
            LabeledContent { SettingTextField(key: spec.key, language: language).frame(width: 220) } label: { label }
        }
    }

    /// What a picker lists: the choices, and a value from outside them (settings.json by hand, an agent that isn't
    /// installed), which would otherwise leave the picker blank.
    static func shown(_ options: [String], _ current: String) -> [String] {
        current.isEmpty || options.contains(current) ? options : options + [current]
    }

    /// Choices that depend on what's installed are computed when shown.
    static func options(_ spec: SettingSpec, _ app: AppModel) -> [String] {
        switch spec.key {
        case "workbench.theme": return ["auto", "ghostty"] + app.themes.themes.map(\.id)
        case "workbench.iconTheme": return app.fileIcons.themes.map(\.id)
        case "agents.default": return app.catalog.installed(app.catalog.all).map(\.id)
        default: return spec.options ?? []
        }
    }

    /// Option values made readable (agent ids → names, theme ids → names).
    static func label(_ key: String, _ v: String, _ app: AppModel) -> String {
        switch key {
        case "agents.default": return app.catalog.name(v)
        case "workbench.theme":
            return v == "auto" ? String(localized: "Match System") : v == "ghostty" ? String(localized: "Ghostty config")
                : app.themes.themes.first { $0.id == v }?.name ?? v
        case "workbench.iconTheme": return app.fileIcons.themes.first { $0.id == v }?.label ?? v
        case "agents.dockStrip.comesFor":
            return ["questions": String(localized: "Questions"), "failures": String(localized: "Questions and Failures"),
                    "all": String(localized: "Anything New")][v] ?? v
        case "agents.dockStrip":
            return ["needed": String(localized: "When Needed"), "always": String(localized: "Always"), "off": String(localized: "Never")][v] ?? v
        case "agents.dockIcon":
            return ["agents": String(localized: "Agents"), "usage": String(localized: "Plan Usage"), "icon": String(localized: "App Icon")][v] ?? v
        case "terminal.opacity": return v == "theme" ? String(localized: "From Theme") : "\(v)%"
        case "artifacts.where":
            return ["agent": String(localized: "Agent’s Own When It Has One"), "local": String(localized: "Always on This Mac")][v] ?? v
        case "agents.skills.browser":
            return ["auto": String(localized: "In Web Projects"), "on": String(localized: "Always"), "off": String(localized: "Never")][v] ?? v
        case "power.keepAwake":
            return ["agents": String(localized: "While Agents Work"), "always": String(localized: "Always"), "off": String(localized: "Never")][v] ?? v
        // Each language in its own words, so it can be found whichever language Kelp is in.
        case "workbench.language": return ["en": "English", "ru": "Русский"][v] ?? String(localized: "Match System")
        case "workbench.sidebar.rowHeight" where v == "system": return String(localized: "Match System")
        case "workbench.sidebar.agentDetail" where v == "needsYou": return String(localized: "When They Need You")
        case "workbench.sidebar.agentIcons" where v == "others": return String(localized: "Other Agents Only")
        case "workbench.sidebar.projectColor":
            return v == "card" ? String(localized: "Filled Card") : String(localized: "On the Icon")
        case "workbench.ci.branchChip":
            let said = ["icon": String(localized: "In Place of the Branch Icon"), "end": String(localized: "After the Counts"), "off": String(localized: "Off")]
            return said[v] ?? v
        case "usage.limits": return v == "all" ? String(localized: "All Agents") : String(localized: "Fullest Limit")
        case "usage.alertAt": return v == "off" ? String(localized: "Off") : "\(v)%"
        case "workbench.sidebar.order":
            return v == "active" ? String(localized: "Agents First") : String(localized: "As You Arrange Them")
        case "agents.onFinish", "agents.onWaiting", "agents.onError":
            return ["sound": String(localized: "Banner and Sound"), "banner": String(localized: "Banner Only"), "off": String(localized: "Off")][v] ?? v
        case "agents.quietUnder": return v == "0" ? String(localized: "Off") : String(localized: "\(v) seconds")
        case "sessions.hibernateMinutes":
            let m = Int(v) ?? -1
            return m == 0 ? String(localized: "Never") : m == 60 ? String(localized: "After 1 Hour")
                : m > 0 && m % 60 == 0 ? String(localized: "After \(m / 60) Hours") : String(localized: "After \(v) Minutes")
        case "agents.remindAfter": return v == "off" ? String(localized: "Off") : String(localized: "After \(v) Minutes")
        default: return loc(v.prefix(1).uppercased() + v.dropFirst())
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
        Button { shown.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
            .help(text)
            .accessibilityLabel(text)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text).fixedSize(horizontal: false, vertical: true).frame(width: 280, alignment: .leading).padding(Metrics.inset)
            }
    }
}

/// Language takes effect at launch: once it differs from what this launch read, a button to get there.
private struct RelaunchRow: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.settings.string("workbench.language") != SettingsWindow.language {
            LabeledContent("Kelp needs to reopen for this.") {
                Button("Relaunch") {
                    guard app.workbench.editedFiles.isEmpty else { Banner.show(String(localized: "Save your files, then relaunch.")); return }
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
    @State private var draft = ""
    @FocusState private var editing: Bool
    init(key: String, language: String? = nil) { self.key = key; self.language = language }

    var body: some View {
        // Bordered, as the number fields: borderless in a grouped form an empty one (Branch prefix) didn't show at all.
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($editing)
            .onSubmit(commit)
            .onAppear { draft = store.string(key, language: language) ?? "" }
            .onDisappear(perform: commit)   // the window closed while typing
            .onChange(of: editing) { _, now in if !now { commit() } }
            .onChange(of: store.string(key, language: language)) { _, v in if !editing { draft = v ?? "" } }
    }

    private func commit() {
        guard draft != store.string(key, language: language) ?? "" else { return }
        if let language { store.setOwn(key, .string(draft), language: language) } else { store.set(key, .string(draft)) }
    }
}

extension Color {
    init?(hex: String) { guard let c = NSColor(hex: hex) else { return nil }; self.init(nsColor: c) }
    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
