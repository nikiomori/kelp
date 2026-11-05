import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// A comment being written: where it goes, and its field, kept across the diff being read again (an agent at work).
@MainActor
struct CommentDraft {
    var file: String, start: Int, end: Int, quote: String, side: String?
    let field = NSTextField(wrappingLabelWithString: "")
    /// Its card, made once: a new read of the diff moves this one, so what's typed and the caret stay.
    var card: NSView?
}

/// A comment is written in a card right under its line, as on GitHub: the Comment button, or the "+" beside a line under
/// the pointer, opens it; ⌘↩ saves, Esc puts it away.
extension DiffViewController {
    /// The card's field: two lines and more as they wrap; its row holds it and the buttons.
    static let draftField: CGFloat = 44
    static var draftHeight: CGFloat { draftField + 22 + 3 * Metrics.gap }

    /// The lines selected (or `row` alone) get a card under the last of them.
    func openDraft(at row: Int? = nil) {
        if let row { table.selectRowIndexes([row], byExtendingSelection: false) }
        var lines: [(Int, String)] = []; var file: String?, removed = true
        for r in table.selectedRowIndexes {
            guard let (path, x) = shownLine(r), let n = x.newLine ?? x.oldLine else { continue }
            file = path; removed = removed && x.newLine == nil
            lines.append((n, x.text))
        }
        guard let file, let first = lines.first, let last = lines.last else { NSSound.beep(); return }
        closeDraft()
        let d = CommentDraft(file: file, start: first.0, end: last.0, quote: lines.map(\.1).joined(separator: "\n"), side: removed ? "old" : nil)
        d.field.isEditable = true
        d.field.isBordered = true
        d.field.drawsBackground = true
        d.field.font = .ui(12)
        d.field.placeholderString = String(localized: "Comment for the agent on \(file):\(first.0)\(first.0 == last.0 ? "" : "-\(last.0)")")
        draft = d
        placeDraft()
        view.window?.makeFirstResponder(d.field)
    }

    /// The card's row goes under its line (and the comments already there), wherever a new read of the diff put it.
    func placeDraft() {
        rows.removeAll { $0 == .draft }
        guard let d = draft else { return }
        guard let at = rows.indices.last(where: { i in
            guard let (path, l) = shownLine(i) else { return false }
            return path == d.file && (d.side == "old" ? l.newLine == nil && l.oldLine == d.end : l.newLine == d.end)
        }) else { return }
        var i = at + 1
        while i < rows.count, case .comment = rows[i] { i += 1 }
        rows.insert(.draft, at: i)
    }

    func draftCard() -> NSView {
        guard let d = draft else { return NSView() }
        if let c = d.card { return c }
        let cancel = ClosureButton(title: String(localized: "Cancel")) { [weak self] in self?.closeDraft() }
        cancel.keyEquivalent = "\u{1b}"
        let save = ClosureButton(title: String(localized: "Comment")) { [weak self] in self?.saveDraft() }
        save.keyEquivalent = "\r"; save.keyEquivalentModifierMask = .command
        save.toolTip = String(localized: "Comment (⌘↩)")
        for b in [cancel, save] { b.bezelStyle = .push; b.controlSize = .small }
        let buttons = NSStackView(views: [NSView(), cancel, save])
        let card = NSStackView(views: [d.field, buttons])
        card.orientation = .vertical
        card.alignment = .trailing
        card.spacing = Metrics.gap
        card.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: 88, bottom: Metrics.gap, right: Metrics.gapWide)
        card.wantsLayer = true; card.layer?.backgroundColor = NSColor.fillRest.cgColor
        NSLayoutConstraint.activate([d.field.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -88 - Metrics.gapWide),
                                     d.field.heightAnchor.constraint(equalToConstant: Self.draftField)])
        draft?.card = card
        return card
    }

    /// The table read again, the comment being typed keeping the keys (Space there is a space, not a comment's box).
    func reloadKeepingDraft() {
        let typing = draft.map { d in view.window?.firstResponder === d.field.currentEditor() } ?? false
        table.reloadData()
        guard typing, let f = draft?.field else { return }
        view.window?.makeFirstResponder(f)
        f.currentEditor()?.selectedRange = NSRange(location: f.stringValue.utf16.count, length: 0)
    }

    func closeDraft() {
        guard draft != nil else { return }
        draft = nil
        placeDraft()
        table.reloadData()
        view.window?.makeFirstResponder(table)
    }

    private func saveDraft() {
        guard let wid = worktreeId, let d = draft else { return }
        let text = d.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        Task {
            guard await app.call(CommentAdd(id: wid, file: d.file, start: d.start, end: d.end, quote: d.quote, text: text, side: d.side)) != nil else { return }
            closeDraft()
            await load()
        }
    }
}

/// A line of the diff that shows a "+" at its start under the pointer: a comment on that line.
final class DiffLineRowView: NSTableRowView {
    var onPlus: (() -> Void)? { didSet { plus.isHidden = true } }
    private lazy var plus: IconButton = {
        let b = IconButton(.symbol("plus"), tip: String(localized: "Comment on This Line")) { [weak self] in self?.onPlus?() }
        b.isHidden = true
        addSubview(b)
        return b
    }()
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area.map(removeTrackingArea)
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with e: NSEvent) { plus.isHidden = onPlus == nil }
    override func mouseExited(with e: NSEvent) { plus.isHidden = true }
    override func layout() {
        super.layout()
        let s = Metrics.iconButton
        plus.frame = NSRect(x: 0, y: (bounds.height - s) / 2, width: s, height: s)
    }
}
