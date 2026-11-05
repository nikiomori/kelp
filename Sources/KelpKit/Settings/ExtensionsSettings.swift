import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Core
import DesignKit
import WorkbenchKit

/// Installed extensions: turn them on or off, remove, create (by hand or with an agent); or the library's, to install.
struct ExtensionsSettings: View {
    @Environment(AppModel.self) private var app
    private var registry: ExtensionRegistry { app.extensions }
    @State private var picking = false
    /// Opened on the library when asked for (`SettingsWindow.show(section: "extensions", group: "library")`).
    @State private var library = UserDefaults.standard.string(forKey: "settings.group") == "library"
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

    /// What can be turned off, then what was installed (with its version). The parts Kelp can't run without are named under
    /// the list: as rows they were a third of it and did nothing.
    @ViewBuilder private var installed: some View {
        Section {
            ForEach(registry.extensions.filter { $0.builtin && !$0.essential }) { row($0) }
        } header: {
            Text("Built-in")
        } footer: {
            let always = registry.extensions.filter(\.essential).map { loc($0.name) }.joined(separator: ", ")
            Text("Turn off what you don't use. Always on: \(always).").font(.subheadline).foregroundStyle(.secondary)
        }
        let added = registry.extensions.filter { !$0.builtin }
        if !added.isEmpty {
            Section("Installed") { ForEach(added) { row($0) } }
        }
        Section {
            Text(String(localized: "To add one, install it from the Library, or ask Claude Code in an agent tab, e.g. “make a Kelp panel that lists my Docker containers”. ")
                 + String(localized: "It knows how through the extensions skill (Settings › Agents)."))
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("How Extensions Work") { app.workbench.showFile(ExtensionRegistry.userDir.appendingPathComponent("EXTENSIONS.md")) }
                    .buttonStyle(.link)
                Spacer()
                Button("Install…") { picking = true }
                    .help("A VS Code extension (.vsix or its folder) — for its file icon themes — or a Kelp extension folder")
                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.open(ExtensionRegistry.userDir) }
                    Button("Reload Extensions") { registry.reload() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    private func row(_ e: ExtensionInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: e.icon).font(.title3).foregroundStyle(e.error == nil ? Color.secondary : Color.textOrange).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(loc(e.name)).fontWeight(.medium)
                    if !e.builtin { Text(e.version).font(.subheadline).foregroundStyle(.secondary) }
                }
                if !e.description.isEmpty { Text(loc(e.description)).font(.subheadline).foregroundStyle(.secondary) }
                if let err = e.error { Text(err).font(.subheadline).foregroundStyle(Color.textOrange).textSelection(.enabled) }
                if let u = e.unavailable { Text(u).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            if let p = e.path, !e.builtin {
                Menu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p]) }
                    let manifest = FileManager.default.fileExists(atPath: p.appendingPathComponent("extension.json").path)
                        ? "extension.json" : "package.json"
                    Button("Edit \(manifest)") { app.workbench.showFile(p.appendingPathComponent(manifest)) }
                    Divider()
                    Button("Uninstall", role: .destructive) { registry.uninstall(e.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Toggle("", isOn: Binding(get: { e.enabled }, set: { registry.setEnabled(e.id, $0) }))
                .toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

extension Workbench {
    /// In a tab of the main window, brought up over Settings: left behind it, the click seemed to do nothing.
    func showFile(_ url: URL) {
        open(TabURI.file(url.path))
        bringToFront()
    }
}
