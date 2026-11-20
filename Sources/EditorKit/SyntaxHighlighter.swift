import AppKit
@preconcurrency import CodeEditLanguages
@preconcurrency import SwiftTreeSitter
import os

/// Tree-sitter colors. The file is parsed once and again after each edit (tree-sitter reuses what didn't change), and
/// only what's on screen is colored, as layout manager temporary attributes, which don't touch the text or its undo.
@MainActor
final class SyntaxHighlighter {
    private let worker = Worker()
    private let query: Query
    let bracketQuery: Query?
    /// The latest parse, for coloring on the main thread.
    private(set) var tree: Tree?
    /// Edits described before they happen (they need the old text), applied to the tree once they have happened.
    private var pending: [InputEdit] = []
    private var asked = 0, applied = 0
    /// Once a text was long, its parses stay off the main thread, because a short parse waiting on a long one there
    /// would block.
    private var background = false
    var colors: [String: NSColor] = [:]
    /// Bracket colors by depth, cycling round. When empty, brackets keep their grammar's colour.
    var bracketColors: [NSColor] = []
    /// Whether a parse asked for hasn't come in yet (a long text's, on the worker's queue).
    var waiting: Bool { applied < asked }
    /// Called when a parse done on the worker's queue came in, so the text is colored again.
    var parsed: (() -> Void)?
    /// Longer texts parse off the main thread so typing never waits for tree-sitter (5 MB took 2 s from scratch). Their
    /// colors catch up a moment later.
    static let syncLimit = 100_000

    init?(_ language: CodeLanguage) {
        guard let treeLanguage = language.language, let highlightQuery = TreeSitterModel.shared.query(for: language.id),
            worker.setLanguage(treeLanguage)
        else { return nil }
        query = highlightQuery
        bracketQuery = Self.bracketQuery(treeLanguage)
    }

    /// Describes an edit about to happen: `range` of the current text becomes `text`. Positions come from `lines`,
    /// which index the old text.
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

    /// Called after the text changed, so the tree follows. It parses from scratch when the change wasn't described
    /// first, as with setText.
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
        let text = Worker.Text(string.copy() as? NSString ?? "")   // a copy: the text view's string keeps changing
        worker.queue.async { [weak self] in
            // When a newer text is on its way, this one is dropped and that one is parsed.
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
            // A block is parsed whole, here on the main thread, so a block past this size keeps the outer grammar's
            // colors.
            guard inj.range.length <= Self.injectedLimit else { continue }
            guard NSMaxRange(inj.range) <= string.length,
                let found = injected(inj.name, string.substring(with: inj.range))
            else {
                continue
            }
            // The block keeps its own colors only, and the outer grammar's go (a fenced block was all one string
            // color). Markdown's inline marks add to a heading's color instead.
            if Self.language(named: inj.name)?.id != .markdownInline {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSIntersectionRange(inj.range, range))
            }
            paint(found, at: inj.range.location, within: range, lm)
        }
        colorBrackets(range, in: string, lm)
    }

    /// The narrowest highlight over the character at `index` ("keyword.return", "comment"), or nil for none or while a
    /// parse is still on its way (the tree would be of an older text).
    func highlight(at index: Int, in string: NSString) -> String? {
        guard !waiting, index < string.length, let tree, let root = tree.rootNode else { return nil }
        let text: SwiftTreeSitter.Predicate.TextProvider = { piece, _ in
            NSMaxRange(piece) <= string.length ? string.substring(with: piece) : nil
        }
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(NSRange(location: index, length: 1))
        return Array(cursor.resolve(with: .init(textProvider: text))).highlights()
            .last { NSLocationInRange(index, $0.range) }?.name
    }

    /// Paints the less specific highlights first, so a later, narrower one wins.
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
    /// What an injected piece of text colors as, by its language and text. The pieces are small and come back on every
    /// scroll.
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
            if newParser.reads(treeLanguage) { parsers[language.id] = (newParser, highlightQuery) }
        }
        guard let (parser, query) = parsers[language.id], let tree = parser.parse(text) else { return nil }
        let found = query.execute(in: tree).resolve(with: .init(string: text)).highlights()
        // The cache is bounded by size, because each edit of a block makes a new entry here, as long as the block.
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

/// The parser and its tree. They are used on the main thread for a short text, and on `queue` alone once the text was
/// long.
private final class Worker: @unchecked Sendable {
    /// The newest parse asked for. An older parse only applies its edits.
    let latest = OSAllocatedUnfairLock(initialState: 0)
    struct Text: @unchecked Sendable {
        let string: NSString
        init(_ string: NSString) { self.string = string }
    }   // an immutable copy, or one read under sync
    let queue = DispatchQueue(label: "kelp.editor.parse")
    private let parser = Parser()
    private var tree: MutableTree?

    func setLanguage(_ language: Language) -> Bool { parser.reads(language) }

    /// Applies the edits to the last tree (nil edits mean from scratch), parses the text, and returns a copy of the
    /// tree for the main thread. Returns nil without parsing when a newer text waits.
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

extension Parser {
    /// Sets the parser to read `language`. Returns false, and logs it, for a grammar this tree-sitter can't load
    /// (built for another version).
    func reads(_ language: Language) -> Bool {
        do {
            try setLanguage(language)
            return true
        } catch {
            Logger(subsystem: "dev.kelp", category: "editor").error("a grammar didn't load: \(error)")
            return false
        }
    }
}
