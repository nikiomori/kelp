import AppKit
import GhosttyKit

extension GhosttyTerminalView {
    /// A text area to Accessibility, as Terminal.app is: the screen is the value and the cursor the caret. Dictation apps
    /// (MacWhisper, Superwhisper…) paste only into a focused text field or area, VoiceOver reads the screen, and writing
    /// tools (Pretype) find an agent's input box by the caret. The identifier says it's a terminal: what's typed runs.
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityIdentifier() -> String { "terminal" }
    public override func accessibilityValue() -> Any? { screen().text }
    public override func accessibilityNumberOfCharacters() -> Int { (screen().text as NSString).length }
    public override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: accessibilityNumberOfCharacters()) }
    public override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: screen().caret, length: 0) }
    public override func accessibilitySelectedText() -> String? { "" }
    public override func accessibilityString(for range: NSRange) -> String? {
        let text = screen().text as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }
    /// The caret's cell is exact; anywhere else a character counts one cell and a line one row (wide characters and
    /// soft wraps put that off — only the caret's place matters to the tools that ask).
    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        let s = screen(), text = s.text as NSString
        guard let surface, range.location >= 0, range.location <= text.length else { return .zero }
        var cell = s.cursor ?? (0, 0)
        if range.location != s.caret || s.cursor == nil {
            let lines = text.substring(to: range.location).components(separatedBy: "\n")
            cell = (lines.count - 1, ((lines.last ?? "") as NSString).length)
        }
        let size = ghostty_surface_size(surface), scale = window?.backingScaleFactor ?? 2
        let cw = Double(size.cell_width_px) / scale, ch = Double(size.cell_height_px) / scale
        let r = NSRect(x: Self.padX + Double(cell.col) * cw, y: bounds.height - Self.padY - Double(cell.row + 1) * ch,
                       width: Double(range.length) * cw, height: ch)
        return window?.convertToScreen(convert(r, to: nil)) ?? r
    }

    /// The screen the program draws on (not the scrollback the view may be showing), the cursor's cell on it, and the
    /// caret: the length of the text up to the cursor, read the same way, so soft wraps and wide characters count as in
    /// the whole. ponytail: a cursor past its row's last written cell sits at that cell; Claude Code and shells write
    /// what's before their cursor, add a cell count if one doesn't.
    func screen() -> (text: String, caret: Int, cursor: (row: Int, col: Int)?) {
        let text = readText(GHOSTTY_POINT_ACTIVE), ns = text as NSString
        guard let c = cursorCell, let size = gridSize else { return (text, ns.length, nil) }
        let at = { (x: Int, y: Int) in ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(x), y: UInt32(y)) }
        var caret = 0
        if c.col > 0 {
            caret = (read(from: at(0, 0), to: at(c.col - 1, c.row)) as NSString).length
        } else if c.row > 0 {
            caret = (read(from: at(0, 0), to: at(size.cols - 1, c.row - 1)) as NSString).length
            if caret < ns.length, ns.character(at: caret) == 0x0A { caret += 1 }   // a row that ended, not one that wrapped
        }
        return (text, min(caret, ns.length), c)
    }

    /// Where Ghostty would put an IME's window: x inside the cursor's cell, y its bottom, in points from the top left.
    private var cursorCell: (row: Int, col: Int)? {
        guard let surface, let size = gridSize else { return nil }
        let s = ghostty_surface_size(surface), scale = window?.backingScaleFactor ?? 2
        let cw = Double(s.cell_width_px) / scale, ch = Double(s.cell_height_px) / scale
        guard cw > 0, ch > 0 else { return nil }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let col = Int((x - Self.padX) / cw + 0.25), row = Int(((y - Self.padY) / ch).rounded()) - 1
        return (0..<size.rows).contains(row) && (0..<size.cols).contains(col) ? (row, col) : nil
    }

    /// A key's echo moves the cursor; once it has, Accessibility hears that the text changed, as from a text view, so a
    /// tool reading the caret (Pretype) reads after the echo — which comes through the daemon and an agent's redraw.
    func watchEcho() {
        let from = cursorCell, until = Date() + 0.5
        echoWatch?.invalidate()
        echoWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            let done = MainActor.assumeIsolated { () -> Bool in   // a scheduled timer fires on the main run loop
                guard let self, Date() < until else { return true }
                guard let now = self.cursorCell, from.map({ $0 != now }) ?? true else { return false }
                NSAccessibility.post(element: self, notification: .valueChanged)
                NSAccessibility.post(element: self, notification: .selectedTextChanged)
                return true
            }
            if done { t.invalidate() }
        }
    }
}
