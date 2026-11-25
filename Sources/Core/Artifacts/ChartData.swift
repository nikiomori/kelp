import Foundation

/// A chart's numbers, kept where the user can change them without the agent (Gamma's Edit Chart): a `<table>` inside
/// the chart's element (`data-chart`, often visually hidden), its first row the column names. Kelp reads it into a
/// sheet and writes it back; the drawing is the agent's to redo from it.
public enum ChartData {
    /// The rows of the first table inside element `id` of `source`, each a list of cells as text; nil without one.
    public static func read(_ source: String, id: String) -> [[String]]? {
        guard let element = BoardEdit.element(source, id: id),
            let table = element.firstMatch(of: /<table\b[^>]*>([\s\S]*?)<\/table>/.ignoresCase())
        else { return nil }
        let rows = String(table.output.1).matches(of: /<tr\b[^>]*>([\s\S]*?)<\/tr>/.ignoresCase()).map { row in
            String(row.output.1).matches(of: /<t[hd]\b[^>]*>([\s\S]*?)<\/t[hd]>/.ignoresCase()).map {
                BoardEdit.unescape(String($0.output.1).replacing(/<[^>]*>/, with: ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return rows.isEmpty ? nil : rows
    }

    /// `source` with the table inside element `id` holding `rows` (the first as the header); nil when it has none.
    public static func write(_ source: String, id: String, rows: [[String]]) -> String? {
        guard let range = BoardEdit.elementRange(source, id: id),
            let table = source[range].firstMatch(of: /<table\b([^>]*)>[\s\S]*?<\/table>/.ignoresCase())
        else { return nil }
        let cells = rows.enumerated().map { i, row in
            "<tr>"
                + row.map { i == 0 ? "<th>\(BoardEdit.escape($0))</th>" : "<td>\(BoardEdit.escape($0))</td>" }
                .joined() + "</tr>"
        }
        var out = source
        out.replaceSubrange(table.range, with: "<table\(table.output.1)>" + cells.joined() + "</table>")
        return out
    }
}
