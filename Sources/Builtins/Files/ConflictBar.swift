import AppKit
import DesignKit
import EditorKit

/// Over a file with merge conflicts: which one the caret is at, the way to the others, and Accept Current / Incoming /
/// Both for it, each one undoable edit. Hidden once none is left; the file is staged in Source Control as resolved.
@MainActor
final class ConflictBar {
    private(set) lazy var bar: Bar = {
        let icon = NSImageView(image: NSImage.symbol("arrow.triangle.merge"))
        icon.contentTintColor = .systemOrange
        label.font = .ui(TextSize.row)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons: [NSView] = [
            IconButton(.symbol("chevron.up"), tip: String(localized: "Previous Conflict")) { [weak self] in
                self?.step(-1)
            },
            IconButton(.symbol("chevron.down"), tip: String(localized: "Next Conflict")) { [weak self] in
                self?.step(1)
            },
            TextButton(String(localized: "Accept Current")) { [weak self] in self?.accept(.current) },
            TextButton(String(localized: "Accept Incoming")) { [weak self] in self?.accept(.incoming) },
            TextButton(String(localized: "Accept Both")) { [weak self] in self?.accept(.both) }
        ]
        return Bar.content([icon, label], buttons, stretching: label)
    }()
    private let label = NSTextField(labelWithString: "")
    private weak var editor: CodeEditor?
    private var conflicts: [MergeConflict] = []

    init(editor: CodeEditor) {
        self.editor = editor
        refresh()
    }

    /// Read the conflicts again: after an edit, or the file read again from disk.
    func refresh() {
        conflicts = editor.map { MergeConflict.all(in: $0.text) } ?? []
        bar.isHidden = conflicts.isEmpty
        // The current side with its <<<<<<< line, the incoming with its >>>>>>> one; a diff3 base between stays plain.
        editor?.tint(
            conflicts.flatMap {
                [
                    (
                        NSRange(location: $0.whole.location, length: NSMaxRange($0.current) - $0.whole.location),
                        .diffAdded
                    ),
                    (
                        NSRange(location: $0.incoming.location, length: NSMaxRange($0.whole) - $0.incoming.location),
                        .conflictIncoming
                    )
                ]
            })
        caretMoved()
    }

    /// The label follows the caret.
    func caretMoved() {
        guard !conflicts.isEmpty else { return }
        label.stringValue = String(localized: "Merge conflict \(current + 1) of \(conflicts.count)")
    }

    /// The one the caret is in, else the next after it, else the first.
    private var current: Int {
        let caret = editor?.selectedRange.location ?? 0
        return conflicts.firstIndex { NSMaxRange($0.whole) > caret } ?? 0
    }

    private func accept(_ keep: MergeConflict.Keep) {
        guard let editor, !conflicts.isEmpty else { return }
        let conflict = conflicts[current]
        editor.apply(
            text: conflict.resolving(editor.text, keeping: keep),
            selection: NSRange(location: conflict.whole.location, length: 0))
        refresh()
        if !conflicts.isEmpty { show(current) }
    }

    private func step(_ by: Int) {
        guard !conflicts.isEmpty else { return }
        let caret = editor?.selectedRange.location ?? 0
        let here = conflicts.firstIndex { NSLocationInRange(caret, $0.whole) }
        let next =
            by > 0
            ? (here.map { $0 + 1 } ?? conflicts.firstIndex { $0.whole.location > caret } ?? 0)
            : (here.map { $0 - 1 } ?? (conflicts.lastIndex { NSMaxRange($0.whole) <= caret } ?? conflicts.count - 1))
        show((next + conflicts.count) % conflicts.count)
    }

    private func show(_ index: Int) {
        guard let editor else { return }
        let start = conflicts[index].whole.location
        let line = (editor.text as NSString).substring(to: start).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        editor.goTo(line: line)
        caretMoved()
        editor.focus()
    }
}
