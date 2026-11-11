import Foundation

/// A canvas with nothing to draw yet, or nothing it can read, as Kelp's empty state (`EmptyStateView`'s anatomy in the
/// page): a light symbol, a title, a line on why and what fills it, and its one action; and a board listed but not
/// written yet as a dashed frame of its size.
enum CanvasStates {
    /// No boards in canvas.json yet. `writer`: the agent writing it now, if one is.
    static func empty(writer: String?) -> String {
        let line =
            writer.map {
                String(localized: "\($0) is writing the first one into boards/. Each board shows as it's saved.")
            }
            ?? String(localized: "Ask the agent for boards: each goes in boards/, and canvas.json lists it.")
        return block(symbol: grid, title: String(localized: "No Boards Yet"), line: line, detail: nil, actions: "")
    }

    /// canvas.json doesn't read: why, where, and the two ways to fix it (by hand, or by its agent).
    static func unreadable(_ why: String, file: String, agent: String?) -> String {
        let ask = String(localized: "Ask \(agent ?? String(localized: "the Agent")) to Fix")
        let open = String(localized: "Open File"), quoted = CanvasPage.escape(why)
        let actions = """
            <span class="kelp-actions"><button class="kelp-pill" data-kelp="source">\(open)</button>\
            <button class="kelp-prominent" data-kelp="fixCanvas" data-why="\(quoted)">\(ask)</button></span>
            """
        return block(
            symbol: warning, title: String(localized: "Canvas.json Doesn't Read"), line: why, detail: file,
            actions: actions)
    }

    /// A board canvas.json names but whose file isn't there yet, at its size.
    static func unwritten(_ name: String, file: String, w: Int, h: Int?, writing: Bool) -> String {
        let label = writing ? "<span class=\"kelp-ring\"></span>" : ""
        return """
            <div class="frame"><div class="name">\(label)\(CanvasPage.escape(name))</div>\
            <div class="kelp-skel" style="width: \(w)px; height: \(h ?? 360)px">\
            <span>\(CanvasPage.escape(file))</span><span>\(String(localized: "Not written yet"))</span></div></div>
            """
    }

    private static func block(symbol: String, title: String, line: String, detail: String?, actions: String) -> String {
        let code = detail.map { "<span class=\"kelp-code\">\(CanvasPage.escape($0))</span>" } ?? ""
        return """
            <div class="kelp-empty">\(symbol)<b>\(CanvasPage.escape(title))</b><p>\(CanvasPage.escape(line))</p>\
            \(code)\(actions)</div>
            """
    }

    private static func symbol(_ path: String) -> String {
        """
        <svg aria-hidden="true" width="40" height="40" viewBox="0 0 16 16" fill="none" stroke="currentColor" \
        stroke-width="0.9" stroke-linecap="round" stroke-linejoin="round">\(path)</svg>
        """
    }
    private static let grid = symbol(
        """
        <rect x="2" y="2" width="5" height="5" rx="1"/><rect x="9" y="2" width="5" height="5" rx="1"/>\
        <rect x="2" y="9" width="5" height="5" rx="1"/><rect x="9" y="9" width="5" height="5" rx="1"/>
        """)
    private static let warning = symbol(
        #"<path d="M8 2.5l6 11H2z"/><path d="M8 7v3"/><circle cx="8" cy="11.8" r=".3" fill="currentColor"/>"#)

    static let style = """
        .kelp-empty { position: fixed; left: 0; right: 0; top: calc(50% - 140px); display: flex; flex-direction: column;
          align-items: center; gap: 10px; text-align: center; padding: 0 16px; }
        .kelp-with-col .kelp-empty { right: 260px; }
        .kelp-empty svg { color: var(--k-sec); opacity: .55; }
        .kelp-empty b { font-size: 13px; font-weight: 600; }
        .kelp-empty p { margin: 0; font-size: 13px; color: var(--k-sec); max-width: 380px; }
        .kelp-code { font: 11px ui-monospace, "SF Mono", Menlo, monospace; color: var(--k-sec); }
        .kelp-actions { display: flex; gap: 8px; margin-top: 4px; }
        .kelp-skel { box-sizing: border-box; border: 1.5px dashed var(--k-sep); border-radius: 4px; display: flex;
          flex-direction: column; gap: 4px; align-items: center; justify-content: center; color: var(--k-sec);
          font-size: calc(11px / var(--z, 1)); }
        .kelp-ring { display: inline-block; width: calc(9px / var(--z, 1)); height: calc(9px / var(--z, 1));
          margin-right: calc(6px / var(--z, 1)); vertical-align: -1px; box-sizing: border-box;
          border-radius: 50%; border: 1.5px solid var(--k-sep); border-top-color: var(--k-sec);
          animation: kelp-spin 1s linear infinite; }
        @keyframes kelp-spin { to { transform: rotate(360deg); } }
        @media (prefers-reduced-motion: reduce) { .kelp-ring { animation: none; } }
        """
}
