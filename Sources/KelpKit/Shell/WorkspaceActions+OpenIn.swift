// Open In and Locate: the editors this Mac has, and the menu items that show where a thing is.
import AppKit
import Core
import DesignKit

extension WorkspaceActions {
    /// The editors Kelp offers, by bundle id. Terminals and git clients get a folder (`folderOnly`), because Terminal
    /// would run a file as a script. `ssh` is the link scheme of an editor that opens a folder on another machine over
    /// SSH itself.
    private static let editors: [(name: String, bundle: String, folderOnly: Bool, ssh: String?)] = [
        ("VS Code", "com.microsoft.VSCode", false, "vscode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92", false, "cursor"),
        ("Windsurf", "com.exafunction.windsurf", false, "windsurf"), ("Zed", "dev.zed.Zed", false, nil),
        ("Sublime Text", "com.sublimetext.4", false, nil), ("Xcode", "com.apple.dt.Xcode", false, nil),
        ("Fork", "com.DanPristupov.Fork", true, nil), ("Tower", "com.fournova.Tower3", true, nil),
        ("GitHub Desktop", "com.github.GitHubClient", true, nil), ("Terminal", "com.apple.Terminal", true, nil),
        ("iTerm", "com.googlecode.iterm2", true, nil), ("Warp", "dev.warp.Warp-Stable", true, nil)
    ]
    private static func editor(_ bundle: String) -> (name: String, bundle: String, folderOnly: Bool, ssh: String?)? {
        editors.first { $0.bundle == bundle }
    }

    /// The host and the path there of a remote project's file or folder. It is nil for a path on this Mac.
    static func onHost(_ path: String) -> (host: String, path: String)? {
        let remotes = Remotes(home: Paths.root)
        if let remote = remotes.of(path) { return (remote.host, remote.path) }
        return remotes.containing(path).map { ($0.remote.host, $0.remotePath) }
    }

    /// The editors this Mac has that can open `path`. For a path on a host, these are the editors that reach it over
    /// SSH.
    static func editors(for path: String?) -> [(name: String, bundle: String, app: URL)] {
        guard let path, onHost(path) != nil else { return installedEditors }
        return installedEditors.filter { editor($0.bundle)?.ssh != nil }
    }

    static var installedEditors: [(name: String, bundle: String, app: URL)] {
        editors.compactMap { editor in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundle).map {
                (editor.name, editor.bundle, $0)
            }
        }
    }

    static func open(_ path: String, in bundle: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            NSSound.beep()
            return
        }
        // On a host, the editor opens its own remote window over SSH (`ssh`).
        if let (host, there) = onHost(path) {
            var link = URLComponents()
            link.scheme = editor(bundle)?.ssh
            link.host = "vscode-remote"
            link.path = "/ssh-remote+" + host + there
            guard link.scheme != nil, let url = link.url else { return NSSound.beep() }
            NSWorkspace.shared.open(
                [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        var target = path, dir: ObjCBool = false
        if editor(bundle)?.folderOnly == true, FileManager.default.fileExists(atPath: target, isDirectory: &dir),
            !dir.boolValue
        {
            target = (target as NSString).deletingLastPathComponent
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: target)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Adds "Open in VS Code"… for whatever editors this Mac has, like "Open With" in Finder.
    static func addOpenIn(
        to menu: NSMenu, path: @escaping @MainActor () -> String?, prefix: String = String(localized: "Open in ")
    ) {
        for editor in editors(for: path()) {
            let item = menu.add(prefix + editor.name) {
                guard let resolved = path() else {
                    NSSound.beep()
                    return
                }
                open(resolved, in: editor.bundle)
            }
            item.image = NSWorkspace.shared.icon(forFile: editor.app.path).resized(16)
        }
    }

    /// Adds the items that show where a thing is, the same everywhere: Reveal in Finder, Open In ›, and Copy Path, or
    /// Copy › when `copies` has more than the path to offer.
    package static func addLocate(
        to menu: NSMenu, path: String, copies: [(title: String, run: @MainActor @Sendable () -> Void)] = []
    ) {
        let host = onHost(path)
        if host == nil {   // a remote project's local folder holds only its marker, so it has no Finder item
            menu.add(String(localized: "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        let editors = NSMenu()
        addOpenIn(to: editors, path: { path }, prefix: "")
        if !editors.items.isEmpty {
            menu.add(String(localized: "Open In"), submenu: editors)
        }
        guard !copies.isEmpty else {
            menu.add(String(localized: "Copy Path")) { copyPath(path) }
            return
        }
        let list = NSMenu()
        list.add(String(localized: "Path")) { copyPath(path) }
        for copy in copies { list.add(copy.title, copy.run) }
        menu.add(String(localized: "Copy"), submenu: list)
    }

    /// Copies where a file or a folder is: its path, or host:path for a remote project's, as scp and rsync name it.
    static func copyPath(_ path: String) {
        copyText(onHost(path).map { "\($0.host):\($0.path)" } ?? path)
    }
}
