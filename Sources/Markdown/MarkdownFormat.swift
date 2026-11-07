import Foundation

/// Pure toolbar edits for a Markdown editor. Ranges are UTF-16 (NSTextView); each returns the new text and selection.
public enum MarkdownFormat {
    public typealias Edit = (text: String, selection: NSRange)

    public static func toggleBold(_ t: String, _ r: NSRange) -> Edit { wrap(t, r, "**", "**") }
    public static func toggleItalic(_ t: String, _ r: NSRange) -> Edit { wrap(t, r, "_", "_") }

    /// Inline code, or a fenced block when the selection spans lines.
    public static func toggleCode(_ t: String, _ r: NSRange) -> Edit {
        (t as NSString).substring(with: r).contains("\n") ? wrap(t, r, "```\n", "\n```") : wrap(t, r, "`", "`")
    }

    /// `[sel](url)` with the url placeholder selected; a selected URL becomes the target. A selected link is unwrapped.
    public static func makeLink(_ t: String, _ r: NSRange, url: String = "url") -> Edit {
        let ns = t as NSString, sel = ns.substring(with: r)
        if let m = sel.wholeMatch(of: /\[([^\]]*)\]\([^)]*\)/) {
            let s = String(m.1)
            return (ns.replacingCharacters(in: r, with: s), NSRange(location: r.location, length: s.utf16.count))
        }
        if sel.hasPrefix("http://") || sel.hasPrefix("https://") {
            return (ns.replacingCharacters(in: r, with: "[](\(sel))"), NSRange(location: r.location + 1, length: 0))
        }
        let s = "[\(sel)](\(url))"
        return (
            ns.replacingCharacters(in: r, with: s),
            NSRange(location: r.location + sel.utf16.count + 3, length: url.utf16.count)
        )
    }

    /// Sets `#`×level on the selected lines; same level again (or level 0) removes it.
    public static func heading(_ t: String, _ r: NSRange, level: Int) -> Edit {
        lines(t, r) { ls in
            let ts = targets(ls)
            let off = level <= 0 || ts.allSatisfy { headingParts(ls[$0]).level == level }
            var out = ls
            for i in ts {
                let body = headingParts(ls[i]).body
                out[i] = off ? body : String(repeating: "#", count: min(level, 6)) + " " + body
            }
            return out
        }
    }

    public static func toggleBullet(_ t: String, _ r: NSRange) -> Edit { toggleList(t, r, .bullet) { _ in "- " } }
    public static func toggleNumbered(_ t: String, _ r: NSRange) -> Edit { toggleList(t, r, .numbered) { "\($0). " } }
    public static func toggleTask(_ t: String, _ r: NSRange) -> Edit { toggleList(t, r, .task) { _ in "- [ ] " } }

    /// Inserts an empty table on its own lines and selects the first header cell.
    public static func insertTable(_ t: String, _ r: NSRange, columns: Int = 2, rows: Int = 2) -> Edit {
        let ns = t as NSString
        func row(_ s: String) -> String {
            "| " + Array(repeating: s, count: max(columns, 1)).joined(separator: " | ") + " |"
        }
        let table =
            ([row("Column"), row("------")] + Array(repeating: row("      "), count: max(rows, 0))).joined(
                separator: "\n") + "\n"
        let lead = r.location == 0 || ns.character(at: r.location - 1) == 10 ? "" : "\n"
        return (
            ns.replacingCharacters(in: r, with: lead + table),
            NSRange(location: r.location + lead.utf16.count + 2, length: 6)
        )
    }

    // MARK: -

    private static func wrap(_ t: String, _ r: NSRange, _ open: String, _ close: String) -> Edit {
        let ns = t as NSString, sel = ns.substring(with: r)
        let o = open.utf16.count, c = close.utf16.count
        if sel.utf16.count >= o + c, sel.hasPrefix(open), sel.hasSuffix(close) {
            let inner = (sel as NSString).substring(with: NSRange(location: o, length: sel.utf16.count - o - c))
            return (
                ns.replacingCharacters(in: r, with: inner), NSRange(location: r.location, length: inner.utf16.count)
            )
        }
        if r.location >= o, NSMaxRange(r) + c <= ns.length,
            ns.substring(with: NSRange(location: r.location - o, length: o)) == open,
            ns.substring(with: NSRange(location: NSMaxRange(r), length: c)) == close
        {
            let outer = NSRange(location: r.location - o, length: r.length + o + c)
            return (ns.replacingCharacters(in: outer, with: sel), NSRange(location: r.location - o, length: r.length))
        }
        return (
            ns.replacingCharacters(in: r, with: open + sel + close), NSRange(location: r.location + o, length: r.length)
        )
    }

    private enum Kind { case none, bullet, numbered, task }

    private static func listParts(_ l: String) -> (indent: String, kind: Kind, body: String) {
        guard let m = l.wholeMatch(of: /(\s*)(?:([-*+] \[[ xX]\](?: |$))|([-*+] )|(\d+[.)] ))?(.*)/) else {
            return ("", .none, l)
        }
        let kind: Kind = m.2 != nil ? .task : m.3 != nil ? .bullet : m.4 != nil ? .numbered : .none
        return (String(m.1), kind, String(m.5))
    }

    private static func headingParts(_ l: String) -> (level: Int, body: String) {
        guard let m = l.prefixMatch(of: /(#{1,6})(?: +|$)/) else { return (0, l) }
        return (m.1.count, String(l[m.range.upperBound...]))
    }

    /// Lines to act on: the single line, or every non-blank line of a multi-line selection.
    private static func targets(_ ls: [String]) -> [Int] {
        ls.count == 1 ? [0] : ls.indices.filter { !ls[$0].allSatisfy(\.isWhitespace) }
    }

    private static func toggleList(_ t: String, _ r: NSRange, _ kind: Kind, _ prefix: @escaping (Int) -> String) -> Edit
    {
        lines(t, r) { ls in
            let ts = targets(ls)
            let off = ts.allSatisfy { listParts(ls[$0]).kind == kind }
            var out = ls
            for (n, i) in ts.enumerated() {
                let p = listParts(ls[i])
                if off {
                    out[i] = p.indent + p.body
                } else if p.kind != kind {
                    out[i] = p.indent + prefix(n + 1) + p.body
                }
            }
            return out
        }
    }

    /// Rewrites the full lines touched by `r`. A caret keeps its place; a selection grows to cover the rewritten lines.
    private static func lines(_ t: String, _ r: NSRange, _ f: ([String]) -> [String]) -> Edit {
        let ns = t as NSString
        var probe = r
        if r.length > 0, ns.character(at: NSMaxRange(r) - 1) == 10 { probe.length -= 1 }
        let lr = ns.lineRange(for: probe)
        var block = ns.substring(with: lr)
        let nl = block.hasSuffix("\n")
        if nl { block.removeLast() }
        let old = block.components(separatedBy: "\n"), new = f(old)
        let joined = new.joined(separator: "\n")
        let out = ns.replacingCharacters(in: lr, with: joined + (nl ? "\n" : ""))
        if r.length == 0 {
            let d = new[0].utf16.count - old[0].utf16.count
            return (out, NSRange(location: max(lr.location, r.location + d), length: 0))
        }
        return (out, NSRange(location: lr.location, length: joined.utf16.count))
    }
}
