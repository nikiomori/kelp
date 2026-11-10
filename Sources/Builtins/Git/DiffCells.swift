import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

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
    private func tint(_ k: DiffLine.Kind) -> NSColor? { k == .add ? .diffAdded : k == .del ? .diffRemoved : nil }
    func number(_ value: Int?, kind: DiffLine.Kind) -> NSTextField {
        let field = label(value.map(String.init) ?? "", font: font, color: .secondaryLabelColor, align: .right)
        if let fill = tint(kind) {
            field.drawsBackground = true
            field.backgroundColor = fill
        }
        return field
    }
    /// The side of a side-by-side row that has no line: hatched, like VS Code.
    func filler() -> NSTextField {
        let field = label("", font: font)
        field.drawsBackground = true
        field.backgroundColor = Self.hatch
        return field
    }
    func band(_ string: String) -> NSTextField {
        let field = label(string, font: .ui(TextSize.caption), color: .tertiaryLabelColor)
        field.drawsBackground = true
        field.backgroundColor = .diffGap
        return field
    }
    private func prefix(_ l: DiffLine, marker: Bool) -> String {
        marker ? (l.kind == .add ? "+ " : l.kind == .del ? "- " : "  ") : " "
    }
    /// Lines wrap at words and go on under their own code's indent, not under the "+" (at most half the column). Tabs
    /// stop every four columns, as `height(of:)` counts them. Limit: past 4000 characters (a minified file) at any
    /// character from the edge, which `height(of:)` can count without measuring every such line on each resize.
    private static func wrap(_ text: String, prefix: String, font: NSFont, width: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle(), space = charWidth(font)
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
    /// Columns before a line's code: the marker, then its leading spaces and tabs.
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
    /// What a row shows of a line: a text field takes seconds over a megabyte, and nobody reads that far along one line.
    static func shown(_ line: String) -> String { line.utf16.count > 20_000 ? String(line.prefix(20_000)) + "…" : line }
    func codeCell(_ l: DiffLine, file f: Int, marker: Bool) -> NSTextField {
        let prefix = prefix(l, marker: marker)
        let text = Self.shown(l.text)
        let colored =
            DiffColors.key(f, l).flatMap { syntax[$0] }.map {
                Highlighter.attributed(
                    prefix + text, spans: $0, from: prefix.utf16.count, font: font, colors: syntaxColors)
            }
            ?? NSAttributedString(
                string: prefix + text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let styled = NSMutableAttributedString(attributedString: colored)
        let key =
            l.kind == .add ? l.newLine.map { "\(f):a:\($0)" } : l.kind == .del ? l.oldLine.map { "\(f):d:\($0)" } : nil
        if let key, let wordRange = words[key], wordRange.length > 0,
            wordRange.location + wordRange.length <= (text as NSString).length
        {
            styled.addAttribute(
                .backgroundColor, value: l.kind == .add ? NSColor.diffAddedWord : .diffRemovedWord,
                range: NSRange(location: wordRange.location + (prefix as NSString).length, length: wordRange.length))
        }
        markFound(styled, from: (prefix as NSString).length)
        // Its own paragraph style, the same `height(of:)` measures with: the field's mode doesn't reach an attributed string.
        styled.addAttribute(
            .paragraphStyle, value: Self.wrap(text, prefix: prefix, font: font, width: wrapWidth(marker: marker)),
            range: NSRange(location: 0, length: styled.length))
        let field = NSTextField(labelWithAttributedString: styled)
        field.maximumNumberOfLines = 0
        if let fill = tint(l.kind) {
            field.drawsBackground = true
            field.backgroundColor = fill
        }
        return field
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard (n.object as? NSTableView) === files, files.selectedRow >= 0 else { return }
        scroll(toFile: diffs[files.selectedRow].path)
    }
    /// A file's band to the top, its changes under it; false for a file this diff doesn't show.
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

    /// Every diff controller made, for `reveal`.
    static let reviews = NSHashTable<DiffViewController>.weakObjects()
    /// A file clicked in Source Control: the review of that workspace on screen scrolls to it, in place of a tab of its
    /// own; false when none shows it.
    static func reveal(_ path: String, worktree: String) -> Bool {
        reviews.allObjects.contains {
            $0.single == nil && $0.worktreeId == worktree && $0.view.window != nil && $0.scroll(toFile: path)
        }
    }

    // MARK: keyboard: ⌥↓/⌥↑ changes, ⌥⇧↓/⌥⇧↑ comments, ⌥→/⌥← files
    func key(_ e: NSEvent) -> Bool {
        if e.keyCode == 49, e.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask) {
            return flipSelectedComment()
        }
        guard e.modifierFlags.contains(.option) else { return false }
        let comments = e.modifierFlags.contains(.shift)
        switch e.keyCode {
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
    /// To the next (or previous) change or comment, and says which of how many it is.
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

    /// A file in the list: its letter and counts, its folder only when the whole of it fits.
    func fileRow(_ row: Int) -> NSView {
        let diff = diffs[row]
        // The same letters and colours as Source Control and Files; a long name loses its middle, not its counts.
        let (letter, color) = changes.first { $0.path == diff.path }?.badge ?? (" ", .labelColor)
        let short = NSMutableAttributedString(
            string: letter + "  ",
            attributes: [.font: NSFont.ui(TextSize.micro, weight: .bold), .foregroundColor: color])
        // The name, then its folder in grey, shown only when all of it fits: a cut folder ("So…") says nothing.
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
        if viewed.has(diff) { nameLabel.alphaValue = 0.55 }   // read: dimmed, as GitHub dims a viewed file
        let row = NSStackView(views: [nameLabel, counts])
        row.distribution = .fill   // the room goes to the name: the counts stand in a column at the end
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        row.toolTip = diff.path
        return row
    }

    /// A file's band across the review: its icon, path and "+6 −2" on a grey fill, where one file's changes end and the
    /// next one's begin (bold text alone on the page didn't mark it).
    func fileBand(_ path: String, added a: Int, removed d: Int) -> NSView {
        let icon = NSImageView(image: app.fileIcons.image((path as NSString).lastPathComponent))
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let name = label(path, font: .ui(TextSize.row, weight: .semibold))
        name.lineBreakMode = .byTruncatingHead
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [
            icon, name, NSTextField(labelWithAttributedString: GitFolders.changes(added: a, removed: d))
        ])
        // the room between goes to a spacer
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

    /// A row as tall as its code wrapped at its column's width (a monospaced font: so many characters a line); a file's
    /// band a little taller than a line.
    func height(of row: Int) -> CGFloat {
        let lineHeight = Self.lineHeight
        if rows.indices.contains(row), rows[row] == .draft { return Self.draftHeight }   // the comment card
        guard rows.indices.contains(row), case .diff(let diffRow) = rows[row] else { return lineHeight }
        func lines(_ line: DiffLine?, _ column: String, marker: Bool) -> Int {
            guard let line, let tableColumn = table.tableColumn(withIdentifier: .init(column)) else { return 1 }
            let width = tableColumn.width - 4, fit = max(1, Int(width / Self.charWidth(font)))
            let shown = Self.shown(line.text)
            let count = shown.reduce(2) { $0 + ($1 == "\t" ? 4 : 1) }   // with its "+ " marker; a tab about four
            guard count > fit else { return 1 }   // most lines: no need to measure
            guard shown.utf16.count <= Highlighter.maxColored else { return (count + fit - 1) / fit }
            // Word wrap leaves each line's end empty, so the characters alone would undercount: ask the text system.
            let marked = prefix(line, marker: marker)
            let text = NSAttributedString(
                string: marked + line.text,
                attributes: [
                    .font: font, .paragraphStyle: Self.wrap(line.text, prefix: marked, font: font, width: width)
                ])
            let tall = text.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin
            ).height
            return max(1, Int((tall / NSLayoutManager().defaultLineHeight(for: font)).rounded(.up)))
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

    private static var measured: (font: NSFont, width: CGFloat)?
    private static func charWidth(_ font: NSFont) -> CGFloat {
        if let cached = measured, cached.font == font { return cached.width }
        let width = max(1, ("0" as NSString).size(withAttributes: [.font: font]).width)
        measured = (font, width)
        return width
    }

    /// The pane got wider or narrower: lines wrap at the new width.
    @objc func columnsResized(_ n: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    /// A hunk's header row: where it is, and Stage / Unstage (and Discard where the diff is the unstaged one).
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
            // Named buttons at the hunk's end, as in Xcode's and GitHub Desktop's reviews.
            func button(_ title: String, _ a: Selector) -> NSButton {
                let hunkButton = NSButton(title: title, target: self, action: a)
                hunkButton.bezelStyle = .push
                hunkButton.controlSize = .small
                hunkButton.tag = f * 10000 + h
                return hunkButton
            }
            stack.addArrangedSubview(NSView())
            // Only where the hunks shown are the unstaged diff's, the one Discard works on.
            let unstaged =
                single.map { $0.source == .unstaged && $0.commit == nil } ?? (sourcePicked == .unstaged)
            if unstaged { stack.addArrangedSubview(button(String(localized: "Discard"), #selector(discardHunk(_:)))) }
            stack.addArrangedSubview(
                button(staged ? String(localized: "Unstage") : String(localized: "Stage"), #selector(hunkAction(_:))))
        }
        return stack
    }
}

/// A file-list row: its folder only when the whole of it fits (`full`), else the name and counts alone (`short`).
final class FitLabel: NSTextField {
    var full = NSAttributedString(), short = NSAttributedString()
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let fitting = full.size().width + 6 <= size.width ? full : short
        if !attributedStringValue.isEqual(to: fitting) { attributedStringValue = fitting }
    }
}
