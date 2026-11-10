import AppKit
import Core
import DesignKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

/// Installed extensions: turn them on or off, remove, create (by hand or with an agent); or the library's, to install.
struct ExtensionsSettings: View {
    @Environment(AppModel.self) private var app
    private var registry: ExtensionRegistry { app.extensions }
    @State private var picking = false
    /// Opened on the library when asked for (`SettingsWindow.show(section: "extensions", group: "library")`).
    @State private var library = UserDefaults.standard.string(forKey: "settings.group") == "library"
    var body: some View {
        Form {
            // The page's first row, as the Agent Catalog's filter: in the title bar it read as the window's, not the page's.
            Section {
                Picker("", selection: $library) {
                    Text("Installed").tag(false)
                    Text("Library").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().frame(maxWidth: .infinity)
            }
            if library { LibrarySection() } else { installed }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, UTType(filenameExtension: "vsix") ?? .zip])
        { result in
            guard case .success(let url) = result else { return }
            Task {
                do { try await registry.install(url) } catch {
                    Banner.show(
                        String(localized: "Couldn't install \(url.lastPathComponent): \(AppModel.message(error))"),
                        style: .error)
                }
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
            Text("Turn off what you don't use. Always on: \(always).").font(.ui(TextSize.caption)).foregroundStyle(
                .secondary)
        }
        let added = registry.extensions.filter { !$0.builtin }
        if !added.isEmpty {
            Section("Installed") { ForEach(added) { row($0) } }
        }
        Section {
            Text(
                String(
                    localized:
                        "To add one, install it from the Library, or ask Claude Code in an agent tab, e.g. “make a Kelp panel that lists my Docker containers”. "
                )
                    + String(localized: "It knows how through the extensions skill (Settings › Agents).")
            )
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            HStack {
                Button("How Extensions Work") {
                    app.workbench.showFile(ExtensionRegistry.userDir.appendingPathComponent("EXTENSIONS.md"))
                }
                .buttonStyle(.link)
                Spacer()
                Button("Install…") { picking = true }
                    .help(
                        "A VS Code extension (.vsix or its folder) — for its file icon themes — or a Kelp extension folder"
                    )
                Menu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ExtensionRegistry.userDir.path)
                    }
                    Button("Reload Extensions") { registry.reload() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    /// A row as every setting's: the name over its description, the form's own sizes and spacing; the symbol beside it.
    private func row(_ info: ExtensionInfo) -> some View {
        LabeledContent {
            HStack(spacing: Metrics.gap) {
                if info.waitsToBeAllowed { Button("Allow…") { Task { await registry.allow(info) } } }
                more(info)
                enabled(info)
            }
        } label: {
            Label {
                Text(info.builtin ? loc(info.name) : "\(loc(info.name)) \(info.version)")
                if !info.description.isEmpty { Text(loc(info.description)) }
                if let err = info.error { Text(err).foregroundStyle(Color.textOrange).textSelection(.enabled) }
                if let reason = info.unavailable { Text(reason) }
                if info.waitsToBeAllowed {
                    Text("New or changed since it was allowed: it runs no commands until you allow it.")
                }
            } icon: {
                Image(systemName: info.icon).foregroundStyle(info.error == nil ? Color.secondary : Color.textOrange)
                    .frame(
                        width: Metrics.iconMenu)
            }
        }
    }

    private func enabled(_ info: ExtensionInfo) -> some View {
        Toggle("", isOn: Binding(get: { info.enabled }, set: { registry.setEnabled(info.id, $0) })).toggleStyle(.switch)
            .labelsHidden()
    }

    /// What can be done to one that was installed; Kelp's own only turn off.
    @ViewBuilder private func more(_ info: ExtensionInfo) -> some View {
        if let folder = info.path, !info.builtin {
            Menu {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                let manifest =
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent("extension.json").path)
                    ? "extension.json" : "package.json"
                Button("Edit \(manifest)") { app.workbench.showFile(folder.appendingPathComponent(manifest)) }
                Divider()
                Button("Uninstall", role: .destructive) { registry.uninstall(info.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

extension Workbench {
    /// In a tab of the main window, brought up over Settings: left behind it, the click seemed to do nothing.
    func showFile(_ url: URL) {
        open(TabURI.file(url.path))
        bringToFront()
    }
}
