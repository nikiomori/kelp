import Foundation

/// One page, many copies (Canva's Bulk Create, Remotion's dataset render): an element takes a column of a CSV file
/// beside the page, `data-field="clients.csv:name"` (its text, or a picture's `src`), and the page is shown and
/// exported once a row.
public enum DataRows {
    /// The rows of a CSV file (RFC 4180: quotes, doubled quotes, line breaks inside quotes), the first being the names;
    /// its cells split by commas, or by semicolons when its first line has those and no commas (as a European
    /// spreadsheet writes it).
    public static func parse(_ text: String) -> [[String]] {
        let head = text.prefix { $0 != "\n" && $0 != "\r" }
        let split: Character = head.contains(",") || !head.contains(";") ? "," : ";"
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))[...]
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

    /// The CSV files the page's elements take columns of, in the order they first appear.
    public static func files(in html: String) -> [String] {
        var seen: [String] = []
        for m in html.matches(of: /\sdata-field="([^":]+):[^"]*"/) where !seen.contains(String(m.output.1)) {
            seen.append(String(m.output.1))
        }
        return seen
    }

    /// A file name made of a row's first cell, without what a folder can't hold (`a/b` is `ab`); `row-7` without one.
    public static func name(_ row: [String], index: Int) -> String {
        let cleaned = (row.first ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|"))
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "row-\(index)" : String(cleaned.prefix(80))
    }
}
