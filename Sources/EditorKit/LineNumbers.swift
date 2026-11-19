import AppKit
import DesignKit

/// Where lines start, found only as far as asked and forgotten past an edit, so a 5 MB file gets line numbers without
/// a scan per keystroke or per frame.
struct LineIndex {
    private(set) var starts = [0]
    /// Every line break before this offset is in `starts`.
    private var scanned = 0

    /// Forgets what's known from `offset` on, because the text changed there.
    mutating func invalidate(from offset: Int) {
        starts.removeSubrange(upperBound(offset)...)
        scanned = min(scanned, offset)
    }

    /// The 0-based line `offset` is on.
    mutating func line(at offset: Int, in string: NSString) -> Int {
        scan(string, to: min(offset, string.length))
        return upperBound(offset) - 1
    }

    /// Where 0-based line `line` starts; nil past the last line.
    mutating func start(ofLine line: Int, in string: NSString) -> Int? {
        while starts.count <= line, scanned < string.length { scan(string, to: scanned + 1) }
        return line < starts.count ? starts[line] : nil
    }

    /// The offset at 0-based `line` and `column`, no further than the text's end; nil past the last line.
    mutating func offset(line: Int, column: Int, in string: NSString) -> Int? {
        start(ofLine: line, in: string).map { min($0 + column, string.length) }
    }

    /// The 1-based line and column of `offset`.
    mutating func position(of offset: Int, in string: NSString) -> (line: Int, column: Int) {
        let line = line(at: offset, in: string)
        return (line + 1, offset - (start(ofLine: line, in: string) ?? 0) + 1)
    }

    private mutating func scan(_ string: NSString, to offset: Int) {
        while scanned < offset {
            let end = min(string.length, max(offset, scanned + 65_536)), from = scanned
            Self.eachBreak(in: string, NSRange(location: from, length: end - from)) { starts.append($0 + 1) }
            scanned = end
        }
    }

    /// Calls `found` with the offset of each \n in `range`. It uses memchr over the UTF-16 bytes, where a \n is 0A 00
    /// at an even byte, because a Swift loop over 3 MB took 100 ms in a debug build.
    static func eachBreak(in string: NSString, _ range: NSRange, _ found: (Int) -> Void) {
        var chars = [unichar](repeating: 0, count: range.length)
        string.getCharacters(&chars, range: range)
        chars.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var next = base
            while let hit = memchr(next, 10, raw.count - (next - base)) {
                let at = UnsafeRawPointer(hit) - base
                if at % 2 == 0, raw[at + 1] == 0 { found(range.location + at / 2) }
                next = UnsafeRawPointer(hit) + 1
            }
        }
    }

    /// How many line breaks `string` has.
    static func breaks(in string: NSString) -> Int {
        var count = 0, at = 0
        while at < string.length {
            let len = min(1 << 20, string.length - at)
            eachBreak(in: string, NSRange(location: at, length: len)) { _ in count += 1 }
            at += len
        }
        return count
    }

    /// The first index whose line start is past `offset`.
    private func upperBound(_ offset: Int) -> Int { starts.partitionPoint { $0 <= offset } }
}

/// The line numbers beside the text, in the editor's colors, with the current line's brighter. A chevron shows where a
/// block folds (always on a folded one, and on the others while the pointer is over the gutter), and a click on it
/// folds or opens the block.
final class LineNumbers: NSRulerView {
    private weak var editor: CodeEditor?
    var color = NSColor.secondaryLabelColor, current = NSColor.labelColor, background = NSColor.textBackgroundColor
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    /// The line under the pointer (its first character). Its chevron sits on the hover grey, so it reads as a button.
    /// The grey fades in on the line the pointer came to, and out when the pointer leaves the gutter, as a control's.
    private var hoverLine: Int? {
        didSet {
            guard hoverLine != oldValue else { return }
            if let hoverLine {
                plateLine = hoverLine
                plateFill = 0
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.duration(Motion.fast)
                animator().plateFill = hoverLine == nil ? 0 : 1
            }
        }
    }
    /// The line whose change bar is under the pointer. The bar gets the hover grey and says what a click does, and the
    /// chevron then has none, because the click goes to the bar.
    private var barLine: Int? {
        didSet {
            guard barLine != oldValue else { return }
            toolTip = barLine == nil ? nil : String(localized: "Show Change")
            needsDisplay = true
        }
    }
    /// The line whose chevron has the grey, and how far it has faded in (the animator steps it).
    private var plateLine: Int?
    @objc private dynamic var plateFill: CGFloat = 0 { didSet { needsDisplay = true } }
    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "plateFill" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }
    private static let chevron: CGFloat = 14
    private static let barInset: CGFloat = 1, barWidth: CGFloat = 3, barHit: CGFloat = 8

    init(_ editor: CodeEditor, in scroll: NSScrollView) {
        self.editor = editor
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor.textView
        // Otherwise its background covered the text, because views don't clip by default since macOS 14.
        clipsToBounds = true
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    required init(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        hoverLine = nil
        barLine = nil
    }
    override func mouseMoved(with event: NSEvent) {
        let line = lineStart(at: event)
        barLine = line.flatMap { changeLine(at: event, start: $0) }
        hoverLine = barLine == nil ? line?.location : nil
    }
    /// The change bars are only drawn, so VoiceOver hears how many there are as the gutter's value.
    override func accessibilityValue() -> Any? {
        guard let count = editor?.changeMarks.count, count > 0 else { return nil }
        return String(localized: "\(count) changes")
    }

    /// Makes the gutter wide enough for the last line's number, three digits at least, and the chevrons.
    func fit(lines: Int) {
        let digits = max(3, String(lines).count)
        let width =
            ceil(CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width) + 12 + Self.chevron
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    /// The editor's own font, so the numbers line up with its lines.
    private var font: NSFont { editor?.textView.font ?? .monospacedDigitSystemFont(ofSize: 13, weight: .regular) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        background.setFill()
        rect.fill()
        guard let editor, let lm = editor.textView.layoutManager, let tc = editor.textView.textContainer else { return }
        let tv = editor.textView, string = tv.string as NSString
        let visible = tv.characters(in: tv.visibleRect)
        let caretLine = editor.lineIndex.line(at: tv.selectedRange().location, in: string)
        var number = editor.lineIndex.line(at: visible.location, in: string)
        let y0 = convert(NSPoint.zero, from: tv).y + tv.textContainerOrigin.y
        let font = self.font
        // A line with room under it for a suggestion's gray text keeps its number on its own row.
        let row = lm.defaultLineHeight(for: font) + CodeEditor.lineExtra
        func draw(_ number: Int, at frag: NSRect, start: Int) {
            if let mark = editor.changeMark(onLine: number) {
                let hovered = barLine.map { mark.lines.contains($0) } == true
                drawChange(mark, y: y0 + frag.minY, height: rowsHeight(of: start, first: frag), hovered: hovered)
            }
            let text = NSAttributedString(
                string: "\(number + 1)",
                attributes: [.font: font, .foregroundColor: numberColor(number, caret: caretLine)])
            let size = text.size()
            text.draw(
                at: NSPoint(
                    x: ruleThickness - Self.chevron - size.width - 4,
                    y: y0 + frag.minY + (min(frag.height, row) - size.height) / 2))
            let line = string.lineRange(for: NSRange(location: start, length: 0))
            let folded = tv.folds.fold(at: MultiCursor.lineEnd(string, start)) != nil
            guard folded || (hovering && editor.foldRegion(line, in: string) != nil) else { return }
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.62, weight: Metrics.iconWeight)
                .applying(.init(paletteColors: [color]))
            guard let img = NSImage.symbol(folded ? "chevron.right" : "chevron.down").withSymbolConfiguration(config)
            else { return }
            let at = NSPoint(
                x: ruleThickness - Self.chevron + (Self.chevron - img.size.width) / 2 - 2,
                y: y0 + frag.minY + (frag.height - img.size.height) / 2)
            if line.location == plateLine, plateFill > 0 {
                let side = max(img.size.width, img.size.height) + Metrics.gap
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(plateFill)
                NSColor.fillHover.setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: at.x + img.size.width / 2 - side / 2, y: at.y + img.size.height / 2 - side / 2, width: side,
                        height: side),
                    xRadius: Metrics.radiusXS, yRadius: Metrics.radiusXS
                ).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            img.draw(at: at, from: .zero, operation: .sourceOver, fraction: 1)
        }
        while let start = editor.lineIndex.start(ofLine: number, in: string), start < string.length,
            start <= NSMaxRange(visible)
        {
            if let fold = tv.folds.fold(at: start) {   // folded away, so go on after the fold
                number = editor.lineIndex.line(at: NSMaxRange(fold), in: string) + 1
                continue
            }
            draw(
                number, at: lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil),
                start: start)
            number += 1
        }
        if !lm.extraLineFragmentRect.isEmpty, editor.lineIndex.start(ofLine: number, in: string) == string.length {
            draw(number, at: lm.extraLineFragmentRect, start: string.length)
        }
    }

    private func numberColor(_ line: Int, caret: Int) -> NSColor {
        if let isError = editor?.problemLines[line] { return isError ? .textRed : .textOrange }
        return line == caret ? current : color
    }

    /// The height of a wrapped line's rows, so its bar runs along all of them.
    private func rowsHeight(of start: Int, first frag: NSRect) -> CGFloat {
        guard let editor, let lm = editor.textView.layoutManager, let tc = editor.textView.textContainer else {
            return frag.height
        }
        let string = editor.textView.string as NSString
        guard start < string.length else { return frag.height }
        var line = string.lineRange(for: NSRange(location: start, length: 0))
        // On the last line, the line break would count the row under it.
        if string.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        guard line.length > 0 else { return frag.height }
        return lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: line, actualCharacterRange: nil), in: tc)
            .height
    }

    private func drawChange(_ mark: CodeEditor.ChangeMark, y: CGFloat, height: CGFloat, hovered: Bool) {
        // Square, as the bar is, because each of a change's lines draws its own piece of it.
        if hovered {
            NSColor.fillHover.setFill()
            (mark.kind == .removed
                ? NSRect(x: 0, y: y - Self.barHit / 2, width: Self.barHit, height: Self.barHit)
                : NSRect(x: 0, y: y, width: Self.barHit, height: height)).fill()
        }
        switch mark.kind {
        case .added: NSColor.textGreen.setFill()
        case .changed: NSColor.textOrange.setFill()
        case .removed: NSColor.textRed.setFill()
        }
        guard mark.kind == .removed else {
            NSRect(x: Self.barInset, y: y, width: Self.barWidth, height: height).fill()
            return
        }
        // No line is left of it, so a wedge points into the gap above this line.
        let wedge = NSBezierPath()
        wedge.move(to: NSPoint(x: 0, y: y - 3))
        wedge.line(to: NSPoint(x: 5, y: y))
        wedge.line(to: NSPoint(x: 0, y: y + 3))
        wedge.close()
        wedge.fill()
    }

    /// A click on a line's chevron (anywhere on the gutter beside a foldable line) folds or opens its block. At the far
    /// left, on a change's bar, it shows that change.
    override func mouseDown(with event: NSEvent) {
        guard let editor, let line = lineStart(at: event) else { return }
        if let number = changeLine(at: event, start: line), let mark = editor.changeMark(onLine: number) {
            let clicked = convert(event.locationInWindow, from: nil).y
            editor.onChangeMark?(
                mark, NSRect(x: 0, y: clicked - Self.barHit / 2, width: Self.barHit, height: Self.barHit), self)
            return
        }
        editor.toggleFold(line: line)
    }

    /// The 0-based number of the line starting at `start`, when the pointer is on its change bar at the far left.
    private func changeLine(at event: NSEvent, start: NSRange) -> Int? {
        guard let editor, convert(event.locationInWindow, from: nil).x <= Self.barHit else { return nil }
        let number = editor.lineIndex.line(at: start.location, in: editor.textView.string as NSString)
        return editor.changeMark(onLine: number) != nil ? number : nil
    }

    /// The line beside the pointer.
    private func lineStart(at event: NSEvent) -> NSRange? {
        guard let editor, let lm = editor.textView.layoutManager, let tc = editor.textView.textContainer else {
            return nil
        }
        let tv = editor.textView, string = tv.string as NSString
        let point = tv.convert(event.locationInWindow, from: nil)
        let index = lm.characterIndex(
            for: NSPoint(x: 0, y: point.y - tv.textContainerOrigin.y), in: tc,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return index < string.length ? string.lineRange(for: NSRange(location: index, length: 0)) : nil
    }
}
