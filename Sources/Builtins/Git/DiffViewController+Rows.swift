// The diff view's tables: their rows and cells, built off the main thread, and the file list beside them.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

extension DiffViewController {
    /// The table's rows and changed words, built off the main thread: a big diff is a lot of rows.
    func buildRows(_ d: [FileDiff], _ cm: [DiffComment], sideBySide: Bool) async -> (
        [ReviewRow], [String: NSRange]
    ) {
        let one = single != nil, open = opened
        return await Task.detached {
            (
                DiffRows.reviewRows(d, comments: cm, sideBySide: sideBySide, hideFileRows: one, opened: open),
                DiffRows.changedWords(d)
            )
        }.value
    }

    func rebuildRows() {
        builds += 1
        let generation = builds, currentDiffs = diffs, cm = comments, layout = sideBySide
        Task {
            let built = await buildRows(currentDiffs, cm, sideBySide: layout)
            guard generation == builds else { return }
            if fadesNextLoad { table.crossfade(Motion.base) }
            fadesNextLoad = false
            (rows, words) = built
            placeDraft()
            reloadKeepingDraft()
            if !find.needle.isEmpty { search(find.needle, step: false) }
        }
    }

    /// Source Control beside the tab lists the same files: the tab's own list steps aside meanwhile, and comes back
    /// where it was when the inspector closes or shows another panel. One file's tab has none.
    func placeFileList() {
        let hide = single != nil || app.workbench.panelBeside == "git.changes"
        guard let list = fileList, let split, list.isHidden != hide else { return }
        list.isHidden = hide
        split.adjustSubviews()
        if !hide { positioned = false }   // at its width again on the next layout
    }

    /// Whether the hunks shown are the staged diff's (Unstage) or the unstaged one's (Stage); nil where they're neither
    /// and git can't take them as they are. The uncommitted diff (against HEAD) is the unstaged one's for a file with
    /// nothing staged, and the staged one's for a file with nothing left unstaged.
    func hunksStaged(_ f: Int) -> Bool? {
        if hidesSpace { return nil }
        if let single {
            return single.commit == nil && (single.source == "unstaged" || single.source == "staged")
                ? single.source == "staged" : nil
        }
        switch source.indexOfSelectedItem {
        case 1: return false
        case 2: return true
        case 0:
            guard diffs.indices.contains(f) else { return nil }
            guard let change = changes.first(where: { $0.path == diffs[f].path }), change.staged else { return false }
            return change.unstaged ? nil : true
        default: return nil
        }
    }

    /// One file of the review in a tab of its own, which has room for a whole file's changes; nil for the agent's last turn.
    private func alone(_ path: String) -> String? {
        guard single == nil, let wid = worktreeId else { return nil }
        switch source.indexOfSelectedItem {
        case 1: return DiffTab.uri(wid, file: path, source: "unstaged")
        case 2: return DiffTab.uri(wid, file: path, source: "staged")
        case 3: return DiffTab.uri(wid, file: path, source: "branch")
        case 4: return DiffTab.uri(wid, file: path, commit: commitHash ?? "HEAD")
        case 5: return nil
        default: return DiffTab.uri(wid, file: path, source: "all")
        }
    }
}

extension DiffViewController {
    // MARK: table
    func numberOfRows(in t: NSTableView) -> Int { t === files ? diffs.count : rows.count }

    /// The file list's rows light up under the pointer as every inspector list's do; the diff's own rows don't.
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if t === files { return ListRowView() }
        let rowView = DiffLineRowView()   // a line shows a "+" under the pointer, for a comment on it
        rowView.onPlus = shownLine(row) != nil && worktreeId != nil ? { [weak self] in self?.openDraft(at: row) } : nil
        return rowView
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let app = self.app
        if t === files { return fileRow(row) }
        let id = col?.identifier.rawValue ?? ""
        let first = id == "t" || id == "l" || col == nil   // nil: a hunk header, one view across the row
        switch rows[row] {
        case .draft: return draftCard()
        case .comment(let comment): return commentRow(comment)
        case .diff(let diffRow):
            switch diffRow {
            case .file(let path, let added, let removed): return fileBand(path, added: added, removed: removed)
            case .binary(let path):
                return label(
                    first ? String(localized: "Binary file \(path) not shown") : "", font: font,
                    color: .secondaryLabelColor)
            case .tooLarge(let path):
                let said = label(
                    first ? String(localized: "\(path) is too large to show here") : "", font: font,
                    color: .secondaryLabelColor)
                guard first, let uri = alone(path) else { return said }
                said.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let open = ClosureButton(title: String(localized: "Open Changes")) { app.workbench.open(uri) }
                open.bezelStyle = .push
                open.controlSize = .small
                let stack = NSStackView(views: [said, open])
                stack.spacing = 8
                return stack
            case .gap(let file, let from, let count, let context):
                return first ? gapRow(file: file, from: from, lines: count, context: context) : band("")
            case .hunk(let file, let hunk, let header):
                return first ? hunkRow(file: file, hunk: hunk, header: header) : band("")
            case .line(let file, let line):
                switch id {
                case "on": return number(line.oldLine, kind: line.kind)
                case "nn": return number(line.newLine, kind: line.kind)
                default: return codeCell(line, file: file, marker: true)
                }
            case .pair(let file, let left, let right):
                switch id {
                case "on": return left.map { number($0.oldLine, kind: $0.kind) } ?? filler()
                case "nn": return right.map { number($0.newLine, kind: $0.kind) } ?? filler()
                case "l": return left.map { codeCell($0, file: file, marker: false) } ?? filler()
                default: return right.map { codeCell($0, file: file, marker: false) } ?? filler()
                }
            }
        }
    }

    /// A hunk's header spans both sides, its buttons at the row's end, rather than ending halfway in an empty strip.
    /// A hunk's header and a file's band run across the row.
    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool {
        guard t === table, rows.indices.contains(row) else { return false }
        switch rows[row] {
        case .diff(.hunk), .diff(.file), .draft, .comment: return true
        default: return false
        }
    }
    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat { t === table ? height(of: row) : t.rowHeight }
}
