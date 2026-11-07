import Foundation

/// `window.kelp` in an extension's web page: the script Kelp puts in it, and the TypeScript that says what it has
/// (`kelp ext types > kelp.d.ts`). Both come from here, so the types can't fall behind the bridge (a test reads them side
/// by side).
public enum ExtBridge {
    /// The bridge, with what the page's `ext:` link carried as `kelp.props`.
    public static func script(props: [String: String]) -> String {
        var p = "{}"
        do { p = String(decoding: try JSONEncoder().encode(props), as: UTF8.self) } catch {}   // strings always encode
        return """
            (() => {
              let n = 0; const pending = {}; const listeners = {settings: [], workspace: [], sessions: []};
              const call = (op, arg, extra) => new Promise(res => { const id = ++n; pending[id] = res;
                window.webkit.messageHandlers.kelp.postMessage(Object.assign({op, arg, id}, extra || {})); });
              window.kelp = {
                workspace: {}, sessions: [], props: \(p),
                exec: c => Array.isArray(c) ? call('exec', '', {argv: JSON.stringify(c)}) : call('exec', c),
                terminal: (c, o) => call('terminal', c, {title: o && o.title}),
                open: u => call('open', u), agent: p => call('agent', p), badge: v => call('badge', v == null ? '' : String(v)),
                run: (id, args) => call('run', id, {args: JSON.stringify(args || {})}), notify: t => call('notify', String(t)),
                settings: { get: k => call('settings.get', k), set: (k, v) => call('settings.set', k, {value: JSON.stringify(v)}) },
                on: (ev, cb) => (listeners[ev] = listeners[ev] || []).push(cb),
                __resolve: (id, v) => { const r = pending[id]; delete pending[id]; r && r(v); },
                __update: (ws, settings) => {
                    window.kelp.workspace = ws; listeners.workspace.forEach(f => f(ws));
                    listeners.settings.forEach(f => f(settings));
                },
                __sessions: list => { window.kelp.sessions = list; listeners.sessions.forEach(f => f(list)); }
              };
              document.addEventListener('DOMContentLoaded', () => window.webkit.messageHandlers.kelp.postMessage({op: 'ready', id: 0}));
            })();
            """
    }

    /// What the bridge has, for an extension's editor: `kelp ext types > kelp.d.ts`.
    public static let declarations = """
        // window.kelp in a Kelp extension's web page. From `kelp ext types`; docs/extensions.md says more.
        interface KelpWorkspace { name: string; path: string; branch: string; project: string }
        interface KelpSession { id: string; title: string; agent: string; status: string; workspace: string; unread: boolean }
        interface KelpExec { code: number; stdout: string; stderr: string }
        interface Kelp {
          /** The workspace on screen; follows it. */
          workspace: KelpWorkspace;
          /** The agents, as the sidebar has them; follows them. */
          sessions: KelpSession[];
          /** What the ext: link that opened this page carried: ext:my.ext/view?file=a.txt gives {file: "a.txt"}. */
          props: Record<string, string>;
          /** A shell command line, or one program and its words passed as they are; runs in the workspace's folder. */
          exec(command: string | string[]): Promise<KelpExec>;
          /** A terminal tab running the command. */
          terminal(command: string, options?: { title?: string }): Promise<null>;
          /** A URL in a browser tab, a path in a file tab. */
          open(uriOrPath: string): Promise<null>;
          /** A new agent with the prompt typed, for the user to send. */
          agent(prompt: string): Promise<null>;
          /** A Kelp command by its id, as `kelp run` does. */
          run(command: string, args?: Record<string, unknown>): Promise<null>;
          /** A banner in the window. */
          notify(text: string): Promise<null>;
          /** The panel icon's badge; null takes it away. */
          badge(value: string | number | null): Promise<null>;
          settings: { get(key: string): Promise<unknown>; set(key: string, value: unknown): Promise<null> };
          on(event: "settings", cb: (settings: Record<string, unknown>) => void): void;
          on(event: "workspace", cb: (workspace: KelpWorkspace) => void): void;
          on(event: "sessions", cb: (sessions: KelpSession[]) => void): void;
        }
        declare const kelp: Kelp;
        """

    /// `json` from a page as a `T`; nil for what doesn't parse (a page's own mistake, nothing to report).
    public static func decode<T: Decodable>(_ json: Any?, as: T.Type) -> T? {
        guard let s = json as? String, let d = s.data(using: .utf8) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: d) } catch { return nil }
    }

    /// `v` as JSON for a page's script; "null" in the one case it can't be (it always can).
    public static func json(_ v: JSONValue) -> String {
        do { return String(decoding: try JSONEncoder().encode(v), as: UTF8.self) } catch { return "null" }
    }

    /// `ext:<extension>/<view>?a=1&b=2` → ("<extension>/<view>", ["a": "1", "b": "2"]).
    public static func split(_ body: String) -> (view: String, props: [String: String]) {
        guard let q = body.firstIndex(of: "?") else { return (body, [:]) }
        let items = URLComponents(string: "x:?" + body[body.index(after: q)...])?.queryItems ?? []
        return (String(body[..<q]), Dictionary(items.compactMap { i in i.value.map { (i.name, $0) } }) { _, b in b })
    }
}
