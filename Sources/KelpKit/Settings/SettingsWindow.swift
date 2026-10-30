import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Core
import Agents
import DesignKit
import WorkbenchKit

/// Settings: every section comes from an extension's settings schema (plus custom views), searchable, like VS Code.
@MainActor
enum SettingsWindow {
    private(set) static var window: NSWindow?
    static func show(_ app: AppModel, section: String? = nil) {
        if let s = section { UserDefaults.standard.set(s, forKey: "settings.section") }
        let fresh = window == nil
        if fresh {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = String(localized: "Settings")
            w.isReleasedWhenClosed = false
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
            List(selection: $selection) {
                Section {
                    ForEach(registry.all.settings) { s in Label { Text(loc(s.title)) } icon: { SettingsIcon(symbol: s.icon, id: s.id) }.tag(s.id) }
                }
                Section {
                    Label { Text("Extensions") } icon: { SettingsIcon(symbol: "puzzlepiece.extension", id: "extensions") }.tag("extensions")
                }
            }
            .toolbar(removing: .sidebarToggle)   // a settings window keeps its sections in view (HIG › Settings)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            Group {
                if !query.isEmpty { SearchResults(query: query) }
                else if selection == "extensions" { ExtensionsSettings() }
                else if let s = registry.all.settings.first(where: { $0.id == selection }) { SectionForm(section: s) }
                else { ContentUnavailableView("Pick a section", systemImage: "gearshape") }
            }
            .navigationTitle(loc(registry.all.settings.first { $0.id == selection }?.title ?? (selection == "extensions" ? "Extensions" : "Settings")))
            .toolbar {
                Button { app.workbench.open(TabURI.file(Paths.root.appendingPathComponent("settings.json").path)) } label: {
                    Label("Open settings.json", systemImage: "curlybraces")
                }
                    .help("Edit settings.json in the editor")
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// A section's symbol on a coloured tile, as System Settings shows its panes; sections extensions add are grey.
private struct SettingsIcon: View {
    let symbol: String, id: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Self.tint[id, default: .gray].gradient, in: RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous))
    }
    static let tint: [String: Color] = ["agents": .purple, "catalog": .indigo, "terminal": Color(white: 0.3), "appearance": .blue, "keyboard": .gray,
                                        "editor": .indigo, "git": .orange, "integrations": .green, "extensions": .gray]
}

private struct SectionForm: View {
    let section: SettingsSection
    var body: some View {
        // Rows keep their order; each run of a group under its heading, as System Settings groups its panes.
        let groups = section.specs.reduce(into: [(String?, [SettingSpec])]()) { g, s in
            if let last = g.indices.last, g[last].0 == s.group { g[last].1.append(s) } else { g.append((s.group, [s])) }
        }
        Form {
            ForEach(groups.indices, id: \.self) { i in
                if let title = groups[i].0 {
                    Section(loc(title)) { ForEach(groups[i].1) { SettingRow(spec: $0) } }
                } else {
                    Section { ForEach(groups[i].1) { SettingRow(spec: $0) } }
                }
            }
            if let custom = section.custom { Section { custom() } }
        }
        .formStyle(.grouped)
    }
}

private struct SearchResults: View {
    let query: String
    @Environment(AppModel.self) private var app
    var body: some View {
        let q = query.lowercased()
        let hits = app.extensions.all.settings.flatMap { s in
            // In English and as shown (a Russian search finds Russian titles).
            s.specs.filter { ($0.title + " " + loc($0.title) + " " + $0.key + " " + ($0.description ?? "") + " "
                              + loc($0.description ?? "")).lowercased().contains(q) }
                .map { (s, $0) }
        }
        let keys = KeyBindings.entries().contains { KeyBindings.matches($0, query) }
        Form {
            if hits.isEmpty, !keys { Text("No settings match “\(query)”.").foregroundStyle(.secondary) }
            ForEach(hits, id: \.1.key) { s, spec in
                Section(loc(s.title)) { SettingRow(spec: spec) }
            }
            if keys { Section("Keyboard") { KeyboardSettings(query: query) } }
        }
        .formStyle(.grouped)
    }
}

/// One row, typed by its spec; reads and writes settings.json through the daemon.
struct SettingRow: View {
    let spec: SettingSpec
    @Environment(AppModel.self) private var app
    private var store: SettingsStore { app.settings }
    init(spec: SettingSpec) { self.spec = spec }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let d = spec.description { Text(loc(d)).font(.caption).foregroundStyle(.secondary) }
        }
        .help(spec.key)
    }

    @ViewBuilder private var control: some View {
        switch spec.type {
        case "boolean":
            Toggle(loc(spec.title), isOn: Binding(get: { store.bool(spec.key) ?? false }, set: { store.set(spec.key, .bool($0)) }))
        case "number" where spec.options?.isEmpty == false:
            // A number with options is a choice (minutes…): a picker of those values, plus a hand-set one from settings.json.
            let current = store.number(spec.key) ?? 0
            let values = (spec.options ?? []).compactMap(Double.init)
            Picker(loc(spec.title), selection: Binding(get: { current }, set: { store.set(spec.key, $0 == $0.rounded() ? .int(Int($0)) : .double($0)) })) {
                ForEach(values.contains(current) ? values : values + [current], id: \.self) { v in
                    Text(Self.label(spec.key, v == v.rounded() ? String(Int(v)) : String(v), app)).tag(v)
                }
            }
        case "number":
            // Bordered, with a stepper: borderless in a grouped form, the number read as a label.
            let value = Binding(get: { store.number(spec.key) ?? 0 }, set: { store.set(spec.key, $0 == $0.rounded() ? .int(Int($0)) : .double($0)) })
            // Centred on each other: by baseline the stepper, taller than the field, left the title riding high.
            LabeledContent {
                HStack(spacing: 4) {
                    TextField("", value: value, format: .number).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 56)
                    Stepper("", value: value).labelsHidden()
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
            } label: {
                Text(loc(spec.title)).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
            }
        case "enum":
            Picker(loc(spec.title), selection: Binding(get: { store.string(spec.key) ?? "" }, set: { store.set(spec.key, .string($0)) })) {
                ForEach(Self.options(spec, app), id: \.self) { Text(Self.label(spec.key, $0, app)).tag($0) }
            }
        case "theme":
            ThemeGallery(selection: Binding(get: { store.string(spec.key) ?? "auto" }, set: { store.set(spec.key, .string($0)) }))
        case "color":
            ColorPicker(loc(spec.title), selection: Binding(get: { Color(hex: store.string(spec.key) ?? "") ?? .accentColor },
                                                            set: { store.set(spec.key, .string($0.hex)) }))
        case "font":
            // A plain picker, like the enum rows: in a fixed-width frame it ended short of the other rows' trailing edge.
            Picker(loc(spec.title), selection: Binding(get: { store.string(spec.key) ?? "" }, set: { store.set(spec.key, .string($0)) })) {
                Text("Default").tag("")
                ForEach(Self.monospaced, id: \.self) { Text($0).tag($0) }
            }
        default:
            LabeledContent(loc(spec.title)) { SettingTextField(key: spec.key).frame(width: 220) }
        }
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
        case "power.keepAwake":
            return ["agents": String(localized: "While agents work"), "always": String(localized: "Always"), "off": String(localized: "Never")][v] ?? v
        // Each language in its own words, so it can be found whichever language Kelp is in.
        case "workbench.language": return ["en": "English", "ru": "Русский"][v] ?? String(localized: "Match System")
        case "workbench.sidebar.rowHeight" where v == "system": return String(localized: "Match System")
        case "workbench.sidebar.agentDetail" where v == "needsYou": return String(localized: "When They Need You")
        case "workbench.sidebar.agentIcons" where v == "others": return String(localized: "Other Agents Only")
        case "workbench.ci.branchChip":
            let said = ["icon": String(localized: "In Place of the Branch Icon"), "end": String(localized: "After the Counts"), "off": String(localized: "Off")]
            return said[v] ?? v
        case "workbench.sidebar.order":
            return v == "active" ? String(localized: "Agents First") : String(localized: "As You Arrange Them")
        case "agents.onFinish", "agents.onWaiting", "agents.onError":
            return ["sound": String(localized: "Banner and Sound"), "banner": String(localized: "Banner Only"), "off": String(localized: "Off")][v] ?? v
        case "agents.quietUnder": return v == "0" ? String(localized: "Off") : String(localized: "\(v) seconds")
        case "sessions.hibernateMinutes":
            let m = Int(v) ?? -1
            return m == 0 ? String(localized: "Never") : m == 60 ? String(localized: "After 1 hour")
                : m > 0 && m % 60 == 0 ? String(localized: "After \(m / 60) hours") : String(localized: "After \(v) minutes")
        default: return loc(v.prefix(1).uppercased() + v.dropFirst())
        }
    }

    static let monospaced: [String] = NSFontManager.shared.availableFontFamilies.filter { fam in
        NSFont(name: fam, size: 12)?.isFixedPitch == true || fam.contains("Mono") || fam.contains("Code")
    }
}

/// A text setting is saved when the field is done (↩ or leaving it), like a Mac preference, not on every keystroke;
/// a change arriving from elsewhere (the CLI, an agent) shows unless the field is being edited.
private struct SettingTextField: View {
    let key: String
    @Environment(AppModel.self) private var app
    private var store: SettingsStore { app.settings }
    @State private var draft = ""
    @FocusState private var editing: Bool
    init(key: String) { self.key = key }

    var body: some View {
        // Bordered, as the number fields: borderless in a grouped form an empty one (Branch prefix) didn't show at all.
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($editing)
            .onSubmit(commit)
            .onAppear { draft = store.string(key) ?? "" }
            .onDisappear(perform: commit)   // the window closed while typing
            .onChange(of: editing) { _, now in if !now { commit() } }
            .onChange(of: store.string(key)) { _, v in if !editing { draft = v ?? "" } }
    }

    private func commit() { if draft != store.string(key) ?? "" { store.set(key, .string(draft)) } }
}

/// Color themes as swatch cards: the terminal's background, a sample, and the ANSI colors.
private struct ThemeGallery: View {
    @Binding var selection: String
    @Environment(AppModel.self) private var app

    private struct Card: Identifiable { let id: String, name: String, bg: Color, fg: Color, dots: [Color] }
    private var cards: [Card] {
        func card(_ t: Theme, id: String? = nil, name: String? = nil) -> Card {
            let c = t.terminal
            return Card(id: id ?? t.id, name: name ?? t.name, bg: Color(hex: c?.background ?? "") ?? .black, fg: Color(hex: c?.foreground ?? "") ?? .white,
                        dots: (c?.palette ?? []).dropFirst().prefix(6).compactMap { Color(hex: $0) })
        }
        let all = app.themes.themes
        let auto = all.first { $0.id == (app.themes.isDark ? "kelp.dark" : "kelp.light") }
        return (auto.map { [card($0, id: "auto", name: "Match System")] } ?? [])
            + [ghosttyCard(base: auto.map { card($0) })]
            + all.map { card($0) }
    }

    /// Your Ghostty config's colours, as the terminal will have them; what it doesn't set, the Kelp theme's. A card without
    /// swatches looked like one that failed to load.
    private func ghosttyCard(base: Card?) -> Card {
        let g = GhosttyConfig.load()
        let dots = (1...6).compactMap { i in
            g?.palette[i].flatMap { Color(hex: $0) } ?? base.flatMap { $0.dots.indices.contains(i - 1) ? $0.dots[i - 1] : nil }
        }
        return Card(id: "ghostty", name: "Ghostty", bg: g?.background.flatMap { Color(hex: $0) } ?? base?.bg ?? Color(nsColor: .controlBackgroundColor),
                    fg: g?.foreground.flatMap { Color(hex: $0) } ?? base?.fg ?? .secondary, dots: dots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Theme")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                ForEach(cards) { c in
                    Button { selection = c.id } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Aa  ~ $").font(.system(size: 12, design: .monospaced)).foregroundStyle(c.fg)
                            HStack(spacing: 3) { ForEach(Array(c.dots.enumerated()), id: \.offset) { Circle().fill($0.element).frame(width: 8, height: 8) } }
                                .frame(height: 8)
                            Text(c.name).font(.caption).foregroundStyle(c.fg).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(c.bg, in: RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                            .strokeBorder(selection == c.id ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selection == c.id ? 2 : 1))
                    }
                    .buttonStyle(PointerCardStyle())
                    .accessibilityLabel(c.name).accessibilityAddTraits(selection == c.id ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Installed extensions: turn them on or off, remove, create (by hand or with an agent); or the library's, to install.
private struct ExtensionsSettings: View {
    @Environment(AppModel.self) private var app
    private var registry: ExtensionRegistry { app.extensions }
    @State private var picking = false
    @State private var library = false
    var body: some View {
        Form { if library { LibrarySection() } else { installed } }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $library) {
                    Text("Installed").tag(false)
                    Text("Library").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, UTType(filenameExtension: "vsix") ?? .zip]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do { try await registry.install(url) }
                catch { Banner.show(String(localized: "Couldn't install \(url.lastPathComponent): \(AppModel.message(error))"), style: .error) }
            }
        }
    }

    /// Two groups, each named once: Kelp's own parts, then what was installed (with its version). "Built-in" on every row
    /// and a bold sentence over the list made three sizes of text in one card.
    @ViewBuilder private var installed: some View {
        Section {
            ForEach(registry.extensions.filter(\.builtin)) { row($0) }
        } header: {
            Text("Built-in")
        } footer: {
            Text("The browser, git and issues are extensions too. Turn off what you don't use.").font(.caption).foregroundStyle(.secondary)
        }
        let added = registry.extensions.filter { !$0.builtin }
        if !added.isEmpty {
            Section("Installed") { ForEach(added) { row($0) } }
        }
        Section {
            Text(String(localized: "To add one, install it from the Library, or ask Claude Code in an agent tab, e.g. “make a Kelp panel that lists my Docker containers”. ")
                 + String(localized: "It knows how through the extensions skill (Settings › Agents)."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("How Extensions Work") { app.workbench.open(TabURI.file(ExtensionRegistry.userDir.appendingPathComponent("EXTENSIONS.md").path)) }
                    .buttonStyle(.link)
                Spacer()
                Button("Install…") { picking = true }
                    .help("A VS Code extension (.vsix or its folder) — for its file icon themes — or a Kelp extension folder")
                Button("Show in Finder") { NSWorkspace.shared.open(ExtensionRegistry.userDir) }
                Button("Reload") { registry.reload() }
            }
        }
    }

    private func row(_ e: ExtensionInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: e.icon).font(.title3).foregroundStyle(e.error == nil ? Color.accentColor : .orange).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(loc(e.name)).fontWeight(.medium)
                    if !e.builtin { Text(e.version).font(.caption).foregroundStyle(.secondary) }
                }
                if !e.description.isEmpty { Text(loc(e.description)).font(.caption).foregroundStyle(.secondary) }
                if let err = e.error { Text(err).font(.caption).foregroundStyle(Color.textOrange).textSelection(.enabled) }
                if let u = e.unavailable { Text(u).font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            if let p = e.path, !e.builtin {
                Menu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p]) }
                    let manifest = FileManager.default.fileExists(atPath: p.appendingPathComponent("extension.json").path)
                        ? "extension.json" : "package.json"
                    Button("Edit \(manifest)") { app.workbench.open(TabURI.file(p.appendingPathComponent(manifest).path)) }
                    Divider()
                    Button("Uninstall", role: .destructive) { registry.uninstall(e.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if e.essential { Text("Required").font(.caption).foregroundStyle(.secondary) } else {
                Toggle("", isOn: Binding(get: { e.enabled }, set: { registry.setEnabled(e.id, $0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
        .padding(.vertical, 2)
    }
}

extension Color {
    init?(hex: String) { guard let c = NSColor(hex: hex) else { return nil }; self.init(nsColor: c) }
    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
