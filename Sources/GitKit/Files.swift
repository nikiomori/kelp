import Core
import Foundation

/// Project files and search. Uses git so .gitignore is honoured exactly like in a terminal.
extension ProjectFiles {
    /// Tracked + untracked-but-not-ignored files, relative paths. A tracked file deleted from the folder is left out: git
    /// tags it "R" (one git process instead of a stat per file, and it works on a remote host too). Outside a sparse
    /// checkout's cone ("S", never checked by git) a file is kept only if it's there. The first `limit`.
    public static func list(_ root: String, limit: Int = listLimit, remotes: Remotes) throws -> [String] {
        let args = ["ls-files", "-t", "--cached", "--others", "--deleted", "--exclude-standard", "-z"]
        let output: (data: Data, truncated: Bool)
        do {
            output = try Git.runPart(args, cwd: root, limit: Subprocess.outputLimit, remotes: remotes)
        } catch  where outsideGit(error) {
            return walk(root, limit: limit)
        }
        let lines: [Substring] = String(
            decoding: output.truncated ? Git.wholeEntries(output.data, 0) : output.data, as: UTF8.self
        )
        .split(separator: "\0").filter { $0.count > 2 }
        let gone = Set(lines.filter { $0.hasPrefix("R ") }.map { $0.dropFirst(2) })
        let remote = remotes.of(root) != nil
        let files =
            lines.lazy.filter { entry in
                guard !entry.hasPrefix("R "), !gone.contains(entry.dropFirst(2)) else { return false }
                return !entry.hasPrefix("S ") || remote
                    || FileManager.default.fileExists(atPath: root + "/" + entry.dropFirst(2))
            }.prefix(limit).map { String($0.dropFirst(2)) } as [String]
        guard !output.truncated || files.count >= limit else { throw GitError.tooMuch }
        return files
    }

    /// What git ignores (`files.ignored`): a folder ignored whole is one entry ending with "/", not opened (.build/,
    /// node_modules/). `folder`, one of those: what's in it, one level, read from the folder. The first `limit`.
    /// Limit: on a host a name with a newline in it reads as two.
    public static func ignored(_ root: String, folder: String? = nil, limit: Int = listLimit, remotes: Remotes)
        throws -> [String]
    {
        guard let folder else {
            let args = ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]
            let output: (data: Data, truncated: Bool)
            do { output = try Git.runPart(args, cwd: root, limit: Subprocess.outputLimit, remotes: remotes) } catch
                where outsideGit(error)
            { return [] }
            return Array(
                String(decoding: output.truncated ? Git.wholeEntries(output.data, 0) : output.data, as: UTF8.self)
                    .split(separator: "\0").prefix(limit).map(String.init))
        }
        let dir = folder.hasSuffix("/") ? folder : folder + "/"
        guard !dir.hasPrefix("/"), !dir.split(separator: "/").contains("..") else {
            throw GitError.refused("“\(dir)” isn't in the workspace.")
        }
        let names: [String]
        if let host = remotes.of(root) {
            names = String(
                decoding: try host.run("cd \(RemoteHost.cdArg(host.path + "/" + dir)) && ls -1Ap"), as: UTF8.self
            )
            .split(separator: "\n").map(String.init)
        } else {
            names = try FileManager.default.contentsOfDirectory(atPath: root + "/" + dir).map { name in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: root + "/" + dir + name, isDirectory: &isDir)
                    && isDir.boolValue ? name + "/" : name
            }
        }
        return names.prefix(limit).map { dir + $0 }
    }

    /// A project added without git: no repository around `root`.
    static func outsideGit(_ error: Error) -> Bool {
        (error as? GitError)?.stderr?.contains("not a git repository") == true
    }

    /// A folder without git, walked here. Limit: hidden files and folders are left out, as there's no .gitignore to say
    /// what else to skip (.venv, .cache); a folder with more than `limit` files (node_modules) shows the first ones.
    static func walk(_ root: String, limit: Int) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var files: [String] = []
        while files.count < limit, let path = enumerator.nextObject() as? String {
            if (path as NSString).lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular { files.append(path) }
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
        limit: Int = searchLimit, remotes: Remotes
    ) throws -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var args: [String], output: (data: Data, truncated: Bool)
        if let rg = ripgrep, remotes.of(root) == nil {   // remote: git grep runs on the host
            args = ["--line-number", "--no-heading", "--null", "--color=never", "--max-columns=300", "--max-count=200"]
            if !regex { args.append("--fixed-strings") }
            // Like git grep -i below (smart-case would honour capitals).
            if !caseSensitive { args.append("--ignore-case") }
            if wholeWord { args.append("--word-regexp") }
            // 1 = no matches
            let found = try Subprocess.checked(
                [rg] + args + ["--", query, "."], cwd: root, ok: [0, 1], limit: searchOutput)
            output = (found.stdout, found.truncated)
        } else {
            args = ["grep", "-n", "-z", "--untracked", "-I"]
            args.append(regex ? "-E" : "-F")   // the same patterns as rg's, near enough: ( is a group, not a character
            if !caseSensitive { args.append("-i") }
            if wholeWord { args.append("-w") }
            do {
                output = try Git.runPart(
                    args + ["-e", query], cwd: root, ok: [0, 1], limit: searchOutput, remotes: remotes)
            } catch  where outsideGit(error) {
                // A folder without git: its files as they are.
                args = args.map { $0 == "--untracked" ? "--no-index" : $0 }
                output = try Git.runPart(
                    args + ["-e", query], cwd: root, ok: [0, 1], limit: searchOutput, remotes: remotes)
            }
        }
        let found = parseGrep(
            String(decoding: output.truncated ? Git.wholeEntries(output.data, 0x0A) : output.data, as: UTF8.self),
            limit: limit)
        // Cut off before `limit` matches: lines that long (git grep has no column limit) are past showing anyway.
        guard !output.truncated || found.count >= limit else {
            throw GitError.refused("Too much matched to show: search for something longer.")
        }
        return found
    }

    /// 2000 matches of rg's 300 columns and a long path fit several times over.
    static let searchOutput = 16 << 20

    /// `path NUL line : text` (rg --null) or `path NUL line NUL text` (git grep -z) lines: the path ends at the NUL, so a
    /// file named "a:b.txt" is found like any other.
    public static func parseGrep(_ output: String, limit: Int = .max) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let nul = line.firstIndex(of: "\0") else { continue }
            var path = String(line[..<nul])
            if path.hasPrefix("./") { path.removeFirst(2) }
            let rest = line[line.index(after: nul)...]
            guard let end = rest.firstIndex(where: { $0 == ":" || $0 == "\0" }), let number = Int(rest[..<end]) else {
                continue
            }
            matches.append(
                SearchMatch(
                    path: path, line: number,
                    text: String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespaces)))
            if matches.count >= limit { break }
        }
        return matches
    }
}

extension Git {
    /// Which of `paths` (relative to `root`; a folder ends with "/") .gitignore and the other exclude files leave out.
    public static func ignored(_ paths: [String], cwd root: String, remotes: Remotes) throws -> Set<String> {
        // 10 s: it runs as files change, for a watch; one that takes longer (a held lock, a huge repo) counts every change.
        let out = try runData(
            ["check-ignore", "-z", "--stdin"], cwd: root, stdin: Data(paths.joined(separator: "\0").utf8), ok: [0, 1],
            timeLimit: 10, remotes: remotes)
        return Set(String(decoding: out, as: UTF8.self).split(separator: "\0").map(String.init))
    }
}
