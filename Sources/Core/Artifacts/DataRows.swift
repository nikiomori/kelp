import Foundation

/// One page, many copies (Canva's Bulk Create, Remotion's dataset render): an element takes a column of a CSV file
/// beside the page, `data-field="clients.csv:name"` (its text, or a picture's `src`), and the page is shown and
/// exported once a row.
public enum DataRows {
    /// The rows of a CSV file (RFC 4180: quotes, doubled quotes, line breaks inside quotes), the first being the names;
    /// its cells split by commas, or by semicolons when its first line has those and no commas (as a European
    /// spreadsheet writes it).
    public static func parse(_ text: String) -> [[String]] {
        // "\r\n" is one Character in Swift, so lines are made plain first; Excel's CSV UTF-8 starts with a BOM.
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let split = separator(text)
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" {
                        cell.append("\"")
                        chars = chars.dropFirst()
                    } else {
                        quoted = false
                    }
                } else {
                    cell.append(c)
                }
                continue
            }
            switch c {
            case "\"": quoted = true
            case split:
                row.append(cell)
                cell = ""
            case "\n":
                row.append(cell)
                rows.append(row)
                (row, cell) = ([], "")
            default: cell.append(c)
            }
        }
        if !cell.isEmpty || !row.isEmpty { rows.append(row + [cell]) }
        return rows.filter { !$0.allSatisfy(\.isEmpty) }
    }

    /// What a CSV's cells are split by: commas, or semicolons when its first line has those and no commas.
    public static func separator(_ text: String) -> Character {
        let head = text.prefix { $0 != "\n" && $0 != "\r" }
        return head.contains(",") || !head.contains(";") ? "," : ";"
    }

    /// `rows` as CSV split by `separator`, a cell quoted when it holds one, a quote or a line break.
    public static func write(_ rows: [[String]], separator: Character = ",") -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(where: { $0 == separator || $0 == "\"" || $0.isNewline })
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: String(separator))
        }.joined(separator: "\n") + "\n"
    }

    /// The CSV files the page's elements take columns of, in the order they first appear.
    public static func files(in html: String) -> [String] {
        var seen: [String] = []
        for m in html.matches(of: /\sdata-field="([^":]+):[^"]*"/) where !seen.contains(String(m.output.1)) {
            seen.append(String(m.output.1))
        }
        return seen
    }

    /// `html` with row `row` (1 is the first after the names) of `tables` in each element that takes a column: its
    /// text, or a picture's `src`, as the page shows it live (`kelpRow`). A row past the end is the last.
    public static func fill(_ html: String, row: Int, tables: [String: [[String]]]) -> String {
        var out = html, from = 0
        while let m = out[out.index(out.startIndex, offsetBy: from)...].firstMatch(
            of: /<([a-zA-Z][\w-]*)\b[^>]*?\sdata-field="([^":]+):([^"]*)"[^>]*>/)
        {
            let tag = m.range, at = out.distance(from: out.startIndex, to: tag.lowerBound)
            from = out.distance(from: out.startIndex, to: tag.upperBound)
            guard let table = tables[String(m.output.2)], table.count > 1,
                let i = table[0].firstIndex(of: String(m.output.3))
            else { continue }
            let cells = table[min(max(row, 1), table.count - 1)], value = i < cells.count ? cells[i] : ""
            if m.output.1.lowercased() == "img" {
                let src = #" src=""# + BoardEdit.escape(value).replacingOccurrences(of: "\"", with: "&quot;") + "\""
                var opening = String(out[tag]).replacing(/\ssrc="[^"]*"/, with: "")
                opening.insert(contentsOf: src, at: opening.index(opening.startIndex, offsetBy: m.output.1.count + 1))
                out.replaceSubrange(tag, with: opening)
                from = at + opening.count
            } else if let whole = BoardEdit.elementRange(out, tag: tag),
                let close = out[..<whole.upperBound].range(of: "</", options: .backwards),
                close.lowerBound >= tag.upperBound
            {
                let text = BoardEdit.escape(value)
                out.replaceSubrange(tag.upperBound..<close.lowerBound, with: text)
                from += text.count
            }
        }
        return out
    }

    /// A file name made of a row's first cell, without what a folder can't hold (`a/b` is `ab`); `row-7` without one.
    public static func name(_ row: [String], index: Int) -> String {
        let cleaned = (row.first ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|"))
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "row-\(index)" : String(cleaned.prefix(80))
    }
}
