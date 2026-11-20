import AppKit
import DesignKit

/// What the language server says about the code under the pointer or around the cursor: a card with the problems
/// there, a symbol's signature and documentation, and the signature of the call being typed. Each is asked for, by
/// the tab's providers, when it's wanted.
extension CodeEditor {
    private static let cardWidth = Metrics.codeCardWidth, cardHeight: CGFloat = 260

    /// Called when the pointer moved over the text, or (nil) left it. Resting on a word asks for what's there, on
    /// HoverPopover's waits; off a word, or out of the text, the card goes unless the pointer went into it.
    func pointerMoved(_ event: NSEvent?) {
        guard hoverProvider != nil || !textView.problemMarks.isEmpty else { return }
        let string = textView.string as NSString
        guard let event else { return hover.card.closeSoon(unlessInside: true) }
        let location = textView.characterIndexForInsertion(at: textView.convert(event.locationInWindow, from: nil))
        guard location < string.length else { return hover.card.closeSoon(unlessInside: true) }
        let word = Self.word(at: location, in: string)
        guard word.length > 0 else { return hover.card.closeSoon(unlessInside: true) }
        if hover.card.isShown, hover.shownWord == word { return hover.card.cancel() }
        hover.card.open { [weak self] in await self?.showHover(at: location) }
    }

    /// For the key: shows what's at the cursor, at once.
    public func showHoverAtCursor() {
        hover.card.cancel()
        let location = textView.selectedRange().location
        Task { await showHover(at: location) }
    }

    private func showHover(at location: Int) async {
        let string = textView.string as NSString
        guard location < string.length else { return }
        let word = Self.word(at: location, in: string)
        guard word.length > 0 else { return }
        let marks = textView.problemMarks.filter { NSIntersectionRange($0.range, word).length > 0 }
        let (line, column) = lineIndex.position(of: location, in: string)
        // A later move cancels this ask (HoverPopover's task), so an answer for another place is dropped.
        let text = await hoverProvider?(line, column)
        guard !Task.isCancelled, text != nil || !marks.isEmpty else { return }
        hover.shownWord = word
        let shown = HoverText.problems(marks)
        if let text {
            if shown.length > 0 { shown.append(NSAttributedString(string: "\n\n")) }
            shown.append(HoverText.attributed(text))
        }
        let card = HoverCard(shown, width: Self.cardWidth, most: Self.cardHeight)
        hover.card.show(card, relativeTo: textView.caretRect(at: location), of: textView, edge: .minY)
    }

    /// Shows the signature `card` under the caret at `location`.
    private func popover(_ card: NSViewController, at location: Int) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient   // the keys stay in the text
        popover.animates = false
        popover.contentViewController = card
        popover.show(relativeTo: textView.caretRect(at: location), of: textView, preferredEdge: .minY)
        // Once up, it grows and shrinks to the next signature (`,`, another overload) instead of jumping, as
        // `HoverPopover` does.
        popover.animates = !Motion.reduced
        return popover
    }

    /// Called when a key went in. `(` and `,` ask for the call's signature, and `)` ends it. The card goes, because its
    /// text is out of date.
    func typed(_ key: String) {
        hover.card.close()
        let before = textView.string as NSString, cursor = textView.selectedRange().location
        // Typing what the gray text shows goes on through it; the list would take its keys.
        if isSuggesting { return }
        if key == "." { showCompletions() }
        if key == ":" || key == ">", cursor >= 2,
            before.substring(with: NSRange(location: cursor - 2, length: 2)) == (key == ":" ? "::" : "->")
        {
            showCompletions()
        }
        // A word was begun and there's a language server to ask: ask once per word, and the list narrows by itself
        // after that.
        if completionProvider != nil, completion.completing == nil, key.count == 1,
            key.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "_" }),
            Self.word(at: cursor, in: before).location == cursor - 1
        {
            showCompletions()
        }
        if key == ")" {
            hover.signatureCard?.close()
        } else if key == "(" || key == "," || hover.signatureCard?.isShown == true {
            askSignature()
        }
    }

    /// Asks for the signature once keys pause, because each ask first sends the language server the whole file, and
    /// every key asked twice (the key, the cursor moving), past the edits' own pause.
    func askSignature() {
        guard let signatureProvider else { return }
        hover.signatureAsk?.cancel()
        hover.signatureAsk = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let at = self?.textView.selectedRange().location, let (line, column) = self?.cursor else {
                return
            }
            let found = await signatureProvider(line, column)
            guard let self, textView.selectedRange().location == at else { return }
            guard let found else {
                hover.signatureCard?.close()
                return
            }
            showSignature(found.label, active: found.active, at: at)
        }
    }

    private func showSignature(_ label: String, active: NSRange?, at location: Int) {
        let text = NSMutableAttributedString(
            string: label, attributes: [.font: NSFont.uiMono(TextSize.row), .foregroundColor: NSColor.labelColor])
        if let active, NSMaxRange(active) <= text.length {
            text.addAttribute(
                .font, value: NSFont.uiMono(TextSize.row, weight: .medium), range: active)
        }
        let card = HoverCard(text, width: Self.cardWidth, most: Self.cardHeight)
        if let open = hover.signatureCard, open.isShown {
            open.contentViewController = card
            open.contentSize = card.preferredContentSize
            return
        }
        hover.signatureCard = popover(card, at: location)
    }
}

/// A server's Markdown as text: code fences in the code font, and the rest with its inline marks.
@MainActor
enum HoverText {
    static func attributed(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString(), body = NSFont.ui(TextSize.row), code = NSFont.uiMono(TextSize.row)
        var fenced = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                fenced.toggle()
                continue
            }
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(fenced ? NSAttributedString(string: line, attributes: [.font: code]) : inline(line, font: body))
        }
        out.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Each problem a line, as the status bar counts them: its sign and message, red for an error, orange for a
    /// warning.
    static func problems(_ marks: [EditorTextView.ProblemMark]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(), font = NSFont.ui(TextSize.row)
        for mark in marks {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            let line = NSMutableAttributedString()
            let label = mark.isError ? String(localized: "Error") : String(localized: "Warning")
            let image = NSImage.symbol(mark.isError ? "xmark.circle" : "exclamationmark.triangle", label)
            if let symbol = image.withSymbolConfiguration(.chrome(Metrics.iconSmall)) {
                let sign = NSTextAttachment()
                sign.image = symbol
                // On the text's middle: an attachment stands on the baseline otherwise.
                sign.bounds = NSRect(
                    origin: NSPoint(x: 0, y: (font.capHeight - symbol.size.height) / 2), size: symbol.size)
                line.append(NSAttributedString(attachment: sign))
                line.append(NSAttributedString(string: " "))
            }
            line.append(NSAttributedString(string: mark.message))
            line.addAttributes(
                [.font: font, .foregroundColor: mark.isError ? NSColor.textRed : .textOrange],
                range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        return out
    }

    private static func inline(_ line: String, font: NSFont) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: line, options: options) else {
            return NSAttributedString(string: line, attributes: [.font: font])
        }
        let out = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        out.addAttribute(.font, value: font, range: NSRange(location: 0, length: out.length))
        return out
    }
}

/// Text in a popover, as tall as it is up to `most`, then scrolling. It can be selected and copied.
@MainActor
final class HoverCard: NSViewController {
    private let text: NSAttributedString, width: CGFloat, most: CGFloat
    init(_ text: NSAttributedString, width: CGFloat, most: CGFloat) {
        self.text = text
        self.width = width
        self.most = most
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let inset = Metrics.inset   // a popover's edge to its content
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: inset, height: inset)
        tv.textContainer?.lineFragmentPadding = 0   // the inset alone, not 5 pt more on each side
        tv.textStorage?.setAttributedString(text)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        tc.size = NSSize(width: width - 2 * inset, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let needed = ceil(lm.usedRect(for: tc).height) + 2 * inset
        tv.frame.size.height = needed
        preferredContentSize = NSSize(width: width, height: min(needed, most))
    }
}

/// The hover and signature cards, and the waits before them. Only this file changes it.
@MainActor
struct HoverState {
    /// The card over code, with the waits and the closing every hover card has.
    fileprivate let card = HoverPopover()
    /// The word the shown card is about, so moving within it keeps the card.
    fileprivate var shownWord: NSRange?
    fileprivate(set) var signatureCard: NSPopover?
    /// The signature ask that runs once typing pauses (`askSignature`).
    fileprivate var signatureAsk: Task<Void, Never>?
}
