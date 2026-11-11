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
                            SettingsIcon(symbol: section.icon, tint: section.tint)
                        }.tag(Optional(section.id))
                    }
                }
                Section {
                    // A row of a ForEach, as the sections are: the list picks a row by the id that gives it, and a row
                    // standing alone with only a tag couldn't be picked.
                    ForEach(["extensions"], id: \.self) { id in
                        Label {
                            Text("Extensions")
                        } icon: {
                            SettingsIcon(symbol: "puzzlepiece.extension", tint: NSColor(hex: 0xA2845E))
                        }.tag(Optional(id))
                    }
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
                    EmptyState(String(localized: "Pick a Section"), symbol: "gearshape")
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
/// meaning a state, so a section is found by eye. Like System Settings' tiles: a filled white glyph on a top-lit gradient.
/// Each section says its colour (`SettingsSection.tint`): Apple's light-mode system colours in both modes, as System
/// Settings keeps them (the dark-mode ones are neon on a tile). One that says none is grey, as General and Keyboard are
/// in System Settings, and as an extension's sections are.
private struct SettingsIcon: View {
    let symbol: String, tint: NSColor?
    var body: some View {
        Image(systemName: symbol).symbolVariant(.fill).font(.symbol(Metrics.iconSmall)).foregroundStyle(.white)
            .frame(width: Metrics.iconMenu, height: Metrics.iconMenu)
            .background(
                Color(nsColor: tint ?? NSColor(hex: 0x8E8E93)).gradient,
                in: RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous))
    }
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
                if section.perLanguage { LanguagePicker(language: $language) }
                ForEach(groups.indices, id: \.self) { index in
                    let rows = groups[index].1.filter {
                        (language.isEmpty || $0.perLanguage == true) && store.meets($0.requires)
                    }
                    if rows.isEmpty {
                        EmptyView()
                    } else if let title = groups[index].0 {
                        Section(loc(title)) {
                            section.previews[title]?()
                            ForEach(rows) { row($0) }
                        }.id(title)
                    } else {
                        Section {
                            section.previews[""]?()
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
