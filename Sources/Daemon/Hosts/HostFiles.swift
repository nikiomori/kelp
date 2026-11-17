import Core
import Foundation

/// Moves, copies, makes and trashes a remote project's files on its host. It does what the Files panel does on this
/// Mac, in sh on the host (POSIX tools only). Paths go in and come out as named under the project's folder on this Mac
/// (`folder`), so a move's Undo is a move again. A free name ("name copy 2.ext") is picked on the host from the names
/// that `FileService.named` makes.
struct HostFiles {
    /// `folder` is the project's folder on this Mac, and `remote` is the host folder it stands for.
    let folder: String, remote: RemoteHost

    /// Returns the remote project that `path` (absolute, standardized) is in or is. Returns nil for a path on this Mac.
    static func of(_ path: String, _ remotes: Remotes) -> HostFiles? {
        if let remote = remotes.of(path) { return HostFiles(folder: path, remote: remote) }
        return remotes.containing(path).map { HostFiles(folder: $0.folder, remote: $0.remote) }
    }

    /// Returns where `path` is on the host. `..` is resolved first, and only a path inside the folder is mapped. Any
    /// other path names nothing on the host. When the folder's length was once dropped without this check, a
    /// worktree's build ended up in the main checkout's folder.
    func there(_ path: String) throws -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        // The folder stands in for the host's, so it is compared as a string. `Paths.inside` looks at this Mac's
        // disk, where the files aren't.
        guard (path + "/").hasPrefix(folder + "/") else {
            throw RPCError.invalidParams("\((path as NSString).lastPathComponent) isn't in the project.")
        }
        return remote.path + path.dropFirst(folder.count)
    }
    /// Maps a host path back to this Mac. It only gets paths that a script here made from what `there` returned, or
    /// put in the trash, so the path is always in `remote.path`.
    func here(_ path: String) -> String { folder + path.dropFirst(remote.path.count) }

    func move(_ from: String, _ to: String, unique: Bool) throws -> String {
        let from = try word(from)
        return try run(
            "f=\(from); [ -e \"$f\" ] || [ -L \"$f\" ] || { echo \"It isn't there any more.\" >&2; exit 1; }; "
                + pick(to, word: "copy", unique: unique) + #"mkdir -p -- "$(dirname -- "$t")" && mv -- "$f" "$t""#)
    }

    func copy(_ path: String, into dir: String) throws -> String {
        let to = dir + "/" + (path as NSString).lastPathComponent
        return try run("f=\(try word(path)); " + pick(to, word: "copy", unique: true) + #"cp -R -- "$f" "$t""#)
    }

    /// Makes a file or folder. A name that is taken fails, so nothing is written over (`set -C`).
    func create(_ path: String, folder isFolder: Bool, text: String?, unique: Bool) throws -> String {
        let make = isFolder ? #"mkdir -- "$t""# : #"(set -C; cat > "$t")"#
        return try run(
            try pick(path, word: nil, unique: unique) + #"mkdir -p -- "$(dirname -- "$t")" && "# + make,
            stdin: isFolder ? nil : Data((text ?? "").utf8))
    }

    /// Moves `path` into a trash in the repository's own folder (`.git/kelp-trash`, which git doesn't list), so Undo
    /// can move it back. Each trashing deletes for good what was put there over a week ago.
    /// Limit: a project whose .git is a file (a worktree) has no trash.
    func trash(_ path: String) throws -> String { try trash(there: there(path)) }

    /// Trashes `path` as the host names it, because a build in a worktree outside the project's folder has no name on
    /// this Mac (`DiskUsage`).
    func trash(there path: String) throws -> String {
        let bin = remote.path + "/.git/kelp-trash"
        return try run(
            "f=\(ShellQuote.word(path)); b=\(ShellQuote.word(bin)); [ -d \(ShellQuote.word(remote.path + "/.git")) ] "
                + #"|| { echo "Its repository has no trash." >&2; exit 1; }; "#
                + #"mkdir -p "$b" && find "$b" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + ; "#
                + #"d="$b/$(date +%s)-$$"; mkdir "$d" && t="$d/$(basename -- "$f")" && mv -- "$f" "$t""#)
    }

    /// Runs `script`, which leaves the path it made in `$t`, and returns that path as named on this Mac.
    private func run(_ script: String, stdin: Data? = nil) throws -> String {
        do {
            let out = try remote.run(script + #" && printf %s "$t""#, stdin: stdin, timeLimit: 120)
            return here(String(decoding: out, as: UTF8.self))
        } catch let error as ProgramError {
            let why = ProgramError.firstSentence(error.stderr) ?? "It didn't work on \(remote.host)."
            throw RPCError.invalidParams(why)
        }
    }

    /// Returns sh that sets `t` to `path` on the host, and fails when that name is taken. With `unique`, `t` is instead
    /// the first free name among `path` and its numbered names.
    private func pick(_ path: String, word: String?, unique: Bool) throws -> String {
        guard unique else {
            let taken = ShellQuote.word((path as NSString).lastPathComponent + " is taken.")
            return "t=\(try self.word(path)); [ -e \"$t\" ] && { echo \(taken) >&2; exit 1; }; "
        }
        let names = [path] + (1...99).map { FileService.named(path, word: word, word == nil ? $0 + 1 : $0) }
        return "for t in " + (try names.map(self.word)).joined(separator: " ") + #"; do [ -e "$t" ] || break; done; "#
    }

    private func word(_ path: String) throws -> String { ShellQuote.word(try there(path)) }
}
