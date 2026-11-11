// What comes from outside the window: kelp:// links, and the ui.* requests agents send.
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// `kelp://` links (from a browser, a script, another app). Looking things up is free; adding a project, or opening a file
/// outside them, asks first.
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
            // Standardized (`..` resolved) before it's compared with the projects': `proj/../../x` is no project of theirs.
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
                app.workbench.addProject(path: path)   // already a project: just shows it
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

    /// A project's file opens right away; one elsewhere once the user says so (`ask`, a sheet), as a folder does: any web
    /// page can send a `kelp://` link, and a preview's page may be a cloned repository's (`PreviewLinks`).
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

    /// In a project's folder, one of its workspaces' or Kelp's own home, once `..` and links are followed.
    func isKnown(_ path: String) -> Bool {
        (app.repos.map(\.path) + app.worktrees.map(\.path) + [Paths.root.path]).contains { Paths.inside(path, $0) }
    }
}

/// IDE actions agents ask for through the daemon (`kelp open`, `kelp ui`). They never pull Kelp to the front, switch the
/// workspace on screen or take the keys unless asked (`--focus`): a tab for another workspace waits there.
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
            // `kelp open`: the user's or their agent's own
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
                // A picture, by its name: `kelp shot` (an agent's too) writes a .png, never over a source file it was told.
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
