import Core
import Foundation
import GitKit

/// Reads and writes files' text and runs the Files panel's operations, for a file on this Mac or in a remote project
/// (on its host, over ssh). It keeps the rules a tab keeps. It opens only regular files up to `Unopenable.openLimit`
/// and only UTF-8 text, and a save never writes over a version whose stamp it wasn't given.
/// It takes any absolute path, because the app opens files outside projects too (`kelp open`, the help, Save As…).
/// Whoever can reach the socket (mode 0600, owned by this user) can already run programs here (`process.run`), so a
/// list of allowed folders would guard nothing.
struct FileService: Sendable {
    let remotes: Remotes

    func read(_ path: String) throws -> FilesRead.Result {
        let path = try absolute(path)
        if let located = remotes.containing(path) { return try readRemote(located.remote, located.remotePath) }
        guard let (stamp, data) = try contents(path) else {
            throw RPCError.invalidParams("It isn't on this Mac any more (moved or deleted).")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Unopenable.binary.error }
        return .init(text: text, stamp: stamp)
    }

    /// Copies a remote project's file into the temporary folder on this Mac, which the system empties, and returns the
    /// copy's path. The copy keeps the file's name so a viewer knows its type. A file on this Mac is its own copy.
    func fetch(_ path: String) throws -> String {
        let path = try absolute(path)
        guard let located = remotes.containing(path) else { return path }
        let data = try remoteBytes(located.remote, located.remotePath)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-remote")
            .appendingPathComponent(
                String(Self.digest(Data((located.remote.host + ":" + located.remotePath).utf8)).dropFirst(7).prefix(16))
            )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: copy, options: .atomic)
        return copy.path
    }

    /// Returns a remote project's icon, kept in the project's folder on this Mac (`.kelp-icon/`, beside its marker). A
    /// kept icon is returned at once and looked for again in the background. With none kept, it is looked for now. The
    /// host is asked only over a connection that is already open, so drawing the sidebar never dials a host. Until
    /// something connects, the result is the kept icon or nil.
    func icon(_ repo: String) throws -> String? {
        let repo = try absolute(repo)
        guard let remote = remotes.of(repo) else { throw RPCError.invalidParams("Not a remote project.") }
        let kept = repo + "/.kelp-icon", name = FileManager.default.names(in: kept).first
        guard remote.connection != nil else { return name.map { kept + "/" + $0 } }
        guard let name else { return try findIcon(remote, keep: kept) }
        DispatchQueue.global(qos: .utility).async {
            Log.store.attempt("looking for \(remote.host)'s project icon") { _ = try findIcon(remote, keep: kept) }
        }
        return kept + "/" + name
    }

    func write(_ path: String, _ text: String, base: FileStamp?) throws -> FilesWrite.Result {
        let path = try absolute(path), data = Data(text.utf8)
        guard data.count <= Unopenable.openLimit else { throw Unopenable.tooBig(data.count).error }
        if let located = remotes.containing(path) {
            return try writeRemote(located.remote, located.remotePath, data, base: base)
        }
        // Limit: the file is checked and then written, so an agent's write between the two is lost, because agents
        // take no lock to wait on.
        if let base {
            guard let now = Self.stamp(path) else { return .init(missing: true) }
            if now != base {
                // When the file can't be read as text now (grown past the limit, now a pipe, or another encoding),
                // the conflict carries no text, and the file is still not written.
                let current = try? contents(path)
                return .init(
                    conflict: .init(
                        stamp: current?.stamp ?? now, text: current.flatMap { String(data: $0.data, encoding: .utf8) }))
            }
        }
        // Writes through a symlink to the file it points at, because an atomic write to the link would replace the
        // link with a plain file.
        try data.write(to: URL(fileURLWithPath: path).resolvingSymlinksInPath(), options: .atomic)
        guard let stamp = Self.stamp(path) else {
            throw RPCError.internalError("\(path) was written but isn't there now.")
        }
        return .init(stamp: stamp)
    }

    func move(_ pairs: [FileMove], unique: Bool) -> FilesMove.Result {
        let (done, error) = each(pairs) { pair in
            if let host = try onHost(pair.from, pair.to) {
                return FileMove(from: pair.from, to: try host.move(pair.from, pair.to, unique: unique))
            }
            let from = try here(pair.from), named = try here(pair.to), to = unique ? Self.free(named) : named
            try FileManager.default.moveItem(atPath: from, toPath: to)
            return FileMove(from: from, to: to)
        }
        return .init(done: done, error: error)
    }

    func trash(_ paths: [String]) -> FilesMove.Result {
        let (done, error) = each(paths) { path in
            if let host = try onHost(path) { return FileMove(from: path, to: try host.trash(path)) }
            let from = try here(path)
            return FileMove(from: from, to: try Trash.move(URL(fileURLWithPath: from)).path)
        }
        return .init(done: done, error: error)
    }

    func copy(_ paths: [String], into: String) -> FilesCopy.Result {
        let (made, error) = each(paths) { path in
            if let host = try onHost(path, into) { return try host.copy(path, into: into) }
            let from = try here(path), dir = try here(into),
                to = Self.free(dir + "/" + (from as NSString).lastPathComponent)
            try FileManager.default.copyItem(atPath: from, toPath: to)
            return to
        }
        return .init(made: made, error: error)
    }

    /// Runs `step` on each item in turn, stopping at the first that fails. Returns what was done, and the message that
    /// says why that item failed.
    private func each<Item, Done>(_ items: [Item], _ step: (Item) throws -> Done) -> ([Done], String?) {
        var done: [Done] = []
        for item in items {
            do { done.append(try step(item)) } catch { return (done, message(error)) }
        }
        return (done, nil)
    }

    func create(_ path: String, folder: Bool, text: String?, unique: Bool) throws -> String {
        if let host = try onHost(path) { return try host.create(path, folder: folder, text: text, unique: unique) }
        let named = try here(path), path = unique ? Self.free(named, word: nil) : named, fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A name that is taken fails, so an existing file is never written over and an existing folder is never taken
        // for a new one.
        if folder {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
        } else {
            try Data((text ?? "").utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
        return path
    }

    /// Returns `path` when nothing is there, or else the first of "name copy.ext", "name copy 2.ext" and so on that
    /// doesn't exist. With `word` nil, the names tried are "name 2.ext" and so on.
    static func free(_ path: String, word: String? = "copy") -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        var number = word == nil ? 2 : 1
        while true {
            let candidate = Self.named(path, word: word, number)
            if !fm.fileExists(atPath: candidate) { return candidate }
            number += 1
        }
    }

    /// Returns a name beside `path` for a copy, such as "name copy 2.ext", without checking whether it is free. With
    /// `number` 1 it is "name copy.ext", and with `word` nil it is "name 2.ext".
    static func named(_ path: String, word: String?, _ number: Int) -> String {
        let url = URL(fileURLWithPath: path), ext = url.pathExtension,
            base = url.deletingPathExtension().lastPathComponent
        let stem = [base, word].compactMap { $0 }.joined(separator: " ") + (number > 1 ? " \(number)" : "")
        return url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? stem : stem + "." + ext).path
    }

    /// The stamp of a file's version on a host, which is the SHA-256 of its bytes.
    static func digest(_ data: Data) -> FileStamp { "sha256:" + data.sha256 }

    // MARK: here

    /// Returns the file's stamp, made of its size, modification time and inode, following symlinks. The same stamp
    /// means the same bytes. Returns nil when the file is gone.
    static func stamp(_ path: String) -> FileStamp? {
        var st = stat()
        return stat(path, &st) == 0 ? Self.stamp(st) : nil
    }
    private static func stamp(_ st: stat) -> FileStamp {
        "\(st.st_size)-\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)-\(st.st_ino)"
    }

    /// Returns the file's stamp and bytes, or nil when the file is gone. It refuses what a tab would refuse (a pipe, or
    /// a file past the limit). The stamp is taken before the read, so a write in between makes the next check read the
    /// file again rather than miss the write.
    private func contents(_ path: String) throws -> (stamp: FileStamp, data: Data)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        if st.st_mode & S_IFMT != S_IFREG { throw Unopenable.special.error }   // a pipe or /dev/zero would block or never end
        guard st.st_size <= Unopenable.openLimit else { throw Unopenable.tooBig(Int(st.st_size)).error }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { handle.closeQuietly() }
        // A file that grew since the stat is still read only up to the limit.
        let data = try handle.read(upToCount: Unopenable.openLimit + 1) ?? Data()
        guard data.count <= Unopenable.openLimit else { throw Unopenable.tooBig(data.count).error }
        return (Self.stamp(st), data)
    }

    private func absolute(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw RPCError.invalidParams("Not an absolute path: \(path)") }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Returns the absolute path for moving, copying or making a file on this Mac. A remote project's files go to
    /// `HostFiles` instead, so a path in one is refused here.
    private func here(_ path: String) throws -> String {
        let path = try absolute(path)
        if let located = remotes.containing(path) {
            throw RPCError.invalidParams(
                "\((path as NSString).lastPathComponent) is in a remote project: move or copy it there on \(located.remote.host), not between it and this Mac."
            )
        }
        return path
    }

    /// Returns the remote project (`HostFiles`) that all of `paths` are in, or nil when they aren't all in one. Then an
    /// operation between a host and this Mac, or between two projects there, reaches `here`, which refuses it.
    private func onHost(_ paths: String...) throws -> HostFiles? {
        let found = try paths.map { HostFiles.of(try absolute($0), remotes) }
        guard let first = found.first ?? nil else { return nil }
        return found.allSatisfy { $0?.folder == first.folder } ? first : nil
    }

    private func message(_ error: Error) -> String { (error as? RPCError)?.message ?? error.localizedDescription }

    // MARK: on a host

    private func readRemote(_ remote: RemoteHost, _ path: String) throws -> FilesRead.Result {
        let body = try remoteBytes(remote, path)
        guard let text = String(data: body, encoding: .utf8) else { throw Unopenable.binary.error }
        return .init(text: text, stamp: Self.digest(body))
    }

    /// Reads a file on a host in one round trip. The host first says what the file is (gone, not a regular file, or
    /// its size), then sends its bytes only when a tab would open it.
    private func remoteBytes(_ remote: RemoteHost, _ path: String) throws -> Data {
        let limit = Unopenable.openLimit
        let script =
            "f=\(ShellQuote.word(path)); if [ ! -e \"$f\" ]; then echo missing; "
            + "elif [ ! -f \"$f\" ]; then echo special; "
            + "else n=$(wc -c < \"$f\") || exit 1; echo $n; [ $n -gt \(limit) ] || head -c \(limit + 1) -- \"$f\"; fi"
        let out = try remote.run(script)
        guard let nl = out.firstIndex(of: 0x0A) else { throw RPCError.internalError("\(remote.host) didn't answer.") }
        let head = String(decoding: out[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces),
            body = out[(nl + 1)...]
        if head == "missing" { throw RPCError.invalidParams("It isn't on \(remote.host) any more (moved or deleted).") }
        if head == "special" { throw Unopenable.special.error }
        guard let size = Int(head) else { throw RPCError.internalError("\(remote.host) answered: \(head)") }
        guard size <= limit, body.count <= limit else { throw Unopenable.tooBig(max(size, body.count)).error }
        return Data(body)
    }

    /// Runs `IconSearch` for the host on one listing of the folders it looks in ("folder<TAB>name" lines, plus each PNG
    /// in an AppIcon set with its size). Then it fetches the icon's bytes and keeps them in `keep`, which is emptied
    /// when there is no icon. Returns the path of the kept copy.
    private func findIcon(_ remote: RemoteHost, keep: String) throws -> String? {
        let places = IconSearch.places.map(ShellQuote.word).joined(separator: " ")
        let script =
            "cd \(RemoteHost.cdArg(remote.path)) || exit 1; export LC_ALL=C; "
            + #"l() { [ -d "$1" ] && ls -1A "$1" | while IFS= read -r f; do printf '%s\t%s\n' "$1" "$f"; done; }; l .; "#
            + #"{ echo; ls -1 | grep -vx node_modules | head -40 | sed 's|$|/|'; } | while IFS= read -r b; do for p in "#
            + places
            + #"; do d="./$b$p"; l "$d"; s="${d}Assets.xcassets/AppIcon.appiconset"; [ -d "$s" ] && for f in "$s"/*.png; do "#
            + #"[ -f "$f" ] && printf '%s\t%s\t%s\n' "$s" "${f##*/}" "$(wc -c < "$f" | tr -d ' ')"; done; done; done; true"#
        var names: [String: [String]] = [:], sizes: [String: Int] = [:]
        for line in String(decoding: try remote.run(script, timeLimit: 30), as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            names[fields[0], default: []].append(fields[1])
            if fields.count == 3 { sizes[fields[0] + "/" + fields[1]] = Int(fields[2]) }
        }
        let fm = FileManager.default, name = (remote.path as NSString).lastPathComponent
        let found = IconSearch.find(in: ".", name: name, list: { names[$0] }, size: { sizes[$0] ?? 0 })
        let data = try found.map { try remoteBytes(remote, remote.path + $0.dropFirst()) }   // "./public/x.svg" → its path there
        if fm.fileExists(atPath: keep) { try fm.removeItem(atPath: keep) }
        guard let found, let data else { return nil }
        try fm.createDirectory(atPath: keep, withIntermediateDirectories: true)
        let copy = keep + "/" + (found as NSString).lastPathComponent
        try data.write(to: URL(fileURLWithPath: copy))
        return copy
    }

    private func writeRemote(_ remote: RemoteHost, _ path: String, _ data: Data, base: FileStamp?) throws
        -> FilesWrite.Result
    {
        let file = ShellQuote.word(path)
        // The text is first sent to a temporary file beside the file, and used only once all of it has arrived. A
        // dropped connection ends the upload as if it were done, so the temporary file's size tells. Then a copy of
        // the file, made with its mode, takes the text and is moved over the file, so a connection dropped meanwhile
        // leaves the file whole. A symlink, a file with other names (hard links) or another user's file is written in
        // place instead, so it stays what it is. In that case a disk that fills up during the write leaves the file
        // short, so the uploaded text beside it is kept, and the error says where it is.
        // A change on the host since the file was read is caught by comparing its digest in that same run, right
        // before the copy, so an edit on the host between a look and the write isn't written over. Exit code 3 means
        // it changed and the caller decides, and 4 means the file is gone. A file that can't be read (permissions)
        // fails the save.
        // Limit: a host without sha256sum, shasum or openssl writes the file without this check.
        let tmp = ShellQuote.word(path + ".kelp-XXXXXX"), drop = "{ rm -f \"$t\"; exit"
        let check =
            base.map { base in
                let want = ShellQuote.word(String(base.dropFirst("sha256:".count)))
                let cannot = ShellQuote.word("Can't read \(path) there.")
                return "[ -e \(file) ] || \(drop) 4; }; "
                    + "[ -r \(file) ] || { printf '%s\\n' \(cannot) >&2; \(drop) 1; }; }; "
                    + "now=$({ sha256sum || shasum -a 256 || openssl dgst -sha256 -r; } < \(file) 2>/dev/null "
                    + "| cut -c1-64); "
                    + "if [ -n \"$now\" ] && [ \"$now\" != \(want) ]; then \(drop) 3; }; fi; "
            } ?? ""
        let script =
            "t=$(mktemp \(tmp)) || exit 1; "
            + "if ! { cat > \"$t\" && [ \"$(wc -c < \"$t\" | tr -d ' ')\" = \(data.count) ]; }; then rm -f \"$t\"; exit 1; fi; "
            + check
            + "if [ -L \(file) ] || [ ! -O \(file) ] || [ \"$(ls -ld -- \(file) | awk '{print $2}')\" != 1 ]; then "
            + "cat \"$t\" > \(file) || { echo \"not written whole; your text is in $t\" >&2; exit 1; }; "
            + "else n=$(mktemp \(tmp)) && cp -p \(file) \"$n\" && cat \"$t\" > \"$n\" && mv -f \"$n\" \(file) "
            + "|| { rm -f \"$n\"; echo \"not written; your text is in $t\" >&2; exit 1; }; fi; rm -f \"$t\""
        do { _ = try remote.run(script, stdin: data) } catch let error as ProgramError where error.status == 3 {
            // The conflict stands whatever happens next, so a file that can't be read again shows the conflict with no
            // text rather than an error.
            let now = Log.store.attempt("reading \(path) again after a conflict") { try remote.run("cat -- \(file)") }
            return .init(
                conflict: .init(
                    stamp: now.map(Self.digest) ?? "", text: now.flatMap { String(data: $0, encoding: .utf8) }))
        } catch let error as ProgramError where error.status == 4 { return .init(missing: true) }
        return .init(stamp: Self.digest(data))
    }
}

extension FilesRead: Handled {
    static let agents = AgentAccess.reads
    func handle(_ files: FileService) throws -> Result { try files.read(path) }
}
extension FilesWrite: Handled {
    func handle(_ files: FileService) throws -> Result { try files.write(path, text, base: base) }
}
extension FilesMove: Handled {
    func handle(_ files: FileService) throws -> Result { files.move(pairs, unique: unique == true) }
}
extension FilesTrash: Handled { func handle(_ files: FileService) throws -> Result { files.trash(paths) } }
extension FilesCopy: Handled { func handle(_ files: FileService) throws -> Result { files.copy(paths, into: into) } }
extension FilesFetch: Handled {
    static let agents = AgentAccess.reads
    func handle(_ files: FileService) throws -> String { try files.fetch(path) }
}
extension RepoIcon: Handled {
    static let agents = AgentAccess.reads
    func handle(_ files: FileService) throws -> String? { try files.icon(path) }
}
extension FilesCreate: Handled {
    func handle(_ files: FileService) throws -> String {
        try files.create(path, folder: folder == true, text: text, unique: unique == true)
    }
}

extension Methods {
    static let fileMethods: [any Answered.Type] = [
        FilesRead.self, FilesWrite.self, FilesMove.self, FilesTrash.self, FilesCopy.self, FilesFetch.self,
        RepoIcon.self, FilesCreate.self
    ]
}
