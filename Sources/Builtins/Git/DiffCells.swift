import AppKit
import Core
import DesignKit
import WorkbenchKit
import KelpKit

@MainActor
extension DiffViewController {
    private func ext(_ f: Int) -> String { (diffs[f].path as NSString).pathExtension }

    func label(_ s: String, font: NSFont, color: NSColor = .labelColor, align: NSTextAlignment = .left) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = color
        t.alignment = align
        t.lineBreakMode = .byClipping
        return t
    }
    private func tint(_ k: DiffLine.Kind) -> NSColor? { k == .add ? Self.addTint : k == .del ? Self.delTint : nil }
    func number(_ n: Int?, kind: DiffLine.Kind) -> NSTextField {
        let t = label(n.map(String.init) ?? "", font: font, color: .secondaryLabelColor, align: .right)
        if let c = tint(kind) { t.drawsBackground = true; t.backgroundColor = c }
        return t
    }
    /// The side of a side-by-side row that has no line: hatched, like VS Code.
    func filler() -> NSTextField {
        let t = label("", font: font)
        t.drawsBackground = true
        t.backgroundColor = Self.hatch
        return t
    }
    func band(_ s: String) -> NSTextField {
        let t = label(s, font: .ui(11), color: .tertiaryLabelColor)
        t.drawsBackground = true; t.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
        return t
    }
    func codeCell(_ l: DiffLine, file f: Int, marker: Bool) -> NSTextField {
        let prefix = marker ? (l.kind == .add ? "+ " : l.kind == .del ? "- " : "  ") : " "
        let s = NSMutableAttributedString(attributedString: Highlighter.attributed(prefix + l.text, ext: ext(f), font: font))
        let key = l.kind == .add ? l.newLine.map { "\(f):a:\($0)" } : l.kind == .del ? l.oldLine.map { "\(f):d:\($0)" } : nil
        if let key, let r = words[key], r.length > 0, r.location + r.length <= (l.text as NSString).length {
            s.addAttribute(.backgroundColor, value: l.kind == .add ? Self.addWord : Self.delWord,
                           range: NSRange(location: r.location + (prefix as NSString).length, length: r.length))
        }
        // Wrapped at any character, as `height(of:)` counts the row's lines: the field's own mode doesn't reach an
        // attributed string, which wrapped at words, ran a line longer and lost it under the next row.
        let chars = NSMutableParagraphStyle()
        chars.lineBreakMode = .byCharWrapping
        s.addAttribute(.paragraphStyle, value: chars, range: NSRange(location: 0, length: s.length))
        let t = NSTextField(labelWithAttributedString: s)
        t.maximumNumberOfLines = 0
        if let c = tint(l.kind) { t.drawsBackground = true; t.backgroundColor = c }
        return t
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard (n.object as? NSTableView) === files, files.selectedRow >= 0 else { return }
        let path = diffs[files.selectedRow].path
        if let i = rows.firstIndex(where: { if case .diff(.file(let p, _, _)) = $0 { p == path } else { false } }) {
            table.scrollRowToVisible(min(i + 40, rows.count - 1)); table.scrollRowToVisible(i)
        }
    }

    // MARK: keyboard: ⌥↓/⌥↑ changes, ⌥→/⌥← files
    func key(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.option) else { return false }
        switch e.keyCode {
        case 125: jump(hunk: 1); return true
        case 126: jump(hunk: -1); return true
        case 124: files.selectRowIndexes([min(files.selectedRow + 1, diffs.count - 1)], byExtendingSelection: false); return true
        case 123: files.selectRowIndexes([max(files.selectedRow - 1, 0)], byExtendingSelection: false); return true
        default: return false
        }
    }
    @objc func nextChange() { jump(hunk: 1) }
    @objc func prevChange() { jump(hunk: -1) }
    private func jump(hunk dir: Int) {
        let idx = rows.indices.filter { if case .diff(.hunk) = rows[$0] { true } else { false } }
        let cur = max(table.selectedRow, dir > 0 ? -1 : rows.count)
        guard let t = dir > 0 ? idx.first(where: { $0 > cur }) : idx.last(where: { $0 < cur }) else { NSSound.beep(); return }
        table.selectRowIndexes([t], byExtendingSelection: false)
        table.scrollRowToVisible(min(t + 8, rows.count - 1))
        table.scrollRowToVisible(t)
    }

    /// A file in the list: its letter and counts, its folder only when the whole of it fits.
    func fileRow(_ row: Int) -> NSView {
        let d = diffs[row]
        // The same letters and colours as Source Control and Files; a long path loses its middle, not its counts.
        let (letter, color) = changes.first { $0.path == d.path }?.badge ?? (" ", .labelColor)
        let t = NSMutableAttributedString(string: letter + "  ", attributes: [.font: NSFont.ui(10, weight: .bold), .foregroundColor: color])
        // The name, its counts, then its folder in grey, shown only when all of it fits: a cut folder ("So…") says nothing.
        let dir = (d.path as NSString).deletingLastPathComponent
        t.append(NSAttributedString(string: (d.path as NSString).lastPathComponent + "  ",
            attributes: [.font: NSFont.ui(12), .foregroundColor: NSColor.labelColor]))
        t.append(RowBadges.changes(added: d.additions, removed: d.deletions))
        let full = NSMutableAttributedString(attributedString: t)
        if !dir.isEmpty {
            full.append(NSAttributedString(string: "  " + dir,
                                           attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        for s in [t, full] { s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length)) }
        let v = FitLabel(labelWithAttributedString: t)
        v.full = full
        v.short = t
        v.toolTip = d.path
        return v
    }

    /// A file's band across the review: its icon, path and "+6 −2" on a grey fill, where one file's changes end and the
    /// next one's begin (bold text alone on the page didn't mark it).
    func fileBand(_ path: String, added a: Int, removed d: Int) -> NSView {
        let icon = NSImageView(image: app.fileIcons.image((path as NSString).lastPathComponent))
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let name = label(path, font: .ui(12, weight: .semibold))
        name.lineBreakMode = .byTruncatingHead
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, name, NSTextField(labelWithAttributedString: RowBadges.changes(added: a, removed: d))])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor.fillSelected.cgColor
        return stack
    }

    // MARK: long lines wrap

    /// A row as tall as its code wrapped at its column's width (a monospaced font: so many characters a line); a file's
    /// band a little taller than a line.
    func height(of row: Int) -> CGFloat {
        let h = Self.lineHeight
        guard rows.indices.contains(row), case .diff(let r) = rows[row] else { return h }
        func lines(_ l: DiffLine?, _ column: String) -> Int {
            guard let l, let c = table.tableColumn(withIdentifier: .init(column)) else { return 1 }
            let fit = max(1, Int((c.width - 4) / Self.charWidth(font)))
            let n = l.text.reduce(2) { $0 + ($1 == "\t" ? 4 : 1) }   // with its "+ " marker; a tab about four
            return (n + fit - 1) / fit
        }
        let n = switch r {
        case .line(_, let l): lines(l, "t")
        case .pair(_, let l, let right): max(lines(l, "l"), lines(right, "r"))
        case .file: 0
        default: 1
        }
        return n == 0 ? h + 6 : h + CGFloat(max(n, 1) - 1) * (h - 4)
    }

    private static var measured: (font: NSFont, width: CGFloat)?
    private static func charWidth(_ font: NSFont) -> CGFloat {
        if let m = measured, m.font == font { return m.width }
        let w = max(1, ("0" as NSString).size(withAttributes: [.font: font]).width)
        measured = (font, w)
        return w
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
        stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        let where_ = label(header, font: .uiMono(11), color: .secondaryLabelColor)
        where_.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(where_)
        if let staged = hunksStaged(f) {
            // Named buttons at the hunk's end, as in Xcode's and GitHub Desktop's reviews.
            func button(_ title: String, _ a: Selector) -> NSButton {
                let b = NSButton(title: title, target: self, action: a)
                b.bezelStyle = .push
                b.controlSize = .small
                b.tag = f * 10000 + h; return b
            }
            stack.addArrangedSubview(NSView())
            // Only where the hunks shown are the unstaged diff's, the one Discard works on.
            let unstaged = single.map { $0.source == "unstaged" && $0.commit == nil } ?? (source.indexOfSelectedItem == 1)
            if unstaged { stack.addArrangedSubview(button(String(localized: "Discard…"), #selector(discardHunk(_:)))) }
            stack.addArrangedSubview(button(staged ? String(localized: "Unstage") : String(localized: "Stage"), #selector(hunkAction(_:))))
        }
        return stack
    }
}
