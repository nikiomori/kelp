import AppKit
import DesignKit

/// What the language server says about the code under the pointer or around the cursor: a card with a symbol's signature
/// and documentation, and the signature of the call being typed. Each asked for when it's wanted, by the tab's providers.
extension CodeEditor {
    private static let rest = 0.5
    private static let cardWidth: CGFloat = 440, cardHeight: CGFloat = 260

    /// The pointer moved: if it rests on text, what's there is asked for.
    func pointerMoved(_ event: NSEvent) {
        hover.wait?.cancel()
        guard hoverProvider != nil else { return }
        let location = textView.characterIndexForInsertion(at: textView.convert(event.locationInWindow, from: nil))
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.showHover(at: location) } }   // queued on main below
        hover.wait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rest, execute: work)
    }

    /// The key's: what's at the cursor.
    public func showHoverAtCursor() { showHover(at: textView.selectedRange().location) }

    private func showHover(at location: Int) {
        let string = textView.string as NSString
        guard let hoverProvider, location < string.length, Self.word(at: location, in: string).length > 0,
            hover.shownAt != location
        else { return }
        let (line, column) = lineIndex.position(of: location, in: string)
        hover.shownAt = location
        Task { [weak self] in
            let text = await hoverProvider(line, column)
            guard let self, hover.shownAt == location, let text else { return }
            open(HoverCard(HoverText.attributed(text), width: Self.cardWidth, most: Self.cardHeight), at: location)
        }
    }

    private func open(_ card: NSViewController, at location: Int) {
        hover.card?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = card
        popover.show(relativeTo: textView.caretRect(at: location), of: textView, preferredEdge: .minY)
        hover.card = popover
    }

    /// A key went in. `(` and `,` ask for the call's signature, `)` ends it; the card goes, its text is out of date.
    func typed(_ key: String) {
        hover.card?.close()
        hover.shownAt = nil
        let before = textView.string as NSString, cursor = textView.selectedRange().location
        if key == ":" || key == ">", cursor >= 2,
            before.substring(with: NSRange(location: cursor - 2, length: 2)) == (key == ":" ? "::" : "->")
        {
            showCompletions()
        }
        if key == ")" {
            hover.signatureCard?.close()
        } else if key == "(" || key == "," || hover.signatureCard?.isShown == true {
            askSignature()
        }
    }

    /// Once keys pause: each ask first sends the language server the whole file, and every key asked twice (the key, the
    /// cursor moving), past the edits' own pause.
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
                .font, value: NSFont.monospacedSystemFont(ofSize: TextSize.of(12), weight: .bold), range: active)
        }
        let card = HoverCard(text, width: Self.cardWidth, most: Self.cardHeight)
        if let open = hover.signatureCard, open.isShown {
            open.contentViewController = card
            open.contentSize = card.preferredContentSize
            return
        }
        let popover = NSPopover()
        popover.behavior = .semitransient   // the keys stay in the text
        popover.animates = false
        popover.contentViewController = card
        popover.show(relativeTo: textView.caretRect(at: location), of: textView, preferredEdge: .minY)
        hover.signatureCard = popover
    }
}

/// A server's Markdown as text: code fences in the code font, the rest with its inline marks.
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
        let inset = Metrics.gapWide
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: inset, height: inset)
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

/// The hover and signature cards, and the waits before them; only this file changes it.
struct HoverState {
    fileprivate var wait: DispatchWorkItem?
    /// Where the card was asked for: a later answer for another place is dropped.
    fileprivate var shownAt: Int?
    fileprivate var card: NSPopover?
    fileprivate(set) var signatureCard: NSPopover?
    /// The signature asked once typing pauses (`askSignature`).
    fileprivate var signatureAsk: Task<Void, Never>?
}
