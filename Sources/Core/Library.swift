import CryptoKit
import os
import Foundation

/// The extension library: github.com/nikiomori/kelp-extensions, a public repo of extensions reviewed before they're
/// merged. Its CI writes index.json with each one's folder at the commit that was reviewed, and installing one downloads
/// exactly that. Any other GitHub folder installs the same way, without the review.
extension IDE {
    public static let libraryRepo = "nikiomori/kelp-extensions"
    public static let libraryIndex = "https://raw.githubusercontent.com/\(libraryRepo)/main/index.json"
    /// Where an installed extension came from, written by `fetchExtension`: `{"source": "https://github.com/…"}`.
    public static let sourceFile = ".kelp-source.json"

    /// A GitHub folder: `https://github.com/o/r`, `github.com/o/r/tree/<ref>/<folder…>` or `o/r`; nil for anything else.
    /// Limit: the ref is one path component, so a branch with "/" in its name is given by its commit instead.
    public static func librarySource(_ s: String) -> (repo: String, ref: String, path: String)? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "github.com/"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        while t.hasSuffix("/") { t.removeLast() }
        if t.hasSuffix(".git") { t.removeLast(4) }
        let parts = t.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9_.-]+/) != nil && $0 != "." && $0 != ".." }) else { return nil }
        let repo = parts[0] + "/" + parts[1]
        if parts.count == 2 { return (repo, "HEAD", "") }
        guard parts.count >= 4, parts[2] == "tree" else { return nil }
        return (repo, parts[3], parts.dropFirst(4).joined(separator: "/"))
    }

    /// One spelling per source, for `sourceFile` and comparing with the library's.
    static func sourceURL(_ s: (repo: String, ref: String, path: String)) -> String {
        "https://github.com/\(s.repo)" + (s.ref == "HEAD" && s.path.isEmpty ? "" : "/tree/\(s.ref)" + (s.path.isEmpty ? "" : "/\(s.path)"))
    }

    /// The library's index; `index` is an https URL, or a file URL for a local one.
    public static func library(index: String = libraryIndex) throws -> [ExtensionLibrary.Entry] {
        guard index.hasPrefix("https://") || index.hasPrefix("file://") else {
            throw RPCError.invalidParams("The library's index must be an https URL: \(index)")
        }
        let reviewed: [ExtensionLibrary.Entry]
        do { reviewed = try JSONDecoder().decode([ExtensionLibrary.Entry].self, from: download(index)) }
        catch let e as RPCError { throw e }
        catch { throw RPCError.internalError("The extension library's index isn't readable: \(error.localizedDescription)") }
        return reviewed + community(beside: index).filter { c in !reviewed.contains { $0.id == c.id } }
    }

    /// community.json beside the index: repositories under the topic kelp-extension, not reviewed (`Entry.reviewed`
    /// false). A library without one, or one that can't be read, just has none.
    static func community(beside index: String) -> [ExtensionLibrary.Entry] {
        guard index.hasSuffix("/index.json") else { return [] }
        let url = String(index.dropLast("index.json".count)) + "community.json"
        do {
            return try JSONDecoder().decode([ExtensionLibrary.Entry].self, from: download(url)).map { var e = $0; e.reviewed = false; return e }
        } catch { return [] }
    }

    /// A GitHub folder (`librarySource`) downloaded into a new temporary folder named by the extension's id, with
    /// `sourceFile` in it. Limit: the repo's whole archive comes down for one folder; fine while repos are small.
    public static func fetchExtension(_ source: String, files: [String: String]? = nil) throws -> URL {
        guard let s = librarySource(source) else {
            throw RPCError.invalidParams("Not a GitHub folder: \(source). Use https://github.com/owner/repo or https://github.com/owner/repo/tree/<branch>/<folder>.")
        }
        let fm = FileManager.default, work = fm.temporaryDirectory.appendingPathComponent("kelp-dl-\(UUID().uuidString.prefix(8))")
        try Paths.ensure(work)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent("archive.tar.gz")
        _ = try download("https://codeload.github.com/\(s.repo)/tar.gz/\(s.ref)", to: archive)
        let folder = try unpackExtension(archive, path: s.path, source: sourceURL(s), work: work)
        if let files, let wrong = differing(folder, from: files) {
            do { try fm.removeItem(at: folder.deletingLastPathComponent()) } catch {}   // a temporary folder: the system clears it anyway
            throw RPCError.invalidParams("\(source): “\(wrong)” isn't the file the library reviewed, so nothing was installed.")
        }
        return folder
    }

    /// The first file in `folder` that isn't as `files` says (missing, changed, or not in the list), nil when all are.
    static func differing(_ folder: URL, from files: [String: String]) -> String? {
        let fm = FileManager.default, root = folder.resolvingSymlinksInPath().path
        var seen = Set<String>()
        let all = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for u in all {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &dir), !dir.boolValue else { continue }
            let path = String(u.resolvingSymlinksInPath().path.dropFirst(root.count + 1))
            if path == sourceFile { continue }   // Kelp's own, written after the download
            guard let data = fm.contents(atPath: u.path), files[path] == sha256(data) else { return path }
            seen.insert(path)
        }
        return files.keys.sorted().first { !seen.contains($0) }
    }

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// `archive` is a GitHub tarball (one top folder); the extension at `path` in it ends up in a temporary folder of its own.
    static func unpackExtension(_ archive: URL, path: String, source: String, work: URL) throws -> URL {
        let fm = FileManager.default, x = work.appendingPathComponent("x")
        try Paths.ensure(x)
        // bsdtar leaves out absolute paths and "..".
        let r = try Subprocess.run(["/usr/bin/tar", "-xzf", archive.path, "-C", x.path], cwd: work.path, env: [:], timeLimit: 60)
        guard r.status == 0 else { throw RPCError.internalError("Couldn't unpack \(source): \(String(decoding: r.stderr, as: UTF8.self))") }
        let top = try fm.contentsOfDirectory(at: x, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard top.count == 1 else { throw RPCError.internalError("\(source) didn't download as a GitHub archive.") }
        let folder = path.isEmpty ? top[0] : top[0].appendingPathComponent(path)
        // A symlink in the archive must not lead out of it.
        guard let real = Paths.real(folder.path), let inside = Paths.real(x.path), real.hasPrefix(inside + "/"),
              let data = fm.contents(atPath: folder.appendingPathComponent("extension.json").path) else {
            throw RPCError.invalidParams("\(source) has no extension.json.")
        }
        guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.string, isValidExtensionID(id) else {
            throw RPCError.invalidParams("\(source): extension.json needs an id of lowercase letters, digits, dots and dashes.")
        }
        let dest = fm.temporaryDirectory.appendingPathComponent("kelp-ext-\(UUID().uuidString.prefix(8))").appendingPathComponent(id)
        try Paths.ensure(dest.deletingLastPathComponent())
        try fm.moveItem(at: folder, to: dest)
        let e = JSONEncoder(); e.outputFormatting = .withoutEscapingSlashes
        // Replaced, not written through: an archive can ship this name as a symlink, and nothing has reviewed it yet.
        try e.encode(["source": source]).write(to: dest.appendingPathComponent(sourceFile), options: .atomic)
        return dest
    }

    /// curl, which every Mac has: redirects followed, an HTTP error is an error, two minutes at most. Into `file`, else returned.
    static func download(_ url: String, to file: URL? = nil) throws -> Data {
        let r = try Subprocess.run(["/usr/bin/curl", "-fsSL", "--max-time", "120"] + (file.map { ["-o", $0.path] } ?? []) + [url],
                                   cwd: NSTemporaryDirectory(), env: ProcessInfo.processInfo.environment, timeLimit: 130)
        guard r.status == 0 else {
            throw RPCError.internalError("Couldn't download \(url): \(String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard !r.truncated else { throw RPCError.internalError("Couldn't download \(url): it's larger than \(Subprocess.outputLimit >> 20) MB.") }
        return r.stdout
    }

    /// Where the extension in `folder` was installed from (`sourceFile`), when it came from GitHub.
    public static func extensionSource(_ folder: URL) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: folder.appendingPathComponent(sourceFile))))?["source"]
    }

    /// Puts an extension folder into `dir` as `name`; one already there goes to the Trash. `move`: a folder of ours
    /// (`fetchExtension`'s), taken rather than copied.
    @discardableResult
    public static func installExtension(_ folder: URL, as name: String, in dir: URL, move: Bool = false) throws -> URL {
        // The name is a folder inside `dir`: "..", "a/b" or ".hidden" would point somewhere else (".." is ~/.kelp itself,
        // which the line below would send to the Trash).
        guard isPlainName(name) else { throw RPCError.invalidParams("“\(name)” can't be an extension's folder name.") }
        let fm = FileManager.default, dest = dir.appendingPathComponent(name)
        try Paths.ensure(dir)
        if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
        if move { try fm.moveItem(at: folder, to: dest) } else { try fm.copyItem(at: folder, to: dest) }
        return dest
    }

    /// One folder name and nothing more: not empty, no "/", not "." or "..", not hidden.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0") && !name.hasPrefix(".") && name.count <= 255
    }

    /// The UI state key with the extensions the user allowed to run commands: folder name → `extensionDigest` of what
    /// was allowed. Only Kelp's window writes it (`state.set`); unset, nothing was ever asked (an older Kelp installed them).
    public static let extensionTrustKey = "extensions.trusted"

    /// Every file of an extension's folder (its manifest, scripts, pages; not a `.git`'s) by its path in the folder
    /// ("/extension.json"), read once: what allowing it covers, and what the look before shows. A link counts by where it
    /// points and what's there ("/lib → /target"). Limit: a linked folder counts by where it points, not by what's in it.
    public static func extensionFiles(_ folder: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        for e in extensionEntries(folder) {
            let target = e.url.resolvingSymlinksInPath()
            files[e.link ? e.name + " → " + target.path : e.name] = FileManager.default.contents(atPath: target.path) ?? Data()
        }
        return files
    }

    /// The digest of `files`: what Kelp's window records when the user allows an extension (`extensionTrustKey`).
    public static func extensionDigest(_ files: [String: Data]) -> String {
        var h = SHA256()
        for (key, body) in files.sorted(by: { $0.key < $1.key }) {
            let name = key.components(separatedBy: " → "), size = withUnsafeBytes(of: UInt64(body.count).littleEndian) { Data($0) }
            // As digests were recorded before this read the files once: the name, a link's target, the size, the bytes.
            for part in [Data(name[0].utf8), Data((name.count > 1 ? name[1] : "").utf8), size, body] {
                h.update(data: part); h.update(data: Data([0]))
            }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `extensionDigest` of the folder as it is: read again only when a file's size, times or inode changed (ctime moves
    /// with any write, and no one can set it back), so a check before every command reads no file that didn't change.
    public static func extensionDigest(_ folder: URL) -> String {
        let entries = extensionEntries(folder)
        let mark = entries.map { e -> String in
            var st = stat()
            _ = stat(e.url.path, &st)   // a link's target's
            return "\(e.name)|\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)|\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)|\(st.st_ino)"
                + (e.link ? "|" + e.url.resolvingSymlinksInPath().path : "")
        }.joined(separator: "\n")
        if let known = digests.withLock({ $0[folder.path] }), known.mark == mark { return known.digest }
        let digest = extensionDigest(extensionFiles(folder))
        digests.withLock { $0[folder.path] = (mark, digest) }
        return digest
    }
    private static let digests = OSAllocatedUnfairLock<[String: (mark: String, digest: String)]>(initialState: [:])

    private static func extensionEntries(_ folder: URL) -> [(name: String, url: URL, link: Bool)] {
        let root = folder.resolvingSymlinksInPath(), all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [(name: String, url: URL, link: Bool)] = []
        while let u = all?.nextObject() as? URL {
            if u.lastPathComponent == ".git" { all?.skipDescendants(); continue }
            var st = stat()
            guard lstat(u.path, &st) == 0, [S_IFREG, S_IFLNK].contains(st.st_mode & S_IFMT) else { continue }
            out.append((String(u.path.dropFirst(root.path.count)), u, st.st_mode & S_IFMT == S_IFLNK))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// What an extension's manifest can run, for a look before it's installed: the shell commands (every "command" with
    /// its "args", "terminal", "run", "test", "format" and "install" text, an "open" of a terminal: or agent: URI) and the
    /// web pages, which can run any.
    public static func commandsIn(_ manifest: JSONValue) -> (commands: [String], pages: [String]) {
        var commands: [String] = [], pages: [String] = []
        func walk(_ v: JSONValue) {
            if let a = v.array { a.forEach(walk) }
            guard case .object(let o) = v else { return }
            for (k, x) in o.sorted(by: { $0.key < $1.key }) {
                guard let s = x.string else { walk(x); continue }
                var run: String?
                if ["command", "terminal", "run", "test", "format", "install"].contains(k) { run = s }
                if k == "command", let args = o["args"]?.array?.compactMap(\.string), !args.isEmpty { run = ([s] + args).joined(separator: " ") }
                if k == "open", s.hasPrefix("terminal:") || s.hasPrefix("agent:") { run = s }
                if let run, !commands.contains(run) { commands.append(run) }
                if k == "web", !pages.contains(s) { pages.append(s) }
            }
        }
        walk(manifest)
        return (commands, pages)
    }
}
