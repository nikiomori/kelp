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

    /// Puts the box under `alert`, when there are pages.
    func offerKeeping(_ pages: [String], in alert: NSAlert) {
        guard !pages.isEmpty else { return }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Keep its \(pages.count) pages in the project")
        alert.suppressionButton?.state = .on
    }

    /// Copies `pages` into the project's own folder when the box under `alert` is on.
    func keep(_ pages: [String], of worktree: Worktree, if alert: NSAlert) async {
        guard alert.suppressionButton?.state == .on, !pages.isEmpty, let repo = app.repo(worktree.repoId) else {
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
        let alert = NSAlert()
        alert.messageText = String(localized: "Close “\(worktree.displayName)”?")
        alert.informativeText = String(localized: "Its folder goes, and with it the pages agents made on this branch.")
        offerKeeping(pages, in: alert)
        alert.addButton(withTitle: String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard await runSheet(alert) == .alertFirstButtonReturn else { return false }
        await keep(pages, of: worktree, if: alert)
        return true
    }
}
