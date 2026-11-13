import AppKit
import Core
import DesignKit

/// The folders whose git Kelp shows and their lines not committed yet: beside the sidebar's rows, in the ⌃Tab switcher,
/// on the window bar (their PR and CI are Git's: `FolderCI`). Workspaces share their project's folder; a workspace on its
/// own branch (a worktree) has its own. Every such folder is watched: the daemon pushes its git when its files change.
@MainActor @Observable
package final class GitFolders {
    private let app: AppModel
    /// Worktree id → changes (observed through AppModel).
    var stats: [String: LineStats] { app.latest(GitEvent.self).byKey.compactMapValues(\.stats) }
    @ObservationIgnored private var following: Set<String> = []

    init(app: AppModel) {
        self.app = app
        track(owner: self) { [weak self] in
            self?.wanted() ?? []
        } changed: { [weak self] in
            self?.follow($0)
        }
    }

    /// Settings › Appearance › Changes and pull requests off: no git is watched for the badges.
    private func wanted() -> Set<String> { app.settings[SettingKeys.gitBadges] ? folders : [] }

    /// Every folder the sidebar lists: each project's own and each workspace's on a branch of its own.
    var folders: Set<String> {
        Set(
            app.repos.compactMap { app.gitFolder(project: $0.id)?.id }
                + app.worktrees.compactMap { app.gitFolder(workspace: $0.id)?.id })
    }

    private func follow(_ now: Set<String>) {
        for id in now.subtracting(following) { app.watch(.git, id) }
        for id in following.subtracting(now) { app.unwatch(.git, id) }
        following = now
    }

    /// What only a branch group's folder holds, as the daemon read it (`GitEvent.only`, `dirty`): commits no other
    /// branch or remote has, files not committed. Nil: not a branch's folder, or not read yet.
    func ownWork(_ id: String) -> (commits: Int, files: Int)? {
        guard let git = app.latest(GitEvent.self).byKey[id], let only = git.only, let dirty = git.dirty else {
            return nil
        }
        return (only, dirty ? max(1, git.changes?.count ?? 1) : 0)
    }

    /// Files folder `id` changes (not committed yet, or on its branch since it left the base) that another folder of
    /// its project changes too, each with those folders' branches: two chats building one thing two ways meet here,
    /// before their merge does. Only folders the sidebar watches count (Settings › Appearance › Changes and pull
    /// requests).
    func shared(_ id: String) -> [String: [String]] {
        let events = app.latest(GitEvent.self).byKey
        func touched(_ e: GitEvent?) -> Set<String> { Set((e?.changes ?? []).map(\.path) + (e?.branchFiles ?? [])) }
        guard let me = app.worktree(id) else { return [:] }
        let mine = touched(events[id])
        guard !mine.isEmpty else { return [:] }
        var out: [String: [String]] = [:], seen: Set<String> = [me.path]
        for (other, event) in events.sorted(by: { $0.key < $1.key }) {
            guard let worktree = app.worktree(other), worktree.repoId == me.repoId, !worktree.archived,
                seen.insert(worktree.path).inserted
            else {
                continue
            }
            for path in mine.intersection(touched(event)) { out[path, default: []].append(worktree.branch) }
        }
        return out
    }

    /// "Also changed on fix-login: App.swift, Login.swift and 2 more", a line a branch.
    static func sharedTip(_ shared: [String: [String]]) -> String? {
        guard !shared.isEmpty else { return nil }
        var byBranch: [String: [String]] = [:]
        for (path, branches) in shared { for b in branches { byBranch[b, default: []].append(path) } }
        return byBranch.keys.sorted().map { branch in
            let names = (byBranch[branch] ?? []).map { ($0 as NSString).lastPathComponent }.sorted()
            let more = names.count > 3 ? String(localized: " and \(names.count - 3) more") : ""
            return String(localized: "Also changed on \(branch): \(names.prefix(3).joined(separator: ", "))\(more)")
        }.joined(separator: "\n")
    }

    /// "+6 −2" in green and red (text shades: NSColor.textGreen); a side with nothing changed is left out ("+6", not "+6 −0").
    /// `compact`, for a row: "+21.7k" from ten thousand lines (generated files), the exact count left to its tooltip.
    package static func changes(_ stats: LineStats?, compact: Bool = false) -> NSAttributedString? {
        guard let stats, stats.totalAdded + stats.totalRemoved > 0 else { return nil }
        return changes(added: stats.totalAdded, removed: stats.totalRemoved, compact: compact)
    }
    package static func changes(added: Int, removed: Int, compact: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(), font = NSFont.uiDigits(TextSize.caption, weight: .regular)
        func short(_ lines: Int) -> String {
            guard compact, lines >= 10_000 else { return "\(lines)" }
            let thousands = (Double(lines) / 100).rounded() / 10
            return (thousands == thousands.rounded() ? String(Int(thousands)) : String(thousands)) + "k"
        }
        for (text, lines, color) in [
            ("+" + short(added), added, NSColor.textGreen), ("−" + short(removed), removed, NSColor.textRed)
        ] where lines > 0 {
            result.append(
                NSAttributedString(
                    string: (result.length > 0 ? " " : "") + text, attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }
}

extension AppModel {
    /// The folder whose git, PR and CI a workspace shows: its own worktree's, or (a workspace of a project) the project's.
    /// Read from the lists alone: asking doesn't start the sidebar's watches (`gitState`).
    package func gitFolder(of workspace: String?) -> Worktree? {
        worktree(workspace).flatMap { gitFolder(workspace: $0.id) ?? gitFolder(project: $0.repoId) }
    }
    /// The key a workspace's git and CI are watched, read and asked again by (`watch(.git, …)`, `latest(GitEvent.self, …)`):
    /// its folder's, so workspaces sharing one folder share one watch, as the sidebar's; its own when it has none.
    package func gitKey(_ workspace: String?) -> String { gitFolder(of: workspace)?.id ?? workspace ?? "" }
    /// The folder a project's row stands for: its own worktree's (nil: a project that isn't a git folder).
    package func gitFolder(project id: String) -> Worktree? {
        guard let repo = repo(id) else { return nil }
        return worktrees.first { $0.repoId == id && $0.path == repo.path && !$0.archived }
    }
    /// A workspace's own folder: one on a branch of its own (nil: it shares its project's).
    func gitFolder(workspace id: String) -> Worktree? {
        guard let worktree = worktree(id), !worktree.archived, worktree.path != repo(worktree.repoId)?.path else {
            return nil
        }
        return worktree
    }
    /// Every folder the sidebar lists, whose git, PR and CI its rows show.
    package var gitFolders: Set<String> { gitState.folders }
    /// Its files that another folder of the project changes too, with that folder's branch (`GitFolders.shared`).
    package func sharedFiles(_ id: String?) -> [String: [String]] { id.map(gitState.shared) ?? [:] }
}
