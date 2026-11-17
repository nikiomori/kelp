import AppKit
import DesignKit
import EditorKit

/// The bar over a file with merge conflicts. It says which conflict the caret is at, steps to the others, and offers
/// Accept Current / Incoming / Both for it, each as one undoable edit. The bar hides once no conflict is left. Staging
/// the file in Source Control marks it resolved.
@MainActor
final class ConflictBar {
    private(set) lazy var bar: Bar = {
        let icon = NSImageView(image: NSImage.symbol("arrow.triangle.merge"))
        icon.contentTintColor = .systemOrange
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
    private let label = NSTextField.label("", font: .ui(TextSize.row))
    private weak var editor: CodeEditor?
    private var conflicts: [MergeConflict] = []

    init(editor: CodeEditor) {
        self.editor = editor
        refresh()
    }

    /// Reads the conflicts again, after an edit or when the file is read again from disk.
    func refresh() {
        conflicts = editor.map { MergeConflict.all(in: $0.text) } ?? []
        bar.isHidden = conflicts.isEmpty
        // Tints the current side with its <<<<<<< line, and the incoming side with its >>>>>>> line. A diff3 base
        // between the two stays plain.
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

    /// Called after a keystroke. It reads the conflicts again only when there are conflicts to follow, or when the edit
    /// could have made or broken a marker line, because otherwise each keystroke would read all of a 5 MB file.
    func edited(_ edit: [(column: Int, removed: String, inserted: String)]?) {
        guard conflicts.isEmpty, let edit, !edit.contains(where: Self.couldMark) else { return refresh() }
    }

    /// Returns whether one piece of an edit can change which lines are conflict markers. A marker line is recognised by
    /// its first eight characters, so a piece further along the line matters only if it holds a marker character or a
    /// line break.
    static func couldMark(_ piece: (column: Int, removed: String, inserted: String)) -> Bool {
        piece.column <= 8
            || [piece.removed, piece.inserted].contains { $0.contains { $0.isNewline || "<|=>".contains($0) } }
    }

    /// Updates the label to the conflict the caret is at.
    func caretMoved() {
        guard !conflicts.isEmpty else { return }
        label.stringValue = String(localized: "Merge conflict \(current + 1) of \(conflicts.count)")
    }

    /// The index of the conflict the caret is in, else of the next one after the caret, else of the first.
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
