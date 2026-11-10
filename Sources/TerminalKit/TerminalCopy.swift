import AppKit
import Core

/// What a paste types into a terminal: copied files as their paths, else the text, else an image (a screenshot,
/// "Copy Image") saved as a PNG, as its path — agents attach an image they're given by path.
public enum TerminalPaste {
    public static func text(from pb: NSPasteboard) -> String? {
        let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return paths(files.map(\.path)) }
        if let text = pb.string(forType: .string) { return text }
        return savedImage(pb).map { paths([$0]) }
    }

    public static func paths(_ list: [String]) -> String {
        list.map(ShellQuote.escapedPath).joined(separator: " ") + " "
    }

    /// The MIME types a program that takes paste events (Kitty's mode 5522: omp) is offered instead of the text, from
    /// the declared types alone: "text/plain" when a paste would type something, and the image when it would be one.
    public static func mimes(_ pb: NSPasteboard) -> [String] {
        let types = pb.types ?? []
        if types.contains(.fileURL) || types.contains(.string) { return ["text/plain"] }
        return NSImage.canInit(with: pb) ? ["text/plain", "image/png"] : []
    }

    /// What a program asked for by MIME type: "text/plain" is what a paste types.
    public static func data(_ pb: NSPasteboard, mime: String) -> Data? {
        switch mime {
        case "text/plain": text(from: pb).map { Data($0.utf8) }
        case "image/png": png(pb)
        default: nil
        }
    }

    static func png(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = NSImage(pasteboard: pb)?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// The pasteboard's image as a PNG in the temporary folder.
    public static func savedImage(_ pb: NSPasteboard) -> String? {
        guard let png = png(pb) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kelp-\(UUID().uuidString.prefix(8)).png")
        return (try? png.write(to: url)) == nil ? nil : url.path
    }
}

/// Text as it should leave a terminal: what TUIs paint around it (box borders, an agent's indented gutter, padding to the
/// right edge, the line breaks it wrapped its text with) isn't part of it.
public enum TerminalCopy {
    static let borders: Set<Character> = ["│", "┃", "║", "▏", "▕"]

    /// `column`: where the first line starts on screen (a selection that begins past the gutter); `columns`: the row
    /// width, to join rows a program wrapped (none without it).
    public static func clean(_ text: String, from column: Int = 0, columns: Int? = nil) -> String {
        var lines = text.components(separatedBy: "\n").map { trimRight(withoutQuoteBar($0)) }
        // A frame's sides: "│ text │" → "text", when every non-empty line has one.
        let full = lines.filter { !$0.isEmpty }
        if !full.isEmpty, full.allSatisfy({ borders.contains($0.trimmingCharacters(in: .whitespaces).first ?? " ") }) {
            lines = lines.map { line in
                var trimmed = Substring(line.drop { $0 == " " })
                if let first = trimmed.first, borders.contains(first) { trimmed = trimmed.dropFirst() }
                if let last = trimmed.last, borders.contains(last) { trimmed = trimmed.dropLast() }
                return trimRight(String(trimmed))
            }
            return dedent(lines, by: indent(lines)).joined(separator: "\n")
        }
        // The first line as it sits on screen, so it lines up with the rows under it.
        lines[0] = String(repeating: " ", count: column) + lines[0]
        // The indent all lines share (Claude Code and Codex draw their text in a gutter, and wrap it themselves).
        let gutter = indent(lines)
        if let columns, gutter > 0 { lines = unwrap(lines, columns: columns) }
        lines = dedent(lines, by: gutter)
        lines[0] = String(lines[0].dropFirst(max(0, column - gutter)))
        return lines.joined(separator: "\n")
    }

    /// A quote's bar turned into the blank it is to the text: Claude Code draws a Markdown quote as a box with only its
    /// left side, and the column stays so its rows line up with the first one and join where they were wrapped. Only a bar
    /// alone: a row of block characters is a program's progress.
    static func withoutQuoteBar(_ line: String) -> String {
        let own = line.prefix(while: isBlank), rest = line.dropFirst(own.count)
        guard rest.first == "▎", rest.dropFirst().first.map(isBlank) ?? true else { return line }
        return own + " " + rest.dropFirst()
    }

    static func indent(_ lines: [String]) -> Int {
        lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min()
            ?? 0
    }
    static func dedent(_ lines: [String], by count: Int) -> [String] {
        count > 0 ? lines.map { String($0.dropFirst(min(count, $0.prefix { $0 == " " }.count))) } : lines
    }

    /// Rows joined back where a program broke its text at the right edge (Claude Code and Codex wrap before the terminal
    /// could, so a long command copies as several lines): a row goes on into the next when the next one's first word
    /// wouldn't have fit after it. A row that fills its width was broken inside a word, unless the next one starts
    /// further in — with the space that didn't fit.
    static func unwrap(_ lines: [String], columns: Int) -> [String] {
        var out: [String] = [], end = 0, lead = 0   // the last row's end column and indent
        for line in lines {
            let own = line.prefix(while: isBlank).count, text = line.dropFirst(own)
            let word = String(text.prefix { !isBlank($0) })
            if let last = out.last, end > 0, !word.isEmpty, end + 1 + width(word) > columns {
                out[out.count - 1] = last + (end >= columns && own <= lead ? "" : " ") + text
            } else {
                out.append(line)
            }
            end = text.isEmpty ? 0 : width(line)
            lead = own
        }
        return out
    }

    static func trimRight(_ line: String) -> String {
        var trimmed = Substring(line)
        while let last = trimmed.last, last == " " || last == "\t" || last == "\u{00A0}" {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }

    static let stops: Set<Character> = [
        " ", "\t", "\"", "'", "`", "(", ")", "[", "]", "{", "}", "<", ">", "|", "│", ","
    ]
    static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{00A0}"
    }

    /// The word around column `col` of a screen row: up to blanks, quotes and brackets, without sentence punctuation
    /// at its end. `start` is its first column and `width` the columns it covers (a wide character takes two).
    public static func word(in line: String, at col: Int) -> (text: String, start: Int, width: Int)? {
        guard let found = run(in: line, at: col) else { return nil }
        let text = trimPunctuation(found.text)
        return text.isEmpty ? nil : (text, found.start, width(text))
    }

    /// The word around column `col` of row `row`, with its parts on the rows it was wrapped onto — by the terminal, or
    /// by a program that breaks its own lines (Claude Code breaks a path longer than the row at the right edge): a word
    /// that ends its row at the edge (`columns`) goes on with the next row's first. `texts` is that joined word, then the
    /// row's own when they differ — a word that just filled its row isn't joined to the next row's first word.
    /// `start` and `width` are the row's own part.
    public static func wrappedWord(rows: (Int) -> String?, row: Int, at col: Int, columns: Int) -> (
        texts: [String], start: Int, width: Int
    )? {
        guard let line = rows(row), let own = word(in: line, at: col), let found = run(in: line, at: col) else {
            return nil
        }
        func atEdge(_ part: Run) -> Bool { part.last && part.start + width(part.text) >= columns }
        var text = found.text, cur = found, index = row
        while atEdge(cur), let next = rows(index + 1),
            let nextRun = run(in: next, at: width(String(next.prefix(while: isBlank))))
        {
            text += nextRun.text
            cur = nextRun
            index += 1
        }
        cur = found
        index = row
        while cur.first, let prev = rows(index - 1), let prevRun = run(in: prev, at: width(trimRight(prev)) - 1),
            atEdge(prevRun)
        {
            text = prevRun.text + text
            cur = prevRun
            index -= 1
        }
        let joined = trimPunctuation(text)
        return (joined == own.text ? [joined] : [joined, own.text], own.start, own.width)
    }

    /// The characters around column `col` up to stops: their text, first column, and whether they begin and end the row's text.
    typealias Run = (text: String, start: Int, first: Bool, last: Bool)
    static func run(in line: String, at col: Int) -> Run? {
        let chars = Array(line)
        var columns: [Int] = [], column = 0   // the column each character starts at
        for ch in chars {
            columns.append(column)
            column += cells(ch)
        }
        guard let index = columns.lastIndex(where: { $0 <= col }), col < column, !stops.contains(chars[index]) else {
            return nil
        }
        var lower = index, upper = index
        while lower > 0, !stops.contains(chars[lower - 1]) { lower -= 1 }
        while upper + 1 < chars.count, !stops.contains(chars[upper + 1]) { upper += 1 }
        return (
            String(chars[lower...upper]), columns[lower], chars[..<lower].allSatisfy(isBlank),
            chars[(upper + 1)...].allSatisfy(isBlank)
        )
    }

    static func trimPunctuation(_ text: String) -> String {
        var trimmed = text
        while let last = trimmed.last, ".:;!?".contains(last) { trimmed.removeLast() }
        return trimmed
    }

    static func width(_ text: String) -> Int { text.reduce(0) { $0 + cells($1) } }

    /// Terminal columns a character takes: two for East Asian wide characters and emoji, else one.
    /// Limit: a range table, not full UAX #11; ambiguous-width characters count as one.
    static func cells(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        if scalar.properties.isEmojiPresentation || character.unicodeScalars.contains("\u{FE0F}") { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
            0xAC00...0xD7A3,
            0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default: return 1
        }
    }
}

/// Where the scrollback is, along the right edge, while it moves (like an overlay scroller); it lets clicks through.
@MainActor
final class ScrollIndicator: NSView {
    private let knob = CALayer()
    private var hide: DispatchWorkItem?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        knob.cornerRadius = 3
        layer?.addSublayer(knob)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Rows between the view and the bottom: it changes when you scroll, not when output streams in at the bottom.
    private var fromBottom: Double?

    func show(total: Double, offset: Double, length: Double) {
        let now = total - length - offset
        defer { fromBottom = now }
        guard total > length, length > 0 else {
            alphaValue = 0
            return
        }
        guard let was = fromBottom, was != now else { return }
        let height = max(24, bounds.height * length / total)
        // offset 0 = the top of the scrollback
        let originY = (bounds.height - height) * (1 - offset / max(1, total - length))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            knob.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.frame = NSRect(x: 1, y: originY, width: 5, height: height)
        CATransaction.commit()
        alphaValue = 1
        hide?.cancel()
        let item = DispatchWorkItem { [weak self] in fadeOut(self) }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }
}

/// `view` fades away, at once under Reduce Motion (TerminalKit has no DesignKit: this is the app's `Motion.appear`).
@MainActor
private func fadeOut(_ view: NSView?) {
    NSAnimationContext.runAnimationGroup {
        $0.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3
        view?.animator().alphaValue = 0
    }
}

/// "120 × 40" in the middle of a terminal while it's resized, then gone.
@MainActor
final class SizeBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hide: DispatchWorkItem?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        isHidden = true
        alphaValue = 0
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func show(_ text: String, in area: NSRect) {
        label.stringValue = text
        let width = label.intrinsicContentSize.width + 28
        frame = NSRect(x: area.midX - width / 2, y: area.midY - 18, width: width, height: 36)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        }
        alphaValue = 1
        isHidden = false
        hide?.cancel()
        let item = DispatchWorkItem { [weak self] in fadeOut(self) }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }
}
