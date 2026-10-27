import AppKit

/// Where lines start, found only as far as asked and forgotten past an edit: a 5 MB file's line numbers without a scan
/// per keystroke or per frame.
struct LineIndex {
    private(set) var starts = [0]
    /// Every line break before this offset is in `starts`.
    private var scanned = 0

    /// The text changed from `offset` on.
    mutating func invalidate(from offset: Int) {
        starts.removeSubrange(upperBound(offset)...)
        scanned = min(scanned, offset)
    }

    /// The 0-based line `i` is on.
    mutating func line(at i: Int, in s: NSString) -> Int {
        scan(s, to: min(i, s.length))
        return upperBound(i) - 1
    }

    /// Where 0-based line `n` starts; nil past the last line.
    mutating func start(ofLine n: Int, in s: NSString) -> Int? {
        while starts.count <= n, scanned < s.length { scan(s, to: scanned + 1) }
        return n < starts.count ? starts[n] : nil
    }

    private mutating func scan(_ s: NSString, to i: Int) {
        while scanned < i {
            let end = min(s.length, max(i, scanned + 65_536)), from = scanned
            Self.eachBreak(in: s, NSRange(location: from, length: end - from)) { starts.append($0 + 1) }
            scanned = end
        }
    }

    /// Calls `found` with the offset of each \n in `range`: memchr over the UTF-16 bytes, a \n being 0A 00 at an even
    /// byte (a Swift loop over 3 MB took 100 ms in a debug build).
    static func eachBreak(in s: NSString, _ range: NSRange, _ found: (Int) -> Void) {
        var chars = [unichar](repeating: 0, count: range.length)
        s.getCharacters(&chars, range: range)
        chars.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var p = base
            while let hit = memchr(p, 10, raw.count - (p - base)) {
                let at = UnsafeRawPointer(hit) - base
                if at % 2 == 0, raw[at + 1] == 0 { found(range.location + at / 2) }
                p = UnsafeRawPointer(hit) + 1
            }
        }
    }

    /// How many line breaks `s` has.
    static func breaks(in s: NSString) -> Int {
        var n = 0, at = 0
        while at < s.length {
            let len = min(1 << 20, s.length - at)
            eachBreak(in: s, NSRange(location: at, length: len)) { _ in n += 1 }
            at += len
        }
        return n
    }

    /// The first index whose start is past `i`.
    private func upperBound(_ i: Int) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi { let mid = (lo + hi) / 2; if starts[mid] <= i { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}

/// The line numbers beside the text, the editor's colors, the current line's brighter.
final class LineNumbers: NSRulerView {
    private weak var editor: CodeEditor?
    var color = NSColor.secondaryLabelColor, current = NSColor.labelColor, background = NSColor.textBackgroundColor

    init(_ editor: CodeEditor, in scroll: NSScrollView) {
        self.editor = editor
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor.textView
        clipsToBounds = true   // its background covered the text otherwise (views don't clip by default since macOS 14)
    }

    required init(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    /// Wide enough for the last line's number, three digits at least.
    func fit(lines: Int) {
        let digits = max(3, String(lines).count)
        let width = ceil(CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width) + 20
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    private var font: NSFont { .monospacedDigitSystemFont(ofSize: editor?.textView.font?.pointSize ?? 13, weight: .regular) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        background.setFill()
        rect.fill()
        guard let editor, let lm = editor.textView.layoutManager, let tc = editor.textView.textContainer else { return }
        let tv = editor.textView, s = tv.string as NSString
        let visible = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc), actualGlyphRange: nil)
        let caretLine = editor.lineIndex.line(at: tv.selectedRange().location, in: s)
        var n = editor.lineIndex.line(at: visible.location, in: s)
        let y0 = convert(NSPoint.zero, from: tv).y + tv.textContainerOrigin.y
        let font = self.font
        func draw(_ n: Int, at frag: NSRect) {
            let text = NSAttributedString(string: "\(n + 1)", attributes: [.font: font, .foregroundColor: n == caretLine ? current : color])
            let size = text.size()
            text.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y0 + frag.minY + (frag.height - size.height) / 2))
        }
        while let start = editor.lineIndex.start(ofLine: n, in: s), start < s.length, start <= NSMaxRange(visible) {
            draw(n, at: lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil))
            n += 1
        }
        if !lm.extraLineFragmentRect.isEmpty, editor.lineIndex.start(ofLine: n, in: s) == s.length { draw(n, at: lm.extraLineFragmentRect) }
    }
}
