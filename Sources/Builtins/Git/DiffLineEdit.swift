import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// Fixing a typo seen in a review: double-click a line of the working tree's diff, type, ↩. It's written over the file as
/// shown, so nothing an agent changed since is lost. Anything else in a diff (a commit's, a branch's) opens the file.
extension DiffViewController: NSTextFieldDelegate {
    private var showsWorkingTree: Bool { source.indexOfSelectedItem <= 1 }

    @objc func rowDoubleClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), let (path, line) = shownLine(row), let n = line.newLine, line.kind != .del else { return }
        guard showsWorkingTree, !hasUnsavedEdits(path) else { return openLine(path, n) }
        beginEdit(row, path: path, line: n, text: line.text)
    }

    private func hasUnsavedEdits(_ path: String) -> Bool {
        guard let root = app.worktree(worktreeId)?.path else { return true }
        return app.workbench.editedFiles.contains { $0.fileURL?.path == root + "/" + path }
    }

    private func beginEdit(_ row: Int, path: String, line: Int, text: String) {
        endEdit()
        let field = NSTextField(string: text)
        field.font = font
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = CodeEditor.page.background   // over the line: what it says now mustn't show through
        field.textColor = CodeEditor.page.text
        field.frame = place(in: row)
        field.delegate = self
        field.focusRingType = .none
        table.addSubview(field)
        lineEdit = (field, path, line, text)
        view.window?.makeFirstResponder(field)
    }

    /// Over the line's own cell, the last column in either layout, so the words don't move as it opens.
    private func place(in row: Int) -> NSRect {
        guard let cell = table.view(atColumn: table.numberOfColumns - 1, row: row, makeIfNecessary: false) else {
            return table.rect(ofRow: row).insetBy(dx: Metrics.inset, dy: 0)
        }
        var rect = table.convert(cell.bounds, from: cell)
        // The cell's text starts after its prefix: "+ " in the unified layout, one space in the split one.
        let lead = ((table.numberOfColumns < 4 ? "  " : " ") as NSString).size(withAttributes: [.font: font]).width
        rect.origin.x += lead
        rect.size.width -= lead
        return rect
    }

    private func endEdit() {
        lineEdit?.field.removeFromSuperview()
        lineEdit = nil
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            endEdit()
            return true
        }
        guard sel == #selector(NSResponder.insertNewline(_:)), let edit = lineEdit else { return false }
        let new = edit.field.stringValue
        endEdit()
        if new != edit.text { Task { await write(new, over: edit.text, path: edit.path, line: edit.line) } }
        return true
    }

    func write(_ new: String, over old: String, path: String, line: Int) async {
        guard let root = app.worktree(worktreeId)?.path, let read = await app.call(FilesRead(path: root + "/" + path)) else { return }
        guard let text = TextEdits.replacing(line: line, expected: old, with: new, in: read.text) else {
            return Banner.show(String(localized: "\((path as NSString).lastPathComponent) changed since this was shown. Nothing was written."), style: .error)
        }
        guard let written = await app.call(FilesWrite(path: root + "/" + path, text: text, base: read.stamp)) else { return }
        // Refused: it changed between the read and the write.
        guard written.stamp != nil else {
            return Banner.show(String(localized: "\((path as NSString).lastPathComponent) changed since this was shown. Nothing was written."), style: .error)
        }
        await load()
    }
}
