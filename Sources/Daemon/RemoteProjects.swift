import Core
import Foundation
import GitKit

/// Remote projects (SSH): added by host and folder, their files read from the host. See `RemoteHost`.
extension Workspaces {

    /// The local folder's name for a path on a host: its last component, or "project" when that isn't a usable name
    /// ("/", "~", "..", "."), so the folder always lands inside the host's folder.
    static func remoteFolderName(_ path: String) -> String {
        let last = (path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) as NSString).lastPathComponent
        return ["", ".", "..", "~"].contains(last) || last.hasPrefix(".") || last.contains("/") ? "project" : last
    }
}

extension RemoteListFolders: Handled {
    func handle(_ remotes: Remotes) throws -> Result {
        let host = host.trimmingCharacters(in: .whitespaces), path = path.trimmingCharacters(in: .whitespaces)
        guard RemoteHost.isHost(host) else {
            throw RPCError.invalidParams("Enter the host, as you'd type it after ssh.")
        }
        // In sh whatever the host's login shell is: the folder's path, whether it's in a repository, then "g name" for a
        // repository, "d name" for the rest.
        let script =
            "cd \(RemoteHost.cdArg(path.isEmpty ? "~" : path)) || exit 1; pwd; "
            + "if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then echo repo; else echo none; fi; "
            + #"for f in *; do [ -d "$f" ] || continue; if [ -e "$f/.git" ]; then echo "g $f"; else echo "d $f"; fi; done"#
        let out: String
        do {
            out = try Git.run(
                ["-o", "ConnectTimeout=10"] + remotes.host(host, path: "~").sshArgs(tty: false) + [
                    "sh -c " + IDE.shellWord(script)
                ],
                cwd: NSHomeDirectory(), executable: remotes.ssh)
        } catch let e as GitError {
            let why = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RPCError.invalidParams(why.isEmpty ? "Couldn't connect to \(host)." : why)
        }
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { throw RPCError.invalidParams("Couldn't list \(path) on \(host).") }
        return Result(
            path: lines[0], repo: lines[1] == "repo",
            folders: lines.dropFirst(2).filter { $0.count > 2 }.map {
                Folder(name: String($0.dropFirst(2)), git: $0.hasPrefix("g "))
            })
    }
}

/// {host, path, init?} → the project (its local folder stands for the one on the host).
extension RepoAddRemote: Handled {
    func handle(_ workspaces: Workspaces) throws -> Repo {
        let host = host.trimmingCharacters(in: .whitespaces), path = path.trimmingCharacters(in: .whitespaces)
        guard RemoteHost.isHost(host) else {
            throw RPCError.invalidParams("Enter the host, as you'd type it after ssh.")
        }
        guard path.hasPrefix("/") || path.hasPrefix("~") else {
            throw RPCError.invalidParams("Enter the folder's full path on \(host).")
        }
        // Already added (the folder's marker names this host and path): that project, whatever its folder is called.
        // The marker keeps git's answer for the top folder (symlinks resolved, ~ expanded): match the path as typed, the
        // same path resolved where that's possible here (the "host" can be this Mac), and ~/… by its tail.
        let real = Paths.real(path)
        func same(_ m: RemoteHost) -> Bool {
            m.host == host
                && (m.path == path || m.path == real
                    || (path.hasPrefix("~/") && m.path.hasSuffix(String(path.dropFirst()))))
        }
        if let r = try workspaces.store.repos().first(where: { workspaces.remotes.of($0.path).map(same) ?? false }) {
            return r
        }
        let name = Workspaces.remoteFolderName(path)
        let hostDir = workspaces.root.appendingPathComponent("remote").appendingPathComponent(
            host.replacingOccurrences(of: "/", with: "_"))
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        // A folder of its own, made here: /a/app and /b/app on one host don't share one, and a failure below removes
        // only this folder, never another project's.
        var folder = hostDir.appendingPathComponent(name), n = 2
        while !Workspaces.claim(folder.path) {
            guard n < 100 else { throw RPCError.internalError("No free folder for \(name) in \(hostDir.path)") }
            folder = hostDir.appendingPathComponent("\(name)-\(n)")
            n += 1
        }
        func mark(_ r: RemoteHost) throws {
            try JSONEncoder().encode(r).write(to: folder.appendingPathComponent(RemoteHost.marker))
        }
        // ~ as the host's shell spells it: ask git there where the repository's top is.
        try mark(RemoteHost(host: host, path: path))
        // init: a folder that isn't a repository yet becomes one (the sheet's Initialize Git and Open).
        if `init` == true {
            do { _ = try Git.run(["init", "-q"], cwd: folder.path, remotes: workspaces.remotes) } catch let e
                as GitError
            {
                Log.store.attempt("removing a remote project's marker folder") {
                    try FileManager.default.removeItem(at: folder)
                }
                throw RPCError.invalidParams("Couldn't run git init in \(path) on \(host): \(e.stderr)")
            }
        }
        let top: String
        do { top = try Git.root(of: folder.path, remotes: workspaces.remotes) } catch let e as GitError {
            Log.store.attempt("removing a remote project's marker folder") {
                try FileManager.default.removeItem(at: folder)
            }
            throw RPCError.invalidParams(
                "Couldn't open \(path) on \(host): \(e.stderr.isEmpty ? "ssh failed" : e.stderr)")
        }
        try mark(RemoteHost(host: host, path: top))
        let r = Repo(
            name: (top as NSString).lastPathComponent.isEmpty ? name : Workspaces.remoteFolderName(top),
            path: folder.path,
            baseBranch: Git.defaultBranch(repo: folder.path, remotes: workspaces.remotes))
        try workspaces.store.save(r)
        try workspaces.syncMainWorkspaces()
        workspaces.notify(ChangedEvent.repo)
        return r
    }
}

/// `files.read` for a remote project's file, as the app first asked it: the text alone.
extension FilesReadRemote: Handled {
    func handle(_ files: FileService) throws -> String {
        guard files.remotes.containing(path) != nil else { throw RPCError.invalidParams("Not in a remote project.") }
        return try files.read(path).text
    }
}

/// `files.write` with the text read as its base instead of a stamp; a file that's gone is just written again.
extension FilesWriteRemote: Handled {
    func handle(_ files: FileService) throws -> Changed? {
        guard let host = files.remotes.containing(path)?.remote.host else {
            throw RPCError.invalidParams("Not in a remote project.")
        }
        let r = try files.write(path, text, base: base.map { FileService.digest(Data($0.utf8)) })
        if let c = r.conflict {
            // A version there that isn't UTF-8 text can't be shown, and writing over it unasked could lose it.
            guard let now = c.text else {
                throw RPCError.invalidParams("It changed on \(host) and isn't UTF-8 text now: not written.")
            }
            return Changed(changed: now)
        }
        if r.missing == true { _ = try files.write(path, text, base: nil) }
        return nil
    }
}
