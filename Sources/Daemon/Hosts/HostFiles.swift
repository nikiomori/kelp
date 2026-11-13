import Core
import Foundation

/// Moving, copying, making and trashing a remote project's files, on its host: what the Files panel does here, in sh
/// there (POSIX tools only). Paths go in and come out as the project's folder here names them (`folder`), so a move's
/// Undo is a move again. A free name ("name copy 2.ext") is picked there from the ones `FileService.named` makes.
struct HostFiles {
    /// The project's folder here, and what it stands for.
    let folder: String, remote: RemoteHost

    /// The remote project `path` (absolute, standardized) is in, or is: nil for one on this Mac.
    static func of(_ path: String, _ remotes: Remotes) -> HostFiles? {
        if let remote = remotes.of(path) { return HostFiles(folder: path, remote: remote) }
        return remotes.containing(path).map { HostFiles(folder: $0.folder, remote: $0.remote) }
    }

    /// Where it is on the host; and back.
    func there(_ path: String) -> String { remote.path + path.dropFirst(folder.count) }
    func here(_ path: String) -> String { folder + path.dropFirst(remote.path.count) }

    func move(_ from: String, _ to: String, unique: Bool) throws -> String {
        try run(
            "f=\(word(from)); [ -e \"$f\" ] || [ -L \"$f\" ] || { echo \"It isn't there any more.\" >&2; exit 1; }; "
                + pick(to, word: "copy", unique: unique) + #"mkdir -p -- "$(dirname -- "$t")" && mv -- "$f" "$t""#)
    }

    func copy(_ path: String, into dir: String) throws -> String {
        let to = dir + "/" + (path as NSString).lastPathComponent
        return try run("f=\(word(path)); " + pick(to, word: "copy", unique: true) + #"cp -R -- "$f" "$t""#)
    }

    /// A taken name fails: nothing is written over (`set -C`).
    func create(_ path: String, folder isFolder: Bool, text: String?, unique: Bool) throws -> String {
        let make = isFolder ? #"mkdir -- "$t""# : #"(set -C; cat > "$t")"#
        return try run(
            pick(path, word: nil, unique: unique) + #"mkdir -p -- "$(dirname -- "$t")" && "# + make,
            stdin: isFolder ? nil : Data((text ?? "").utf8))
    }

    /// Into the repository's own folder (`.git/kelp-trash`, which git doesn't list), so Undo moves it back; what was
    /// put there over a week ago goes for good then. Limit: a project whose .git is a file (a worktree) has no trash.
    func trash(_ path: String) throws -> String {
        let bin = remote.path + "/.git/kelp-trash"
        return try run(
            "f=\(word(path)); b=\(ShellQuote.word(bin)); [ -d \(ShellQuote.word(remote.path + "/.git")) ] "
                + #"|| { echo "Its repository has no trash." >&2; exit 1; }; "#
                + #"mkdir -p "$b" && find "$b" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + ; "#
                + #"d="$b/$(date +%s)-$$"; mkdir "$d" && t="$d/$(basename -- "$f")" && mv -- "$f" "$t""#)
    }

    /// `script`, which leaves the path made in `$t`: that path, as named here.
    private func run(_ script: String, stdin: Data? = nil) throws -> String {
        do {
            let out = try remote.run(script + #" && printf %s "$t""#, stdin: stdin, timeLimit: 120)
            return here(String(decoding: out, as: UTF8.self))
        } catch let error as ProgramError {
            let why = ProgramError.firstSentence(error.stderr) ?? "It didn't work on \(remote.host)."
            throw RPCError.invalidParams(why)
        }
    }

    /// Sets `t` to `path` there or, `unique`, the first free one of it and its numbered names.
    private func pick(_ path: String, word: String?, unique: Bool) -> String {
        guard unique else {
            let taken = ShellQuote.word((path as NSString).lastPathComponent + " is taken.")
            return "t=\(self.word(path)); [ -e \"$t\" ] && { echo \(taken) >&2; exit 1; }; "
        }
        let names = [path] + (1...99).map { FileService.named(path, word: word, word == nil ? $0 + 1 : $0) }
        return "for t in " + names.map(self.word).joined(separator: " ") + #"; do [ -e "$t" ] || break; done; "#
    }

    private func word(_ path: String) -> String { ShellQuote.word(there(path)) }
}
