import Core
import Foundation

/// What a diff is taken against.
public enum DiffSource: Sendable {
    case unstaged   // worktree vs index
    case staged   // index vs HEAD
    case allUncommitted   // worktree vs HEAD
    case branch(base: String)   // HEAD vs merge-base(base)
    case commit(String)
    case since(tree: String)   // the working tree now vs a snapshot taken earlier (`snapshotTree`)
    case between(String, String)   // one snapshot (or commit) vs a later one: a turn that ended before the next began
}

extension Git {
    public static func parseDiff(_ output: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var header: [String] = [], path = "", binary = false
        var hunks: [Hunk] = []
        var cur: Hunk?
        var oldLine = 0, newLine = 0
        func flushHunk() {
            if let hunk = cur {
                hunks.append(hunk)
                cur = nil
            }
        }
        func flushFile() {
            flushHunk()
            if !header.isEmpty {
                files.append(FileDiff(path: path, header: header.joined(separator: "\n"), hunks: hunks, binary: binary))
            }
            header = []
            hunks = []
            binary = false
            path = ""
        }
        for raw in output.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                flushFile()
                header = [raw]
                // `a/x b/x`, or `"a/x" "b/x"` when a name has quotes, backslashes or control characters (git escapes those).
                if let bQuote = raw.range(of: raw.hasSuffix("\"") ? " \"b/" : " b/", options: .backwards),
                    let name = headerPath(raw[raw.index(after: bQuote.lowerBound)...])
                {
                    path = name
                }
            } else if cur == nil && !header.isEmpty && !raw.hasPrefix("@@") {
                if raw.hasPrefix("Binary files") || raw.hasPrefix("GIT binary patch") { binary = true }
                if raw.hasPrefix("+++ "), let name = headerPath(raw.dropFirst(4)) { path = name }
                if raw.hasPrefix("--- ") && path.isEmpty, let name = headerPath(raw.dropFirst(4)) { path = name }
                header.append(raw)
            } else if raw.hasPrefix("@@") {
                flushHunk()
                // @@ -a,b +c,d @@
                let nums = raw.split(separator: " ").dropFirst().prefix(2).map {
                    $0.dropFirst().split(separator: ",").first.flatMap { Int($0) }
                }
                oldLine = nums.first.flatMap { $0 } ?? 1
                newLine = nums.dropFirst().first.flatMap { $0 } ?? 1
                cur = Hunk(header: raw, oldStart: oldLine, newStart: newLine, lines: [])
            } else if cur != nil {
                // By scalar: "+" and a combining mark after it are one Character, and the line would be dropped.
                guard let marker = raw.unicodeScalars.first else { continue }   // trailing empty
                let text = String(raw.unicodeScalars.dropFirst())
                switch marker {
                case "+":
                    cur?.lines.append(DiffLine(kind: .add, text: text, oldLine: nil, newLine: newLine))
                    newLine += 1
                case "-":
                    cur?.lines.append(DiffLine(kind: .del, text: text, oldLine: oldLine, newLine: nil))
                    oldLine += 1
                case " ":
                    cur?.lines.append(DiffLine(kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                    oldLine += 1
                    newLine += 1
                case "\\": if let last = cur?.lines.indices.last { cur?.lines[last].noNewline = true }   // "\ No newline at end of file"
                default: break
                }
            }
        }
        flushFile()
        return files
    }

    /// How much of a diff one reply carries (git's output and a little per line, `Allowance`): a file past its share
    /// comes back with its header only (`tooLarge`), and so does every file once the whole is spent, so an agent
    /// regenerating a lock file or writing thousands of files can't make a reply the app chokes on. In a review (every
    /// file) one file gets an eighth, so a regenerated lock file doesn't push the rest out; asked for alone, the whole.
    public static let diffBudget = 8 << 20

    /// What's left of `diffBudget` while a diff is read. A file costs its bytes and 40 for each line: about its size in
    /// the reply, where each line is an object of its own (and a row on screen).
    struct Allowance {
        var left = Git.diffBudget
        let perFile: Int
        init(oneFile: Bool) { perFile = oneFile ? Git.diffBudget : Git.diffBudget / 8 }
        /// Whether this many bytes could still go in, whatever their lines.
        func fits(_ count: Int) -> Bool { count <= min(left, perFile) }
        /// Whether this file's text still goes in (counted if so).
        mutating func take(_ data: Data) -> Bool {
            guard fits(data.count) else { return false }
            let lines = data.withUnsafeBytes { b in b.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } }
            guard fits(data.count + 40 * lines) else { return false }
            left -= data.count + 40 * lines
            return true
        }
    }

    /// Each file of git's diff output decoded on its own: as UTF-8, or byte for byte (Latin-1) when it isn't, so a patch
    /// built back from it applies (a lossy decode would put U+FFFD where the file has other bytes). A file past what's
    /// left of `budget` is read up to its first hunk only.
    static func parseDiff(_ data: Data, budget: inout Allowance) -> [FileDiff] {
        let mark = Data("\ndiff --git ".utf8)
        var starts = [data.startIndex], from = data.startIndex
        while let found = data.range(of: mark, in: from..<data.endIndex) {
            starts.append(found.lowerBound + 1)
            from = found.upperBound
        }
        return zip(starts, starts.dropFirst() + [data.endIndex]).flatMap { start, end -> [FileDiff] in
            var chunk = data[start..<end]
            let fits = budget.take(chunk)
            if !fits, let hunks = chunk.range(of: Data("\n@@".utf8)) { chunk = chunk[..<hunks.lowerBound] }
            let utf8 = String(data: chunk, encoding: .utf8)
            return parseDiff(utf8 ?? String(data: chunk, encoding: .isoLatin1) ?? "").map {
                var file = $0
                if utf8 == nil { file.latin1 = true }
                if !fits { file.tooLarge = true }
                return file
            }
        }
    }

    /// `a/x` or `b/x` from a diff header, unquoted; nil for `/dev/null`.
    static func headerPath(_ name: Substring) -> String? {
        var name = String(name)
        if name.hasSuffix("\t") { name.removeLast() }   // git ends a ---/+++ name that has a space with a tab
        name = unquoted(name)
        return name.hasPrefix("a/") || name.hasPrefix("b/") ? String(name.dropFirst(2)) : nil
    }

    /// A name git wrote C-quoted (`"x\"y"`, `"\303\244"`) as it is.
    static func unquoted(_ name: String) -> String {
        guard name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") else { return name }
        let bytes = Array(name.utf8.dropFirst().dropLast())
        let escapes: [UInt8: UInt8] = [
            UInt8(ascii: "n"): 10, UInt8(ascii: "t"): 9, UInt8(ascii: "r"): 13, UInt8(ascii: "a"): 7,
            UInt8(ascii: "b"): 8, UInt8(ascii: "f"): 12, UInt8(ascii: "v"): 11
        ]
        var out: [UInt8] = [], index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                out.append(bytes[index])
                index += 1
                continue
            }
            if index + 3 < bytes.count, let octal = String(bytes: bytes[(index + 1)...(index + 3)], encoding: .ascii),
                let byte = UInt8(octal, radix: 8)
            {
                out.append(byte)
                index += 4
                continue
            }
            out.append(escapes[bytes[index + 1]] ?? bytes[index + 1])
            index += 2
        }
        return String(bytes: out, encoding: .utf8) ?? name
    }

    /// `ignoreSpace`: changes of whitespace alone left out (`git diff -w`), and the files with nothing else changed.
    /// `context`: unchanged lines around each change (git's -U); a large one gives a file whole, as one hunk.
    public static func diff(
        _ path: String, source: DiffSource, file: String? = nil, ignoreSpace: Bool = false, context: Int = 3,
        remotes: Remotes = .none
    ) throws -> [FileDiff] {
        // Fixed prefixes and no external tool or textconv: a user's diff.noprefix / diff.mnemonicPrefix / diff.external don't
        // change the output, and a repo's own config can't run a program on every diff shown (nor give a patch that won't apply).
        let common =
            [
                "--no-color", "--no-ext-diff", "--no-textconv", "-U\(max(0, context))", "--src-prefix=a/",
                "--dst-prefix=b/"
            ]
            + (ignoreSpace ? ["-w"] : [])
        var args = ["diff"] + common
        switch source {
        case .unstaged: break
        case .staged: args.append("--cached")
        case .allUncommitted: args.append("HEAD")
        case .branch(let base): args.append("\(try rev(base))...HEAD")
        case .commit(let commit):
            args = ["show", "--format=", "-M", "--diff-merges=first-parent"] + common + [try rev(commit)]
        case .since(let tree): args += [try rev(tree), try snapshotTree(path, remotes: remotes)]   // two trees: new files included, nothing staged
        case .between(let from, let to): args += [try rev(from), try rev(to)]
        }
        let only = file.map { ["--"] + literal([$0]) } ?? []
        var budget = Allowance(oneFile: file != nil)
        // Read up to twice the budget: the budget is spent by then, unless whole files were past their share. git's
        // output after that is dropped as it comes; the files it held are named by a second, short run, header only.
        let out = try runPart(args + only, cwd: path, limit: 2 * diffBudget, remotes: remotes)
        var diffs = parseDiff(out.truncated ? wholeFiles(out.data) : out.data, budget: &budget)
        if out.truncated {
            let shown = Set(diffs.map(\.path))
            let names = try run(args + ["--name-only", "-z"] + only, cwd: path, remotes: remotes).split(separator: "\0")
                .map(String.init)
            diffs += names.filter { !shown.contains($0) }.map {
                FileDiff(path: $0, header: "diff --git a/\($0) b/\($0)", hunks: [], binary: false, tooLarge: true)
            }
        }
        // Untracked files are invisible to `git diff`; show them as all-added for working-tree sources.
        if case .unstaged = source { diffs += try untrackedDiffs(path, only: file, budget: &budget, remotes: remotes) }
        if case .allUncommitted = source {
            diffs += try untrackedDiffs(path, only: file, budget: &budget, remotes: remotes)
        }
        // With -w git still names a file whose only change was whitespace, with no hunks. Limit: a pure rename goes too.
        return ignoreSpace ? diffs.filter { !$0.hunks.isEmpty || $0.binary || $0.tooLarge == true } : diffs
    }

    /// The files of diff output cut off somewhere: up to where the last one begins.
    static func wholeFiles(_ data: Data) -> Data {
        data.range(of: Data("\ndiff --git ".utf8), options: .backwards).map { data[...$0.lowerBound] } ?? Data()
    }

    static func untrackedDiffs(_ path: String, only: String?, budget: inout Allowance, remotes: Remotes = .none) throws
        -> [FileDiff]
    {
        let remote = remotes.of(path)
        let files = try status(path, only: only, limit: FileChange.limit, remotes: remotes).filter {
            $0.untracked && (only == nil || $0.path == only)
        }
        // On the host: all of them in one round trip, each at most a byte past the limit (the folder here is a marker).
        let there = remote.map { r in (try? untrackedOnHost(r, files.map(\.path), budget: budget.left)) ?? [:] } ?? [:]
        return files.compactMap { file in
            let full = (path as NSString).appendingPathComponent(file.path)
            let mode = FileManager.default.isExecutableFile(atPath: full) ? "100755" : "100644"   // staged as it is: a script stays runnable
            let hdr =
                "diff --git a/\(file.path) b/\(file.path)\nnew file mode \(mode)\n--- /dev/null\n+++ b/\(file.path)"
            let asBinary = FileDiff(path: file.path, header: hdr, hunks: [], binary: true)
            let tooLarge = FileDiff(path: file.path, header: hdr, hunks: [], binary: false, tooLarge: true)
            if remote != nil {
                switch there[file.path] {
                case .none: return asBinary
                case .some(.none): return tooLarge   // the host read no more: the budget was spent
                case .some(.some(let data)):
                    guard data.count <= 1_000_000 else { return asBinary }
                    return budget.take(data) ? added(data, file.path, hdr) ?? asBinary : tooLarge
                }
            }
            // A symlink is shown as git stores it, its target path; following it could read /dev/zero or a huge file.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: full) {
                let hunk = Hunk(
                    header: "@@ -0,0 +1 @@", oldStart: 0, newStart: 1,
                    lines: [DiffLine(kind: .add, text: target, oldLine: nil, newLine: 1, noNewline: true)])
                return FileDiff(
                    path: file.path,
                    header: hdr.replacingOccurrences(of: "new file mode \(mode)", with: "new file mode 120000"),
                    hunks: [hunk], binary: false)
            }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int else {
                return nil
            }
            guard size <= 1_000_000 else { return asBinary }   // a log, a dataset, a folder that should be ignored: not read
            guard budget.fits(size) else { return tooLarge }   // not read
            guard let data = FileManager.default.contents(atPath: full) else { return nil }
            return budget.take(data) ? added(data, file.path, hdr) ?? asBinary : tooLarge
        }
    }

    /// Untracked files on a remote project's host, one ssh round trip per 200 (a command line has a length limit): each
    /// its first 1 MB and a byte; one that isn't a regular file or can't be read is left out (shown as binary). Once
    /// `budget` bytes came the host reads no more: those files are there as nil.
    static func untrackedOnHost(_ host: RemoteHost, _ paths: [String], budget: Int) throws -> [String: Data?] {
        var out: [String: Data?] = [:], left = budget
        for start in stride(from: 0, to: paths.count, by: 200) {
            let chunk = paths[start..<min(start + 200, paths.count)]
            guard left > 0 else {
                chunk.forEach { out[$0] = .some(nil) }
                continue
            }
            let names = chunk.map { IDE.shellWord(host.path + "/" + $0) }.joined(separator: " ")
            // Each file as a line with its length (-1: not read, -2: the budget is spent) and then that many bytes.
            let script =
                "t=$(mktemp) || exit 1; left=\(left); for f in \(names); do if [ $left -le 0 ]; then echo -2; "
                + "elif [ -f \"$f\" ] && head -c 1000001 -- \"$f\" > \"$t\" 2>/dev/null; "
                + "then n=$(wc -c < \"$t\"); left=$((left - n)); echo $n; cat \"$t\"; else echo -1; fi; done; rm -f \"$t\""
            var rest = try host.run(script)[...]
            for path in chunk {
                guard let nl = rest.firstIndex(of: 0x0A), let length = Int(String(decoding: rest[..<nl], as: UTF8.self))
                else { break }
                rest = rest[(nl + 1)...]
                if length == -2 {
                    out[path] = .some(nil)
                    left = 0
                    continue
                }
                guard length >= 0, rest.count >= length else { continue }
                out[path] = Data(rest.prefix(length))
                rest = rest.dropFirst(length)
                left -= length
            }
        }
        return out
    }

    /// A new file's text as one added hunk; nil when it isn't text.
    private static func added(_ data: Data, _ path: String, _ hdr: String) -> FileDiff? {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        let lastNewline = lines.last == ""
        if lastNewline { lines.removeLast() }
        var added = lines.enumerated().map { DiffLine(kind: .add, text: $1, oldLine: nil, newLine: $0 + 1) }
        if !lastNewline, !added.isEmpty { added[added.count - 1].noNewline = true }
        let hunk = Hunk(header: "@@ -0,0 +1,\(lines.count) @@", oldStart: 0, newStart: 1, lines: added)
        return FileDiff(path: path, header: hdr, hunks: lines.isEmpty ? [] : [hunk], binary: false)
    }
}
