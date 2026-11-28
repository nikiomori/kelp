import AppKit
import Core
import DesignKit

/// The folders whose git status Kelp shows, with their uncommitted lines. They show beside the sidebar's rows, in the
/// ⌃Tab switcher and on the window bar (their PR and CI come from the Git built-in's `FolderCI`). Workspaces share
/// their project's folder, but a workspace on its own branch (a worktree) has its own. Every such folder is watched,
/// and the daemon pushes its git status when its files change.
@MainActor @Observable
package final class GitFolders {
    private let app: AppModel
    /// Worktree id → changes (observed through AppModel).
    var stats: [String: LineStats] { app.latest(GitEvent.self).byKey.compactMapValues(\.stats) }
    /// Folder `id`'s changes, read alone: a row asks for its own, not for every folder's.
    func stats(_ id: String) -> LineStats? { app.latest(GitEvent.self, id)?.stats }
    @ObservationIgnored private var following: Set<String> = []
    /// Each folder's changed and branch files as a set, with the lists it was made from. Every sidebar row asks
    /// `shared` on each update, so a set is made again only when its folder's status brings new lists.
    @ObservationIgnored private(set) var touchedSets: [String: Touched] = [:]
    struct Touched {
        let changes: [FileChange]?, branchFiles: [String]?, paths: Set<String>
    }

    init(app: AppModel) {
        self.app = app
        track(owner: self) { [weak self] in
            self?.wanted() ?? []
        } changed: { [weak self] in
            self?.follow($0)
        }
    }

    /// The folders to watch. With Settings › Appearance › Changes and pull requests off, no git is watched for the
    /// badges.
    private func wanted() -> Set<String> { app.settings[SettingKeys.gitBadges] ? folders : [] }

    /// Every folder the sidebar lists: each project's own folder, the folder of each workspace on a branch of its
    /// own, and each live chat's own worktree that is no workspace (`Session.branchKey`).
    var folders: Set<String> {
        let groups = Set(app.worktrees.map(\.path))
        let chats = app.sessions.filter { chat in
            chat.status != .exited && !chat.isTerminal && chat.branchFolder.map { !groups.contains($0) } == true
        }
        return Set(
            app.repos.compactMap { app.gitFolder(project: $0.id)?.id }
                + app.worktrees.compactMap { app.gitFolder(workspace: $0.id)?.id } + chats.map(\.branchKey))
    }

    private func follow(_ now: Set<String>) {
        for id in now.subtracting(following) { app.watch(.git, id) }
        for id in following.subtracting(now) { app.unwatch(.git, id) }
        following = now
    }

    /// The branch folder `id` has out, as its last git status said. It is nil while HEAD is detached or before the
    /// status comes.
    func branch(_ id: String) -> String? { app.latest(GitEvent.self).byKey[id]?.branches?.current }

    /// Returns the work that only a branch group's folder holds, as the daemon read it (`GitEvent.only`, `dirty`):
    /// commits that no other branch or remote has, and files not committed. It is nil when the folder isn't a branch's
    /// folder or hasn't been read yet.
    func ownWork(_ id: String) -> (commits: Int, files: Int)? {
        guard let git = app.latest(GitEvent.self).byKey[id], let only = git.only, let dirty = git.dirty else {
            return nil
        }
        return (only, dirty ? max(1, git.changes?.count ?? 1) : 0)
    }

    /// Returns the files that folder `id` changes (not committed yet, or on its branch since it left the base) that
    /// another folder of the same project changes too, each with the other folders' branches. This shows two chats
    /// building one thing two ways before their merge does. Only folders the sidebar watches count (Settings ›
    /// Appearance › Changes and pull requests).
    func shared(_ id: String) -> [String: [String]] {
        let events = app.latest(GitEvent.self).byKey
        guard let me = app.worktree(id) else { return [:] }
        let mine = touched(id, events[id])
        guard !mine.isEmpty else { return [:] }
        var out: [String: [String]] = [:], seen: Set<String> = [me.path]
        for (other, event) in events.sorted(by: { $0.key < $1.key }) {
            guard let worktree = app.worktree(other), worktree.repoId == me.repoId, !worktree.archived,
                seen.insert(worktree.path).inserted
            else {
                continue
            }
            for path in mine.intersection(touched(other, event)) { out[path, default: []].append(worktree.branch) }
        }
        return out
    }

    /// The files folder `id` changes or its branch brings, from `touchedSets` while its lists are the same (unchanged
    /// lists share their storage, so the check costs nothing).
    private func touched(_ id: String, _ event: GitEvent?) -> Set<String> {
        if let known = touchedSets[id], known.changes == event?.changes, known.branchFiles == event?.branchFiles {
            return known.paths
        }
        let paths = Set((event?.changes ?? []).map(\.path) + (event?.branchFiles ?? []))
        touchedSets[id] = Touched(changes: event?.changes, branchFiles: event?.branchFiles, paths: paths)
        return paths
    }

    /// Returns a tip such as "Also changed on fix-login: App.swift, Login.swift and 2 more", one line per branch.
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

    /// Returns "+6 −2" in green and red (text shades such as NSColor.textGreen). A side with nothing changed is left
    /// out ("+6", not "+6 −0"). With `compact`, used on a row, ten thousand lines and more (generated files) show as
    /// "+21.7k", and the exact count is left to the tooltip.
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
    /// Returns the folder whose git status, PR and CI a workspace shows. That is the workspace's own worktree, or the
    /// project's folder for a workspace that sits in it. It reads only the lists, so asking doesn't start the
    /// sidebar's watches (`gitState`).
    package func gitFolder(of workspace: String?) -> Worktree? {
        worktree(workspace).flatMap { gitFolder(workspace: $0.id) ?? gitFolder(project: $0.repoId) }
    }
    /// The key under which a workspace's git status and CI are watched, read and asked for again (`watch(.git, …)`,
    /// `latest(GitEvent.self, …)`). It is the key of the workspace's git folder, so workspaces that share a folder
    /// share one watch, as the sidebar does; a workspace with no folder of its own uses its own key.
    package func gitKey(_ workspace: String?) -> String { gitFolder(of: workspace)?.id ?? workspace ?? "" }
    /// Returns the folder that a project's row stands for, which is the project's own worktree (nil for a project that
    /// isn't a git folder).
    package func gitFolder(project id: String) -> Worktree? {
        guard let repo = repo(id) else { return nil }
        return worktrees.first { $0.repoId == id && $0.path == repo.path && !$0.archived }
    }
    /// The workspace's own git folder, when it is on a branch of its own; nil when it shares its project's folder.
    func gitFolder(workspace id: String) -> Worktree? {
        guard let worktree = worktree(id), !worktree.archived, worktree.path != repo(worktree.repoId)?.path else {
            return nil
        }
        return worktree
    }
    /// Every folder the sidebar lists. The sidebar's rows show their git status, PR and CI.
    package var gitFolders: Set<String> { gitState.folders }
    /// Returns the files of folder `id` that another folder of the project changes too, with that folder's branch
    /// (`GitFolders.shared`).
    package func sharedFiles(_ id: String?) -> [String: [String]] { id.map(gitState.shared) ?? [:] }
}
