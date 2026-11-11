import CryptoKit
import Foundation
import os

/// The extension library: github.com/nikiomori/kelp-extensions, a public repo of extensions reviewed before they're
/// merged. Its CI writes index.json with each one's folder at the commit that was reviewed, and installing one downloads
/// exactly that. Any other GitHub folder installs the same way, without the review. With what an extension's folder
/// holds: its id, the authoring guide beside it, and the digest of its files the user allows.
public enum ExtensionFiles {
    public static func isValidExtensionID(_ id: String) -> Bool { id.wholeMatch(of: /[a-z0-9][a-z0-9.-]*/) != nil }

    /// The extension authoring guide (Resources/extensions.md; docs/extensions.md links to it).
    public static let extensionGuide = Paths.resource("extensions", "md") ?? ""

    /// EXTENSIONS.md, rewritten when missing or older than this build's guide.
    public static func writeGuide(in dir: URL) throws {
        let guide = dir.appendingPathComponent("EXTENSIONS.md")
        guard !extensionGuide.isEmpty, String(contentsIfAny: guide) != extensionGuide else { return }
        try Paths.ensure(dir)
        try extensionGuide.write(to: guide, atomically: true, encoding: .utf8)
    }

    public static let libraryRepo = "nikiomori/kelp-extensions"
    public static let libraryIndex = "https://raw.githubusercontent.com/\(libraryRepo)/main/index.json"
    /// Where an installed extension came from, written by `fetchExtension`: `{"source": "https://github.com/…"}`.
    public static let sourceFile = ".kelp-source.json"

    /// A GitHub folder: `https://github.com/o/r`, `github.com/o/r/tree/<ref>/<folder…>` or `o/r`; nil for anything else.
    /// Limit: the ref is one path component, so a branch with "/" in its name is given by its commit instead.
    public static func librarySource(_ text: String) -> (repo: String, ref: String, path: String)? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "github.com/"] where rest.hasPrefix(prefix) {
            rest.removeFirst(prefix.count)
        }
        while rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count >= 2,
            parts.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9_.-]+/) != nil && $0 != "." && $0 != ".." })
        else { return nil }
        let repo = parts[0] + "/" + parts[1]
        if parts.count == 2 { return (repo, "HEAD", "") }
        guard parts.count >= 4, parts[2] == "tree" else { return nil }
        return (repo, parts[3], parts.dropFirst(4).joined(separator: "/"))
    }

    /// One spelling per source, for `sourceFile` and comparing with the library's.
    static func sourceURL(_ source: (repo: String, ref: String, path: String)) -> String {
        "https://github.com/\(source.repo)"
            + (source.ref == "HEAD" && source.path.isEmpty
                ? "" : "/tree/\(source.ref)" + (source.path.isEmpty ? "" : "/\(source.path)"))
    }

    /// The library's index; `index` is an https URL, or a file URL for a local one.
    public static func library(index: String = libraryIndex) throws -> [ExtensionLibrary.Entry] {
        guard index.hasPrefix("https://") || index.hasPrefix("file://") else {
            throw RPCError.invalidParams("The library's index must be an https URL: \(index)")
        }
        let reviewed: [ExtensionLibrary.Entry]
        do { reviewed = try JSONDecoder().decode([ExtensionLibrary.Entry].self, from: download(index)) } catch let error
            as RPCError
        { throw error } catch {
            throw RPCError.internalError("The extension library's index isn't readable: \(error.localizedDescription)")
        }
        return reviewed + community(beside: index).filter { c in !reviewed.contains { $0.id == c.id } }
    }

    /// community.json beside the index: repositories under the topic kelp-extension, not reviewed (`Entry.reviewed`
    /// false). A library without one, or one that can't be read, just has none.
    static func community(beside index: String) -> [ExtensionLibrary.Entry] {
        guard index.hasSuffix("/index.json") else { return [] }
        let url = String(index.dropLast("index.json".count)) + "community.json"
        do {
            return try JSONDecoder().decode([ExtensionLibrary.Entry].self, from: download(url)).map {
                var entry = $0
                entry.reviewed = false
                return entry
            }
        } catch { return [] }
    }

    /// A GitHub folder (`librarySource`) downloaded into a new temporary folder named by the extension's id, with
    /// `sourceFile` in it. Limit: the repo's whole archive comes down for one folder; fine while repos are small.
    public static func fetchExtension(_ source: String, files: [String: String]? = nil) throws -> URL {
        guard let found = librarySource(source) else {
            throw RPCError.invalidParams(
                "Not a GitHub folder: \(source). Use https://github.com/owner/repo or https://github.com/owner/repo/tree/<branch>/<folder>."
            )
        }
        let fm = FileManager.default,
            work = fm.temporaryDirectory.appendingPathComponent("kelp-dl-\(UUID().uuidString.prefix(8))")
        try Paths.ensure(work)
        defer { fm.removeIfAny(work) }
        let archive = work.appendingPathComponent("archive.tar.gz")
        _ = try download("https://codeload.github.com/\(found.repo)/tar.gz/\(found.ref)", to: archive)
        let folder = try unpackExtension(archive, path: found.path, source: sourceURL(found), work: work)
        if let files, let wrong = differing(folder, from: files) {
            do { try fm.removeItem(at: folder.deletingLastPathComponent()) } catch {}   // a temporary folder: the system clears it anyway
            throw RPCError.invalidParams(
                "\(source): “\(wrong)” isn't the file the library reviewed, so nothing was installed.")
        }
        return folder
    }

    /// The first file in `folder` that isn't as `files` says (missing, changed, or not in the list), nil when all are.
    static func differing(_ folder: URL, from files: [String: String]) -> String? {
        let fm = FileManager.default, root = folder.resolvingSymlinksInPath().path
        var seen = Set<String>()
        let all = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for url in all {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue else { continue }
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1))
            if path == sourceFile { continue }   // Kelp's own, written after the download
            guard let data = fm.contents(atPath: url.path), files[path] == data.sha256 else { return path }
            seen.insert(path)
        }
        return files.keys.sorted().first { !seen.contains($0) }
    }

    /// `archive` is a GitHub tarball (one top folder); the extension at `path` in it ends up in a temporary folder of its own.
    static func unpackExtension(_ archive: URL, path: String, source: String, work: URL) throws -> URL {
        let fm = FileManager.default, unpacked = work.appendingPathComponent("x")
        try Paths.ensure(unpacked)
        // bsdtar leaves out absolute paths and "..".
        let result = try Subprocess.run(
            ["/usr/bin/tar", "-xzf", archive.path, "-C", unpacked.path], cwd: work.path, env: [:], timeLimit: 60)
        guard result.status == 0 else {
            throw RPCError.internalError("Couldn't unpack \(source): \(String(decoding: result.stderr, as: UTF8.self))")
        }
        let top = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).filter {
            !$0.lastPathComponent.hasPrefix(".")
        }
        guard top.count == 1 else { throw RPCError.internalError("\(source) didn't download as a GitHub archive.") }
        let folder = path.isEmpty ? top[0] : top[0].appendingPathComponent(path)
        // A symlink in the archive must not lead out of it.
        guard let real = Paths.real(folder.path), let inside = Paths.real(unpacked.path), real.hasPrefix(inside + "/"),
            let data = fm.contents(atPath: folder.appendingPathComponent("extension.json").path)
        else {
            throw RPCError.invalidParams("\(source) has no extension.json.")
        }
        guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.string, isValidExtensionID(id)
        else {
            throw RPCError.invalidParams(
                "\(source): extension.json needs an id of lowercase letters, digits, dots and dashes.")
        }
        let dest = fm.temporaryDirectory.appendingPathComponent("kelp-ext-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent(id)
        try Paths.ensure(dest.deletingLastPathComponent())
        try fm.moveItem(at: folder, to: dest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Replaced, not written through: an archive can ship this name as a symlink, and nothing has reviewed it yet.
        try encoder.encode(["source": source]).write(to: dest.appendingPathComponent(sourceFile), options: .atomic)
        return dest
    }

    /// curl, which every Mac has: redirects followed, an HTTP error is an error, two minutes at most. Into `file`, else returned.
    static func download(_ url: String, to file: URL? = nil) throws -> Data {
        let result = try Subprocess.run(
            ["/usr/bin/curl", "-fsSL", "--max-time", "120"] + (file.map { ["-o", $0.path] } ?? []) + [url],
            cwd: NSTemporaryDirectory(), env: ProcessInfo.processInfo.environment, timeLimit: 130)
        guard result.status == 0 else {
            throw RPCError.internalError(
                "Couldn't download \(url): \(String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        guard !result.truncated else {
            throw RPCError.internalError(
                "Couldn't download \(url): it's larger than \(Subprocess.outputLimit >> 20) MB.")
        }
        return result.stdout
    }

    /// Where the extension in `folder` was installed from (`sourceFile`), when it came from GitHub.
    public static func extensionSource(_ folder: URL) -> String? {
        (try? JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: folder.appendingPathComponent(sourceFile))))?["source"]
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
        for entry in extensionEntries(folder) {
            let target = entry.url.resolvingSymlinksInPath()
            files[entry.link ? entry.name + " → " + target.path : entry.name] =
                FileManager.default.contents(atPath: target.path) ?? Data()
        }
        return files
    }

    /// The digest of `files`: what Kelp's window records when the user allows an extension (`extensionTrustKey`).
    public static func extensionDigest(_ files: [String: Data]) -> String {
        var hasher = SHA256()
        for (key, body) in files.sorted(by: { $0.key < $1.key }) {
            let name = key.components(separatedBy: " → "),
                size = withUnsafeBytes(of: UInt64(body.count).littleEndian) { Data($0) }
            // As digests were recorded before this read the files once: the name, a link's target, the size, the bytes.
            for part in [Data(name[0].utf8), Data((name.count > 1 ? name[1] : "").utf8), size, body] {
                hasher.update(data: part)
                hasher.update(data: Data([0]))
            }
        }
        return hasher.finalize().hex
    }

    /// `extensionDigest` of the folder as it is: read again only when a file's size, times or inode changed (ctime moves
    /// with any write, and no one can set it back), so a check before every command reads no file that didn't change.
    public static func extensionDigest(_ folder: URL) -> String {
        let entries = extensionEntries(folder)
        let mark = entries.map { entry -> String in
            var st = stat()
            _ = stat(entry.url.path, &st)   // a link's target's
            return
                "\(entry.name)|\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)|\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)|\(st.st_ino)"
                + (entry.link ? "|" + entry.url.resolvingSymlinksInPath().path : "")
        }.joined(separator: "\n")
        if let known = digests.withLock({ $0[folder.path] }), known.mark == mark { return known.digest }
        let digest = extensionDigest(extensionFiles(folder))
        digests.withLock { $0[folder.path] = (mark, digest) }
        return digest
    }
    private static let digests = OSAllocatedUnfairLock<[String: (mark: String, digest: String)]>(initialState: [:])

    private static func extensionEntries(_ folder: URL) -> [(name: String, url: URL, link: Bool)] {
        // Paths relative to the folder, as the enumerator gives them: a URL's path would be standardized ("/private/var"
        // read as "/var"), and the folder's length cut from it would leave names like "son" for "/extension.json".
        let root = folder.resolvingSymlinksInPath(), all = FileManager.default.enumerator(atPath: root.path)
        var out: [(name: String, url: URL, link: Bool)] = []
        while let relative = all?.nextObject() as? String {
            let url = root.appendingPathComponent(relative)
            if url.lastPathComponent == ".git" {
                all?.skipDescendants()
                continue
            }
            var st = stat()
            guard lstat(url.path, &st) == 0, [S_IFREG, S_IFLNK].contains(st.st_mode & S_IFMT) else { continue }
            out.append(("/" + relative, url, st.st_mode & S_IFMT == S_IFLNK))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// What an extension's manifest can run, for a look before it's installed: the shell commands (every "command" with
    /// its "args", "terminal", "run", "test", "format" and "install" text, an "open" of a terminal: or agent: URI) and the
    /// web pages, which can run any.
    public static func commandsIn(_ manifest: JSONValue) -> (commands: [String], pages: [String]) {
        var commands: [String] = [], pages: [String] = []
        func walk(_ value: JSONValue) {
            if let array = value.array { array.forEach(walk) }
            guard case .object(let fields) = value else { return }
            for (key, child) in fields.sorted(by: { $0.key < $1.key }) {
                guard let text = child.string else {
                    walk(child)
                    continue
                }
                var run: String?
                if ["command", "terminal", "run", "test", "format", "install"].contains(key) { run = text }
                if key == "command", let args = fields["args"]?.array?.compactMap(\.string), !args.isEmpty {
                    run = ([text] + args).joined(separator: " ")
                }
                if key == "open", text.hasPrefix("terminal:") || text.hasPrefix("agent:") { run = text }
                if let run, !commands.contains(run) { commands.append(run) }
                if key == "web", !pages.contains(text) { pages.append(text) }
            }
        }
        walk(manifest)
        return (commands, pages)
    }
}

extension Data {
    /// Its SHA-256, as hex.
    public var sha256: String { SHA256.hash(data: self).hex }
}

extension Digest {
    /// As hex, as `shasum` writes it.
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
