import AppKit
import Core
import DesignKit
import KelpKit

@MainActor
extension DiffViewController {

    func label(_ string: String, font: NSFont, color: NSColor = .labelColor, align: NSTextAlignment = .left)
        -> NSTextField
    {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        field.alignment = align
        field.lineBreakMode = .byClipping
        return field
    }
    private func tint(_ kind: DiffLine.Kind) -> NSColor? {
        kind == .add ? .diffAdded : kind == .del ? .diffRemoved : nil
    }
    func number(_ value: Int?, kind: DiffLine.Kind) -> NSTextField {
        lineCell(value.map(String.init) ?? "", font: font, color: .secondaryLabelColor, align: .right, fill: tint(kind))
    }
    /// The side of a side-by-side row that has no line, hatched as in VS Code.
    func filler() -> NSTextField { lineCell("", font: font, fill: Self.hatch) }
    func band(_ string: String) -> NSTextField {
        lineCell(string, font: .ui(TextSize.caption), color: .tertiaryLabelColor, fill: .diffGap)
    }

    /// The cells a line's row is made of. Each is a cell the table set aside when its row scrolled away, or else a new
    /// one. Every look a cell can have is set again here, so nothing of the line it showed before stays.
    static let lineCellId = NSUserInterfaceItemIdentifier("diff.line")
    static let codeCellId = NSUserInterfaceItemIdentifier("diff.code")
    private func lineCell(
        _ string: String, font: NSFont, color: NSColor = .labelColor, align: NSTextAlignment = .left, fill: NSColor?
    ) -> NSTextField {
        let field = table.makeView(withIdentifier: Self.lineCellId, owner: nil) as? NSTextField ?? label("", font: font)
        field.identifier = Self.lineCellId
        field.font = font
        field.textColor = color
        field.alignment = align
        field.stringValue = string
        Self.fill(field, fill)
        return field
    }
    private static func fill(_ field: NSTextField, _ color: NSColor?) {
        field.drawsBackground = color != nil
        field.backgroundColor = color ?? .clear
    }
    private func prefix(_ diffLine: DiffLine, marker: Bool) -> String {
        marker ? (diffLine.kind == .add ? "+ " : diffLine.kind == .del ? "- " : "  ") : " "
    }
    /// Lines wrap at words and go on under their own code's indent, not under the "+", indented at most half the
    /// column. Tab stops come every four columns, as `height(of:)` counts them. Limit: past 4000 characters (a
    /// minified file) at any character from the edge, which `height(of:)` can count without measuring every such line
    /// on each resize.
    private static func wrap(_ text: String, prefix: String, font: NSFont, width: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle(), space = metrics(font).char
        style.tabStops = []
        style.defaultTabInterval = 4 * space
        guard text.utf16.count <= 4000 else {
            style.lineBreakMode = .byCharWrapping
            return style
        }
        style.lineBreakMode = .byWordWrapping
        style.headIndent = min(CGFloat(indent(prefix, text)) * space, width / 2)
        return style
    }
    /// The number of columns before a line's code: the marker, then the line's leading spaces and tabs.
    nonisolated static func indent(_ prefix: String, _ text: String) -> Int {
        var column = prefix.count
        for c in text {
            if c == " " { column += 1 } else if c == "\t" { column = (column / 4 + 1) * 4 } else { break }
        }
        return column
    }
    /// The width a code column wraps its lines at.
    private func wrapWidth(marker: Bool) -> CGFloat {
        (table.tableColumn(withIdentifier: .init(marker ? "t" : "r"))?.width ?? 0) - 4
    }
    /// The part of a line a row shows. A text field takes seconds over a megabyte, and nobody reads that far along one
    /// line.
    static func shown(_ line: String) -> String { line.utf16.count > 20_000 ? String(line.prefix(20_000)) + "…" : line }
    func codeCell(_ diffLine: DiffLine, file f: Int, marker: Bool) -> NSTextField {
        let prefix = prefix(diffLine, marker: marker)
        let text = Self.shown(diffLine.text)
        let colored =
            DiffColors.key(f, diffLine).flatMap { syntax[$0] }.map {
                Highlighter.attributed(
                    prefix + text, spans: $0, from: prefix.utf16.count, font: font, colors: syntaxColors)
            }
            ?? NSAttributedString(
                string: prefix + text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let styled = NSMutableAttributedString(attributedString: colored)
        let key =
            diffLine.kind == .add
            ? diffLine.newLine.map { "\(f):a:\($0)" }
            : diffLine.kind == .del ? diffLine.oldLine.map { "\(f):d:\($0)" } : nil
        if let key, let wordRange = words[key], wordRange.length > 0,
            wordRange.location + wordRange.length <= (text as NSString).length
        {
            styled.addAttribute(
                .backgroundColor, value: diffLine.kind == .add ? NSColor.diffAddedWord : .diffRemovedWord,
                range: NSRange(location: wordRange.location + (prefix as NSString).length, length: wordRange.length))
        }
        markFound(styled, from: (prefix as NSString).length)
        // The text gets its own paragraph style, the same one `height(of:)` measures with, because the field's mode
        // doesn't reach an attributed string.
        styled.addAttribute(
            .paragraphStyle, value: Self.wrap(text, prefix: prefix, font: font, width: wrapWidth(marker: marker)),
            range: NSRange(location: 0, length: styled.length))
        let field =
            table.makeView(withIdentifier: Self.codeCellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithAttributedString: styled)
        field.identifier = Self.codeCellId
        field.maximumNumberOfLines = 0
        field.attributedStringValue = styled
        Self.fill(field, tint(diffLine.kind))
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === files, files.selectedRow >= 0 else { return }
        scroll(toFile: diffs[files.selectedRow].path)
    }
    /// Scrolls a file's band to the top, with its changes under it; returns false for a file this diff doesn't show.
    @discardableResult func scroll(toFile path: String) -> Bool {
        guard
            let index = rows.firstIndex(where: {
                if case .diff(.file(let filePath, _, _)) = $0 { filePath == path } else { false }
            })
        else { return false }
        table.scrollRowToVisible(min(index + 40, rows.count - 1))
        table.scrollRowToVisible(index)
        return true
    }

    /// Every diff controller made, for `reveal` to look through.
    static let reviews = NSHashTable<DiffViewController>.weakObjects()
    /// Called for a file clicked in Source Control. The review of that workspace on screen scrolls to the file, in
    /// place of a tab of its own. Returns false when no review shows it.
    static func reveal(_ path: String, worktree: String) -> Bool {
        reviews.allObjects.contains {
            $0.single == nil && $0.worktreeId == worktree && $0.view.window != nil && $0.scroll(toFile: path)
        }
    }

    // MARK: keyboard: ⌥↓/⌥↑ changes, ⌥⇧↓/⌥⇧↑ comments, ⌥→/⌥← files
    func key(_ event: NSEvent) -> Bool {
        if event.keyCode == 49, event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask) {
            return flipSelectedComment()
        }
        guard event.modifierFlags.contains(.option) else { return false }
        let comments = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 125:
            jump(1, comments: comments)
            return true
        case 126:
            jump(-1, comments: comments)
            return true
        case 124:
            files.selectRowIndexes([min(files.selectedRow + 1, diffs.count - 1)], byExtendingSelection: false)
            return true
        case 123:
            files.selectRowIndexes([max(files.selectedRow - 1, 0)], byExtendingSelection: false)
            return true
        default: return false
        }
    }
    @objc func nextChange() { jump(1) }
    @objc func prevChange() { jump(-1) }
    /// Jumps to the next (or previous) change or comment, and says which of how many it is.
    private func jump(_ dir: Int, comments: Bool = false) {
        let idx = rows.indices.filter {
            switch rows[$0] {
            case .comment: comments
            case .diff(.hunk): !comments
            default: false
            }
        }
        let cur = max(table.selectedRow, dir > 0 ? -1 : rows.count)
        guard let target = dir > 0 ? idx.first(where: { $0 > cur }) : idx.last(where: { $0 < cur }),
            let index = idx.firstIndex(of: target)
        else {
            NSSound.beep()
            return
        }
        position.stringValue =
            comments
            ? String(localized: "Comment \(index + 1) of \(idx.count)")
            : String(localized: "Change \(index + 1) of \(idx.count)")
        table.selectRowIndexes([target], byExtendingSelection: false)
        table.scrollRowToVisible(min(target + 8, rows.count - 1))
        table.scrollRowToVisible(target)
    }

    /// A file's row in the list: its letter and counts, and its folder only when the whole folder fits.
    func fileRow(_ row: Int) -> NSView {
        let diff = diffs[row]
        // The same letters and colours as in Source Control and Files. A long name loses its middle, not its counts.
        let (letter, color) = changes.first { $0.path == diff.path }?.badge ?? (" ", .labelColor)
        let short = NSMutableAttributedString(
            string: letter + "  ",
            attributes: [.font: NSFont.ui(TextSize.micro, weight: .bold), .foregroundColor: color])
        // The name, then its folder in grey, shown only when all of it fits, because a cut folder ("So…") says nothing.
        let dir = (diff.path as NSString).deletingLastPathComponent
        short.append(
            NSAttributedString(
                string: (diff.path as NSString).lastPathComponent + "  ",
                attributes: [.font: NSFont.ui(TextSize.row), .foregroundColor: NSColor.labelColor]))
        let full = NSMutableAttributedString(attributedString: short)
        if !dir.isEmpty {
            full.append(
                NSAttributedString(
                    string: "  " + dir,
                    attributes: [.font: NSFont.ui(TextSize.caption), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        for s in [short, full] {
            s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        }
        let nameLabel = FitLabel(labelWithAttributedString: short)
        nameLabel.full = full
        nameLabel.short = short
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let counts = NSTextField(
            labelWithAttributedString: GitFolders.changes(added: diff.additions, removed: diff.deletions))
        counts.setContentHuggingPriority(.required, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        if viewed.has(diff) { nameLabel.alphaValue = 0.55 }   // a file marked viewed is dimmed, as GitHub dims it
        let row = NSStackView(views: [nameLabel, counts])
        row.distribution = .fill   // the room goes to the name, and the counts stand in a column at the end
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        row.toolTip = diff.path
        return row
    }

    /// A file's band across the review: its icon, path and "+6 −2" on a grey fill, where one file's changes end and
    /// the next one's begin. Bold text alone on the page didn't mark that place.
    func fileBand(_ path: String, added a: Int, removed d: Int) -> NSView {
        let icon = NSImageView(image: app.fileIcons.image((path as NSString).lastPathComponent))
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let name = label(path, font: .ui(TextSize.row, weight: .semibold))
        name.lineBreakMode = .byTruncatingHead
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [
            icon, name, NSTextField(labelWithAttributedString: GitFolders.changes(added: a, removed: d))
        ])
        // A spacer takes the room between.
        if single == nil, let index = diffs.firstIndex(where: { $0.path == path }) {
            let gap = NSView()
            gap.setContentHuggingPriority(.init(1), for: .horizontal)
            stack.addArrangedSubview(gap)
            stack.addArrangedSubview(viewedBox(index))
        }
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.fillSelected.cgColor
        return stack
    }

    // MARK: long lines wrap

    /// The height of a row: its code wrapped at its column's width (a monospaced font fits so many characters on a
    /// line), and a file's band a little taller than a line. The line count of each line is cached by its text and
    /// width (`wraps`), so a reload or a scroll back measures none again.
    func height(of row: Int) -> CGFloat {
        let lineHeight = Self.lineHeight
        if rows.indices.contains(row), rows[row] == .draft { return Self.draftHeight }   // the comment card
        guard rows.indices.contains(row), case .diff(let diffRow) = rows[row] else { return lineHeight }
        func lines(_ line: DiffLine?, _ column: String, marker: Bool) -> Int {
            guard let line, let tableColumn = table.tableColumn(withIdentifier: .init(column)) else { return 1 }
            let width = tableColumn.width - 4, marked = prefix(line, marker: marker)
            return wraps.count(.init(text: line.text, prefix: marked, width: width, font: font)) {
                wrappedLines(line.text, prefix: marked, width: width)
            }
        }
        let lineCount =
            switch diffRow {
            case .line(_, let line): lines(line, "t", marker: true)
            case .pair(_, let left, let right): max(lines(left, "l", marker: false), lines(right, "r", marker: false))
            case .file: 0
            default: 1
            }
        return lineCount == 0 ? lineHeight + 6 : lineHeight + CGFloat(max(lineCount, 1) - 1) * (lineHeight - 4)
    }

    /// How many lines a line of code takes wrapped at `width`.
    private func wrappedLines(_ text: String, prefix marked: String, width: CGFloat) -> Int {
        let metrics = Self.metrics(font), fit = max(1, Int(width / metrics.char))
        let shown = Self.shown(text)
        let count = shown.reduce(2) { $0 + ($1 == "\t" ? 4 : 1) }   // with its "+ " marker; a tab counts about four
        guard count > fit else { return 1 }   // most lines fit, so they need no measuring
        guard shown.utf16.count <= Highlighter.maxColored else { return (count + fit - 1) / fit }
        // Word wrap leaves each line's end empty, so counting characters alone would undercount. The text system is
        // asked instead.
        let attributed = NSAttributedString(
            string: marked + text,
            attributes: [.font: font, .paragraphStyle: Self.wrap(text, prefix: marked, font: font, width: width)])
        let tall = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin
        ).height
        return max(1, Int((tall / metrics.line).rounded(.up)))
    }

    /// A character's width and a line's height in the code's font, measured once per font.
    private static var measured: (font: NSFont, char: CGFloat, line: CGFloat)?
    private static func metrics(_ font: NSFont) -> (char: CGFloat, line: CGFloat) {
        if let cached = measured, cached.font == font { return (cached.char, cached.line) }
        let char = max(1, ("0" as NSString).size(withAttributes: [.font: font]).width)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        measured = (font, char, line)
        return (char, line)
    }

    /// Called when the pane got wider or narrower, so lines wrap at the new width. While the pane is dragged, that
    /// happens once the drag ends (`DiffTable.onResized`), not on every frame of it.
    @objc func columnsResized(_ notification: Notification) {
        guard !table.inLiveResize else {
            table.resizedLive = true
            return
        }
        remeasure()
    }
    func remeasure() { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }

    /// A hunk's header row: where the hunk is, and Stage / Unstage (and Discard where the diff is the unstaged one).
    func hunkRow(file f: Int, hunk h: Int, header: String) -> NSView {
        let stack = NSStackView()
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.diffHunk.cgColor
        let where_ = label(header, font: .uiMono(TextSize.caption), color: .secondaryLabelColor)
        where_.lineBreakMode = .byTruncatingTail
        where_.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(where_)
        if let staged = hunksStaged(f) {
            // Buttons with names sit at the end of the hunk, as in Xcode's and GitHub Desktop's reviews.
            func button(_ title: String, _ selector: Selector) -> NSButton {
                let hunkButton = TextButton(title, target: self, action: selector)
                hunkButton.tag = f * 10000 + h
                return hunkButton
            }
            stack.addArrangedSubview(NSView())
            // Discard shows only where the hunks shown are the unstaged diff's, the one Discard works on.
            let unstaged =
                single.map { $0.source == .unstaged && $0.commit == nil } ?? (sourcePicked == .unstaged)
            if unstaged { stack.addArrangedSubview(button(String(localized: "Discard"), #selector(discardHunk(_:)))) }
            stack.addArrangedSubview(
                button(staged ? String(localized: "Unstage") : String(localized: "Stage"), #selector(hunkAction(_:))))
        }
        return stack
    }
}

/// How many lines each line of code wraps to, by its text and the width it wraps at (`height(of:)`).
struct WrapCounts {
    struct Key: Hashable {
        let text: String, prefix: String, width: CGFloat, font: NSFont
    }
    private var counts: [Key: Int] = [:]
    /// How many lines were measured, rather than found here.
    private(set) var measured = 0

    /// Limit: forgets everything past 50,000 counts (widths a pane was set to one after another), and measures again.
    mutating func count(_ key: Key, measure: () -> Int) -> Int {
        if let known = counts[key] { return known }
        if counts.count >= 50_000 { counts = [:] }
        measured += 1
        let lines = measure()
        counts[key] = lines
        return lines
    }
}

/// A file-list row. It shows its folder only when the whole folder fits (`full`), and else the name and counts alone
/// (`short`).
final class FitLabel: NSTextField {
    var full = NSAttributedString(), short = NSAttributedString()
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let fitting = full.size().width + 6 <= size.width ? full : short
        if !attributedStringValue.isEqual(to: fitting) { attributedStringValue = fitting }
    }
}
