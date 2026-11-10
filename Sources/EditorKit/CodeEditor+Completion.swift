import AppKit

/// What goes in at the cursor: asked of the server, narrowed as you type, put in with the server's edits; a snippet's tab stops
/// after that, ⇥ moving through them.
extension CodeEditor {
    /// ⌃Space, a trigger character or Esc.
    public func showCompletions() {
        guard completionProvider != nil || snippetSource != nil, let (line, column) = cursor else { return }
        let provider = completionProvider, at = textView.selectedRange().location, s = textView.string as NSString
        let start = min(Self.word(at: at, in: s).location, at)
        let member = start > 0 && s.character(at: start - 1) == 46   // after a dot: a member, not a snippet
        Task { [weak self] in
            var items = await provider?(line, column) ?? []
            if !member, let own = await self?.snippetSource?() { items += own }
            self?.open(items, from: start)
        }
    }

    /// Only the snippets for this file: a way to see them.
    public func showSnippets() {
        let at = textView.selectedRange().location,
            start = min(Self.word(at: at, in: textView.string as NSString).location, at)
        Task { [weak self] in
            guard let items = await self?.snippetSource?(), !items.isEmpty else { return NSSound.beep() }
            self?.open(items, from: start)
        }
    }

    private func open(_ items: [Completion], from start: Int) {
        guard !items.isEmpty, textView.selectedRange().location >= start else { return }
        completion.completing = (start, items)
        refreshCompletions()
    }

    /// The word typed since it opened narrows it; a cursor gone from that word closes it.
    func refreshCompletions() {
        guard let (start, items) = completion.completing else { return }
        let at = textView.selectedRange(), s = textView.string as NSString
        guard at.length == 0, at.location >= start, at.location <= s.length,
            Self.word(at: at.location, in: s).location <= start || at.location == start
        else { return closeCompletions() }
        let typed = s.substring(with: NSRange(location: start, length: at.location - start))
        let list = completion.list ?? CompletionList()
        completion.list = list
        list.onAccept = { [weak self] in self?.accept($0) }
        list.show(CompletionFilter.ranked(items, typed: typed), at: caretOnScreen(start), in: textView.window)
        if !list.isOpen { completion.completing = nil }
    }

    func closeCompletions() {
        completion.completing = nil
        completion.list?.close()
    }

    private func caretOnScreen(_ location: Int) -> NSRect {
        let rect = textView.convert(textView.caretRect(at: location), to: nil)
        return textView.window?.convertToScreen(rect) ?? rect
    }

    private func range(_ edit: TextEdit, in string: NSString) -> NSRange {
        let from = lineIndex.offset(line: edit.line, column: edit.column, in: string) ?? string.length
        let to = lineIndex.offset(line: edit.endLine, column: edit.endColumn, in: string) ?? string.length
        return NSRange(location: from, length: max(to - from, 0))
    }

    /// The server's edit reached as far as was typed when it was asked; the item takes all that's been typed since too.
    func accept(_ completion: Completion) {
        let tv = textView, string = tv.string as NSString, at = tv.selectedRange().location
        let start = completion.edit.map { range($0, in: string).location } ?? self.completion.completing?.start ?? at
        let own = NSRange(location: min(start, at), length: at - min(start, at))
        closeCompletions()
        let line = string.lineRange(for: NSRange(location: own.location, length: 0))
        let indent = string.substring(with: line).prefix { $0 == " " || $0 == "\t" }
        let (text, stops) =
            completion.snippet
            ? Snippet.parse(Snippet.fitted(completion.insert, indent: String(indent), unit: tv.indentUnit))
            : (completion.insert, [])
        let edits = ([(own, text)] + completion.more.map { (range($0, in: string), $0.text) }).sorted {
            $0.0.location < $1.0.location
        }
        tv.replace(edits.map(\.0), with: edits.map(\.1))
        let before = edits.prefix { $0.0.location < own.location }.reduce(0) {
            $0 + ($1.1 as NSString).length - $1.0.length
        }
        let base = own.location + before
        guard !stops.isEmpty else {
            return tv.setSelectedRange(NSRange(location: base + (text as NSString).length, length: 0))
        }
        self.completion.snippetStops = stops.map {
            $0.map { NSRange(location: $0.location + base, length: $0.length) }
        }
        tv.setCursors(self.completion.snippetStops[0])
    }

    /// A server's edits, one undo, the cursors staying where they are.
    public func perform(_ edits: [TextEdit]) {
        let string = textView.string as NSString
        let sorted = edits.map { (range($0, in: string), $0.text) }.sorted { $0.0.location < $1.0.location }
        textView.replace(sorted.map(\.0), with: sorted.map(\.1), keep: true)
    }

    /// The word at the cursor.
    public var wordAtCursor: String {
        let string = textView.string as NSString
        return string.substring(with: Self.word(at: textView.selectedRange().location, in: string))
    }

    /// Under the cursor, as a menu of what can be done there.
    public func popUpAtCursor(_ menu: NSMenu) {
        let caret = textView.caretRect(at: textView.selectedRange().location)
        menu.popUp(positioning: nil, at: NSPoint(x: caret.minX, y: caret.maxY), in: textView)
    }

    /// ⇥ in a snippet: on to the next stop, moved by what was typed at this one. Past the last the snippet is over.
    /// False when no snippet is going on, or the cursors left it.
    func nextSnippetStop() -> Bool {
        guard let now = completion.snippetStops.first else { return false }
        let cursors = textView.cursors
        guard cursors.count == now.count else {
            completion.snippetStops = []
            return false
        }
        let moved = zip(now, cursors).map { (end: NSMaxRange($0), by: NSMaxRange($1) - NSMaxRange($0)) }
        completion.snippetStops = completion.snippetStops.dropFirst().map { group in
            group.map { stop in
                let by = moved.last { $0.end <= stop.location }?.by ?? 0
                return NSRange(location: stop.location + by, length: stop.length)
            }
        }
        guard let next = completion.snippetStops.first else { return true }   // that was the last: the cursor stays
        textView.setCursors(next)
        return true
    }

    /// The keys the list and a snippet take first. True when one did.
    func handle(_ command: Selector) -> Bool {
        if completion.list?.isOpen == true, let list = completion.list {
            switch command {
            case #selector(NSResponder.moveUp(_:)): list.move(by: -1)
            case #selector(NSResponder.moveDown(_:)): list.move(by: 1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let selected = list.selected { accept(selected) }
            case #selector(NSResponder.cancelOperation(_:)): closeCompletions()
            default: return false
            }
            return true
        }
        if command == #selector(NSResponder.insertTab(_:)) { return nextSnippetStop() }
        if command == #selector(NSResponder.cancelOperation(_:)) { completion.snippetStops = [] }
        return false
    }
}

/// What completion keeps between keys; only this file changes it.
struct CompletionState {
    /// While the list is open: where the word it completes starts, and all that was offered.
    fileprivate(set) var completing: (start: Int, items: [CodeEditor.Completion])?
    fileprivate(set) var list: CompletionList?
    /// A snippet's tab stops still to come, the current one first.
    fileprivate var snippetStops: [[NSRange]] = []
}
