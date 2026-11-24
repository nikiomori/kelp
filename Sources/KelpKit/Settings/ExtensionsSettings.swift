import AppKit
import Core
import DesignKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

/// Settings › Extensions. It lists installed extensions to turn on or off, remove or create (by hand or with an agent),
/// or the library's extensions to install.
struct ExtensionsSettings: View {
    @Environment(AppModel.self) private var app
    private var registry: ExtensionRegistry { app.extensions }
    @State private var picking = false
    /// Whether the library shows, which it does when asked for (`SettingsWindow.show(section: "extensions",
    /// group: "library")`).
    @State private var library = UserDefaults.standard.string(forKey: "settings.group") == "library"
    var body: some View {
        // The switch sits over the list on the content's left edge, as the Agent Catalog's filter does. In a card of
        // its own it was a box around one control, and in the title bar it read as the window's own.
        VStack(alignment: .leading, spacing: 0) {
            Segments(
                labels: [String(localized: "Installed"), String(localized: "Library")],
                name: String(localized: "Show"),
                selection: Binding {
                    library ? 1 : 0
                } set: {
                    library = $0 == 1
                }
            )
            .padding([.horizontal, .top], Metrics.sheetInset)   // the grouped form's own margin
            Form { if library { LibrarySection() } else { installed } }
                .formStyle(.grouped)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, UTType(filenameExtension: "vsix") ?? .zip])
        { result in
            guard case .success(let url) = result else { return }
            Task {
                do { try await registry.install(url) } catch {
                    Banner.show(
                        String(localized: "Couldn’t install \(url.lastPathComponent): \(AppModel.message(error))"),
                        style: .error)
                }
            }
        }
    }

    /// Lists what can be turned off, then what was installed (with its version). The parts Kelp can't run without are
    /// named under the list, because as rows they were a third of it and did nothing.
    @ViewBuilder private var installed: some View {
        Section {
            ForEach(registry.extensions.filter { $0.builtin && !$0.essential }) { row($0) }
        } header: {
            Text("Built-in").font(.ui(TextSize.body, weight: .semibold))
        } footer: {
            let always = registry.extensions.filter(\.essential).map { loc($0.name) }.joined(separator: ", ")
            Text("Turn off what you don’t use. Always on: \(always).").font(.ui(TextSize.caption)).foregroundStyle(
                .secondary)
        }
        let added = registry.extensions.filter { !$0.builtin }
        if !added.isEmpty {
            TitledSection("Installed") { ForEach(added) { row($0) } }
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
                Spacer()
                Button("Install…") { picking = true }
                    .help(
                        "A VS Code extension (.vsix or its folder) — for its file icon themes — or a Kelp extension folder"
                    )
                Menu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ExtensionRegistry.userDir.path)
                    }
                    Button("Reload Extensions") { registry.reload() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.symbol())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(String(localized: "More Actions")).accessibilityLabel(String(localized: "More Actions"))
            }
        }
    }

    /// A row laid out like every setting's row: the name over its description, in the form's own sizes and spacing,
    /// with the symbol beside it.
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
                // A label's lines under the title are set as the system sets them (smaller, grey), because the
                // window's font is set for its rows.
                if !info.description.isEmpty {
                    Text(loc(info.description)).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
                if let err = info.error {
                    Text(err).font(.ui(TextSize.caption)).foregroundStyle(Color.textRed).textSelection(.enabled)
                }
                if let reason = info.unavailable {
                    Text(reason).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
                if info.waitsToBeAllowed {
                    Text("New or changed since it was allowed: it runs no commands until you allow it.").font(
                        .ui(TextSize.caption)
                    ).foregroundStyle(.secondary)
                }
            } icon: {
                SymbolIcon(info.icon).foregroundStyle(info.error == nil ? Color.secondary : Color.textRed)
            }
        }
    }

    private func enabled(_ info: ExtensionInfo) -> some View {
        // Named, though the name is hidden: VoiceOver says which extension the switch is for.
        Toggle(loc(info.name), isOn: Binding(get: { info.enabled }, set: { registry.setEnabled(info.id, $0) }))
            .toggleStyle(.switch).labelsHidden()
    }

    /// The actions for an installed extension. Kelp's own extensions can only be turned off.
    @ViewBuilder private func more(_ info: ExtensionInfo) -> some View {
        if let folder = info.path, !info.builtin {
            Menu {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                let manifest =
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent("extension.json").path)
                    ? "extension.json" : "package.json"
                Button("Edit \(manifest)") { app.workbench.showFile(folder.appendingPathComponent(manifest)) }
                Divider()
                Button("Uninstall…", role: .destructive) {
                    Task {
                        let sure = await confirm(
                            String(localized: "Uninstall “\(loc(info.name))”?"),
                            detail: String(localized: "Its folder moves to the Trash."),
                            action: String(localized: "Uninstall"), destructive: true)
                        if sure { registry.uninstall(info.id) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.symbol())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(String(localized: "More Actions")).accessibilityLabel(String(localized: "More Actions"))
        }
    }
}

extension Workbench {
    /// Opens a file in a tab of the main window and brings the window up over Settings, because left behind Settings,
    /// the click seemed to do nothing.
    func showFile(_ url: URL) {
        open(TabURI.file(url.path))
        bringToFront()
    }
}
