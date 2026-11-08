import AppKit
import Core
import EditorKit

/// A diff's code coloured by the editor's tree-sitter grammars, so it reads like the file: each file's old side (its
/// unchanged and removed lines) and new side (unchanged and added lines) parsed once as one text, then cut per line.
/// The hunks are pieces of the file, not all of it; tree-sitter makes the best of that, as it does of a file being typed.
/// A side past `limit`, a language without a grammar and lines opened between changes show plain.
enum DiffColors {
    struct Span: Sendable, Equatable {
        let range: NSRange
        let name: String
    }
    /// Characters a side: the rows wait for the colours, and past this the parse would hold them up (200 K in a debug
    /// build: about 0.3 s, off the main thread).
    static let limit = 200_000

    /// A line's key: a removed line by its old number, the others by their new one.
    static func key(_ file: Int, _ l: DiffLine) -> String? {
        l.kind == .del ? l.oldLine.map { "\(file):o:\($0)" } : l.newLine.map { "\(file):n:\($0)" }
    }

    /// The grammar of each file that has one, on the main thread (the queries are made there).
    @MainActor static func grammars(_ diffs: [FileDiff]) -> [Int: CodeGrammar] {
        var byExt: [String: CodeGrammar?] = [:], out: [Int: CodeGrammar] = [:]
        for (index, diff) in diffs.enumerated() where !diff.binary && !diff.hunks.isEmpty {
            let name = (diff.path as NSString).lastPathComponent, ext = (name as NSString).pathExtension
            let grammar = byExt[ext] ?? CodeGrammar(fileName: name)
            if !ext.isEmpty { byExt[ext] = grammar }   // "Makefile", "Dockerfile": by the name
            out[index] = grammar
        }
        return out
    }

    /// Every line's captures by `key`, any thread. A line longer than `Highlighter.maxColored` is left out: its cell
    /// stays one colour.
    static func spans(_ diffs: [FileDiff], grammars: [Int: CodeGrammar]) -> [String: [Span]] {
        var out: [String: [Span]] = [:]
        for (f, g) in grammars where diffs.indices.contains(f) {
            let lines = diffs[f].hunks.flatMap(\.lines)
            for side in [DiffLine.Kind.del, .add] {
                let shown = lines.filter { $0.kind == .context || $0.kind == side }
                for (k, v) in spans(of: shown, file: f, keep: side, grammar: g) { out[k] = v }
            }
        }
        return out
    }

    /// One side's lines as one text, parsed; the captures cut at line ends. Unchanged lines are kept from the new side only.
    private static func spans(of lines: [DiffLine], file f: Int, keep side: DiffLine.Kind, grammar: CodeGrammar)
        -> [String: [Span]]
    {
        var starts: [Int] = [], at = 0
        for line in lines {
            starts.append(at)
            at += line.text.utf16.count + 1
        }
        guard at <= limit, !lines.isEmpty else { return [:] }
        func kept(_ l: DiffLine) -> Bool { l.kind == side || (side == .add && l.kind == .context) }
        var out: [String: [Span]] = [:]
        for (range, name) in grammar.highlights(lines.map(\.text).joined(separator: "\n")) {
            // The last line starting at or before the capture, then each line it runs into.
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= range.location { lo = mid + 1 } else { hi = mid }
            }
            var lineIndex = max(0, lo - 1)
            while lineIndex < lines.count, starts[lineIndex] < NSMaxRange(range) {
                let line = lines[lineIndex], length = line.text.utf16.count
                let cut = NSIntersectionRange(range, NSRange(location: starts[lineIndex], length: length))
                if cut.length > 0, kept(line), length <= Highlighter.maxColored, let lineKey = key(f, line) {
                    out[lineKey, default: []].append(
                        Span(range: NSRange(location: cut.location - starts[lineIndex], length: cut.length), name: name)
                    )
                }
                lineIndex += 1
            }
        }
        // A line with no captures is still coloured by the grammar (all plain): no regex for it.
        for line in lines where kept(line) { if let lineKey = key(f, line), out[lineKey] == nil { out[lineKey] = [] } }
        return out
    }
}
