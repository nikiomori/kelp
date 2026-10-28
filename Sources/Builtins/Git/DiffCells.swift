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
        let t = label(s, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
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
        let t = NSTextField(labelWithAttributedString: s)
        t.lineBreakMode = .byClipping; t.toolTip = l.text.count > 120 ? l.text : nil
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
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        t.append(RowBadges.changes(added: d.additions, removed: d.deletions))
        let full = NSMutableAttributedString(attributedString: t)
        if !dir.isEmpty {
            full.append(NSAttributedString(string: "  " + dir,
                                           attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        for s in [t, full] { s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length)) }
        let v = FitLabel(labelWithAttributedString: t)
        v.full = full
        v.short = t
        v.toolTip = d.path
        return v
    }

    /// A hunk's header row: where it is, and Stage / Unstage (and Discard where the diff is the unstaged one).
    func hunkRow(file f: Int, hunk h: Int, header: String) -> NSView {
        let stack = NSStackView()
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        let where_ = label(header, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
        where_.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(where_)
        if canStageHunks(f) {
            // Named buttons at the hunk's end, as in Xcode's and GitHub Desktop's reviews.
            let staged = single?.source == "staged" || (single == nil && source.indexOfSelectedItem == 2)
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
