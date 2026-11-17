import Core
import Foundation
import GitKit

extension Workspaces {
    /// Makes a branch's worktree in a remote project and returns the path of its stand-in folder on this Mac. The
    /// worktree is on the host, beside the project's folder (`<folder>-worktrees/<branch>`). The stand-in works like
    /// the project's own: its `.kelp-remote` names the host folder, and the worktree's git, files, agents and terminals
    /// reach the host through it. With `existing`, the branch is checked out as it is ("origin/x" becomes a local "x"
    /// that follows it). Otherwise a new branch is made from `base`.
    func remoteWorktree(_ repo: Repo, _ host: RemoteHost, branch: String, base: String, existing: Bool) throws -> String
    {
        let name = existing && branch.hasPrefix("origin/") ? String(branch.dropFirst("origin/".count)) : branch
        let slug = name.replacingOccurrences(of: "/", with: "-")
        let there = host.path + "-worktrees/" + slug
        let add = existing ? ["worktree", "add", there, name] : ["worktree", "add", "-b", branch, there, base]
        _ = try Git.run(add, cwd: repo.path, remotes: remotes)
        // The stand-in gets a folder of its own, beside the project's stand-in.
        let dir = URL(fileURLWithPath: repo.path).deletingLastPathComponent(),
            stem =
                URL(fileURLWithPath: repo.path)
                .lastPathComponent + "-" + slug
        var folder = dir.appendingPathComponent(stem), number = 2
        while !Self.claim(folder.path) {
            guard number < 100 else { throw RPCError.internalError("No free folder for \(stem) in \(dir.path)") }
            folder = dir.appendingPathComponent("\(stem)-\(number)")
            number += 1
        }
        try JSONEncoder().encode(RemoteHost(host: host.host, path: there))
            .write(to: folder.appendingPathComponent(RemoteHost.marker))
        return folder.path
    }
}
