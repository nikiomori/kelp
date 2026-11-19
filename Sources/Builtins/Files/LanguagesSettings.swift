import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// The Settings › Languages page. It lists every language that has a server, the project's own languages first, with
/// which servers are installed and running, and Install for those that are missing. The daemon is asked when the page
/// shows and after each action on it.
struct LanguagesSettings: View {
    let app: AppModel
    @State private var typed = ""
    private var lsp: LSPManager { LSPManager.of(app) }

    var body: some View {
        let root = lsp.projectRoot, used = root.flatMap { lsp.used[$0] } ?? []
        let rows = LanguageRows.matching(LanguageRows.rows(app.extensions.all.languages), typed)
        let known = lsp.states[root ?? ""] != nil
        let here = rows.filter { !used.isDisjoint(with: $0.languages) }
        let rest = rows.filter { used.isDisjoint(with: $0.languages) }
        let have = rest.filter { row in row.servers.contains { lsp.status($0, in: root) != .missing } }
        let lack = rest.filter { row in !have.contains(row) }
        return Form {
            Section {
                TextField("Search", text: $typed, prompt: Text("Search languages and servers"))
                    .labelsHidden()
            } footer: {
                if !known { ProgressView().controlSize(.small) }
            }
            if known {
                group(String(localized: "In This Project"), here, in: root, asks: true)
                group(String(localized: "Installed"), have, in: root)
                group(String(localized: "Not Installed"), lack, in: root)
                if rows.isEmpty { Text("No language or server matches “\(typed)”.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task {
            if let worktree = app.worktree(app.workbench.workspaceId) { await lsp.scan(worktree) }
            await lsp.refresh(lsp.projectRoot)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [LanguageRow], in root: String?, asks: Bool = false) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: Metrics.inset) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.ui(TextSize.row, weight: .medium))
                            Text(row.files).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                        }
                        .frame(width: 180, alignment: .leading)
                        VStack(alignment: .leading, spacing: Metrics.gap) {
                            ForEach(row.servers, id: \.command) {
                                ServerLine(app: app, server: $0, root: root, asks: asks)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One server's line: a dot, the server's name, what the server is doing, and the one action that fits.
struct ServerLine: View {
    let app: AppModel
    let server: LanguageSpec.Server
    let root: String?
    var asks = false
    /// A file's own server list offers Restart as a button, while the settings page keeps Restart in the row's menu.
    var restarts = false
    private var lsp: LSPManager { LSPManager.of(app) }

    var body: some View {
        let status = lsp.status(server, in: root, asks: asks)
        HStack(spacing: Metrics.gap) {
            StateDot(dot(status))
            Text(LSPManager.name(server)).font(.uiMono(TextSize.caption)).lineLimit(1)
            Text(words(status)).font(.ui(TextSize.caption))
                .foregroundStyle(status == .failed ? Color.textRed : Color.secondary).lineLimit(1)
            Spacer(minLength: Metrics.gap)
            action(status)
        }
        .help(status == .missing ? server.install ?? "" : "")
        .contextMenu {
            if let root, case .running = status { Button("Restart") { Task { await lsp.restart(server, in: root) } } }
            if let install = server.install { Button("Copy Install Command") { copyText(install) } }
        }
    }

    @ViewBuilder
    private func action(_ status: ServerStatus) -> some View {
        switch status {
        case .missing where server.install != nil: Button("Install") { lsp.install(server) }.controlSize(.small)
        case .installing: ProgressView().controlSize(.small)
        case .failed: restart
        case .running where restarts: restart
        case .untrusted: Button("Trust Project") { Task { if let root { await lsp.trust(root) } } }.controlSize(.small)
        default: EmptyView()
        }
    }

    @ViewBuilder private var restart: some View {
        if let root { Button("Restart") { Task { await lsp.restart(server, in: root) } }.controlSize(.small) }
    }

    private func words(_ status: ServerStatus) -> String {
        let role = server.optional == true ? String(localized: " · optional") : ""
        return switch status {
        case .unknown: ""
        case .missing: String(localized: "Not installed") + role
        case .installing: String(localized: "Installing…")
        case .installed: String(localized: "Installed")
        case .running(1): String(localized: "Running · 1 file")
        case .running(let files): String(localized: "Running · \(files) files")
        case .failed: String(localized: "Didn’t start")
        case .untrusted: String(localized: "Installed · waits for this project’s trust")
        }
    }

    /// Filled while the server is there (installed or running), red only when it didn't start.
    private func dot(_ status: ServerStatus) -> StateDot.State {
        switch status {
        case .running, .installed, .untrusted: .on
        case .failed: .broken
        default: .off
        }
    }
}

/// The popover listing a file's own servers, opened from its status bar: what runs, Restart, Install, and a link to
/// all languages.
struct FileServers: View {
    let app: AppModel
    let language: LanguageSpec
    let root: String
    let file: String
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.inset) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gap) {
                Text(LanguageRows.name(language.id)).font(.ui(TextSize.heading, weight: .semibold))
                Text(file).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: Metrics.gap) {
                ForEach(language.allServers, id: \.command) {
                    ServerLine(app: app, server: $0, root: root, asks: true, restarts: true)
                }
            }
            Divider()
            Button("All Languages…") {
                app.extensions.run("workbench.openSettings", ["section": .string("languages"), "group": .null])
            }
            .buttonStyle(.link).font(.ui(TextSize.row))
        }
        .frame(width: Metrics.popoverWidth, alignment: .leading)   // the text column, as HelpMark's
        .padding(Metrics.inset)
        .task { await LSPManager.of(app).refresh(root) }
    }
}

extension Builtins {
    /// Settings › Languages.
    static func languagesSettings(_ app: AppModel) -> SettingsSection {
        let languages = app.extensions.all.languages
        return SettingsSection(
            id: "languages", title: "Languages", icon: "curlybraces", specs: [],
            custom: { AnyView(LanguagesSettings(app: app)) },
            keywords: ["Language Servers", "LSP", "Linters"] + languages.map { LanguageRows.name($0.id) }
                + languages.flatMap(\.allServers).map(\.command),
            fillsPane: true, order: 72)
    }
}
