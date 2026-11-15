import AppKit
import Core
import DesignKit
import WorkbenchKit
import os

/// A project's group templates (`LayoutTemplate`), kept with the daemon's state under the project (`templates/<repo>`):
/// saved from a group's row, listed on a group's empty screen, which a click arranges as it says.
@MainActor
struct LayoutTemplates {
    let app: AppModel

    func all(_ repoId: String) -> [LayoutTemplate] {
        guard let saved = app.uiState[Self.key(repoId)] else { return [] }
        return Self.log.attempt("reading templates") { try saved.decode([LayoutTemplate].self) } ?? []
    }

    /// Save Layout as Template… on a group's row: its panes and what runs in them, under a name; one of that name is
    /// replaced (how one is changed: arrange a group, save it again). In its own window now, it opens in one.
    func save(from id: String) async {
        guard let worktree = app.worktree(id) else { return }
        let layout = app.workbench.layouts[id]
        guard !layout.allTabs.isEmpty,
            let name = await prompt(
                String(localized: "Save Layout as Template"),
                String(localized: "New groups in this project can open with these panes and what runs in them."),
                initial: app.groupName(worktree) ?? "", action: String(localized: "Save")),
            !name.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        let made = LayoutTemplate(name: name, from: layout, ownWindow: app.workbench.inOwnWindow(id)) { uri in
            app.session(TabURI.body(uri)).map(Self.running)
        }
        store(all(worktree.repoId).filter { $0.name != name } + [made], worktree.repoId)
    }

    func delete(_ name: String, in repoId: String) { store(all(repoId).filter { $0.name != name }, repoId) }

    /// The empty group `id` arranged as `template` says: what ran starts again, each in its tab.
    func use(_ template: LayoutTemplate, in id: String) async {
        // Once: a double click, or a second click while the first one's sessions start, leaves it be.
        guard app.workbench.layouts[id].allTabs.isEmpty, Self.using.insert(id).inserted else { return }
        defer { Self.using.remove(id) }
        var started: [String: String] = [:]
        for tab in template.runs {
            let run = Self.run(tab.uri)
            let create = app.workbench.sized(
                SessionCreate(worktreeId: id, agent: run.agent, command: run.command, tmux: run.tmux, title: run.title))
            if let session = await app.call(create) {
                app.upsert(session)
                started[tab.id] = TabURI.session(session.id)
            }
        }
        app.workbench.layouts[id] = template.filled(started)
        if template.ownWindow, !app.workbench.inOwnWindow(id) { app.workbench.moveToOwnWindow(id) }
    }

    /// What its names say on the empty screen: "Claude · npm run dev · localhost:3000".
    func summary(_ template: LayoutTemplate) -> String {
        template.layout.allTabs.compactMap { tab -> String? in
            let uri = tab.uri, c = URLComponents(string: uri)
            func value(_ name: String) -> String? { c?.queryItems?.first { $0.name == name }?.value }
            switch TabURI.scheme(uri) {
            case "agent": return app.catalog.name(TabURI.body(uri))
            case "terminal": return value("title") ?? value("cmd") ?? value("tmux") ?? String(localized: "Terminal")
            case "file": return URL(fileURLWithPath: TabURI.filePath(uri).path).lastPathComponent
            default:
                return URL(string: TabURI.pageURL(uri)).flatMap { u in
                    u.host.map { $0 + (u.port.map { ":\($0)" } ?? "") }
                }
            }
        }.joined(separator: " · ")
    }

    /// What runs again for a session's tab: its agent anew, its command (a Run command's), or a shell where it was.
    static func running(_ s: Session) -> String {
        var c = URLComponents()
        c.scheme = "terminal"
        if s.isAgent, let agent = s.agent { return "agent:" + agent }
        if s.agent == "custom", s.argv.count == 3, s.argv[1] == "-lc" {
            c.queryItems = [URLQueryItem(name: "cmd", value: s.argv[2]), URLQueryItem(name: "title", value: s.title)]
        } else if let tmux = Tmux.session(s.argv) {
            c.queryItems = [URLQueryItem(name: "tmux", value: tmux)]
        }
        return c.string ?? "terminal:"
    }

    /// What a run URI starts (as `EditorArea.runURI` reads one).
    static func run(_ uri: String) -> (agent: String?, command: String?, title: String?, tmux: String?) {
        let c = URLComponents(string: uri)
        func value(_ name: String) -> String? { c?.queryItems?.first { $0.name == name }?.value }
        if TabURI.scheme(uri) == "agent" { return (TabURI.body(uri), nil, nil, nil) }
        if let tmux = value("tmux") { return (nil, nil, nil, tmux) }
        if let cmd = value("cmd") { return (nil, cmd, value("title"), nil) }
        return ("shell", nil, nil, nil)
    }

    private static var using: Set<String> = []
    private static let log = Logger.kelp("templates")
    private static func key(_ repoId: String) -> String { "templates/" + repoId }
    private func store(_ templates: [LayoutTemplate], _ repoId: String) {
        app.uiState[Self.key(repoId)] =
            templates.isEmpty ? nil : Self.log.attempt("saving templates") { try JSONValue.from(templates) }
    }
}
