import Core
import Foundation

/// Flat rows for a diff table: one place builds them so inline and side-by-side stay consistent.
public enum DiffRow: Equatable, Sendable {
    case file(path: String, additions: Int, deletions: Int)
    case hunk(file: Int, index: Int, header: String)
    /// Unchanged lines between hunks, collapsed: the new file's `from..<from+lines`; `context` is the function git names
    /// in the next hunk's header.
    case gap(file: Int, from: Int, lines: Int, context: String)
    case line(file: Int, DiffLine)   // inline
    case pair(file: Int, left: DiffLine?, right: DiffLine?)   // side-by-side
    case binary(path: String)
    case tooLarge(path: String)   // past what one diff reply carries (`FileDiff.tooLarge`)
}

public enum DiffRows {
    /// Pair deletions with the additions that follow them; context lines appear on both sides.
    public static func pairs(_ lines: [DiffLine]) -> [(DiffLine?, DiffLine?)] {
        var out: [(DiffLine?, DiffLine?)] = []
        var i = 0
        while i < lines.count {
            if lines[i].kind == .context {
                out.append((lines[i], lines[i]))
                i += 1
                continue
            }
            var dels: [DiffLine] = [], adds: [DiffLine] = []
            while i < lines.count, lines[i].kind == .del {
                dels.append(lines[i])
                i += 1
            }
            while i < lines.count, lines[i].kind == .add {
                adds.append(lines[i])
                i += 1
            }
            for k in 0..<max(dels.count, adds.count) {
                out.append((k < dels.count ? dels[k] : nil, k < adds.count ? adds[k] : nil))
            }
        }
        return out
    }

    /// What opens a gap: its file and where it starts, for the lines `build` shows in its place.
    public static func gapKey(_ path: String, _ from: Int) -> String { "\(path):\(from)" }

    /// The text after a hunk header's "@@ … @@": the function or type git found above it ("" when none).
    public static func context(_ header: String) -> String {
        guard let r = header.range(of: "@@", options: .backwards), r.lowerBound > header.startIndex else { return "" }
        return header[r.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// `opened`: the unchanged lines of gaps the user opened, by `gapKey`, shown in their place.
    public static func build(_ files: [FileDiff], sideBySide: Bool, opened: [String: [DiffLine]] = [:]) -> [DiffRow] {
        var rows: [DiffRow] = []
        for (fi, f) in files.enumerated() {
            rows.append(.file(path: f.path, additions: f.additions, deletions: f.deletions))
            if f.tooLarge == true {
                rows.append(.tooLarge(path: f.path))
                continue
            }
            if f.binary {
                rows.append(.binary(path: f.path))
                continue
            }
            var prevEnd: Int?
            for (hi, h) in f.hunks.enumerated() {
                if let p = prevEnd, h.newStart > p {
                    if let shown = opened[gapKey(f.path, p)] {
                        rows += shown.map { sideBySide ? .pair(file: fi, left: $0, right: $0) : .line(file: fi, $0) }
                    } else {
                        rows.append(.gap(file: fi, from: p, lines: h.newStart - p, context: context(h.header)))
                    }
                }
                rows.append(.hunk(file: fi, index: hi, header: h.header))
                if sideBySide {
                    for (l, r) in pairs(h.lines) { rows.append(.pair(file: fi, left: l, right: r)) }
                } else {
                    for l in h.lines { rows.append(.line(file: fi, l)) }
                }
                prevEnd = h.newStart + h.lines.filter { $0.newLine != nil }.count
            }
        }
        return rows
    }
}

/// A row of the review table: a diff row, or a comment shown under the line it is about.
public enum ReviewRow: Equatable, Sendable {
    case diff(DiffRow)
    case comment(DiffComment)
    /// A comment being written, in a card under its line (placed by the view, not built here).
    case draft
}

extension DiffRows {
    /// The part of two versions of a line that differs: what's left after the common start and end (UTF-16 ranges).
    /// Limit: one range per line, not a word-by-word diff; enough to spot the edit, as VS Code's first pass does.
    public static func changedRanges(_ a: String, _ b: String) -> (NSRange, NSRange) {
        let x = Array(a.utf16), y = Array(b.utf16)
        var p = 0
        while p < min(x.count, y.count), x[p] == y[p] { p += 1 }
        var s = 0
        while s < min(x.count, y.count) - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        return (NSRange(location: p, length: x.count - p - s), NSRange(location: p, length: y.count - p - s))
    }

    /// Changed range of every line that has a counterpart on the other side, by "file:d:oldLine" / "file:a:newLine".
    public static func changedWords(_ diffs: [FileDiff]) -> [String: NSRange] {
        var out: [String: NSRange] = [:]
        for (fi, f) in diffs.enumerated() {
            for h in f.hunks {
                for (l, r) in pairs(h.lines) {
                    guard let l, let r, l.kind == .del, r.kind == .add, let o = l.oldLine, let n = r.newLine else {
                        continue
                    }
                    let (a, b) = changedRanges(l.text, r.text)
                    out["\(fi):d:\(o)"] = a
                    out["\(fi):a:\(n)"] = b
                }
            }
        }
        return out
    }

    /// The table's rows: comments that aren't resolved go under their last line, once: a removed line's (`side` "old")
    /// under that removed line, the others under the new file's. One from before sides keeps a number only: a line of the
    /// new file wins, and a deleted line takes it only when the new file has no such line.
    /// `hideFileRows`: one-file mode, where the bar already names the file.
    public static func reviewRows(
        _ diffs: [FileDiff], comments: [DiffComment], sideBySide: Bool, hideFileRows: Bool,
        opened: [String: [DiffLine]] = [:]
    ) -> [ReviewRow] {
        var newLines = Set<String>()
        for (fi, f) in diffs.enumerated() {
            for h in f.hunks { for l in h.lines { if let n = l.newLine { newLines.insert("\(fi):\(n)") } } }
        }
        func under(_ fi: Int, _ l: DiffLine) -> [ReviewRow] {
            let here = comments.filter { $0.file == diffs[fi].path && $0.state != .resolved }
            if let n = l.newLine { return here.filter { $0.side != "old" && $0.endLine == n }.map { .comment($0) } }
            guard let o = l.oldLine else { return [] }
            let unsided = !newLines.contains("\(fi):\(o)")
            return here.filter { $0.endLine == o && ($0.side == "old" || ($0.side == nil && unsided)) }.map {
                .comment($0)
            }
        }
        var out: [ReviewRow] = []
        for r in build(diffs, sideBySide: sideBySide, opened: opened) {
            if hideFileRows, case .file = r { continue }
            out.append(.diff(r))
            switch r {
            case .line(let f, let l): out += under(f, l)
            case .pair(let f, let l, let right):
                if let x = right ?? l { out += under(f, x) }
                if let l, right != nil, l.kind == .del { out += under(f, l) }   // the removed line beside an added one
            default: break
            }
        }
        return out
    }
}
