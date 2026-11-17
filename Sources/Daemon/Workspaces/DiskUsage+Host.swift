import Core
import Foundation
import GitKit

/// Measures a remote project's disk use on its host, where git and `du` run over the project's connection. The
/// connection dials the way the Files panel's first read does, because a view that asks for the measure has just been
/// shown. Paths in the project's folder come back under their names on this Mac, in its stand-in folder. The worktrees
/// beside that folder and Claude Code's chats on the host come back as the host names them.
extension DiskUsage {
    func measure(_ repo: Repo, on remote: RemoteHost) throws -> [Item] {
        let remotes = workspaces.remotes, root = try real(on: remote)
        var gathered = Gathered(root: root, here: false)
        let listed = try ProjectFiles.ignored(repo.path, remotes: remotes).map(Self.trimmed)
        gathered.ignored = Self.kept(listed, really: try Git.ignored(listed, cwd: repo.path, remotes: remotes))
        // Limit: a worktree on a host is shown but not removed from here, because the menu on its branch does that.
        let linked = try Git.linkedWorktrees(repo.path, remotes: remotes).map(\.path)
        for worktree in linked {
            let out = try remote.run(
                "cd -- \(ShellQuote.word(worktree)) 2>/dev/null || exit 0; "
                    + "git ls-files -z --others --ignored --exclude-standard --directory", timeLimit: 60)
            gathered.builds += Self.outermost(
                String(decoding: out, as: UTF8.self).split(separator: "\0").map {
                    Self.trimmed(String($0))
                }
            )
            .map { worktree + "/" + $0 }.filter { Self.isBuild($0, here: false) }.map { ($0, worktree) }
        }
        let totals = try Self.du(linked, on: remote)
        gathered.worktrees = linked.map { RepoWorktreeSizes.Item(path: $0, bytes: totals[$0] ?? 0, removable: false) }
        gathered.sizes = try Self.du(
            gathered.ignored.map { root + "/" + $0.rel } + gathered.builds.map(\.path), on: remote)
        gathered.total = try Self.du([root], on: remote)[root] ?? 0
        gathered.extra = try chats(of: [root] + linked, on: remote)
        // Paths in the project's folder get their names in the stand-in folder here, and the rest keep the host's.
        let here = { (path: String) in
            // The host's path is compared as a string, because `Paths.inside` looks at this Mac's disk.
            (path + "/").hasPrefix(root + "/") ? repo.path + path.dropFirst(root.count) : path
        }
        return Self.parts(gathered).map { item in
            var item = item
            item.path = here(item.path)
            item.worktree = item.worktree.map(here)
            return item
        }
    }

    /// Returns the sizes of Claude Code's conversations on the host for those folders, kept in its config folder there.
    private func chats(of folders: [String], on remote: RemoteHost) throws -> [Item] {
        let names = folders.map { "\"$d\"/" + ShellQuote.word(Self.claudeName($0)) }.joined(separator: " ")
        // `du` exits with 1 when a folder isn't there, as for most folders, because they have no conversations. A `du`
        // that failed in any other way fails the measure (`duEnded`).
        let out = try remote.run(
            #"d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"; du -sk -- "# + names + " 2>/dev/null; " + Self.duEnded,
            timeLimit: 60)
        return String(decoding: out, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let tab = line.firstIndex(of: "\t"), let kb = Int(line[..<tab]) else { return nil }
            return Item(path: String(line[line.index(after: tab)...]), bytes: kb * 1024, what: .chats, removable: false)
        }
    }

    /// Moves paths into the project's `.git/kelp-trash` on the host, which is the Files panel's trash there (kept a
    /// week, then removed). Only paths that are in the project's folder or a worktree, that git ignores and tracks
    /// nothing in, and that neither are a worktree nor contain one, are moved.
    func trash(_ paths: [String], of repo: Repo, on remote: RemoteHost) throws -> RepoRemoveWorktrees.Result {
        let root = try real(on: remote),
            linked = try Git.linkedWorktrees(repo.path, remotes: workspaces.remotes).map(\.path)
        // This connection names paths as the host does, and its trash is in the project's own .git there.
        var at = remote
        at.path = root
        let roots = [root] + linked, aside = HostFiles(folder: root, remote: at)
        var out = RepoRemoveWorktrees.Result(removed: [], kept: [:])
        for path in paths {
            // The path as the host names it, with `..` taken out so it can't leave the project. URL's standardizing
            // is used because it keeps `/private`, while NSString's drops it.
            let there = URL(
                fileURLWithPath: path.hasPrefix(repo.path + "/") ? root + path.dropFirst(repo.path.count) : path
            )
            .standardized.path
            guard let base = roots.filter({ there.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else {
                out.kept[path] = "Not part of the project."
                continue
            }
            // A worktree's own folder is refused too. In an ignored folder such as `.claude/worktrees/x`, git ignores
            // the worktree and tracks nothing in it, so it would be moved whole, uncommitted work and all.
            if roots.contains(where: { ($0 + "/").hasPrefix(there + "/") }) {
                out.kept[path] = roots.contains(there) ? "It is a worktree." : "A worktree is inside it."
                continue
            }
            do {
                let rel = ShellQuote.word(String(there.dropFirst(base.count + 1)))
                let said = try remote.run(
                    "cd -- \(ShellQuote.word(base)) || exit 1; [ -e \(rel) ] || { echo missing; exit 0; }; "
                        + "git check-ignore -q -- \(rel) && [ -z \"$(git ls-files -- \(rel) | head -c1)\" ] "
                        + "&& echo ok || echo tracked", timeLimit: 60)
                switch String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
                case "ok":
                    // This trashes the checked path as the host names it. A path in a worktree beside the project's
                    // folder isn't under `root`, so it has no name here to turn back into a host path.
                    _ = try aside.trash(there: there)
                    out.removed.append(path)
                case "missing": out.kept[path] = "Not part of the project."
                default: out.kept[path] = "Git tracks it."
                }
            } catch { out.kept[path] = (error as? RPCError)?.message ?? error.localizedDescription }
        }
        return out
    }

    /// The project's folder on the host as git there names it, links resolved (`pwd -P`).
    private func real(on remote: RemoteHost) throws -> String {
        let out = try remote.run("cd -- \(ShellQuote.word(remote.path)) && pwd -P", timeLimit: 30)
        let real = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return real.isEmpty ? remote.path : real
    }
}
