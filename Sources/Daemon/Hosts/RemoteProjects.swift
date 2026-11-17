import Core
import Foundation
import GitKit

/// Remote projects (SSH) are added by host and folder, and their files are read from the host. See `RemoteHost`.
extension Workspaces {

    /// Returns the local folder's name for a path on a host. It is the path's last component, or "project" when that
    /// isn't a usable name ("/", "~", "..", ".", or a name that starts with a dot), so the folder always lands inside
    /// the host's folder.
    static func remoteFolderName(_ path: String) -> String {
        let last = (path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) as NSString).lastPathComponent
        return ["", ".", "..", "~"].contains(last) || last.hasPrefix(".") || last.contains("/") ? "project" : last
    }
}

extension RemoteListFolders: Handled {
    static let agents = AgentAccess.reads
    func handle(_ remotes: Remotes) throws -> Result {
        let host = host.trimmingCharacters(in: .whitespaces), path = path.trimmingCharacters(in: .whitespaces)
        guard RemoteHost.isHost(host) else {
            throw RPCError.invalidParams("Enter the host, as you'd type it after ssh.")
        }
        // Written in sh, whatever the host's login shell is: it prints the folder's path, whether it is in a
        // repository, then "g name" for each repository and "d name" for every other folder.
        let script =
            "cd \(RemoteHost.cdArg(path.isEmpty ? "~" : path)) || exit 1; pwd; "
            + "if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then echo repo; else echo none; fi; "
            + #"for f in *; do [ -d "$f" ] || continue; if [ -e "$f/.git" ]; then echo "g $f"; else echo "d $f"; fi; done"#
        let out: String
        do {
            out = String(
                decoding: try Subprocess.output(
                    [remotes.ssh, "-o", "ConnectTimeout=10"] + remotes.host(host, path: "~").sshArgs(tty: false) + [
                        "sh -c " + ShellQuote.word(script)
                    ],
                    cwd: NSHomeDirectory()), as: UTF8.self)
        } catch let error as ProgramError {
            let why = error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Adds a remote project from {host, path, init?} and returns it. The project's local folder stands for the folder on
/// the host.
extension RepoAddRemote: Handled {
    func handle(_ workspaces: Workspaces) throws -> Repo {
        let host = host.trimmingCharacters(in: .whitespaces), path = path.trimmingCharacters(in: .whitespaces)
        guard RemoteHost.isHost(host) else {
            throw RPCError.invalidParams("Enter the host, as you'd type it after ssh.")
        }
        guard path.hasPrefix("/") || path.hasPrefix("~") else {
            throw RPCError.invalidParams("Enter the folder's full path on \(host).")
        }
        // When the project is already added (its folder's marker names this host and path), return that project,
        // whatever its folder is called. The marker keeps git's answer for the top folder, with symlinks resolved and
        // ~ expanded. So the path matches as typed, as resolved on this Mac where that's possible (the "host" can be
        // this Mac), or, for ~/…, by its tail.
        let real = Paths.real(path)
        func same(_ marker: RemoteHost) -> Bool {
            marker.host == host
                && (marker.path == path || marker.path == real
                    || (path.hasPrefix("~/") && marker.path.hasSuffix(String(path.dropFirst()))))
        }
        if let existing = try workspaces.store.repos().first(where: {
            workspaces.remotes.of($0.path).map(same) ?? false
        }) {
            return existing
        }
        let name = Workspaces.remoteFolderName(path)
        let hostDir = workspaces.root.appendingPathComponent("remote").appendingPathComponent(
            host.replacingOccurrences(of: "/", with: "_"))
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        // The project gets a folder of its own on this Mac, so /a/app and /b/app on one host don't share one, and a
        // failure below removes only this folder, never another project's.
        var folder = hostDir.appendingPathComponent(name), number = 2
        while !Workspaces.claim(folder.path) {
            guard number < 100 else { throw RPCError.internalError("No free folder for \(name) in \(hostDir.path)") }
            folder = hostDir.appendingPathComponent("\(name)-\(number)")
            number += 1
        }
        func mark(_ remote: RemoteHost) throws {
            try JSONEncoder().encode(remote).write(to: folder.appendingPathComponent(RemoteHost.marker))
        }
        // The marker first keeps the path as typed, with ~ as the host's shell spells it. Git on the host then says
        // where the repository's top is.
        try mark(RemoteHost(host: host, path: path))
        // With `init`, a folder that isn't a repository yet becomes one (the sheet's Initialize Git and Open).
        if `init` == true {
            do { _ = try Git.run(["init", "-q"], cwd: folder.path, remotes: workspaces.remotes) } catch let error
                as GitError
            {
                Log.store.attempt("removing a remote project's marker folder") {
                    try FileManager.default.removeItem(at: folder)
                }
                let why = error.stderr ?? error.message
                throw RPCError.invalidParams("Couldn't run git init in \(path) on \(host): \(why)")
            }
        }
        let top: String
        do { top = try Git.root(of: folder.path, remotes: workspaces.remotes) } catch let error as GitError {
            Log.store.attempt("removing a remote project's marker folder") {
                try FileManager.default.removeItem(at: folder)
            }
            let why = error.stderr.map { $0.isEmpty ? "ssh failed" : $0 } ?? error.message
            throw RPCError.invalidParams("Couldn't open \(path) on \(host): \(why)")
        }
        try mark(RemoteHost(host: host, path: top))
        let repo = Repo(
            name: (top as NSString).lastPathComponent.isEmpty ? name : Workspaces.remoteFolderName(top),
            path: folder.path,
            baseBranch: Git.defaultBranch(repo: folder.path, remotes: workspaces.remotes))
        try workspaces.store.save(repo)
        try workspaces.syncMainWorkspaces()
        workspaces.notify(ChangedEvent.repo)
        return repo
    }
}

/// Scans a host's keys with ssh-keyscan, at the address where ~/.ssh/config sends `host` (`ssh -G`). Returns the keys
/// as known_hosts lines, and the file that ssh keeps them in.
private func scanKeys(_ remotes: Remotes, _ host: String) -> (lines: [String], knownHosts: String)? {
    func run(_ argv: [String], stdin: Data? = nil) -> String? {
        Log.session.attempt("asking \(host)'s key") {
            String(
                decoding: try Subprocess.output(argv, cwd: NSHomeDirectory(), stdin: stdin, timeLimit: 15),
                as: UTF8.self)
        }
    }
    guard RemoteHost.isHost(host), let config = run([remotes.ssh, "-G", "--", host]) else { return nil }
    var said: [String: String] = [:]
    for line in config.split(separator: "\n") {
        let words = line.split(separator: " ", maxSplits: 1).map(String.init)
        if words.count == 2, said[words[0]] == nil { said[words[0]] = words[1] }
    }
    guard let name = said["hostname"], said["proxyjump"] == nil, said["proxycommand"] == nil,
        let scanned = run(["/usr/bin/ssh-keyscan", "-T", "10", "-t", "ed25519", "-p", said["port"] ?? "22", name])
    else { return nil }
    let lines = scanned.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
    let known = (said["userknownhostsfile"]?.split(separator: " ").first.map(String.init) ?? "~/.ssh/known_hosts")
    return lines.isEmpty ? nil : (lines, (known as NSString).expandingTildeInPath)
}

/// Returns the fingerprint ("SHA256:…") and the kind of the first key in `lines`, as ssh-keygen shows them.
func keyFingerprint(_ lines: [String]) -> RemoteHostKey.Key? {
    let out = Log.session.attempt("reading a host key's fingerprint") {
        String(
            decoding: try Subprocess.output(
                ["/usr/bin/ssh-keygen", "-l", "-f", "-"], cwd: "/",
                stdin: Data((lines.joined(separator: "\n") + "\n").utf8),
                timeLimit: 10), as: UTF8.self)
    }
    // "256 SHA256:abc… [host]:22 (ED25519)"
    guard let words = out?.split(separator: "\n").first?.split(separator: " "), words.count >= 3,
        let kind = words.last?.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    else { return nil }
    return .init(fingerprint: String(words[1]), kind: kind)
}

extension HostCommands: Handled {
    func handle(_ workspaces: Workspaces) throws -> [String] {
        guard let worktree = try workspaces.store.worktree(worktreeId),
            let remote = workspaces.remotes.of(worktree.path)
        else { throw RPCError.invalidParams("Not a remote project's workspace.") }
        let names = Set(commands.map { ($0 as NSString).lastPathComponent }.filter { !$0.isEmpty })
        guard !names.isEmpty else { return [] }
        // Look in the host's login shell, where an agent's command line runs too (`RemoteHost.command`), because
        // nvm's PATH is set in .bashrc.
        let look =
            "for c in " + names.sorted().map(ShellQuote.word).joined(separator: " ")
            + #"; do command -v "$c" >/dev/null 2>&1 && echo "found:$c"; done; exit 0"#
        let out = try remote.run(#"exec "$SHELL" -ilc "# + ShellQuote.word(look), timeLimit: 20)
        return String(decoding: out, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
            $0.hasPrefix("found:") ? String($0.dropFirst(6)) : nil
        }.filter(names.contains)
    }
}

extension RemoteHostKey: Handled {
    func handle(_ remotes: Remotes) throws -> Result { scanKeys(remotes, host).flatMap { keyFingerprint($0.lines) } }
}

extension RemoteTrustHost: Handled {
    func handle(_ remotes: Remotes) throws -> Done {
        guard let (lines, file) = scanKeys(remotes, host), keyFingerprint(lines)?.fingerprint == fingerprint else {
            throw RPCError.invalidParams("\(host)'s key isn't the one shown any more: not trusted.")
        }
        let dir = (file as NSString).deletingLastPathComponent, fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let had = fm.contents(atPath: file).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let text = had + (had.isEmpty || had.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: URL(fileURLWithPath: file), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        return Done()
    }
}

extension Methods {
    static let remoteMethods: [any Answered.Type] = [
        RemoteListFolders.self, RepoAddRemote.self, RemoteHostKey.self,
        RemoteTrustHost.self, HostCommands.self
    ]
}
