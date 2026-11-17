import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit
import WorkbenchKit

/// Opens the links a terminal prints: a page as a tab or in the browser, a file as a tab, and a remote project's
/// local page through its forwarded port.
extension PaneView {
    /// A local link in the terminal of a remote project points at the host. Returns `url` with the port forwarded to
    /// it on this Mac. For this Mac's own projects it returns `url` unchanged, and it returns nil when the port can't
    /// be forwarded.
    private static func hostLink(_ url: String, in wid: String?, _ app: AppModel) async -> String? {
        guard let wid, app.worktree(wid).flatMap({ RemoteHost.of($0.path) }) != nil,
            var components = URLComponents(string: url)
        else { return url }
        guard let forward = await app.call(PortsForward(worktreeId: wid, port: components.port ?? 80)) else {
            return nil
        }
        components.port = forward.port
        return components.string
    }

    /// Opens a link ⌘-clicked in the terminal. Local pages open as a browser tab and other pages in the default
    /// browser, and ⌥ swaps the two. Files open as a tab, with ⌥ or without. Nothing else opens, because a program
    /// prints these links (OSC 8 can hide the target behind any text), and an app, a .command file or another app's
    /// scheme would run. A link without a scheme is a path from `cwd`, or from another project
    /// (`TerminalPaths.resolve`). Such a path is one Ghostty found in the text ("banner/x.html"), or an agent's
    /// Markdown link to its own file.
    static func openLink(_ url: URL, cwd: String, elsewhere: [String], workspace wid: String? = nil, in app: AppModel) {
        if url.scheme == nil {
            let path = url.path(percentEncoded: false)
            if !TerminalPaths.open(
                path, cwd: cwd, elsewhere: elsewhere, workspace: wid, flags: NSEvent.modifierFlags, in: app)
            {
                Banner.show(
                    String(
                        localized:
                            "No file “\(path)” in \((cwd as NSString).abbreviatingWithTildeInPath) or your other projects."
                    ))
            }
            return
        }
        // A file link a program on a remote project's host printed (OSC 8) names the host's file.
        if url.isFileURL, TerminalPaths.openOnHost(url.path(percentEncoded: false), cwd: cwd, workspace: wid, in: app) {
            return
        }
        let option = NSEvent.modifierFlags.contains(.option)
        switch PreviewLinks.target(url) {
        case .web(let link):
            let local = url.host == "localhost" || url.host == "127.0.0.1"
            guard local else {
                if option { app.workbench.open(link, split: .right) } else { PreviewLinks.openOutside(url) }
                return
            }
            Task {
                guard let here = await hostLink(link, in: wid, app) else { return }
                if option {
                    URL(string: here).map(PreviewLinks.openOutside)
                } else {
                    app.workbench.open(here, split: .right)
                }
            }
        case .file(let path): app.workbench.open(TabURI.file(path), split: .right)
        case .mail, .refused: PreviewLinks.openOutside(url)   // openOutside says why another app's scheme doesn't open
        }
    }
}
