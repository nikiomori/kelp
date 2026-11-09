import Foundation

/// Jupyter notebooks (.ipynb, nbformat 4) as HTML: Markdown cells, code cells with their outputs
/// (text, HTML-escaped; PNG/JPEG/SVG images; error tracebacks without ANSI colors).
public enum NotebookHTML {
    public struct Summary: Equatable, Sendable {
        public var cells: Int
        public var language: String
    }

    public static func summary(_ data: Data) -> Summary? {
        guard let nb = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cells = nb["cells"] as? [Any]
        else { return nil }
        return Summary(cells: cells.count, language: language(nb))
    }

    public static func render(_ data: Data) -> String? {
        guard let nb = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cells = nb["cells"] as? [[String: Any]]
        else { return nil }
        let lang = MarkdownHTML.esc(language(nb).filter { $0.isLetter || $0.isNumber || "+#._-".contains($0) })   // a class name
        var html = ""
        for cell in cells {
            let src = text(cell["source"])
            switch cell["cell_type"] as? String {
            case "markdown":
                html += "<div class=\"nb-md\">\(MarkdownHTML.render(src))</div>\n"
            case "code":
                let count = (cell["execution_count"] as? Int).map(String.init) ?? " "
                html += "<div class=\"nb-cell\"><div class=\"nb-in\">In [\(count)]:</div>"
                html += "<pre><code class=\"language-\(lang)\">\(MarkdownHTML.esc(src))</code></pre>"
                for out in cell["outputs"] as? [[String: Any]] ?? [] { html += output(out) }
                html += "</div>\n"
            default:
                html += "<pre>\(MarkdownHTML.esc(src))</pre>\n"
            }
        }
        return html + style
    }

    static func output(_ out: [String: Any]) -> String {
        switch out["output_type"] as? String {
        case "stream":
            return
                "<pre class=\"nb-out\(out["name"] as? String == "stderr" ? " nb-err" : "")\">\(MarkdownHTML.esc(text(out["text"])))</pre>"
        case "error":
            let tb = (out["traceback"] as? [String] ?? []).joined(separator: "\n")
            return
                "<pre class=\"nb-out nb-err\">\(MarkdownHTML.esc(stripANSI(tb.isEmpty ? "\(out["ename"] ?? ""): \(out["evalue"] ?? "")" : tb)))</pre>"
        case "execute_result", "display_data":
            let data = out["data"] as? [String: Any] ?? [:]
            for (mime, tag) in [("image/png", "png"), ("image/jpeg", "jpeg")] {
                // Decoded and encoded again: only base64 reaches the attribute, whatever the file holds.
                if let encoded = data[mime] {
                    return
                        "<img class=\"nb-img\" src=\"data:image/\(tag);base64,\(Data(base64Encoded: text(encoded), options: .ignoreUnknownCharacters)?.base64EncodedString() ?? "")\">"
                }
            }
            if let svg = data["image/svg+xml"] {   // inline SVG would run scripts; show it as an image instead
                let b64 = Data(text(svg).utf8).base64EncodedString()
                return "<img class=\"nb-img\" src=\"data:image/svg+xml;base64,\(b64)\">"
            }
            if let md = data["text/markdown"] { return "<div class=\"nb-md\">\(MarkdownHTML.render(text(md)))</div>" }
            if let tex = data["text/latex"] {   // `$…$`, as SymPy writes it
                return "<div class=\"nb-md\">\(MarkdownHTML.render(text(tex)))</div>"
            }
            if let plain = data["text/plain"] { return "<pre class=\"nb-out\">\(MarkdownHTML.esc(text(plain)))</pre>" }
            return ""
        default: return ""
        }
    }

    static func language(_ nb: [String: Any]) -> String {
        let meta = nb["metadata"] as? [String: Any]
        return ((meta?["language_info"] as? [String: Any])?["name"] as? String)
            ?? ((meta?["kernelspec"] as? [String: Any])?["language"] as? String) ?? "python"
    }

    /// nbformat stores text either as a string or as a list of lines.
    static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let lines = value as? [String] { return lines.joined() }
        return ""
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    static let style = """
        <style>
        .nb-cell { margin: 18px 0; } .nb-in { font: 11px ui-monospace, SFMono-Regular, monospace; color: #888; margin-bottom: 4px; }
        .nb-out { background: transparent; border-left: 3px solid rgba(127,127,127,.35); padding: 6px 10px; margin: 6px 0 0; white-space: pre-wrap; }
        .nb-err { border-left-color: #e5484d; color: #e5484d; } .nb-img { max-width: 100%; margin-top: 8px; }
        </style>
        """
}
