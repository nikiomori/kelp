import Core
import Foundation

/// A design's canvas as the tab shows it: its rows of boards, each board in a frame of its own (an iframe: its styles
/// and its phone width are its own) holding the board's fragment on a page Kelp makes from the project's design system,
/// once in light and once in dark when the system has a dark theme. The boards' scripts don't run; Kelp's (`script`)
/// size the frames, fit the canvas to the pane and check what's drawn.
enum CanvasPage {
    /// Which themes the boards show in (a view preference of this Mac; none set: the window's own).
    enum Themes: String, CaseIterable { case both, light, dark }
    static let themesKey = "artifacts.canvasThemes"

    /// How it's drawn: in which themes, who is writing it now (their board gets the ring), and whether it's a
    /// dashboard: its boards as the pane's page, one view at a time, without rows, names or sizes (`DashboardPage`).
    struct View: Sendable {
        var themes: Themes
        var writer: String?
        var dashboard = false
    }

    struct Built: Sendable {
        var html: String
        /// What the files themselves say is wrong, before anything is drawn: part of the check.
        var issues: [String]
        /// Each board's tweaks, and the marks not sent yet (`CanvasEdit`).
        var tweaks: [String: [Tweak]] = [:]
        var marks: [CanvasMark] = []
        /// The design system's token names by group: the properties panel's choices (`CanvasEditMode`).
        var tokens: [String: [String]] = [:]
    }

    /// The page for `snapshot` (the canvas and its boards' text), with the design system from `root` and the marks from
    /// `folder`. Reads files: off the main thread.
    static func build(_ snapshot: CanvasSnapshot, folder: URL, root: String, view: View) -> Built {
        let themes = view.themes
        let json = snapshot.canvas
        let system = DesignSystem.dir(root: root)
        let tokensJSON = read(system.appendingPathComponent("tokens.json")) ?? ""
        let tokens = DesignSystem.css(tokens: tokensJSON)
        let kit = read(system.appendingPathComponent("kit.css")) ?? ""
        let hasSystem = !kit.isEmpty || !tokens.light.isEmpty
        var issues: [String] = [], tweaks: [String: [Tweak]] = [:]
        guard let canvas = ArtifactCanvas.read(json) else {
            let why = problem(json)
            let page = CanvasStates.unreadable(
                why, file: Artifacts.projectPath(folder.appendingPathComponent("canvas.json").path), agent: view.writer)
            return Built(html: shell(body: page), issues: ["canvas.json: " + why])
        }
        // The board its agent saved last is the one being written, while it writes.
        let newest =
            view.writer == nil
            ? nil
            : canvas.boards.max {
                let a = Artifacts.fileStat(folder.appendingPathComponent($0.file).path)?.mtime.tv_sec ?? 0
                let b = Artifacts.fileStat(folder.appendingPathComponent($1.file).path)?.mtime.tv_sec ?? 0
                return a < b
            }?.file
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
                guard let source = snapshot.boards[board.file] else {
                    if view.writer == nil { issues.append("\(board.file): no such file") }
                    frames += CanvasStates.unwritten(
                        board.title ?? (board.file as NSString).lastPathComponent, file: board.file,
                        w: min(max(board.w ?? 1280, 40), 8000), h: board.h, writing: view.writer != nil)
                    continue
                }
                issues += lint(source, board: board.file, hasSystem: hasSystem)
                tweaks[board.file] = Tweak.all(in: source)
                for theme in shown {
                    let vars =
                        (theme == "dark" ? tokens.dark : tokens.light) + " " + Tweak.css(tweaks[board.file] ?? [])
                    let doc = boardPage(source, theme: theme, vars: vars, kit: kit, base: folder)
                    frames += frame(
                        board, theme: theme, doc: doc, dark: shown.count > 1 && theme == "dark",
                        writing: board.file == newest && theme == shown.first)
                }
            }
            let title = row.title.map { "<h2>\(escape($0))</h2>" } ?? ""
            rows += "<section class=\"row\">\(title)<div class=\"boards\">\(frames)</div></section>"
        }
        let body = canvas.boards.isEmpty ? CanvasStates.empty(writer: view.writer) : rows
        let marks = CanvasMark.read(Artifacts.small(folder.appendingPathComponent(CanvasMark.file).path))
        return Built(
            html: shell(body: "<div id=\"kelp-canvas\">\(body)</div>", dashboard: view.dashboard), issues: issues,
            tweaks: tweaks,
            marks: marks, tokens: DesignSystem.names(tokens: tokensJSON))
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

    private static let ring = "<span class=\"kelp-ring\"></span>"

    private static func frame(
        _ board: ArtifactCanvas.Board, theme: String, doc: String, dark: Bool, writing: Bool
    ) -> String {
        let w = min(max(board.w ?? 1280, 40), 8000), h = board.h.map { min(max($0, 40), 8000) }
        let size = h.map { "\(w) × \($0)" } ?? "\(w)"
        let name = (board.title ?? (board.file as NSString).lastPathComponent) + " · " + size + (dark ? " · dark" : "")
        let height = h.map { " data-h=\"\($0)\"" } ?? ""
        return """
            <div class="frame"><div class="name">\(writing ? ring : "")\(escape(name))</div>\
            <iframe sandbox="allow-same-origin" \
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
        let bare = source.matches(of: /<[^>]*\bdata-value\b[^>]*>/).filter { !$0.output.contains("data-source") }.count
        if bare > 0 { out.append("\(board): \(bare) figures without data-source (where each came from, and when)") }
        if hasSystem {
            let plain = source.replacing(/<!--\s*tweak[^>]*-->/, with: "")
            let typed = plain.matches(of: /#[0-9a-fA-F]{3,8}\b|rgba?\(/).count
            if typed > 0 { out.append("\(board): \(typed) colours typed in; use the tokens (var(--name))") }
        }
        return out
    }

    /// Why canvas.json doesn't read: where its JSON breaks, or that it isn't a list of boards.
    static func problem(_ json: String) -> String {
        do { _ = try JSONSerialization.jsonObject(with: Data(json.utf8)) } catch {
            return ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
        }
        return String(localized: "It isn't {\"boards\": [{\"file\", \"row\", \"title\", \"w\", \"h\"}]}.")
    }

    private static func shell(body: String, dashboard: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 32px 40px 80px; background: var(--k-ground); color: var(--k-label);
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
        \(CanvasChrome.style)
        \(CanvasStates.style)
        \(CanvasEdit.style)
        \(CanvasEditMode.style)
        \(dashboard ? DashboardPage.style : "")
        </style></head><body\(dashboard ? " class=\"kelp-dash\"" : "")>\(body)</body></html>
        """
    }

    private static func read(_ url: URL) -> String? {
        Artifacts.small(url.path, limit: 4 << 20).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Text for an attribute or an element: `&`, `<`, `>` and `"` escaped.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
