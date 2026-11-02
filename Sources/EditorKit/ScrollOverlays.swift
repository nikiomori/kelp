import AppKit
import DesignKit

/// The editor's scroll view, with views that stay over the text however it scrolls: its clip view would draw over any other.
final class EditorScrollView: NSScrollView {
    let marks = ScrollMarks()
    let sticky = StickyLines()

    override func tile() {
        super.tile()
        for v in [sticky, marks] where v.superview !== self || subviews.last !== v { addSubview(v, positioned: .above, relativeTo: nil) }
        let width = ScrollMarks.width
        marks.frame = NSRect(x: bounds.maxX - width, y: contentView.frame.minY, width: width, height: contentView.frame.height)
        placeSticky()
    }

    func placeSticky() {
        let height = sticky.height
        sticky.isHidden = height == 0
        let y = isFlipped ? contentView.frame.minY : contentView.frame.maxY - height
        sticky.frame = NSRect(x: 0, y: y, width: bounds.width - ScrollMarks.width, height: height)
    }
}

/// Beside the scroller: where the problems, changes, matches and the cursor are in the whole file.
final class ScrollMarks: NSView {
    static let width: CGFloat = 6
    private static let mark: CGFloat = 2
    /// The file's lines, and what's on them, 0-based.
    var lines = 1
    var ticks: [(line: Int, color: NSColor)] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // the scroller's under it

    override func draw(_ dirtyRect: NSRect) {
        guard lines > 0 else { return }
        var seen = Set<Int>()
        for t in ticks {
            let y = Int(CGFloat(t.line) / CGFloat(lines) * bounds.height)
            guard seen.insert(y).inserted else { continue }   // a thousand matches, a pixel each
            t.color.setFill()
            NSRect(x: 0, y: CGFloat(y), width: bounds.width, height: Self.mark).fill()
        }
    }
}

/// The lines that open the scopes around the top of what's on screen: a click goes to one.
final class StickyLines: NSView {
    static let most = 5
    var onLine: ((Int) -> Void)?
    private let stack = NSStackView()
    private var shown: [Int] = []
    var height: CGFloat { CGFloat(shown.count) * rowHeight + (shown.isEmpty ? 0 : 1) }
    private var rowHeight: CGFloat = 16

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }
    override var isFlipped: Bool { true }

    func show(_ lines: [(line: Int, text: String)], look: (font: NSFont, text: NSColor, background: NSColor), indent: CGFloat, rowHeight: CGFloat) {
        guard lines.map(\.line) != shown || self.rowHeight != rowHeight else { return }
        shown = lines.map(\.line)
        self.rowHeight = rowHeight
        layer?.backgroundColor = look.background.cgColor
        stack.setViews(lines.map { l in
            let row = NSTextField(labelWithString: l.text)
            row.font = look.font
            row.textColor = look.text
            row.lineBreakMode = .byTruncatingTail
            let holder = StickyRow(row, indent: indent, height: rowHeight)
            holder.onClick = { [weak self] in self?.onLine?(l.line) }
            return holder
        }, in: .top)
    }

    private final class StickyRow: NSView {
        var onClick: (() -> Void)?
        init(_ label: NSTextField, indent: CGFloat, height: CGFloat) {
            super.init(frame: .zero)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: height), label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
                label.centerYAnchor.constraint(equalTo: centerYAnchor), trailingAnchor.constraint(equalTo: label.trailingAnchor)
            ])
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}

extension CodeEditor {
    /// Past how many lines up a scope isn't looked for.
    private static let stickyReach = 600

    /// The ticks beside the scroller, all there is to mark as of now.
    func refreshScrollMarks() {
        let s = textView.string as NSString
        var ticks: [(line: Int, color: NSColor)] = changeMarks.map { m in
            (m.line, m.kind == .added ? .textGreen : m.kind == .changed ? .textOrange : .textRed)
        }
        ticks += textView.findMarks.prefix(2000).map { (lineIndex.line(at: $0.location, in: s), NSColor.findHighlightColor) }
        ticks += problems.map { ($0.line, $0.isError ? NSColor.textRed : NSColor.textOrange) }   // over what they share a pixel with
        ticks.reverse()
        ticks.append((lineIndex.line(at: textView.selectedRange().location, in: s), .tertiaryLabelColor))
        (scroll as? EditorScrollView)?.marks.lines = lineCount
        (scroll as? EditorScrollView)?.marks.ticks = ticks
    }

    func stickyLines() -> [Int] { scopeLines(around: topLine - 1) }

    /// The scopes around the cursor, outermost first, as `(0-based line, its text)`.
    public var scopesAtCursor: [(line: Int, text: String)] { scopeRows(scopeLines(around: (cursor?.line ?? 1) - 1)) }

    private func scopeRows(_ lines: [Int]) -> [(line: Int, text: String)] {
        let s = textView.string as NSString
        return lines.compactMap { n in
            guard let start = lineIndex.start(ofLine: n, in: s) else { return nil }
            return (n, s.substring(with: s.lineRange(for: NSRange(location: start, length: 0))).trimmingCharacters(in: .newlines))
        }
    }

    /// The scopes around `top`, outermost first: lines above it less indented, or headings, whose fold reaches it.
    private func scopeLines(around top: Int) -> [Int] {
        let s = textView.string as NSString
        guard top > 0, let at = lineIndex.start(ofLine: top, in: s) else { return [] }
        var found: [Int] = [], least = Folds.indent(s.lineRange(for: NSRange(location: at, length: 0)), in: s) ?? Int.max, n = top - 1
        while n >= 0, top - n <= Self.stickyReach, found.count < StickyLines.most, least > 0 || isMarkdown {
            defer { n -= 1 }
            guard let start = lineIndex.start(ofLine: n, in: s) else { continue }
            let line = s.lineRange(for: NSRange(location: start, length: 0))
            guard let indent = Folds.indent(line, in: s), indent < least || (isMarkdown && s.character(at: start) == 35) else { continue }
            guard let r = foldRegion(line, in: s), NSLocationInRange(at, r) else { continue }
            least = min(least, indent)
            found.append(n)
        }
        return found.reversed()
    }

    func refreshSticky() {
        guard let view = scroll as? EditorScrollView, let tv = Optional(textView), let lm = tv.layoutManager else { return }
        let rows = scopeRows(stickyEnabled ? stickyLines() : [])
        let indent = (scroll.verticalRulerView?.ruleThickness ?? 0) + tv.textContainerOrigin.x + (tv.textContainer?.lineFragmentPadding ?? 0)
        let row = lm.defaultLineHeight(for: Self.font)
        view.sticky.show(rows, look: (Self.font, Self.page.text, Self.page.background), indent: indent, rowHeight: row)
        view.placeSticky()
    }
}
