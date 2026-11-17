// What comes from outside the window: kelp:// links, and the ui.* requests agents send.
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// `kelp://` links (from a browser, a script, another app). Looking things up is free; adding a project, or opening a
/// file outside them, asks first.
@MainActor
struct KelpLinks {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    func handle(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "workspace" where app.worktree(id) != nil: app.workbench.show(workspace: id)
        case "session" where app.session(id) != nil: app.workbench.focus(session: id)
        case "open":
            // The path is standardized (`..` resolved) before it's compared with the project paths, so that
            // `proj/../../x` doesn't count as inside a project.
            guard
                let path = query.first(where: { $0.name == "path" })?.value.map({
                    (($0 as NSString).expandingTildeInPath as NSString).standardizingPath
                }),
                FileManager.default.fileExists(atPath: path)
            else {
                Banner.show(String(localized: "Kelp can't find the file in that link."), style: .error)
                return
            }
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &dir)
            if !dir.boolValue {
                openFile(path, line: query.first { $0.name == "line" }?.value.flatMap(Int.init))
            } else if app.repos.contains(where: { Paths.inside(path, $0.path) }) {   // a link out of a project isn't in it
                app.workbench.addProject(path: path)   // already a project, so this just shows it
            } else {
                Task {
                    if await confirm(
                        String(localized: "Add “\((path as NSString).lastPathComponent)” to Kelp?"),
                        detail: String(localized: "A link asked to open \(path) as a project."),
                        action: String(localized: "Add Project"))
                    {
                        app.workbench.addProject(path: path)
                    }
                }
            }
        default: Banner.show(String(localized: "Kelp doesn't know the link \(url.absoluteString)."), style: .error)
        }
        NSApp.activate()
    }

    private func openFile(_ path: String, line: Int?) {
        let worktree = app.worktree(holding: path)
        whenAllowed(path) {
            app.workbench.open(TabURI.file(path) + (line.map { "#L\($0)" } ?? ""), workspace: worktree?.id)
        }
    }

    /// Runs `open` right away for a file in a project, and for a file elsewhere once the user says so (`ask`, a sheet),
    /// as for a folder. Any web page can send a `kelp://` link, and a preview's page may come from a cloned repository
    /// (`PreviewLinks`).
    func whenAllowed(
        _ path: String,
        ask: @escaping @MainActor (String) async -> Bool = askToOpen,
        _ open: @escaping @MainActor () -> Void
    ) {
        guard !isKnown(path) else { return open() }
        Task { if await ask(path) { open() } }
    }

    static func askToOpen(_ path: String) async -> Bool {
        await confirm(
            String(localized: "Open “\((path as NSString).lastPathComponent)”?"),
            detail: String(localized: "A link asked to open \(path), which is outside your projects."),
            action: String(localized: "Open"))
    }

    /// Whether the path is in a project's folder, one of its workspaces' folders, or Kelp's own home, once `..` and
    /// links are followed.
    func isKnown(_ path: String) -> Bool {
        (app.repos.map(\.path) + app.worktrees.map(\.path) + [Paths.root.path]).contains { Paths.inside(path, $0) }
    }
}

/// IDE actions agents ask for through the daemon (`kelp open`, `kelp ui`). They never pull Kelp to the front, switch
/// the workspace on screen or take the keys unless asked (`--focus`). A tab for another workspace waits there.
@MainActor
struct UIRequests {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    func handle(_ event: UIEvent) {
        switch event.action {
        case "open":
            guard let uri = event.uri else { return }
            let split = event.split.flatMap(SplitDirection.init(rawValue:))
            let focus = event.focus == true
            if let wid = event.worktreeId, wid != app.workbench.workspaceId, !focus, app.workbench.workspaceId != nil {
                app.workbench.openInBackground(uri, workspace: wid)
                return
            }
            // `kelp open`, run by the user or by one of their agents
            if TabURI.runs(uri) {
                app.workbench.runURI(uri, split: split, workspace: event.worktreeId, focus: focus)
            } else if focus {
                app.workbench.open(uri, split: split, workspace: event.worktreeId)
            } else {
                app.workbench.showAside(uri, split: split, workspace: event.worktreeId)
            }
            if focus { NSApp.activate() }
        case "command":
            guard let id = event.id else { return }
            if id == "extensions.reload" {
                app.extensions.reload()
                return
            }
            if id == "window.shot", let shotWindow = app.workbench.mainWindow,
                let path = event.args?["path"]?.string
            {
                // Only a picture, by its name, because `kelp shot` (an agent's too) writes a .png and must never write
                // over a source file it was told.
                guard path.lowercased().hasSuffix(".png") else {
                    return Banner.show(String(localized: "A window's picture is a .png file."), style: .error)
                }
                AppDelegate.snap(shotWindow, to: path)
                return
            }
            guard let command = app.extensions.command(id) else {
                Banner.show(String(localized: "Unknown command \(id)"), style: .error)
                return
            }
            if case .object(let args)? = event.args { command.run(args) } else { command.run([:]) }
        default: break
        }
    }
}
