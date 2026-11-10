import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// A file of the review marked as read, as GitHub's "Viewed": a box at the end of its band, the file dimmed in the list,
/// and how many are left. A file an agent changed after it was marked comes back unread (`ViewedFiles`).
extension DiffViewController {
    func readViewed() {
        viewed = worktreeId.map { ViewedFiles.read(app.uiState.strings(ViewedFiles.key($0))) } ?? [:]
    }

    func viewedBox(_ row: Int) -> NSButton {
        let box = NSButton(
            checkboxWithTitle: String(localized: "Viewed"), target: self, action: #selector(toggleViewed(_:)))
        box.tag = row
        box.controlSize = .small
        box.font = .ui(11)
        box.setContentHuggingPriority(.required, for: .horizontal)   // the path takes the room, not the box
        box.state = ViewedFiles.viewed(diffs[row], in: viewed, printed: prints[diffs[row].path]) ? .on : .off
        return box
    }

    @objc private func toggleViewed(_ b: NSButton) {
        guard let wid = worktreeId, diffs.indices.contains(b.tag) else { return }
        let entries = ViewedFiles.marking(diffs[b.tag], b.state == .on, in: viewed, diffs: diffs)
        viewed = ViewedFiles.read(entries)
        files.reloadData(forRowIndexes: [b.tag], columnIndexes: [0])   // dimmed or not
        status.stringValue = statusText()
        viewedWrite = Task { [app, before = viewedWrite] in
            await before?.value
            _ = await app.uiState.save(ViewedFiles.key(wid), .array(entries.map(JSONValue.string)))
        }
    }

    /// "3 files +12 −4 · 1 of 3 left · 2 open comments"; the one file's counts alone in one-file mode.
    func statusText() -> String {
        let add = diffs.reduce(0) { $0 + $1.additions }, del = diffs.reduce(0) { $0 + $1.deletions }
        if single != nil {
            return diffs.isEmpty ? String(localized: "No changes") : GitFolders.changes(added: add, removed: del).string
        }
        let left = diffs.filter { !ViewedFiles.viewed($0, in: viewed, printed: prints[$0.path]) }.count
        let open = comments.filter { $0.state == .open }.count
        return String(localized: "\(diffs.count) files") + "  \(GitFolders.changes(added: add, removed: del).string)"
            + (left < diffs.count ? "  ·  " + String(localized: "\(left) of \(diffs.count) left") : "")
            + (open > 0 ? "  ·  " + String(localized: "\(open) open comments") : "")
    }
}
