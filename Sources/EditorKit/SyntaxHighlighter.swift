import AppKit
@preconcurrency import CodeEditLanguages
@preconcurrency import SwiftTreeSitter
import os

/// Tree-sitter colors: the file parsed once and again after each edit (tree-sitter reuses what didn't change), and only
/// what's on screen colored, as layout manager temporary attributes (they don't touch the text or its undo).
@MainActor
final class SyntaxHighlighter {
    private let worker = Worker()
    private let query: Query
    let bracketQuery: Query?
    /// The latest parse, for coloring on the main thread.
    private(set) var tree: Tree?
    /// Edits described before they happen (the old text is needed for them), applied to the tree when they have.
    private var pending: [InputEdit] = []
    private var asked = 0, applied = 0
    /// Once a text was long, its parses stay off the main thread (a short one waiting on a long one there would block).
    private var background = false
    var colors: [String: NSColor] = [:]
    /// By depth, round and round; none: brackets keep their grammar's colour.
    var bracketColors: [NSColor] = []
    /// A parse done on the worker's queue came in: color again.
    var parsed: (() -> Void)?
    /// Longer texts parse off the main thread so typing never waits for tree-sitter (5 MB took 2 s from scratch); their
    /// colors catch up a moment later.
    static let syncLimit = 100_000

    init?(_ language: CodeLanguage) {
        guard let treeLanguage = language.language, let highlightQuery = TreeSitterModel.shared.query(for: language.id),
            worker.setLanguage(treeLanguage)
        else { return nil }
        query = highlightQuery
        bracketQuery = Self.bracketQuery(treeLanguage)
    }

    /// An edit about to happen: `range` of the current text becomes `text`. Positions come from `lines` (the old text's).
    func willReplace(_ range: NSRange, with text: String, in string: NSString, lines: inout LineIndex) {
        func point(_ location: Int) -> Point {
            let row = lines.line(at: location, in: string)
            return Point(row: row, column: (location - (lines.start(ofLine: row, in: string) ?? 0)) * 2)
        }
        let start = point(range.location), newText = text as NSString
        let lastBreak = newText.range(of: "\n", options: .backwards)
        let newEnd =
            lastBreak.location == NSNotFound
            ? Point(row: Int(start.row), column: Int(start.column) + newText.length * 2)
            : Point(
                row: Int(start.row) + text.utf16.lazy.filter { $0 == 10 }.count,
                column: (newText.length - NSMaxRange(lastBreak)) * 2)
        pending.append(
            InputEdit(
                startByte: range.location * 2, oldEndByte: NSMaxRange(range) * 2,
                newEndByte: (range.location + newText.length) * 2,
                startPoint: start, oldEndPoint: point(NSMaxRange(range)), newEndPoint: newEnd))
    }

    /// After the text changed: the tree follows (from scratch when the change wasn't described first, as setText's).
    func parse(_ string: NSString, described: Bool = true) {
        let edits = described ? pending : nil
        pending = []
        asked += 1
        let generation = asked, worker = worker
        background = background || string.length > Self.syncLimit
        guard background else {
            tree = worker.parse(edits, Worker.Text(string), generation)
            applied = generation
            return
        }
        worker.latest.withLock { $0 = generation }
        let text = Worker.Text(string.copy() as? NSString ?? "")   // the text view's own string keeps changing
        worker.queue.async { [weak self] in
            // A newer text is on its way: parsed then.
            guard let newTree = worker.parse(edits, text, generation) else { return }
            DispatchQueue.main.async {
                guard let self, generation > self.applied else { return }
                self.tree = newTree
                self.applied = generation
                self.parsed?()
            }
        }
    }

    /// Colors `range` (the visible part, mostly) from the tree, and the languages inside it (a Markdown paragraph's
    /// inline marks, a fenced block, `<script>` in HTML) from their own.
    func color(_ range: NSRange, in tv: NSTextView) {
        guard let lm = tv.layoutManager, let tree, let root = tree.rootNode else { return }
        let string = tv.string as NSString
        let text: SwiftTreeSitter.Predicate.TextProvider = { piece, _ in
            NSMaxRange(piece) <= string.length ? string.substring(with: piece) : nil
        }
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(range)
        let matches = Array(cursor.resolve(with: .init(textProvider: text)))
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        paint(matches.highlights(), at: 0, within: range, lm)
        for inj in matches.compactMap({ $0.injection(with: text) })
        where NSIntersectionRange(inj.range, range).length > 0 {
            // A block is parsed whole, here on the main thread: past this it keeps the outer grammar's colors.
            guard inj.range.length <= Self.injectedLimit else { continue }
            guard NSMaxRange(inj.range) <= string.length,
                let found = injected(inj.name, string.substring(with: inj.range))
            else {
                continue
            }
            // Its own colors only: the outer grammar's go (a fenced block was all one string color); Markdown's inline
            // marks add to a heading's color instead.
            if Self.language(named: inj.name)?.id != .markdownInline {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSIntersectionRange(inj.range, range))
            }
            paint(found, at: inj.range.location, within: range, lm)
        }
        colorBrackets(range, in: string, lm)
    }

    /// The less specific first: a later, narrower one wins.
    private func paint(_ found: [NamedRange], at offset: Int, within range: NSRange, _ lm: NSLayoutManager) {
        for highlight in found {
            guard let tint = colors[highlight.name] ?? colors[highlight.nameComponents.first ?? ""] else { continue }
            let overlap = NSIntersectionRange(
                NSRange(location: highlight.range.location + offset, length: highlight.range.length), range)
            if overlap.length > 0 {
                lm.addTemporaryAttribute(.foregroundColor, value: tint, forCharacterRange: overlap)
            }
        }
    }

    // MARK: Languages inside

    private var parsers: [TreeSitterLanguage: (Parser, Query)] = [:]
    /// What an injected piece of text colors as, by its language and text: they're small and come back on every scroll.
    private var seen: [String: [NamedRange]] = [:]
    private var seenCharacters = 0
    private static let injectedLimit = 64_000

    /// The highlights of `text` (a piece of the file) in the language called `name`, parsed on its own; nil for a
    /// language without a grammar here.
    private func injected(_ name: String, _ text: String) -> [NamedRange]? {
        guard let language = Self.language(named: name) else { return nil }
        let key = language.tsName + "\u{0}" + text
        if let known = seen[key] { return known }
        if parsers[language.id] == nil, let treeLanguage = language.language,
            let highlightQuery = TreeSitterModel.shared.query(for: language.id)
        {
            let newParser = Parser()
            if (try? newParser.setLanguage(treeLanguage)) != nil { parsers[language.id] = (newParser, highlightQuery) }
        }
        guard let (parser, query) = parsers[language.id], let tree = parser.parse(text) else { return nil }
        let found = query.execute(in: tree).resolve(with: .init(string: text)).highlights()
        // By size: each edit of a block is a new entry here, as long as the block.
        seenCharacters += text.utf16.count
        if seen.count > 500 || seenCharacters > 2_000_000 {
            seen = [:]
            seenCharacters = text.utf16.count
        }
        seen[key] = found
        return found
    }

    /// A language by the name an injection or a fenced block gives it (`js`, `markdown_inline`, `yml`).
    static func language(named name: String) -> CodeLanguage? {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "-")
        let aliases = [
            "js": "javascript", "ts": "typescript", "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
            "yml": "yaml",
            "py": "python", "rb": "ruby", "rs": "rust", "c++": "cpp", "cs": "c-sharp", "csharp": "c-sharp",
            "golang": "go", "md": "markdown"
        ]
        let id = aliases[normalized] ?? normalized
        return CodeLanguage.allLanguages.first {
            $0.tsName == id || $0.extensions.contains(id) || $0.additionalIdentifiers.contains(id)
        }
    }
}

/// The parser and its tree: used on the main thread for a short text, on `queue` alone once it was long.
private final class Worker: @unchecked Sendable {
    /// The newest parse asked for: an older one only applies its edits.
    let latest = OSAllocatedUnfairLock(initialState: 0)
    struct Text: @unchecked Sendable {
        let string: NSString
        init(_ string: NSString) { self.string = string }
    }   // an immutable copy, or read under sync
    let queue = DispatchQueue(label: "kelp.editor.parse")
    private let parser = Parser()
    private var tree: MutableTree?

    func setLanguage(_ language: Language) -> Bool { (try? parser.setLanguage(language)) != nil }

    /// The edits applied to the last tree (none: from scratch) and the text parsed; a copy for the main thread. Nil
    /// without parsing when a newer text waits.
    func parse(_ edits: [InputEdit]?, _ text: Text, _ generation: Int) -> Tree? {
        let string = text.string
        if let edits, let tree { for edit in edits { tree.edit(edit) } } else { tree = nil }
        guard latest.withLock({ $0 <= generation }) else { return nil }
        tree = parser.parse(
            tree: tree,
            readBlock: { byte, _ in
                let at = byte / 2
                guard at < string.length else { return nil }
                var chars = [unichar](repeating: 0, count: min(16_384, string.length - at))
                string.getCharacters(&chars, range: NSRange(location: at, length: chars.count))
                return chars.withUnsafeBytes { Data($0) }
            })
        return tree?.copy()
    }
}
