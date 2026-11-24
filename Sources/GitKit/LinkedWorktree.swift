import Core
import Foundation

extension Git {
    /// The linked worktree `dir` is in (its top folder, which holds a `.git` file), when that worktree belongs to the
    /// same repository as `folder` and isn't `folder`'s own checkout: an agent's branch of its own (Claude Code's
    /// `.claude/worktrees/…`). Read off the files alone, no git run, because each of an agent's hooks asks it.
    public static func linkedWorktree(containing dir: String, besides folder: String) -> String? {
        guard let here = checkout(dir), here.linked, let home = checkout(folder), here.top != home.top,
            let repository = commonFolder(here), repository == commonFolder(home)
        else { return nil }
        return here.top
    }

    /// The branch a checkout has out, read from its HEAD file; nil while HEAD is detached or can't be read.
    public static func headBranch(_ folder: String) -> String? {
        guard let checkout = checkout(folder), let gitDir = gitDir(checkout),
            let data = FileManager.default.contents(atPath: gitDir + "/HEAD"),
            let head = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            head.hasPrefix("ref: refs/heads/")
        else { return nil }
        return String(head.dropFirst("ref: refs/heads/".count))
    }

    /// The top folder of the checkout `path` is in, and whether it is a linked worktree (its `.git` is a file).
    private static func checkout(_ path: String) -> (top: String, linked: Bool)? {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.path != "/" {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path, isDirectory: &isFolder) {
                // Resolved here, where the folder is there: a path under it that isn't (a hook's cwd) resolves no link.
                return (url.resolvingSymlinksInPath().path, !isFolder.boolValue)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// The checkout's git folder: its `.git` folder, or the one its `.git` file points at.
    private static func gitDir(_ checkout: (top: String, linked: Bool)) -> String? {
        guard checkout.linked else { return checkout.top + "/.git" }
        guard let data = FileManager.default.contents(atPath: checkout.top + "/.git"),
            let text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ")
        else { return nil }
        let pointed = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return pointed.hasPrefix("/")
            ? pointed : URL(fileURLWithPath: checkout.top).appendingPathComponent(pointed).path
    }

    /// The main checkout's folder that the repository's worktrees share.
    private static func commonFolder(_ checkout: (top: String, linked: Bool)) -> String? {
        guard checkout.linked else { return checkout.top }
        guard let gitDir = gitDir(checkout), let cut = gitDir.range(of: "/.git/worktrees/") else { return nil }
        return URL(fileURLWithPath: String(gitDir[..<cut.lowerBound])).resolvingSymlinksInPath().path
    }
}
