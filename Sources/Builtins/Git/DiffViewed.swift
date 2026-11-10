import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// What the Viewed boxes keep: the marks, each file's print, and the write under way.
struct ViewedMarks {
    /// Files marked as read, with their diff's print then.
    var marks: [String: String] = [:]
    /// Each file's print (`ViewedFiles.print`), made with its rows off the main thread: a big diff hashes slowly.
    var prints: [String: String] = [:]
    /// The last write of `marks`: each waits for the one before, so quick clicks land in order.
    var write: Task<Void, Never>?

    func has(_ diff: FileDiff) -> Bool { ViewedFiles.viewed(diff, in: marks, printed: prints[diff.path]) }
}

/// A file of the review marked as read, as GitHub's "Viewed": a box at the end of its band, the file dimmed in the list,
/// and how many are left. A file an agent changed after it was marked comes back unread (`ViewedFiles`).
extension DiffViewController {
    func readViewed() {
        viewed.marks = worktreeId.map { ViewedFiles.read(app.uiState.strings(ViewedFiles.key($0))) } ?? [:]
    }

    func viewedBox(_ row: Int) -> NSButton {
        let box = NSButton(
            checkboxWithTitle: String(localized: "Viewed"), target: self, action: #selector(toggleViewed(_:)))
        box.tag = row
        box.controlSize = .small
        box.font = .ui(11)
        box.setContentHuggingPriority(.required, for: .horizontal)   // the path takes the room, not the box
        box.state = viewed.has(diffs[row]) ? .on : .off
        return box
    }

    @objc private func toggleViewed(_ b: NSButton) {
        guard let wid = worktreeId, diffs.indices.contains(b.tag) else { return }
        let entries = ViewedFiles.marking(diffs[b.tag], b.state == .on, in: viewed.marks, diffs: diffs)
        viewed.marks = ViewedFiles.read(entries)
        files.reloadData(forRowIndexes: [b.tag], columnIndexes: [0])   // dimmed or not
        status.stringValue = statusText()
        viewed.write = Task { [app, before = viewed.write] in
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
        let left = diffs.filter { !viewed.has($0) }.count
        let open = notes.saved.filter { $0.state == .open }.count
        return String(localized: "\(diffs.count) files") + "  \(GitFolders.changes(added: add, removed: del).string)"
            + (left < diffs.count ? "  ·  " + String(localized: "\(left) of \(diffs.count) left") : "")
            + (open > 0 ? "  ·  " + String(localized: "\(open) open comments") : "")
    }
}
