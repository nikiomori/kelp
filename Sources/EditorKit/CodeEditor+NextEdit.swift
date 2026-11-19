import AppKit
import DesignKit

/// The next edit offered (NextEdit): asked for once typing pauses and no gray text comes, shown where it goes (what
/// goes struck through in red, what comes in green), with "⇥ to line N" at the cursor's line when that's elsewhere.
/// ⇥ goes there, ⇥ again takes it; Esc, any edit or a cursor gone far drops it.
extension CodeEditor {
    /// Asks the app for the cursor's lines as the model would write them next; nil means none is asked for.
    public var nextEditProvider: ((NextEdit.Ask) async -> String?)? {
        get { nextEdit.provider }
        set {
            nextEdit.provider = newValue
            if newValue == nil {
                dropNextEdit()
                nextEdit.base = nil
            }
        }
    }

    /// Told when an edit is offered (true) and when it goes, taken or not (false).
    public var onNextEdit: ((_ offered: Bool) -> Void)? {
        get { nextEdit.onEvent }
        set { nextEdit.onEvent = newValue }
    }

    /// Whether an edit is offered now.
    public var isOfferingEdit: Bool { nextEdit.shown != nil }

    /// Before an edit, with the old text still there. One near the last (on their lines or next to them, within a
    /// minute) adds to the edit being made; one elsewhere starts a new edit, and the text as it is now is what the
    /// model is shown as before it.
    func nextEditWillReplace(_ range: NSRange, with text: String) {
        dropNextEdit()
        guard nextEdit.provider != nil else { return }
        let string = textView.string as NSString
        let first = lineIndex.line(at: range.location, in: string)
        let last = lineIndex.line(at: NSMaxRange(range), in: string)
        let added = Self.breaks(text) - Self.breaks(string.substring(with: range))
        let region = nextEdit.region
        if nextEdit.base != nil, Date().timeIntervalSince(nextEdit.at) < 60, first <= region.upperBound + 1,
            last + 1 >= region.lowerBound
        {
            let low = min(first, region.lowerBound)
            nextEdit.region = low...max(low, max(region.upperBound, last) + added)
        } else {
            let now = textView.string
            if let base = nextEdit.base, let made = NextEdit.change(from: NextEdit.lines(base), to: NextEdit.lines(now))
            {
                nextEdit.earlier = Array((nextEdit.earlier + [made]).suffix(2))
            }
            nextEdit.base = now
            nextEdit.region = first...max(first, last + added)
        }
        nextEdit.at = Date()
    }

    private static func breaks(_ text: String) -> Int { text.utf16.lazy.filter { $0 == 10 }.count }

    /// Asks for the next edit around the only cursor, when one was made in the last minute and nothing else goes on.
    func askNextEdit() {
        let tv = textView, at = tv.selectedRange()
        guard let provider = nextEdit.provider, let base = nextEdit.base, Date().timeIntervalSince(nextEdit.at) < 60,
            tv.isEditable, tv.cursors.count == 1, at.length == 0, completion.list?.isOpen != true,
            !completion.snippetActive, !tv.hasMarkedText(), tv.window?.firstResponder === tv
        else { return }
        let string = tv.string as NSString
        guard
            let ask = NextEdit.ask(
                base: base, now: tv.string, line: lineIndex.line(at: at.location, in: string),
                earlier: nextEdit.earlier)
        else { return }
        let edits = suggestion.edits
        nextEdit.task?.cancel()
        nextEdit.task = Task { [weak self] in
            // A cursor moved meanwhile asks no more: the answer would take its next ⇥ back to where it was.
            guard let answer = await provider(ask), !Task.isCancelled, let self, suggestion.edits == edits,
                textView.selectedRange() == at, suggestion.shown == nil, completion.list?.isOpen != true,
                let proposal = NextEdit.proposal(answer, for: ask)
            else { return }
            let (range, text) = NextEdit.replacement(
                proposal, in: textView.string as NSString, lineBreak: textView.lineBreak)
            nextEdit.shown = .init(proposal: proposal, range: range, text: text)
            drawNextEdit()
            nextEdit.onEvent?(true)
        }
    }

    /// Takes ⇥ and Esc while an edit is offered. Returns true when it took the key.
    func handleNextEdit(_ command: Selector) -> Bool {
        guard let shown = nextEdit.shown else { return false }
        switch command {
        case #selector(NSResponder.insertTab(_:)):
            if shown.proposal.reach.contains(cursorLine) { take(shown) } else { goTo(shown) }
        case #selector(NSResponder.cancelOperation(_:)): dropNextEdit()
        default: return false
        }
        return true
    }

    /// The cursor moved: the pill follows it, and an edit far from it goes.
    func nextEditSelectionChanged() {
        guard let shown = nextEdit.shown else { return }
        let line = cursorLine, reach = shown.proposal.reach
        if line < reach.lowerBound - 2 * NextEdit.half || line >= reach.upperBound + 2 * NextEdit.half {
            return dropNextEdit()
        }
        placePill()
    }

    func dropNextEdit() {
        nextEdit.task?.cancel()
        nextEdit.task = nil
        guard nextEdit.shown != nil else { return }
        nextEdit.shown = nil
        unstrike()
        nextEdit.view = placeGhost(nextEdit.view, nil)
        nextEdit.pill?.isHidden = true
        nextEdit.onEvent?(false)
    }

    private var cursorLine: Int {
        lineIndex.line(at: textView.selectedRange().location, in: textView.string as NSString)
    }

    /// Puts the cursor where the edit starts: the first character a line changes, or the end of the line above the
    /// lines it adds.
    private func goTo(_ shown: NextEditState.Shown) {
        let p = shown.proposal
        var at = shown.range.location
        if p.old.count == 1, p.new.count == 1 {
            at += NextEdit.inline(p.old[0], p.new[0]).gone.location
        } else if p.old.isEmpty {
            at = max(0, at - 1)
        }
        textView.setSelectedRange(NSRange(location: at, length: 0))
        textView.scrollRangeToVisible(shown.range)
    }

    private func take(_ shown: NextEditState.Shown) {
        // The caret goes after the last line put in, before its line break.
        let text = shown.text, end = (text as NSString).length
        let caret = text.hasSuffix("\r\n") ? end - 2 : text.hasSuffix("\n") ? end - 1 : end
        textView.replace([shown.range], with: [text], caret: [caret])
    }

    private func drawNextEdit() {
        guard let shown = nextEdit.shown else { return }
        let p = shown.proposal, range = shown.range, string = textView.string as NSString
        let green = NSColor.textGreen, tint = NSColor.systemGreen.withAlphaComponent(0.16)
        if p.old.count == 1, p.new.count == 1 {
            let (gone, put) = NextEdit.inline(p.old[0], p.new[0])
            strike(NSRange(location: range.location + gone.location, length: gone.length))
            let ghost = put.isEmpty ? nil : (put, range.location + NSMaxRange(gone))
            nextEdit.view = placeGhost(nextEdit.view, ghost, color: green, tint: tint)
        } else {
            // What comes goes under the last line it replaces, or under the line above where it only adds.
            let anchor =
                p.old.isEmpty
                ? range.location - 1 : MultiCursor.lineEnd(string, max(range.location, NSMaxRange(range) - 1))
            // No tint: the last line's is as tall as the room under it, where the lines that come show.
            if !p.old.isEmpty {
                strike(NSRange(location: range.location, length: anchor - range.location), tint: false)
            }
            let ghost = p.new.isEmpty ? nil : ("\n" + p.new.joined(separator: "\n"), anchor)
            nextEdit.view = placeGhost(nextEdit.view, ghost, color: green, tint: tint)
        }
        placePill()
    }

    private func strike(_ range: NSRange, tint: Bool = true) {
        guard range.length > 0, let lm = textView.layoutManager else { return }
        var marks: [NSAttributedString.Key: Any] = [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor.textRed
        ]
        if tint { marks[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.12) }
        lm.addTemporaryAttributes(marks, forCharacterRange: range)
        nextEdit.struck = range
    }

    private func unstrike() {
        guard let range = nextEdit.struck, let lm = textView.layoutManager else { return }
        nextEdit.struck = nil
        let inside = NSIntersectionRange(range, NSRange(location: 0, length: textView.length))
        for key in [NSAttributedString.Key.strikethroughStyle, .strikethroughColor, .backgroundColor] {
            lm.removeTemporaryAttribute(key, forCharacterRange: inside)
        }
        markBrackets()   // a bracket's mark inside went with the tint
    }

    /// "⇥ to line N" after the cursor's line, while the edit offered is on another.
    private func placePill() {
        let tv = textView
        guard let shown = nextEdit.shown, !shown.proposal.reach.contains(cursorLine) else {
            nextEdit.pill?.isHidden = true
            return
        }
        let pill = nextEdit.pill ?? JumpPill()
        if pill.superview !== tv { tv.addSubview(pill) }
        nextEdit.pill = pill
        pill.label = String(localized: "to line \(shown.proposal.lines.lowerBound + 1)")
        let string = tv.string as NSString
        let end = tv.caretRect(at: MultiCursor.lineEnd(string, tv.selectedRange().location))
        let size = pill.fitting
        pill.frame = NSRect(x: end.maxX + 10, y: end.midY - size.height / 2, width: size.width, height: size.height)
        pill.isHidden = false
    }
}

/// What the next edit keeps between keys. Only CodeEditor+NextEdit changes it.
struct NextEditState {
    struct Shown {
        let proposal: NextEdit.Proposal
        /// The whole lines taking it replaces, and with what.
        let range: NSRange, text: String
    }
    var provider: ((NextEdit.Ask) async -> String?)?
    var onEvent: ((Bool) -> Void)?
    var task: Task<Void, Never>?
    /// The text before the edit being made, the lines that edit spans now, and when it was last added to.
    var base: String?, region = 0...0, at = Date.distantPast
    /// The two edits made before it.
    var earlier: [NextEdit.Change] = []
    var shown: Shown?
    var struck: NSRange?
    var view: GhostTextView?, pill: JumpPill?
}

/// "⇥ to line 14": a key cap and where it goes, at the end of the cursor's line.
final class JumpPill: NSView {
    var label = "" { didSet { needsDisplay = true } }
    private static let height: CGFloat = 18, key: CGFloat = 18
    private let font = NSFont.ui(TextSize.caption)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var fitting: NSSize {
        let width = (label as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(2 + Self.key + 6 + width + 9), height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2)
        NSColor.controlBackgroundColor.setFill()
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.stroke()
        let cap = NSRect(x: 2.5, y: 2.5, width: Self.key, height: Self.height - 5)
        let capPath = NSBezierPath(roundedRect: cap, xRadius: Metrics.radiusXS, yRadius: Metrics.radiusXS)
        NSColor.separatorColor.setStroke()
        capPath.stroke()
        let ink: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let tab = "⇥" as NSString, tabSize = tab.size(withAttributes: ink)
        tab.draw(at: NSPoint(x: cap.midX - tabSize.width / 2, y: cap.midY - tabSize.height / 2), withAttributes: ink)
        let text = label as NSString, textSize = text.size(withAttributes: ink)
        text.draw(at: NSPoint(x: cap.maxX + 6, y: bounds.midY - textSize.height / 2), withAttributes: ink)
    }
}
