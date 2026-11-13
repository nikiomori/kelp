import Core
import Foundation
import GitKit

extension Workspaces {
    /// A branch's worktree in a remote project: on its host, beside the project's folder
    /// (`<folder>-worktrees/<branch>`), and a stand-in here like the project's own (its `.kelp-remote` names that
    /// folder), through which its git, files, agents and terminals reach the host. Answers the stand-in's path.
    /// `existing`: the branch as it is ("origin/x" a local "x" that follows it); else a new one from `base`.
    func remoteWorktree(_ repo: Repo, _ host: RemoteHost, branch: String, base: String, existing: Bool) throws -> String
    {
        let name = existing && branch.hasPrefix("origin/") ? String(branch.dropFirst("origin/".count)) : branch
        let slug = name.replacingOccurrences(of: "/", with: "-")
        let there = host.path + "-worktrees/" + slug
        let add = existing ? ["worktree", "add", there, name] : ["worktree", "add", "-b", branch, there, base]
        _ = try Git.run(add, cwd: repo.path, remotes: remotes)
        // Beside the project's stand-in, a folder of its own.
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
