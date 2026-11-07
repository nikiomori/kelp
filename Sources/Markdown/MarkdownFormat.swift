import Foundation

/// Pure toolbar edits for a Markdown editor. Ranges are UTF-16 (NSTextView); each returns the new text and selection.
public enum MarkdownFormat {
    public typealias Edit = (text: String, selection: NSRange)

    public static func toggleBold(_ text: String, _ range: NSRange) -> Edit { wrap(text, range, "**", "**") }
    public static func toggleItalic(_ text: String, _ range: NSRange) -> Edit { wrap(text, range, "_", "_") }

    /// Inline code, or a fenced block when the selection spans lines.
    public static func toggleCode(_ text: String, _ range: NSRange) -> Edit {
        (text as NSString).substring(with: range).contains("\n")
            ? wrap(text, range, "```\n", "\n```") : wrap(text, range, "`", "`")
    }

    /// `[sel](url)` with the url placeholder selected; a selected URL becomes the target. A selected link is unwrapped.
    public static func makeLink(_ text: String, _ range: NSRange, url: String = "url") -> Edit {
        let ns = text as NSString, sel = ns.substring(with: range)
        if let match = sel.wholeMatch(of: /\[([^\]]*)\]\([^)]*\)/) {
            let label = String(match.1)
            return (
                ns.replacingCharacters(in: range, with: label),
                NSRange(location: range.location, length: label.utf16.count)
            )
        }
        if sel.hasPrefix("http://") || sel.hasPrefix("https://") {
            return (
                ns.replacingCharacters(in: range, with: "[](\(sel))"), NSRange(location: range.location + 1, length: 0)
            )
        }
        let link = "[\(sel)](\(url))"
        return (
            ns.replacingCharacters(in: range, with: link),
            NSRange(location: range.location + sel.utf16.count + 3, length: url.utf16.count)
        )
    }

    /// Sets `#`×level on the selected lines; same level again (or level 0) removes it.
    public static func heading(_ text: String, _ range: NSRange, level: Int) -> Edit {
        lines(text, range) { ls in
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

    public static func toggleBullet(_ text: String, _ range: NSRange) -> Edit {
        toggleList(text, range, .bullet) { _ in "- " }
    }
    public static func toggleNumbered(_ text: String, _ range: NSRange) -> Edit {
        toggleList(text, range, .numbered) { "\($0). " }
    }
    public static func toggleTask(_ text: String, _ range: NSRange) -> Edit {
        toggleList(text, range, .task) { _ in "- [ ] " }
    }

    /// Inserts an empty table on its own lines and selects the first header cell.
    public static func insertTable(_ text: String, _ range: NSRange, columns: Int = 2, rows: Int = 2) -> Edit {
        let ns = text as NSString
        func row(_ cell: String) -> String {
            "| " + Array(repeating: cell, count: max(columns, 1)).joined(separator: " | ") + " |"
        }
        let table =
            ([row("Column"), row("------")] + Array(repeating: row("      "), count: max(rows, 0))).joined(
                separator: "\n") + "\n"
        let lead = range.location == 0 || ns.character(at: range.location - 1) == 10 ? "" : "\n"
        return (
            ns.replacingCharacters(in: range, with: lead + table),
            NSRange(location: range.location + lead.utf16.count + 2, length: 6)
        )
    }

    // MARK: -

    private static func wrap(_ text: String, _ range: NSRange, _ open: String, _ close: String) -> Edit {
        let ns = text as NSString, sel = ns.substring(with: range)
        let openLength = open.utf16.count, closeLength = close.utf16.count
        if sel.utf16.count >= openLength + closeLength, sel.hasPrefix(open), sel.hasSuffix(close) {
            let inner = (sel as NSString).substring(
                with: NSRange(location: openLength, length: sel.utf16.count - openLength - closeLength))
            return (
                ns.replacingCharacters(in: range, with: inner),
                NSRange(location: range.location, length: inner.utf16.count)
            )
        }
        if range.location >= openLength, NSMaxRange(range) + closeLength <= ns.length,
            ns.substring(with: NSRange(location: range.location - openLength, length: openLength)) == open,
            ns.substring(with: NSRange(location: NSMaxRange(range), length: closeLength)) == close
        {
            let outer = NSRange(
                location: range.location - openLength, length: range.length + openLength + closeLength)
            return (
                ns.replacingCharacters(in: outer, with: sel),
                NSRange(location: range.location - openLength, length: range.length)
            )
        }
        return (
            ns.replacingCharacters(in: range, with: open + sel + close),
            NSRange(location: range.location + openLength, length: range.length)
        )
    }

    private enum Kind { case none, bullet, numbered, task }

    private static func listParts(_ line: String) -> (indent: String, kind: Kind, body: String) {
        guard let match = line.wholeMatch(of: /(\s*)(?:([-*+] \[[ xX]\](?: |$))|([-*+] )|(\d+[.)] ))?(.*)/) else {
            return ("", .none, line)
        }
        let kind: Kind = match.2 != nil ? .task : match.3 != nil ? .bullet : match.4 != nil ? .numbered : .none
        return (String(match.1), kind, String(match.5))
    }

    private static func headingParts(_ line: String) -> (level: Int, body: String) {
        guard let match = line.prefixMatch(of: /(#{1,6})(?: +|$)/) else { return (0, line) }
        return (match.1.count, String(line[match.range.upperBound...]))
    }

    /// Lines to act on: the single line, or every non-blank line of a multi-line selection.
    private static func targets(_ ls: [String]) -> [Int] {
        ls.count == 1 ? [0] : ls.indices.filter { !ls[$0].allSatisfy(\.isWhitespace) }
    }

    private static func toggleList(
        _ text: String, _ range: NSRange, _ kind: Kind, _ prefix: @escaping (Int) -> String
    ) -> Edit {
        lines(text, range) { ls in
            let ts = targets(ls)
            let off = ts.allSatisfy { listParts(ls[$0]).kind == kind }
            var out = ls
            for (n, i) in ts.enumerated() {
                let parts = listParts(ls[i])
                if off {
                    out[i] = parts.indent + parts.body
                } else if parts.kind != kind {
                    out[i] = parts.indent + prefix(n + 1) + parts.body
                }
            }
            return out
        }
    }

    /// Rewrites the full lines touched by `range`. A caret keeps its place; a selection grows to cover the rewritten
    /// lines.
    private static func lines(_ text: String, _ range: NSRange, _ rewrite: ([String]) -> [String]) -> Edit {
        let ns = text as NSString
        var probe = range
        if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 10 { probe.length -= 1 }
        let lr = ns.lineRange(for: probe)
        var block = ns.substring(with: lr)
        let nl = block.hasSuffix("\n")
        if nl { block.removeLast() }
        let old = block.components(separatedBy: "\n"), new = rewrite(old)
        let joined = new.joined(separator: "\n")
        let out = ns.replacingCharacters(in: lr, with: joined + (nl ? "\n" : ""))
        if range.length == 0 {
            let shift = new[0].utf16.count - old[0].utf16.count
            return (out, NSRange(location: max(lr.location, range.location + shift), length: 0))
        }
        return (out, NSRange(location: lr.location, length: joined.utf16.count))
    }
}
