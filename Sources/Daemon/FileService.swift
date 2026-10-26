import Foundation
import CryptoKit
import Core
import GitKit

/// Files' text and the Files panel's operations, for a file here or in a remote project (on its host, by ssh), with the
/// rules a tab keeps: only regular files up to `Unopenable.openLimit`, only UTF-8 text, and a save never writes over a
/// version it wasn't given the stamp of.
/// Any absolute path: the app opens files outside projects too (`kelp open`, the help, Save As…), and whoever can reach
/// the socket (0600, this user's) can already run programs here (`process.run`), so a list of allowed folders would
/// guard nothing.
struct FileService: Sendable {
    let remotes: Remotes

    func read(_ path: String) throws -> FilesRead.Result {
        let path = try absolute(path)
        if let r = remotes.containing(path) { return try readRemote(r.remote, r.remotePath) }
        guard let (stamp, data) = try contents(path) else { throw RPCError.invalidParams("It isn't on this Mac any more (moved or deleted).") }
        guard let text = String(data: data, encoding: .utf8) else { throw Unopenable.binary.error }
        return .init(text: text, stamp: stamp)
    }

    /// A remote project's file copied here, in the temporary folder (the system empties it), named as the file is so a
    /// viewer knows its type; a file here is its own copy.
    func fetch(_ path: String) throws -> String {
        let path = try absolute(path)
        guard let r = remotes.containing(path) else { return path }
        let data = try remoteBytes(r.remote, r.remotePath)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-remote")
            .appendingPathComponent(String(Self.digest(Data((r.remote.host + ":" + r.remotePath).utf8)).dropFirst(7).prefix(16)))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: copy, options: .atomic)
        return copy.path
    }

    /// A remote project's icon, kept in its folder here (`.kelp-icon/`, beside its marker): a kept one at once, looked for
    /// again in the background; none kept, looked for now.
    func icon(_ repo: String) throws -> String? {
        let repo = try absolute(repo)
        guard let remote = remotes.of(repo) else { throw RPCError.invalidParams("Not a remote project.") }
        let kept = repo + "/.kelp-icon"
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: kept))?.first else { return try findIcon(remote, keep: kept) }
        DispatchQueue.global(qos: .utility).async { Log.store.attempt("looking for \(remote.host)'s project icon") { _ = try findIcon(remote, keep: kept) } }
        return kept + "/" + name
    }

    func write(_ path: String, _ text: String, base: FileStamp?) throws -> FilesWrite.Result {
        let path = try absolute(path), data = Data(text.utf8)
        guard data.count <= Unopenable.openLimit else { throw Unopenable.tooBig(data.count).error }
        if let r = remotes.containing(path) { return try writeRemote(r.remote, r.remotePath, data, base: base) }
        // Limit: checked, then written: an agent's write in that window is lost (agents take no lock to wait on).
        if let base {
            guard let now = Self.stamp(path) else { return .init(missing: true) }
            if now != base {
                // Unreadable as text (grown past the limit, a pipe now, another encoding): no text, and still not written.
                let c = try? contents(path)
                return .init(conflict: .init(stamp: c?.stamp ?? now, text: c.flatMap { String(data: $0.data, encoding: .utf8) }))
            }
        }
        // Through a symlink to the file it points at: an atomic write to the link would replace it with a plain file.
        try data.write(to: URL(fileURLWithPath: path).resolvingSymlinksInPath(), options: .atomic)
        guard let stamp = Self.stamp(path) else { throw RPCError.internalError("\(path) was written but isn't there now.") }
        return .init(stamp: stamp)
    }

    func move(_ pairs: [FileMove], unique: Bool) -> FilesMove.Result {
        var done: [FileMove] = []
        for p in pairs {
            do {
                let from = try here(p.from), named = try here(p.to), to = unique ? Self.free(named) : named
                try FileManager.default.moveItem(atPath: from, toPath: to)
                done.append(.init(from: from, to: to))
            } catch { return .init(done: done, error: message(error)) }
        }
        return .init(done: done, error: nil)
    }

    func trash(_ paths: [String]) -> FilesMove.Result {
        var done: [FileMove] = []
        for p in paths {
            do {
                let from = try here(p)
                done.append(.init(from: from, to: try Trash.move(URL(fileURLWithPath: from)).path))
            } catch { return .init(done: done, error: message(error)) }
        }
        return .init(done: done, error: nil)
    }

    func copy(_ paths: [String], into: String) -> FilesCopy.Result {
        var made: [String] = []
        for p in paths {
            do {
                let from = try here(p), dir = try here(into), to = Self.free(dir + "/" + (from as NSString).lastPathComponent)
                try FileManager.default.copyItem(atPath: from, toPath: to)
                made.append(to)
            } catch { return .init(made: made, error: message(error)) }
        }
        return .init(made: made, error: nil)
    }

    func create(_ path: String, folder: Bool, text: String?, unique: Bool) throws -> String {
        let named = try here(path), path = unique ? Self.free(named, word: nil) : named, fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A taken name fails: never an existing file written over, or a folder taken for a new one.
        if folder { try fm.createDirectory(atPath: path, withIntermediateDirectories: false) }
        else { try Data((text ?? "").utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
        return path
    }

    /// `path`, or the first of "name copy.ext", "name copy 2.ext"… (`word: nil`: "name 2.ext") that doesn't exist.
    static func free(_ path: String, word: String? = "copy") -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let u = URL(fileURLWithPath: path), ext = u.pathExtension, base = u.deletingPathExtension().lastPathComponent, dir = u.deletingLastPathComponent()
        var i = word == nil ? 2 : 1
        while true {
            let stem = [base, word].compactMap { $0 }.joined(separator: " ") + (i > 1 ? " \(i)" : "")
            let c = dir.appendingPathComponent(ext.isEmpty ? stem : stem + "." + ext).path
            if !fm.fileExists(atPath: c) { return c }
            i += 1
        }
    }

    /// A version on a host: its bytes' SHA-256.
    static func digest(_ data: some DataProtocol) -> FileStamp {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: here

    /// Its size, modification time and inode, through symlinks: the same stamp, the same bytes. Nil when it's gone.
    static func stamp(_ path: String) -> FileStamp? {
        var st = stat()
        return stat(path, &st) == 0 ? Self.stamp(st) : nil
    }
    private static func stamp(_ st: stat) -> FileStamp { "\(st.st_size)-\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)-\(st.st_ino)" }

    /// Its stamp and bytes, refused as a tab would (a pipe, past the limit); nil when it's gone. The stamp is taken before
    /// the read: a write in between makes the next check read it again, never miss it.
    private func contents(_ path: String) throws -> (stamp: FileStamp, data: Data)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        if st.st_mode & S_IFMT != S_IFREG { throw Unopenable.special.error }   // a pipe or /dev/zero would block or never end
        guard st.st_size <= Unopenable.openLimit else { throw Unopenable.tooBig(Int(st.st_size)).error }
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? h.close() }
        let data = try h.read(upToCount: Unopenable.openLimit + 1) ?? Data()   // grown since the stat: still capped
        guard data.count <= Unopenable.openLimit else { throw Unopenable.tooBig(data.count).error }
        return (Self.stamp(st), data)
    }

    private func absolute(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw RPCError.invalidParams("Not an absolute path: \(path)") }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Moving, copying and making files is done here only: a remote project's folder here stands for the one on its host.
    private func here(_ path: String) throws -> String {
        let path = try absolute(path)
        if let r = remotes.containing(path) {
            throw RPCError.invalidParams("\((path as NSString).lastPathComponent) is in a remote project: move, copy or make files there on \(r.remote.host).")
        }
        return path
    }

    private func message(_ e: Error) -> String { (e as? RPCError)?.message ?? e.localizedDescription }

    // MARK: on a host

    private func readRemote(_ remote: RemoteHost, _ path: String) throws -> FilesRead.Result {
        let body = try remoteBytes(remote, path)
        guard let text = String(data: body, encoding: .utf8) else { throw Unopenable.binary.error }
        return .init(text: text, stamp: Self.digest(body))
    }

    /// One round trip: what it is (gone, not a regular file, its size), then its bytes only when a tab would open it.
    private func remoteBytes(_ remote: RemoteHost, _ path: String) throws -> Data {
        let limit = Unopenable.openLimit
        let script = "f=\(RemoteHost.quote(path)); if [ ! -e \"$f\" ]; then echo missing; elif [ ! -f \"$f\" ]; then echo special; "
            + "else n=$(wc -c < \"$f\") || exit 1; echo $n; [ $n -gt \(limit) ] || head -c \(limit + 1) -- \"$f\"; fi"
        let out = try remote.run(script)
        guard let nl = out.firstIndex(of: 0x0A) else { throw RPCError.internalError("\(remote.host) didn't answer.") }
        let head = String(decoding: out[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces), body = out[(nl + 1)...]
        if head == "missing" { throw RPCError.invalidParams("It isn't on \(remote.host) any more (moved or deleted).") }
        if head == "special" { throw Unopenable.special.error }
        guard let size = Int(head) else { throw RPCError.internalError("\(remote.host) answered: \(head)") }
        guard size <= limit, body.count <= limit else { throw Unopenable.tooBig(max(size, body.count)).error }
        return Data(body)
    }

    /// `IconSearch` on the host, from one listing of the folders it looks in ("folder<TAB>name", and an AppIcon set's PNGs
    /// with their size), then the icon's bytes: kept in `keep` (emptied when there's none) → the kept copy.
    private func findIcon(_ remote: RemoteHost, keep: String) throws -> String? {
        let places = IconSearch.places.map(RemoteHost.quote).joined(separator: " ")
        let script = "cd \(RemoteHost.cdArg(remote.path)) || exit 1; export LC_ALL=C; "
            + #"l() { [ -d "$1" ] && ls -1A "$1" | while IFS= read -r f; do printf '%s\t%s\n' "$1" "$f"; done; }; l .; "#
            + #"{ echo; ls -1 | grep -vx node_modules | head -40 | sed 's|$|/|'; } | while IFS= read -r b; do for p in "# + places
            + #"; do d="./$b$p"; l "$d"; s="${d}Assets.xcassets/AppIcon.appiconset"; [ -d "$s" ] && for f in "$s"/*.png; do "#
            + #"[ -f "$f" ] && printf '%s\t%s\t%s\n' "$s" "${f##*/}" "$(wc -c < "$f" | tr -d ' ')"; done; done; done; true"#
        var names: [String: [String]] = [:], sizes: [String: Int] = [:]
        for line in String(decoding: try remote.run(script, timeLimit: 30), as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { continue }
            names[f[0], default: []].append(f[1])
            if f.count == 3 { sizes[f[0] + "/" + f[1]] = Int(f[2]) }
        }
        let fm = FileManager.default, found = IconSearch.find(in: ".", list: { names[$0] }, size: { sizes[$0] ?? 0 })
        let data = try found.map { try remoteBytes(remote, remote.path + $0.dropFirst()) }   // "./public/x.svg" → its path there
        if fm.fileExists(atPath: keep) { try fm.removeItem(atPath: keep) }
        guard let found, let data else { return nil }
        try fm.createDirectory(atPath: keep, withIntermediateDirectories: true)
        let copy = keep + "/" + (found as NSString).lastPathComponent
        try data.write(to: URL(fileURLWithPath: copy))
        return copy
    }

    private func writeRemote(_ remote: RemoteHost, _ path: String, _ data: Data, base: FileStamp?) throws -> FilesWrite.Result {
        let file = RemoteHost.quote(path)
        // Changed there since it was read: the caller decides. Compared by the bytes' digest; one that can't be read
        // (permissions) fails the save rather than being written over.
        if let base {
            let out = try remote.run("if [ -e \(file) ]; then echo present; cat -- \(file); else echo missing; fi")
            guard let nl = out.firstIndex(of: 0x0A) else { throw RPCError.internalError("\(remote.host) didn't answer.") }
            if out[..<nl].elementsEqual("missing".utf8) { return .init(missing: true) }
            let now = out[(nl + 1)...], stamp = Self.digest(now)
            if stamp != base { return .init(conflict: .init(stamp: stamp, text: String(data: now, encoding: .utf8))) }
        }
        // Sent to a file beside it, then copied over it on the host once all of it came (a dropped connection ends the
        // upload as if it were done: its size tells), so the file keeps its mode, owner and links and is never half.
        let tmp = RemoteHost.quote(path + ".kelp-XXXXXX")
        let script = "t=$(mktemp \(tmp)) || exit 1; cat > \"$t\" && [ \"$(wc -c < \"$t\" | tr -d ' ')\" = \(data.count) ] && cat \"$t\" > \(file); "
            + "s=$?; rm -f \"$t\"; exit $s"
        try Git.runData(remote.sshArgs(tty: false) + ["sh -c " + RemoteHost.quote(script)], cwd: NSHomeDirectory(), stdin: data, executable: remote.ssh)
        return .init(stamp: Self.digest(data))
    }
}

extension FilesRead: Handled { func handle(_ files: FileService) throws -> Result { try files.read(path) } }
extension FilesWrite: Handled { func handle(_ files: FileService) throws -> Result { try files.write(path, text, base: base) } }
extension FilesMove: Handled { func handle(_ files: FileService) throws -> Result { files.move(pairs, unique: unique == true) } }
extension FilesTrash: Handled { func handle(_ files: FileService) throws -> Result { files.trash(paths) } }
extension FilesCopy: Handled { func handle(_ files: FileService) throws -> Result { files.copy(paths, into: into) } }
extension FilesFetch: Handled { func handle(_ files: FileService) throws -> String { try files.fetch(path) } }
extension RepoIcon: Handled { func handle(_ files: FileService) throws -> String? { try files.icon(path) } }
extension FilesCreate: Handled {
    func handle(_ files: FileService) throws -> String { try files.create(path, folder: folder == true, text: text, unique: unique == true) }
}

extension Methods {
    static let fileMethods: [any Handled.Type] = [FilesRead.self, FilesWrite.self, FilesMove.self, FilesTrash.self, FilesCopy.self, FilesCreate.self,
                                                        FilesFetch.self, RepoIcon.self]
}
