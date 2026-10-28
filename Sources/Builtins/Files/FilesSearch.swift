import AppKit
import Core
import DesignKit
import Quartz
import Markdown
import WorkbenchKit
import KelpKit

@MainActor
extension FilesPanel {
    // MARK: search
    private func showResults(_ on: Bool) {
        resultsScroll.isHidden = !on
        leftScroll.isHidden = on || !loadError.isHidden
        if !on { noResults?.isHidden = true }
    }
    func showLoadError(_ message: String?) {
        loadError.stringValue = message.map { String(localized: "Couldn't list the files: \($0)") } ?? ""
        loadError.isHidden = message == nil
        leftScroll.isHidden = message != nil || !resultsScroll.isHidden
    }
    /// Results follow the typing (a pause of a quarter second), like Xcode's Find navigator.
    func controlTextDidChange(_ n: Notification) {
        guard n.object as? NSSearchField === search else { return }
        typing.after(0.25) { [weak self] in self?.runSearch() }
    }
    /// ↓ from the field goes into the results; ↩ there opens the line.
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if let r = renaming, c === r.field, sel == #selector(NSResponder.cancelOperation(_:)) {   // Esc keeps the old name
            r.field.stringValue = r.url.lastPathComponent
            view.window?.makeFirstResponder(outline)
            return true
        }
        guard c === search, sel == #selector(NSResponder.moveDown(_:)), !matches.isEmpty, !resultsScroll.isHidden else { return false }
        view.window?.makeFirstResponder(results); results.selectRowIndexes([0], byExtendingSelection: false)
        return true
    }
    @objc func runSearch() {
        guard let w = worktree else { return }
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        showResults(!q.isEmpty)
        guard !q.isEmpty else { return }
        Task {
            let found = await app.tryCall(FilesSearch(id: w.id, query: q))
            guard worktree?.id == w.id, search.stringValue.trimmingCharacters(in: .whitespaces) == q else { return }   // a newer search or workspace
            matches = found.value ?? []
            results.reloadData()
            noMatches.stringValue = found.error.map { String(localized: "Couldn't search: \($0)") } ?? String(localized: "No matches for “\(q)”.")
            noResults?.isHidden = !matches.isEmpty
        }
    }
    func numberOfRows(in t: NSTableView) -> Int { matches.count }
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let m = matches[row]
        let top = NSTextField(labelWithString: "\(m.path):\(m.line)")
        top.font = .uiDigits(11)
        top.textColor = .secondaryLabelColor
        let txt = NSTextField(labelWithString: m.text)
        txt.font = .uiMono(11)
        txt.lineBreakMode = .byTruncatingTail
        let s = NSStackView(views: [top, txt])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = Metrics.lineGap
        s.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        return s
    }
    @objc func openResult() {
        let r = results.clickedRow >= 0 ? results.clickedRow : results.selectedRow
        if matches.indices.contains(r) { let m = matches[r]; openFile(m.path, line: m.line) }
    }
}
