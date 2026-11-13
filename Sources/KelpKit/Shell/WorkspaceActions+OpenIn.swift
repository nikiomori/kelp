// Open In and Locate: the editors this Mac has, and the menu items that show where a thing is.
import AppKit
import Core
import DesignKit

extension WorkspaceActions {
    private static let editors = [
        ("VS Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Windsurf", "com.exafunction.windsurf"),
        ("Zed", "dev.zed.Zed"), ("Sublime Text", "com.sublimetext.4"), ("Xcode", "com.apple.dt.Xcode"),
        ("Fork", "com.DanPristupov.Fork"), ("Tower", "com.fournova.Tower3"),
        ("GitHub Desktop", "com.github.GitHubClient"),
        ("Terminal", "com.apple.Terminal"), ("iTerm", "com.googlecode.iterm2"), ("Warp", "dev.warp.Warp-Stable")
    ]
    /// Terminals and git clients get a folder: Terminal would run a file as a script.
    private static let folderOnly: Set = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.DanPristupov.Fork",
        "com.fournova.Tower3", "com.github.GitHubClient"
    ]

    /// Editors that open a folder on another machine over SSH themselves, by the link scheme each answers to.
    private static let overSSH = [
        "com.microsoft.VSCode": "vscode", "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf"
    ]

    /// A remote project's file or folder: its host and its path there; nil for one on this Mac.
    static func onHost(_ path: String) -> (host: String, path: String)? {
        let remotes = Remotes(home: Paths.root)
        if let remote = remotes.of(path) { return (remote.host, remote.path) }
        return remotes.containing(path).map { ($0.remote.host, $0.remotePath) }
    }

    /// The editors this Mac has that can open `path`: on a host, those that reach it over SSH.
    static func editors(for path: String?) -> [(name: String, bundle: String, app: URL)] {
        guard let path, onHost(path) != nil else { return installedEditors }
        return installedEditors.filter { overSSH[$0.bundle] != nil }
    }

    static var installedEditors: [(name: String, bundle: String, app: URL)] {
        editors.compactMap { name, bundle in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { (name, bundle, $0) }
        }
    }

    static func open(_ path: String, in bundle: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            NSSound.beep()
            return
        }
        // On a host: the editor's own remote window, over SSH (`overSSH`).
        if let (host, there) = onHost(path) {
            var link = URLComponents()
            link.scheme = overSSH[bundle]
            link.host = "vscode-remote"
            link.path = "/ssh-remote+" + host + there
            guard link.scheme != nil, let url = link.url else { return NSSound.beep() }
            NSWorkspace.shared.open(
                [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        var target = path, dir: ObjCBool = false
        if folderOnly.contains(bundle), FileManager.default.fileExists(atPath: target, isDirectory: &dir),
            !dir.boolValue
        {
            target = (target as NSString).deletingLastPathComponent
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: target)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// "Open in VS Code"… for whatever editors this Mac has, like "Open With" in Finder.
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

    /// Where a thing is, the same items everywhere: Reveal in Finder, Open In ›, and Copy Path, or Copy › when `copies`
    /// has more than the path to offer.
    package static func addLocate(
        to menu: NSMenu, path: String, copies: [(title: String, run: @MainActor @Sendable () -> Void)] = []
    ) {
        let host = onHost(path)
        if host == nil {   // a remote project's folder here holds only its marker
            menu.add(String(localized: "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        let editors = NSMenu()
        addOpenIn(to: editors, path: { path }, prefix: "")
        if !editors.items.isEmpty {
            menu.add(String(localized: "Open In"), submenu: editors)
        }
        let copyPath: @MainActor () -> Void = {
            copyText(host.map { "\($0.host):\($0.path)" } ?? path)   // as scp and rsync name it
        }
        guard !copies.isEmpty else {
            menu.add(String(localized: "Copy Path"), copyPath)
            return
        }
        let list = NSMenu()
        list.add(String(localized: "Path"), copyPath)
        for copy in copies { list.add(copy.title, copy.run) }
        menu.add(String(localized: "Copy"), submenu: list)
    }
}
