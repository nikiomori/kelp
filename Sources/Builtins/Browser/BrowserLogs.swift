import KelpKit
import WebKit

/// `kelp browser console | network`: what the page printed and asked for, kept here since the agent first drove the tab
/// (an agent's own page: since it opened). The page's `console`, `fetch` and `XMLHttpRequest` are wrapped in its own
/// world (Kelp's world has its own globals), so the page could post fake entries: it only fills its own lists.
extension BrowserTab {
    /// Starts keeping the lists: for the next documents, and for this one from now.
    @discardableResult
    func watch() -> AgentDrive {
        if let drive { return drive }
        let made = AgentDrive()
        drive = made
        showAgentBar()
        let uc = web.configuration.userContentController
        uc.add(WeakHandler(self), name: "kelpWatch")
        uc.addUserScript(WKUserScript(source: Self.watchJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.evaluateJavaScript(Self.watchJS)
        return made
    }

    func note(_ message: WKScriptMessage) {
        guard drive != nil, let entry = message.body as? [String: Any] else { return }
        let text = String((entry["text"] as? String ?? "").prefix(2000))
        if entry["k"] as? String == "start", let id = entry["id"] as? String {
            drive?.started(id)
            return
        }
        if let id = entry["id"] as? String { drive?.inflight[id] = nil }
        if entry["k"] as? String == "net" {
            let status = (entry["status"] as? Int).map { $0 == 0 ? "failed" : String($0) } ?? "failed"
            let ms = (entry["ms"] as? Int).map { ", \($0) ms" } ?? ""
            noteRequest(
                "\(status) \(entry["method"] as? String ?? "GET") \(entry["url"] as? String ?? "") (\(entry["type"] as? String ?? "")\(ms)"
                    + (text.isEmpty ? ")" : ": \(text))"))
        } else {
            noteLog("[\(entry["level"] as? String ?? "log")] \(text)")
        }
    }

    func noteLog(_ line: String) {
        if let drive { AgentDrive.add(line, to: &drive.logs) }
    }
    func noteRequest(_ line: String) {
        if let drive { AgentDrive.add(line, to: &drive.requests) }
    }

    /// The list as text, emptied after when `clear`.
    func listed(_ console: Bool, clear: Bool) -> String {
        let list = (console ? drive?.logs : drive?.requests) ?? []
        if clear { if console { drive?.logs = [] } else { drive?.requests = [] } }
        return list.isEmpty ? (console ? "No console messages." : "No requests.") : list.joined(separator: "\n")
    }

    static let watchJS = #"""
        (() => { if (window.__kelpWatch) return; window.__kelpWatch = true;
        const post = d => { try { window.webkit.messageHandlers.kelpWatch.postMessage(d); } catch (_) {} };
        // An error as its kind and message (`TypeError: …`), then its stack without nameless frames (a lone "@": a timer's
        // or eval's), none when that's all it had.
        const stack = e => String(e.stack || '').split('\n').filter(l => l.trim() && l.trim() !== '@').join('\n');
        const str = v => { if (typeof v === 'string') return v; if (v instanceof Error) return String(v) + (stack(v) ? '\n' + stack(v) : '');
          try { return JSON.stringify(v) ?? String(v); } catch (_) { return String(v); } };
        const log = (level, text) => post({k: 'console', level, text});
        for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
          const f = console[level]; console[level] = function (...a) { log(level, a.map(str).join(' ')); return f.apply(this, a); };
        }
        addEventListener('error', e => {
          const t = e.target;
          if (t && t !== window && t.localName) log('error', 'Failed to load <' + t.localName + '> ' + (t.currentSrc || t.src || t.href || ''));
          else if (e.error && stack(e.error)) log('error', str(e.error));
          else log('error', (e.error ? str(e.error) : e.message) + (e.filename && e.filename !== 'undefined' ? ' (' + e.filename + ':' + e.lineno + ')' : ''));
        }, true);
        addEventListener('unhandledrejection', e => log('error', 'Unhandled rejection: ' + str(e.reason)));
        const abs = u => { try { return new URL(u, location.href).href; } catch (_) { return String(u); } };
        // Each call says when it starts, so an action waits for the calls it set off (`AgentDrive.busy`).
        const doc = Math.random().toString(36).slice(2); let seq = 0;
        const start = () => { const id = doc + ++seq; post({k: 'start', id}); return id; };
        const net = (type, method, url, t, status, text, id) =>
          post({k: 'net', type, method, url, status, ms: Math.round(performance.now() - t), text: text || '', id});
        const F = window.fetch;
        if (F) window.fetch = function (input, init) {
          const t = performance.now(), url = abs(input && input.url || input), id = start();
          const method = String(init && init.method || input && input.method || 'GET').toUpperCase();
          return F.apply(this, arguments).then(
            r => { net('fetch', method, r.url || url, t, r.status, '', id); return r; },
            e => { net('fetch', method, url, t, 0, str(e), id); throw e; });
        };
        const X = XMLHttpRequest.prototype, open = X.open, send = X.send;
        X.open = function (m, u) { this.__kelp = {method: String(m).toUpperCase(), url: abs(u)}; return open.apply(this, arguments); };
        X.send = function () {
          const r = this.__kelp, t = performance.now(), id = r && start();
          const done = () => net('xhr', r.method, this.responseURL || r.url, t, this.status, '', id);
          if (r) this.addEventListener('loadend', done);
          return send.apply(this, arguments);
        };
        })();
        """#
}

/// What an agent driving a page leaves on its tab (`kelp browser`), made by `BrowserTab.watch()`: a page only the user
/// browses carries none of it.
@MainActor
final class AgentDrive {
    /// Each list keeps its last lines only: `while (true) alert()` stays bounded.
    static let keep = 500
    /// When `kelp browser` last acted here (`BrowserTab.agentAnswers`).
    var drivenAt = Date.distantPast
    /// The user took the agent's page over: its questions go to the user, and the agent's commands are refused.
    var takenOver = false
    /// The page's size the agent set (`kelp browser viewport`): the page sits at the pane's top, in the middle, at that
    /// size; nil fills the pane (`BrowserTab.placeWeb`).
    var viewport: CGSize?
    /// `kelp browser dialog`: how the agent answers the page's next question (BrowserDialogs.swift).
    var dialogAnswer: (accept: Bool, text: String?)?
    /// `kelp browser console | network`.
    var logs: [String] = [], requests: [String] = []
    /// The questions the page answered and what it downloaded, since the last action's answer said them.
    var dialogs: [String] = [], downloads: [String] = []

    /// The page's fetch and XHR calls still out, by id, with when each started.
    var inflight: [String: Date] = [:]
    /// A call started in the last 1.5 s is still out: what an action set off is loading.
    var busy: Bool { inflight.values.contains { Date().timeIntervalSince($0) < 1.5 } }

    func started(_ id: String) {
        inflight = inflight.filter { Date().timeIntervalSince($0.value) < 60 }   // a page that left takes its calls along
        inflight[id] = Date()
    }

    static func add(_ line: String, to list: inout [String]) {
        list.append(line)
        if list.count > keep { list.removeFirst(list.count - keep) }
    }
}
