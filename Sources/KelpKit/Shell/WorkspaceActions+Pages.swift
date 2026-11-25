import AppKit
import Core
import DesignKit

/// The pages agents made on a branch live in its folder's `.kelp/artifacts`, kept out of git, so removing the folder
/// would take them without a word. The question that removes it says so, with a box (on) that copies them into the
/// project's own folder first, where its Artifacts panel lists them.
extension WorkspaceActions {
    /// The pages in `worktree`: its `.kelp/artifacts` folders, as paths in it.
    func pages(in worktree: Worktree) async -> [String] {
        (await app.quiet(FilesIgnored(id: worktree.id, folder: Artifacts.folder + "/")) ?? []).filter {
            $0.hasSuffix("/")
        }
    }

    /// Puts the box in `alert`, when there are pages.
    func offerKeeping(_ pages: [String], in alert: NSAlert) {
        guard !pages.isEmpty else { return }
        let box = NSButton(
            checkboxWithTitle: String(localized: "Keep the pages made here in the project (\(pages.count))"),
            target: nil, action: nil)
        box.state = .on
        alert.accessoryView = box
    }

    /// Copies `pages` into the project's own folder when the box in `alert` is on.
    func keep(_ pages: [String], of worktree: Worktree, if alert: NSAlert) async {
        guard (alert.accessoryView as? NSButton)?.state == .on, !pages.isEmpty, let repo = app.repo(worktree.repoId)
        else {
            return
        }
        let into = (repo.path as NSString).appendingPathComponent(Artifacts.folder)
        _ = await app.quiet(FilesCreate(path: into, folder: true))   // there already, it says so: fine
        await app.call(
            FilesCopy(paths: pages.map { (worktree.path as NSString).appendingPathComponent($0) }, into: into))
    }

    /// Before a branch's folder is closed without another question: one about its pages, when it has any. False when
    /// the user cancelled.
    func askAboutPages(closing worktree: Worktree) async -> Bool {
        let pages = await pages(in: worktree)
        guard !pages.isEmpty else { return true }
        let alert = NSAlert(
            question: String(localized: "Close “\(worktree.displayName)”?"),
            detail: String(localized: "Its folder goes, and with it the pages agents made on this branch."),
            action: String(localized: "Close"), destructive: true)
        offerKeeping(pages, in: alert)
        guard await runSheet(alert) == .alertFirstButtonReturn else { return false }
        await keep(pages, of: worktree, if: alert)
        return true
    }
}
