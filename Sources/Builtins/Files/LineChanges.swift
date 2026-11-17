import Core
import EditorKit

/// A run of lines that differ from HEAD, as the editor's gutter marks it. Lines are 0-based in the file as it is now. A
/// removal sits on the line below the gap, with a count of 0. Each run keeps the index of the hunk it came from.
typealias LineChange = CodeEditor.ChangeMark

extension LineChange {
    /// Reads the hunks of one file, top to bottom.
    static func of(_ hunks: [Hunk]) -> [LineChange] {
        var out: [LineChange] = []
        for (h, hunk) in hunks.enumerated() {
            var next = max(hunk.newStart, 1) - 1, removed = 0, added = 0
            func flush() {
                if added > 0 {
                    out.append(
                        LineChange(kind: removed > 0 ? .changed : .added, line: next - added, count: added, hunk: h))
                } else if removed > 0 {
                    out.append(LineChange(kind: .removed, line: next, count: 0, hunk: h))
                }
                removed = 0
                added = 0
            }
            for l in hunk.lines {
                switch l.kind {
                case .del: removed += 1
                case .add:
                    added += 1
                    next += 1
                case .context:
                    flush()
                    next += 1
                }
            }
            flush()
        }
        return out
    }
}
