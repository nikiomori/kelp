import AppKit
import DesignKit

/// ⌘F in a code editor: floats at its top right. Matches as you type, the count and every match shown; ↩ / ⇧↩ or ⌘G / ⇧⌘G
/// step, ⌥↩ makes every match a cursor, Esc goes back to the text. The chevron opens replacing, with `$1` in a regex.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    private weak var editor: CodeEditor?
    let field = NSSearchField(), replaceField = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private lazy var steps = NSSegmentedControl.steps(
        previous: String(localized: "Previous Match (⇧⌘G)"), next: String(localized: "Next Match (⌘G)"),
        target: self, action: #selector(stepped))
    private(set) var options = FindOptions()
    private var scope: NSRange?
    private var found: [NSTextCheckingResult] = []
    private var regex: NSRegularExpression?
    private var index: Int?
    private lazy var caseToggle = TextToggle("Aa", tip: String(localized: "Match Case")) { [weak self] in
        self?.flip(\.matchCase)
    }
    private lazy var wordToggle = TextToggle("ab", tip: String(localized: "Whole Word")) { [weak self] in
        self?.flip(\.wholeWord)
    }
    private lazy var regexToggle = TextToggle(".*", tip: String(localized: "Regular Expression")) { [weak self] in
        self?.flip(\.regex)
    }
    private lazy var scopeToggle = TextToggle("[ ]", tip: String(localized: "In Selection")) { [weak self] in
        self?.flipScope()
    }
    private lazy var caseKept = TextToggle("AB", tip: String(localized: "Preserve Case")) { [weak self] in
        self?.flip(\.preserveCase)
    }
    private lazy var more = IconButton(Self.symbol("chevron.right"), tip: String(localized: "Replace")) { [weak self] in
        self?.toggleReplace()
    }
    private lazy var replaceRow = NSStackView(views: [
        replaceField, caseKept, button(String(localized: "Replace")) { [weak self] in self?.replaceOne() },
        button(String(localized: "All")) { [weak self] in self?.replaceAll() }
    ])

    init(editor: CodeEditor) {
        self.editor = editor
        super.init(frame: .zero)
        for searchField in [field, replaceField] {
            searchField.delegate = self
            searchField.controlSize = .small
            searchField.font = .ui(12)
            searchField.sendsSearchStringImmediately = true
            searchField.focusRingType = .none
            searchField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        }
        field.placeholderString = String(localized: "Find")
        replaceField.placeholderString = String(localized: "Replace")
        (replaceField.cell as? NSSearchFieldCell)?.searchButtonCell?.isTransparent = true
        count.font = .uiDigits(11)
        count.textColor = .secondaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        let close = IconButton(Self.symbol("xmark"), tip: String(localized: "Close")) { [weak self] in self?.close() }
        let top = NSStackView(views: [
            more, field, count, caseToggle, wordToggle, regexToggle, scopeToggle, steps, close
        ])
        top.spacing = Metrics.gap
        replaceRow.spacing = Metrics.gap
        replaceRow.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.iconButton + Metrics.gap, bottom: 0, right: 0)
        replaceRow.isHidden = true
        let rows = NSStackView(views: [top, replaceRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Metrics.gap
        rows.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        let card = FloatingCard(rows, radius: Metrics.radiusMD)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSView {
        let button = PointerButton()
        button.title = title
        button.font = .ui(11)
        button.padding = Metrics.gap
        button.restFill = .fillRest
        button.onClick = action
        return button
    }

    func begin(with text: String?) {
        isHidden = false
        if let text, !text.isEmpty, text != field.stringValue { field.stringValue = text }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        search(moving: true)
    }

    func close() {
        isHidden = true
        guard let tv = editor?.textView else { return }
        tv.findMarks = []
        tv.findCurrent = nil
        editor?.refreshScrollMarks()
        window?.makeFirstResponder(tv)
    }

    /// The text changed under it: the matches move, the cursor stays where the edit left it.
    /// A moment after the typing stops: a search per key over a 5 MB file was 19 ms of every key while the bar was open.
    func textChanged() {
        guard !isHidden else { return }
        researching?.cancel()
        let again = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.search(moving: false) } }   // main queue
        researching = again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: again)
    }
    private var researching: DispatchWorkItem?

    func flip(_ option: WritableKeyPath<FindOptions, Bool>) {
        options[keyPath: option].toggle()
        caseToggle.isOn = options.matchCase
        wordToggle.isOn = options.wholeWord
        regexToggle.isOn = options.regex
        caseKept.isOn = options.preserveCase
        search(moving: true)
    }

    private func flipScope() {
        let selection = editor?.textView.selectedRange()
        scope = scope == nil && selection?.length ?? 0 > 0 ? selection : nil
        scopeToggle.isOn = scope != nil
        search(moving: true)
    }

    private func toggleReplace() {
        replaceRow.isHidden.toggle()
        more.image = Self.symbol(replaceRow.isHidden ? "chevron.right" : "chevron.down")
    }

    func search(moving: Bool) {
        guard let tv = editor?.textView else { return }
        let string = tv.string as NSString, query = field.stringValue
        found = []
        regex = nil
        index = nil
        defer {
            tv.findMarks = found.map(\.range)
            tv.findCurrent = index.map { found[$0].range }
            editor?.refreshScrollMarks()
            showCount()
        }
        guard !query.isEmpty else { return }
        do { regex = try TextSearch.pattern(query, options) } catch {
            count.stringValue = String(localized: "Not a valid pattern")
            return
        }
        guard let regex else { return }
        let inScope = scope.map { NSIntersectionRange($0, NSRange(location: 0, length: string.length)) }
        found = TextSearch.matches(regex, in: string, within: inScope)
        let from = tv.selectedRange().location
        index = found.isEmpty ? nil : found.firstIndex { $0.range.location >= from } ?? 0
        if moving, let index { show(index) }
    }

    private func showCount() {
        guard !field.stringValue.isEmpty, regex != nil else {
            if regex == nil, field.stringValue.isEmpty { count.stringValue = "" }
            steps.isEnabled = false
            return
        }
        let more = found.count >= TextSearch.mostMatches ? "+" : ""
        count.stringValue =
            found.isEmpty
            ? String(localized: "No matches") : String(localized: "\((index ?? 0) + 1) of \("\(found.count)\(more)")")
        steps.isEnabled = !found.isEmpty
    }

    /// Selected and in view. The keys stay in the field.
    private func show(_ position: Int) {
        guard let tv = editor?.textView, found.indices.contains(position) else { return }
        index = position
        let range = found[position].range
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.findCurrent = range
        showCount()
    }

    func step(forward: Bool) {
        guard !found.isEmpty else {
            NSSound.beep()
            return
        }
        show(((index ?? -1) + (forward ? 1 : found.count - 1)) % found.count)
    }

    @objc private func stepped() { step(forward: steps.selectedSegment == 1) }

    /// Cursors in the text, one on each match: type to change them all.
    private func selectAllMatches() {
        guard let tv = editor?.textView, !found.isEmpty else { return }
        let ranges = found.map(\.range)
        close()
        tv.setCursors(ranges)
    }

    private func replaceOne() {
        guard let tv = editor?.textView, let regex, let index, found.indices.contains(index) else { return }
        let match = found[index], string = tv.string as NSString
        let new = TextSearch.replacement(match, regex, in: string, template: replaceField.stringValue, options)
        tv.replace([match.range], with: [new])
        tv.setSelectedRange(NSRange(location: match.range.location + (new as NSString).length, length: 0))
        search(moving: true)
    }

    func replaceAll() {
        guard let tv = editor?.textView, let regex, !found.isEmpty else { return }
        let string = tv.string as NSString, template = replaceField.stringValue
        tv.replace(
            found.map(\.range),
            with: found.map { TextSearch.replacement($0, regex, in: string, template: template, options) }, keep: true)
        search(moving: false)
    }

    /// ⌘G and ⇧⌘G with the keys in a field. Before the menu: its item would go to the field's editor, a text view too, whose
    /// find panel is off.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let forward = event.findStep, !isHidden,
            (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        else { return super.performKeyEquivalent(with: event) }
        step(forward: forward)
        return true
    }

    /// The menu's Find items with the keys on one of the bar's buttons, which the text view isn't behind.
    @objc func performFindPanelAction(_ sender: Any?) {
        switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
        case .next: step(forward: true)
        case .previous: step(forward: false)
        default: window?.makeFirstResponder(field)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === field { search(moving: true) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        if control === replaceField {
            replaceOne()
        } else if mods.contains(.option) {
            selectAllMatches()
        } else {
            step(forward: !mods.contains(.shift))
        }
        return true
    }
}

extension CodeEditor {
    /// ⌘F, ⌘G, ⇧⌘G and ⌘E.
    func find(_ action: NSFindPanelAction) {
        let selected =
            textView.selectedRange().length > 0
            ? (textView.string as NSString).substring(with: textView.selectedRange()) : nil
        let oneLine = selected?.contains("\n") == true ? nil : selected
        switch action {
        case .next, .previous:
            guard let findBar, !findBar.isHidden else { return openFind(with: oneLine) }
            findBar.step(forward: action == .next)
        case .setFindString:
            openFind(with: oneLine)
            focus()
        default: openFind(with: oneLine)
        }
    }

    func openFind(with text: String?) {
        let bar =
            findBar
            ?? {
                let created = FindBar(editor: self)
                created.translatesAutoresizingMaskIntoConstraints = false
                // Beside the scroll view, not in it: its clip view would draw over the bar.
                (scroll.superview ?? scroll).addSubview(created, positioned: .above, relativeTo: scroll)
                NSLayoutConstraint.activate([
                    created.topAnchor.constraint(equalTo: scroll.topAnchor, constant: Metrics.gap),
                    created.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -Metrics.inset)
                ])
                findBar = created
                return created
            }()
        bar.begin(with: text)
    }
}

extension EditorTextView {
    /// Every match in what's drawn; the one the bar is on stands out.
    func drawFindMarks(in rect: NSRect) {
        guard !findMarks.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let shown = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: rect.insetBy(dx: 0, dy: -20), in: tc), actualGlyphRange: nil)
        var lo = 0, hi = findMarks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(findMarks[mid]) <= shown.location { lo = mid + 1 } else { hi = mid }
        }
        let origin = textContainerOrigin
        for mark in findMarks[lo...] {
            if mark.location > NSMaxRange(shown) { break }
            if folds.intersects(mark) { continue }
            NSColor.findHighlightColor.withAlphaComponent(mark == findCurrent ? 0.7 : 0.3).setFill()
            lm.enumerateEnclosingRects(
                forGlyphRange: lm.glyphRange(forCharacterRange: mark, actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc
            ) { markRect, _ in
                markRect.offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
    }
}
