import AppKit
import SwiftUI
import WebKit
import Core
import Agents
import WorkbenchKit

// MARK: web views

/// An extension's HTML page with `window.kelp` (exec, terminal, open, agent, settings, workspace).
@MainActor
final class ExtWebController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private let page: URL, folder: URL, app: AppModel
    /// The panel icon's badge `kelp.badge` sets (nil in a tab).
    private let badge: ExtBadge?
    private(set) var web: WKWebView!
    init(page: URL, folder: URL, app: AppModel, badge: ExtBadge? = nil) {
        self.page = page
        self.folder = folder
        self.app = app
        self.badge = badge
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let app = self.app
        let cfg = WKWebViewConfiguration(), pages = ExtPages(folder: folder)
        cfg.setURLSchemeHandler(pages, forURLScheme: ExtPages.scheme)
        cfg.userContentController.add(WeakHandler(self), name: "kelp")
        cfg.userContentController.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: cfg); web.isInspectable = true
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        view = web
        if let u = pages.url(of: page) { web.load(URLRequest(url: u)) }
        track(owner: self) { app.workbench.workspaceId } changed: { [weak self] _ in self?.push() }
        track(owner: self) { app.settings.values } changed: { [weak self] _ in self?.push() }
    }

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
            Task {
                let r = await Shell.run(app, arg, cwd: ctx.workspace?.path ?? folder.path, extension: folder.lastPathComponent)
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
        case "settings.get": reply(id, app.settings.value(arg) ?? .null)
        case "settings.set":
            let v = (d["value"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            app.settings.set(arg, v); reply(id, .null)
        default: reply(id, .null)
        }
        if op == "ready" { push() }
    }

    private func reply(_ id: Int, _ v: JSONValue) {
        guard let u = web.url, Self.isOwn(u, folder), let s = try? String(data: JSONEncoder().encode(v), encoding: .utf8) else { return }
        web.evaluateJavaScript("window.kelp.__resolve(\(id), \(s))")
    }

    static let bridge = """
    (() => {
      let n = 0; const pending = {}; const listeners = {settings: [], workspace: []};
      const call = (op, arg, extra) => new Promise(res => { const id = ++n; pending[id] = res;
        window.webkit.messageHandlers.kelp.postMessage(Object.assign({op, arg, id}, extra || {})); });
      window.kelp = {
        workspace: {}, exec: c => call('exec', c), terminal: (c, o) => call('terminal', c, {title: o && o.title}),
        open: u => call('open', u), agent: p => call('agent', p), badge: v => call('badge', v == null ? '' : String(v)),
        settings: { get: k => call('settings.get', k), set: (k, v) => call('settings.set', k, {value: JSON.stringify(v)}) },
        on: (ev, cb) => (listeners[ev] = listeners[ev] || []).push(cb),
        __resolve: (id, v) => { const r = pending[id]; delete pending[id]; r && r(v); },
        __update: (ws, settings) => { window.kelp.workspace = ws; listeners.workspace.forEach(f => f(ws)); listeners.settings.forEach(f => f(settings)); }
      };
      document.addEventListener('DOMContentLoaded', () => window.webkit.messageHandlers.kelp.postMessage({op: 'ready', id: 0}));
    })();
    """
}

/// WKUserContentController retains its handlers; break the cycle.
package final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    package init(_ t: WKScriptMessageHandler) { target = t }
    package func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
