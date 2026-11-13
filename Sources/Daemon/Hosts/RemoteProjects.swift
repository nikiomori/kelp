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
        // A folder of its own, made here: /a/app and /b/app on one host don't share one, and a failure below removes
        // only this folder, never another project's.
        var folder = hostDir.appendingPathComponent(name), number = 2
        while !Workspaces.claim(folder.path) {
            guard number < 100 else { throw RPCError.internalError("No free folder for \(name) in \(hostDir.path)") }
            folder = hostDir.appendingPathComponent("\(name)-\(number)")
            number += 1
        }
        func mark(_ remote: RemoteHost) throws {
            try JSONEncoder().encode(remote).write(to: folder.appendingPathComponent(RemoteHost.marker))
        }
        // ~ as the host's shell spells it: ask git there where the repository's top is.
        try mark(RemoteHost(host: host, path: path))
        // init: a folder that isn't a repository yet becomes one (the sheet's Initialize Git and Open).
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
        let result = try files.write(path, text, base: base.map { FileService.digest(Data($0.utf8)) })
        if let conflict = result.conflict {
            // A version there that isn't UTF-8 text can't be shown, and writing over it unasked could lose it.
            guard let now = conflict.text else {
                throw RPCError.invalidParams("It changed on \(host) and isn't UTF-8 text now: not written.")
            }
            return Changed(changed: now)
        }
        if result.missing == true { _ = try files.write(path, text, base: nil) }
        return nil
    }
}

/// A host's keys as ssh-keyscan reads them where ~/.ssh/config sends `host` (`ssh -G`): its known_hosts lines, and
/// the file ssh keeps them in.
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

/// "SHA256:…" and the kind of the first of `lines`' keys, as ssh-keygen shows one.
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
        // In its login shell, as an agent's command line is there (`RemoteHost.command`): nvm's PATH is in .bashrc.
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
        RemoteListFolders.self, RepoAddRemote.self, FilesReadRemote.self, FilesWriteRemote.self, RemoteHostKey.self,
        RemoteTrustHost.self, HostCommands.self
    ]
}
