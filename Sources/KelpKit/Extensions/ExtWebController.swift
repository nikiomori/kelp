import AppKit
import SwiftUI
import WebKit
import Core
import Agents
import WorkbenchKit

// MARK: web views

/// An extension's HTML page with `window.kelp` (`ExtBridge`: exec, terminal, open, agent, run, notify, settings, workspace,
/// sessions, props).
@MainActor
final class ExtWebController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private let page: URL, folder: URL, app: AppModel
    /// The panel icon's badge `kelp.badge` sets (nil in a tab).
    private let badge: ExtBadge?
    /// What the `ext:` link that opened it carried (`ext:my.ext/view?file=a.txt`): `kelp.props`.
    private let props: [String: String]
    private(set) var web: WKWebView!
    init(page: URL, folder: URL, app: AppModel, badge: ExtBadge? = nil, props: [String: String] = [:]) {
        self.page = page
        self.folder = folder
        self.app = app
        self.badge = badge
        self.props = props
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let app = self.app
        let cfg = WKWebViewConfiguration(), pages = ExtPages(folder: folder)
        cfg.setURLSchemeHandler(pages, forURLScheme: ExtPages.scheme)
        cfg.userContentController.add(WeakHandler(self), name: "kelp")
        cfg.userContentController.addUserScript(WKUserScript(source: ExtBridge.script(props: props), injectionTime: .atDocumentStart,
                                                             forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: cfg); web.isInspectable = true
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        view = web
        if let u = pages.url(of: page) { web.load(URLRequest(url: u)) }
        track(owner: self) { app.workbench.workspaceId } changed: { [weak self] _ in self?.push() }
        track(owner: self) { app.settings.values } changed: { [weak self] _ in self?.push() }
        track(owner: self) { app.sessions } changed: { [weak self] _ in self?.pushSessions() }
    }

    /// The agents, as `kelp.sessions` and to `kelp.on("sessions")`: id, title, agent, status, workspace, unread.
    private func pushSessions(again: Bool = false) {
        guard let u = web.url, Self.isOwn(u, folder) else { return }
        let list = ExtBridge.json(JSONValue.array(app.sessions.filter(\.isChat).map { s in
            .obj(["id": .string(s.id), "title": .string(app.catalog.displayName(s)), "agent": .string(s.agent ?? "shell"),
                  "status": .string(s.status.rawValue), "workspace": .string(s.worktreeId ?? ""), "unread": .bool(s.unread)])
        }))
        // A session's other fields change all the time (output, meters); the page hears only of these.
        guard again || list != sentSessions else { return }
        sentSessions = list
        web.evaluateJavaScript("window.kelp && window.kelp.__sessions(\(list))")
    }
    /// What the page last got: the same list isn't sent again.
    private var sentSessions = ""

    /// The window stays on the extension's own pages: the bridge is in every page it shows, and `push` hands it the
    /// settings and the workspace's path. A link elsewhere opens as a preview's do (`PreviewLinks`); its frames load anything.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let f = a.targetFrame, !f.isMainFrame { decisionHandler(.allow); return }
        guard let u = a.request.url, !Self.isOwn(u, folder) else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if a.navigationType == .linkActivated { PreviewLinks.open(u, in: app) }
    }

    /// A page in the extension's folder (served from it: `ExtPages`, which serves this web view's folder only); nothing else
    /// is (a site, `about:blank`, a file elsewhere).
    static func isOwn(_ u: URL, _ folder: URL) -> Bool {
        if u.scheme == ExtPages.scheme { return ExtPages(folder: folder).file(u) != nil }
        return u.isFileURL && u.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    private func push() {
        guard let u = web.url, Self.isOwn(u, folder) else { return }
        let ctx = IDEContext.of(app)
        let ws: JSONValue = .obj(["name": .string(ctx.workspace?.displayName ?? ""), "path": .string(ctx.workspace?.path ?? ""),
                                  "branch": .string(ctx.workspace?.branch ?? ""), "project": .string(ctx.project?.name ?? "")])
        let settings = JSONValue.object(app.settings.values)
        guard let w = try? String(data: JSONEncoder().encode(ws), encoding: .utf8),
              let s = try? String(data: JSONEncoder().encode(settings), encoding: .utf8) else { return }
        web.evaluateJavaScript("window.kelp && window.kelp.__update(\(w), \(s))")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        // The handler is visible to every frame, whatever it loaded: only the extension's own page may run commands.
        guard m.frameInfo.isMainFrame, let u = m.frameInfo.request.url, Self.isOwn(u, folder) else { return }
        guard let d = m.body as? [String: Any], let op = d["op"] as? String else { return }
        let id = d["id"] as? Int ?? 0, arg = d["arg"] as? String ?? ""
        let ctx = IDEContext.of(app)
        switch op {
        case "exec":
            // An array is one program and its words, each passed as it is (no shell reads them): `kelp.exec(["git", "log"])`.
            let argv = ExtBridge.decode(d["argv"], as: [String].self)
            let line = argv.map { $0.map(IDE.shellWord).joined(separator: " ") } ?? arg
            Task {
                let r = await Shell.run(app, line, cwd: ctx.workspace?.path ?? folder.path, extension: folder.lastPathComponent)
                reply(id, .obj(["code": .int(Int(r.code)), "stdout": .string(r.stdout), "stderr": .string(r.stderr)]))
            }
        case "terminal": app.workbench.editor?.run(command: arg, title: d["title"] as? String); reply(id, .null)
        // What a page opens or hands an agent is often data it shows (an issue's link, its body): `open` doesn't run
        // commands or agents (kelp.terminal / kelp.agent do, by name), and an agent's prompt is typed for the user to send.
        case "open":
            if let u = ExtActions.openableURI(TabURI.normalize(arg, cwd: ctx.workspace?.path)) { app.workbench.open(u) }
            reply(id, .null)
        case "agent": app.workbench.editor?.newAgent(nil, prompt: arg, draft: true); reply(id, .null)
        case "badge": badge?.value = PanelBadge(arg); reply(id, .null)
        // A Kelp command by its id (the menus', the palette's, an extension's), as `kelp run` does.
        case "run":
            let args = ExtBridge.decode(d["args"], as: [String: JSONValue].self)
            app.extensions.run(arg, args ?? [:]); reply(id, .null)
        case "notify": Banner.show(arg); reply(id, .null)
        case "settings.get": reply(id, app.settings.value(arg) ?? .null)
        case "settings.set":
            let v = (d["value"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            app.settings.set(arg, v); reply(id, .null)
        default: reply(id, .null)
        }
        if op == "ready" { push(); pushSessions(again: true) }
    }

    private func reply(_ id: Int, _ v: JSONValue) {
        guard let u = web.url, Self.isOwn(u, folder), let s = try? String(data: JSONEncoder().encode(v), encoding: .utf8) else { return }
        web.evaluateJavaScript("window.kelp.__resolve(\(id), \(s))")
    }

}

/// WKUserContentController retains its handlers; break the cycle.
package final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    package init(_ t: WKScriptMessageHandler) { target = t }
    package func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
