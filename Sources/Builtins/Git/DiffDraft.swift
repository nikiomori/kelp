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

/// The review's comments: those saved (on this diff's commit), the one being written, and the open ones left out of Send
/// to Agent (`DiffFindings`).
@MainActor
struct ReviewNotes {
    var saved: [DiffComment] = []
    var draft: CommentDraft?
    var skipped: Set<String> = []
}

/// A comment is written in a card right under its line, as on GitHub: the Comment button, or the "+" beside a line under
/// the pointer, opens it; ⌘↩ saves, Esc puts it away.
extension DiffViewController {
    /// Where a line's code starts, past its numbers: what goes under a line (a card, unchanged lines) starts there too.
    static let codeIndent: CGFloat = 88
    /// The commit on screen when it's a past one's diff: a comment there is on that commit, not the folder's HEAD.
    var shownCommit: String? {
        if let single { return single.source == .commit ? single.commit : nil }
        return sourcePicked == .commit ? commitHash : nil
    }

    /// The card's field: two lines and more as they wrap; its row holds it and the buttons.
    static let draftField: CGFloat = 44
    static var draftHeight: CGFloat { draftField + 22 + 3 * Metrics.gap }

    /// The lines selected (or `row` alone) get a card under the last of them.
    func openDraft(at row: Int? = nil) {
        if let row { table.selectRowIndexes([row], byExtendingSelection: false) }
        // One file, and one side's numbers: a range across two files, or from an old line to a new one, names lines that
        // aren't the ones quoted.
        let shown = table.selectedRowIndexes.compactMap { shownLine($0) }
        guard let file = shown.first?.0 else {
            NSSound.beep()
            return
        }
        let lines = shown.filter { $0.0 == file }.map(\.1), removed = lines.allSatisfy { $0.newLine == nil }
        let numbers = lines.compactMap { removed ? $0.oldLine : $0.newLine }
        guard let first = numbers.min(), let last = numbers.max() else {
            NSSound.beep()
            return
        }
        closeDraft()
        let newDraft = CommentDraft(
            file: file, start: first, end: last, quote: lines.map(\.text).joined(separator: "\n"),
            side: removed ? "old" : nil)
        newDraft.field.isEditable = true
        newDraft.field.isBordered = true
        newDraft.field.drawsBackground = true
        newDraft.field.font = .ui(12)
        newDraft.field.placeholderString = String(
            localized: "Comment for the agent on \(file):\(first)\(first == last ? "" : "-\(last)")")
        notes.draft = newDraft
        placeDraft()
        view.window?.makeFirstResponder(newDraft.field)
    }

    /// The card's row goes under its line (and the comments already there), wherever a new read of the diff put it.
    func placeDraft() {
        rows.removeAll { $0 == .draft }
        guard let draft = notes.draft else { return }
        guard
            let at = rows.indices.last(where: { row in
                guard let (path, l) = shownLine(row) else { return false }
                return path == draft.file
                    && (draft.side == "old" ? l.newLine == nil && l.oldLine == draft.end : l.newLine == draft.end)
            })
        else { return }
        var index = at + 1
        while index < rows.count, case .comment = rows[index] { index += 1 }
        rows.insert(.draft, at: index)
    }

    func draftCard() -> NSView {
        guard let draft = notes.draft else { return NSView() }
        if let existing = draft.card { return existing }
        let cancel = ClosureButton(title: String(localized: "Cancel")) { [weak self] in self?.closeDraft() }
        cancel.keyEquivalent = "\u{1b}"
        let save = ClosureButton(title: String(localized: "Comment")) { [weak self] in self?.saveDraft() }
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        save.toolTip = String(localized: "Comment (⌘↩)")
        for b in [cancel, save] {
            b.bezelStyle = .push
            b.controlSize = .small
        }
        let buttons = NSStackView(views: [NSView(), cancel, save])
        let card = NSStackView(views: [draft.field, buttons])
        card.orientation = .vertical
        card.alignment = .trailing
        card.spacing = Metrics.gap
        card.edgeInsets = NSEdgeInsets(
            top: Metrics.gap, left: Self.codeIndent, bottom: Metrics.gap, right: Metrics.gapWide)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.fillRest.cgColor
        NSLayoutConstraint.activate([
            draft.field.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -Self.codeIndent - Metrics.gapWide),
            draft.field.heightAnchor.constraint(equalToConstant: Self.draftField)
        ])
        notes.draft?.card = card
        return card
    }

    /// The table read again, the comment being typed keeping the keys (Space there is a space, not a comment's box).
    func reloadKeepingDraft() {
        let typing = notes.draft.map { d in view.window?.firstResponder === d.field.currentEditor() } ?? false
        table.reloadData()
        guard typing, let field = notes.draft?.field else { return }
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    func closeDraft() {
        guard notes.draft != nil else { return }
        notes.draft = nil
        placeDraft()
        table.reloadData()
        view.window?.makeFirstResponder(table)
    }

    private func saveDraft() {
        guard let wid = worktreeId, let draft = notes.draft else { return }
        let text = draft.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        Task {
            guard
                await app.call(
                    CommentAdd(
                        id: wid, file: draft.file, start: draft.start, end: draft.end, quote: draft.quote, text: text,
                        side: draft.side,
                        commit: shownCommit)) != nil
            else { return }
            closeDraft()
            await load()
        }
    }
}

/// A line of the diff that shows a "+" at its start under the pointer: a comment on that line.
final class DiffLineRowView: NSTableRowView {
    var onPlus: (() -> Void)? { didSet { plus.isHidden = true } }
    private lazy var plus: IconButton = {
        let button = IconButton(.symbol("plus"), tip: String(localized: "Comment on This Line")) { [weak self] in
            self?.onPlus?()
        }
        button.isHidden = true
        addSubview(button)
        return button
    }()
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area.map(removeTrackingArea)
        let trackingArea = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(trackingArea)
        area = trackingArea
    }
    override func mouseEntered(with e: NSEvent) { plus.isHidden = onPlus == nil }
    override func mouseExited(with e: NSEvent) { plus.isHidden = true }
    override func layout() {
        super.layout()
        let size = Metrics.iconButton
        plus.frame = NSRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
    }
}
