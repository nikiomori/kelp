import Core
import Foundation

/// A design's canvas as the tab shows it: its rows of boards, each board in a frame of its own (an iframe: its styles
/// and its phone width are its own) holding the board's fragment on a page Kelp makes from the project's design system,
/// once in light and once in dark when the system has a dark theme. The boards' scripts don't run; Kelp's (`script`)
/// size the frames, fit the canvas to the pane and check what's drawn.
enum CanvasPage {
    /// Which themes the boards show in (a view preference of this Mac).
    enum Themes: String, CaseIterable { case both, light, dark }
    static let themesKey = "artifacts.canvasThemes"

    struct Built: Sendable {
        var html: String
        /// What the files themselves say is wrong, before anything is drawn: part of the check.
        var issues: [String]
    }

    /// The page for the canvas in `json`, its boards read from `folder` and the design system from `root`. `ground`:
    /// the pane's background and text colours. Reads files: off the main thread.
    static func build(
        _ json: String, folder: URL, root: String, themes: Themes, ground: (background: String, text: String)?
    ) -> Built {
        let system = DesignSystem.dir(root: root)
        let tokens = DesignSystem.css(tokens: read(system.appendingPathComponent("tokens.json")) ?? "")
        let kit = read(system.appendingPathComponent("kit.css")) ?? ""
        let hasSystem = !kit.isEmpty || !tokens.light.isEmpty
        var issues: [String] = []
        guard let canvas = ArtifactCanvas.read(json) else {
            let why = "canvas.json doesn't read as {\"boards\": [{\"file\", \"row\", \"title\", \"w\", \"h\"}]}"
            return Built(html: shell(ground, body: note(why)), issues: [why])
        }
        let shown: [String] =
            switch themes {
            case .light: ["light"]
            case .dark: ["dark"]
            case .both: tokens.dark == tokens.light ? ["light"] : ["light", "dark"]
            }
        var rows = ""
        for row in canvas.rows {
            var frames = ""
            for board in row.boards {
                guard let source = read(folder.appendingPathComponent(board.file)) else {
                    issues.append("\(board.file): no such file")
                    frames +=
                        "<div class=\"frame\"><div class=\"name\">\(escape(board.file))</div>"
                        + note("\(board.file) is missing") + "</div>"
                    continue
                }
                issues += lint(source, board: board.file, hasSystem: hasSystem)
                let tweaks = Tweak.css(Tweak.all(in: source))
                for theme in shown {
                    let vars = (theme == "dark" ? tokens.dark : tokens.light) + " " + tweaks
                    let doc = boardPage(source, theme: theme, vars: vars, kit: kit, base: folder)
                    frames += frame(board, theme: theme, doc: doc, dark: shown.count > 1 && theme == "dark")
                }
            }
            let title = row.title.map { "<h2>\(escape($0))</h2>" } ?? ""
            rows += "<section class=\"row\">\(title)<div class=\"boards\">\(frames)</div></section>"
        }
        let empty = String(localized: "No boards yet: the agent writes them into boards/ and lists them here.")
        let body = canvas.boards.isEmpty ? note(empty) : rows
        return Built(html: shell(ground, body: "<div id=\"kelp-canvas\">\(body)</div>"), issues: issues)
    }

    /// A board's own page: `vars` (the system's tokens for its theme, then its tweaks), the kit, then the fragment.
    static func boardPage(_ fragment: String, theme: String, vars: String, kit: String, base: URL) -> String {
        """
        <!doctype html><html data-theme="\(theme)"><head><meta charset="utf-8"><base href="\(base.absoluteString)/">
        <style>:root { color-scheme: \(theme); \(vars) }
        html, body { margin: 0; }
        body { background: var(--bg, Canvas); color: var(--text, CanvasText);
          font: var(--size-body, 15px)/1.5 var(--font-body, -apple-system, BlinkMacSystemFont, sans-serif); }
        </style><style>\(kit)</style></head><body>\(fragment)</body></html>
        """
    }

    private static func frame(_ board: ArtifactCanvas.Board, theme: String, doc: String, dark: Bool) -> String {
        let w = min(max(board.w ?? 1280, 40), 8000), h = board.h.map { min(max($0, 40), 8000) }
        let size = h.map { "\(w) × \($0)" } ?? "\(w)"
        let name = (board.title ?? (board.file as NSString).lastPathComponent) + " · " + size + (dark ? " · dark" : "")
        let height = h.map { " data-h=\"\($0)\"" } ?? ""
        return """
            <div class="frame"><div class="name">\(escape(name))</div><iframe sandbox="allow-same-origin" \
            data-board="\(escape(board.file))" data-theme="\(theme)" data-w="\(w)"\(height) \
            style="width: \(w)px; height: \(h ?? 600)px" srcdoc="\(escape(doc))"></iframe></div>
            """
    }

    /// What's wrong in a board's source, without drawing it.
    static func lint(_ source: String, board: String, hasSystem: Bool) -> [String] {
        var out: [String] = []
        if source.range(of: "<script", options: .caseInsensitive) != nil {
            out.append("\(board): scripts don't run in Kelp; draw every state as markup")
        }
        if source.range(of: #"<(html|head|body)[\s>]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            out.append("\(board): a board is a fragment; drop <html>, <head> and <body>")
        }
        if hasSystem {
            let plain = source.replacing(/<!--\s*tweak[^>]*-->/, with: "")
            let typed = plain.matches(of: /#[0-9a-fA-F]{3,8}\b|rgba?\(/).count
            if typed > 0 { out.append("\(board): \(typed) colours typed in; use the tokens (var(--name))") }
        }
        return out
    }

    private static func shell(_ ground: (background: String, text: String)?, body: String) -> String {
        let bg = ground?.background ?? "#ececec", fg = ground?.text ?? "#1d1d1f"
        return """
            <!doctype html><html><head><meta charset="utf-8"><style>
            :root { color-scheme: light dark; }
            body { margin: 0; padding: 32px 40px 80px; background: \(bg); color: \(fg);
              font: 12px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; }
            #kelp-canvas { display: flex; width: max-content; flex-direction: column; gap: 48px;
              transform-origin: 0 0; }
            .row h2 { font-size: calc(13px / var(--z, 1)); font-weight: 600; margin: 0 0 18px; }
            .boards { display: flex; gap: 48px; align-items: flex-start; }
            .frame { display: flex; flex-direction: column; gap: 6px; flex: none; }
            .name { opacity: 0.6; font-size: calc(11px / var(--z, 1)); white-space: nowrap; }
            iframe { border: 0; display: block; border-radius: 4px; background: #fff;
              box-shadow: 0 0 0 0.5px rgba(0,0,0,.15), 0 1px 4px rgba(0,0,0,.18); }
            iframe[data-theme="dark"] { background: #1c1c1e; }
            .note { padding: 24px; opacity: 0.6; font-size: 13px; }
            </style></head><body>\(body)</body></html>
            """
    }

    private static func note(_ text: String) -> String { "<div class=\"note\">\(escape(text))</div>" }

    private static func read(_ url: URL) -> String? {
        Artifacts.small(url.path, limit: 4 << 20).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Text for an attribute or an element: `&`, `<`, `>` and `"` escaped.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
