import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit
import WorkbenchKit

/// Links a terminal prints, opened: a page as a tab or in the browser, a file as a tab, a remote project's local
/// page through its forwarded port.
extension PaneView {
    /// A local link in a terminal of a remote project means the host: `url` with the port it has on this Mac. As it was
    /// on this Mac's own projects, nil when it can't be brought here.
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

    /// A link ⌘-clicked in the terminal: local pages open as a browser tab, the rest in the default browser; ⌥ swaps
    /// the two. Files open as a tab, ⌥ or not. Nothing else opens: a program prints these links (OSC 8 hides the target
    /// behind any text), and an app, a .command file or another app's scheme would run. A link without a scheme is a
    /// path from `cwd` (or another project's, `TerminalPaths.resolve`): one Ghostty found in the text ("banner/x.html"),
    /// or an agent's Markdown link to its own file.
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
        case .mail, .refused: PreviewLinks.openOutside(url)   // which says why another app's scheme doesn't open
        }
    }
}
