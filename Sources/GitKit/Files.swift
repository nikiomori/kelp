import Core
import Foundation

/// Project files and search. Uses git so .gitignore is honoured exactly like in a terminal.
extension ProjectFiles {
    /// Tracked + untracked-but-not-ignored files, relative paths. A tracked file deleted from the folder is left out: git
    /// tags it "R" (one git process instead of a stat per file, and it works on a remote host too). Outside a sparse
    /// checkout's cone ("S", never checked by git) a file is kept only if it's there. The first `limit`.
    public static func list(_ root: String, limit: Int = listLimit, remotes: Remotes = .none) throws -> [String] {
        let a = ["ls-files", "-t", "--cached", "--others", "--deleted", "--exclude-standard", "-z"]
        let r: (data: Data, truncated: Bool)
        do {
            r = try Git.runPart(a, cwd: root, limit: Subprocess.outputLimit, remotes: remotes)
        } catch  where outsideGit(error) {
            return walk(root, limit: limit)
        }
        let lines: [Substring] = String(decoding: r.truncated ? Git.wholeEntries(r.data, 0) : r.data, as: UTF8.self)
            .split(separator: "\0").filter { $0.count > 2 }
        let gone = Set(lines.filter { $0.hasPrefix("R ") }.map { $0.dropFirst(2) })
        let remote = remotes.of(root) != nil
        let files =
            lines.lazy.filter { l in
                guard !l.hasPrefix("R "), !gone.contains(l.dropFirst(2)) else { return false }
                return !l.hasPrefix("S ") || remote
                    || FileManager.default.fileExists(atPath: root + "/" + l.dropFirst(2))
            }.prefix(limit).map { String($0.dropFirst(2)) } as [String]
        guard !r.truncated || files.count >= limit else { throw Git.tooMuch(a) }
        return files
    }

    /// What git ignores (`files.ignored`): a folder ignored whole is one entry ending with "/", not opened (.build/,
    /// node_modules/). `folder`, one of those: what's in it, one level, read from the folder. The first `limit`.
    /// Limit: on a host a name with a newline in it reads as two.
    public static func ignored(_ root: String, folder: String? = nil, limit: Int = listLimit, remotes: Remotes = .none)
        throws -> [String]
    {
        guard let folder else {
            let a = ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]
            let r: (data: Data, truncated: Bool)
            do { r = try Git.runPart(a, cwd: root, limit: Subprocess.outputLimit, remotes: remotes) } catch
                where outsideGit(error)
            { return [] }
            return Array(
                String(decoding: r.truncated ? Git.wholeEntries(r.data, 0) : r.data, as: UTF8.self)
                    .split(separator: "\0").prefix(limit).map(String.init))
        }
        let dir = folder.hasSuffix("/") ? folder : folder + "/"
        guard !dir.hasPrefix("/"), !dir.split(separator: "/").contains("..") else {
            throw GitError(args: [dir], status: 1, stderr: "“\(dir)” isn't in the workspace.")
        }
        let names: [String]
        if let r = remotes.of(root) {
            names = String(decoding: try r.run("cd \(RemoteHost.cdArg(r.path + "/" + dir)) && ls -1Ap"), as: UTF8.self)
                .split(separator: "\n").map(String.init)
        } else {
            names = try FileManager.default.contentsOfDirectory(atPath: root + "/" + dir).map { n in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: root + "/" + dir + n, isDirectory: &isDir)
                    && isDir.boolValue ? n + "/" : n
            }
        }
        return names.prefix(limit).map { dir + $0 }
    }

    /// A project added without git: no repository around `root`.
    static func outsideGit(_ e: Error) -> Bool { (e as? GitError)?.stderr.contains("not a git repository") == true }

    /// A folder without git, walked here. Limit: hidden files and folders are left out, as there's no .gitignore to say
    /// what else to skip (.venv, .cache); a folder with more than `limit` files (node_modules) shows the first ones.
    static func walk(_ root: String, limit: Int) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root) else { return [] }
        var files: [String] = []
        while files.count < limit, let p = e.nextObject() as? String {
            if (p as NSString).lastPathComponent.hasPrefix(".") {
                e.skipDescendants()
                continue
            }
            if e.fileAttributes?[.type] as? FileAttributeType == .typeRegular { files.append(p) }
        }
        return files
    }

    /// Bundled or system ripgrep, else `git grep`.
    static var ripgrep: String? {
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("rg").path
        return [bundled, "/opt/homebrew/bin/rg", "/usr/local/bin/rg"].compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// The first `limit` matches; what rg or git grep print past `searchOutput` bytes is read and dropped.
    public static func search(
        _ root: String, query: String, regex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false,
        limit: Int = searchLimit, remotes: Remotes = .none
    ) throws -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var a: [String], r: (data: Data, truncated: Bool)
        if let rg = ripgrep, remotes.of(root) == nil {   // remote: git grep runs on the host
            a = ["--line-number", "--no-heading", "--null", "--color=never", "--max-columns=300", "--max-count=200"]
            if !regex { a.append("--fixed-strings") }
            if !caseSensitive { a.append("--ignore-case") }   // like git grep -i below (smart-case would honour capitals)
            if wholeWord { a.append("--word-regexp") }
            r = try Git.runPart(a + ["--", query, "."], cwd: root, executable: rg, ok: [0, 1], limit: searchOutput)   // 1 = no matches
        } else {
            a = ["grep", "-n", "-z", "--untracked", "-I"]
            a.append(regex ? "-E" : "-F")   // the same patterns as rg's, near enough: ( is a group, not a character
            if !caseSensitive { a.append("-i") }
            if wholeWord { a.append("-w") }
            do {
                r = try Git.runPart(a + ["-e", query], cwd: root, ok: [0, 1], limit: searchOutput, remotes: remotes)
            } catch  where outsideGit(error) {
                a = a.map { $0 == "--untracked" ? "--no-index" : $0 }   // a folder without git: its files as they are
                r = try Git.runPart(a + ["-e", query], cwd: root, ok: [0, 1], limit: searchOutput, remotes: remotes)
            }
        }
        let found = parseGrep(
            String(decoding: r.truncated ? Git.wholeEntries(r.data, 0x0A) : r.data, as: UTF8.self), limit: limit)
        // Cut off before `limit` matches: lines that long (git grep has no column limit) are past showing anyway.
        guard !r.truncated || found.count >= limit else {
            throw GitError(args: a, status: 0, stderr: "Too much matched to show: search for something longer.")
        }
        return found
    }

    /// 2000 matches of rg's 300 columns and a long path fit several times over.
    static let searchOutput = 16 << 20

    /// `path NUL line : text` (rg --null) or `path NUL line NUL text` (git grep -z) lines: the path ends at the NUL, so a
    /// file named "a:b.txt" is found like any other.
    public static func parseGrep(_ s: String, limit: Int = .max) -> [SearchMatch] {
        var r: [SearchMatch] = []
        for l in s.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let nul = l.firstIndex(of: "\0") else { continue }
            var path = String(l[..<nul])
            if path.hasPrefix("./") { path.removeFirst(2) }
            let rest = l[l.index(after: nul)...]
            guard let end = rest.firstIndex(where: { $0 == ":" || $0 == "\0" }), let n = Int(rest[..<end]) else {
                continue
            }
            r.append(
                SearchMatch(
                    path: path, line: n,
                    text: String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespaces)))
            if r.count >= limit { break }
        }
        return r
    }
}

extension Git {
    /// Which of `paths` (relative to `root`; a folder ends with "/") .gitignore and the other exclude files leave out.
    public static func ignored(_ paths: [String], cwd root: String, remotes: Remotes = .none) throws -> Set<String> {
        // 10 s: it runs as files change, for a watch; one that takes longer (a held lock, a huge repo) counts every change.
        let out = try runData(
            ["check-ignore", "-z", "--stdin"], cwd: root, stdin: Data(paths.joined(separator: "\0").utf8), ok: [0, 1],
            timeLimit: 10, remotes: remotes)
        return Set(String(decoding: out, as: UTF8.self).split(separator: "\0").map(String.init))
    }
}
