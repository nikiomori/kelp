import Core
import Foundation
import os

let gitLog = Logger.kelp("git")

/// What went wrong running git: git failed, Kelp didn't run it (and says why), or it printed more than Kelp reads.
public enum GitError: Error, CustomStringConvertible, Sendable {
    case failed(args: [String], status: Int32, stderr: String)
    /// Kelp's own sentence for people, saying what's in the way (a merge under way, a name that reads as an option).
    case refused(String)
    case tooMuch

    public var description: String {
        switch self {
        case .failed(let args, let status, let stderr):
            "git \(args.joined(separator: " ")) failed (\(status)): \(stderr)"
        case .refused(let why): why
        case .tooMuch: "It printed more than \(Subprocess.outputLimit >> 20) MB, more than Kelp reads."
        }
    }
    /// The error for people: git's first sentence without the command line or "fatal:", or Kelp's own message. A
    /// sentence ending in "…overwritten by checkout:" keeps its next line.
    public var message: String {
        if case .failed(_, _, let stderr) = self, let said = ProgramError.firstSentence(stderr) { return said }
        return description
    }
    /// What git said on stderr; nil when git didn't fail by itself.
    public var stderr: String? {
        if case .failed(_, _, let stderr) = self { stderr } else { nil }
    }
}

/// Running the system git (the daemon's). Behaviour matches what you'd see in a terminal.
extension Git {
    @discardableResult
    public static func run(
        _ args: [String], cwd: String, stdin: String? = nil, ok: Set<Int32> = [0], env extra: [String: String] = [:],
        remotes: Remotes
    ) throws -> String {
        String(
            decoding: try runData(
                args, cwd: cwd, stdin: stdin.map { Data($0.utf8) }, ok: ok, env: extra, remotes: remotes),
            as: UTF8.self)
    }

    /// Whether git says yes (exits 0), for checks such as a ref that may not exist (`rev-parse --verify`) or an
    /// upstream that may not be set. A git that couldn't run at all says no too, and that's logged.
    public static func succeeds(_ args: [String], cwd: String, remotes: Remotes) -> Bool {
        do {
            try run(args, cwd: cwd, remotes: remotes)
            return true
        } catch is GitError {
            return false
        } catch {
            gitLog.error("git \(args.first ?? "", privacy: .public) didn't run: \(error)")
            return false
        }
    }

    /// Returns the output of `run` without its final newline and any space around it, for a hash, a name, a path or a
    /// count.
    public static func line(
        _ args: [String], cwd: String, ok: Set<Int32> = [0], env extra: [String: String] = [:],
        remotes: Remotes
    ) throws -> String {
        try run(args, cwd: cwd, ok: ok, env: extra, remotes: remotes).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git like `run`, but returns the output as the bytes git wrote, so a diff of a file that isn't UTF-8 goes
    /// back to `git apply` unchanged. Output longer than `Subprocess.outputLimit` is an error, so nothing here works on
    /// a part as if it were the whole.
    @discardableResult
    public static func runData(
        _ args: [String], cwd: String, stdin: Data? = nil, ok: Set<Int32> = [0], env extra: [String: String] = [:],
        timeLimit: TimeInterval = 300, remotes: Remotes
    ) throws -> Data {
        let output = try runPart(
            args, cwd: cwd, stdin: stdin, ok: ok, env: extra, timeLimit: timeLimit, limit: Subprocess.outputLimit,
            remotes: remotes)
        guard !output.truncated else { throw GitError.tooMuch }
        return output.data
    }

    /// Runs git like `runData`, but keeps the first `limit` bytes of the output. `truncated` says there was more, which
    /// was read and dropped. It is for a caller that shows a part (a long status, a huge diff) and says so.
    static func runPart(
        _ args: [String], cwd: String, stdin: Data? = nil, ok: Set<Int32> = [0], env extra: [String: String] = [:],
        timeLimit: TimeInterval = 300, limit: Int, remotes: Remotes
    ) throws -> (data: Data, truncated: Bool) {
        // `timeLimit` is the longest a git run (here or on a host) may take before it's stopped, and it then fails like
        // any other error. The default of five minutes is far past any real fetch or push, and short of a thread lost
        // for good.
        // Paths are passed as they are, not C-quoted ("\321\204…" for "ф"). fsmonitor is off, because otherwise a
        // folder's own .git/config (one that came in a download, not a clone) would start its program on every status
        // Kelp runs.
        let hooks = args.first.map(runsHooks.contains) ?? false
        var args = ["-c", "core.quotePath=false", "-c", "core.fsmonitor=false"] + args
        var argv0 = "/usr/bin/git", cwd = cwd
        var off: [(String, String)] = []
        let remote = remotes.of(cwd)
        // A repo's diff drivers don't run anything either.
        if let sub = args.dropFirst(4).first, ["diff", "show", "log"].contains(sub) {
            args.insert(contentsOf: ["--no-ext-diff", "--no-textconv"], at: 5)
        }
        // Read-only commands don't verify signatures either, because a repo's `log.showSignature` would run its own
        // `gpg.program` on every log.
        if let sub = args.dropFirst(4).first, readOnly.contains(sub) {
            args = Self.noSignatures + args
            if remote == nil { off = RepoFilters.off(cwd) }
        }
        var env = gitEnv.merging(extra) { $1 }
        if let host = remote {   // for a remote project, the same git runs on its host
            args = host.sshArgs(tty: false) + [Self.onHost(args, env: env, path: host.path, hooks: hooks)]
            argv0 = host.ssh
            cwd = NSHomeDirectory()
        }
        env.merge(configEnv(off, after: ProcessInfo.processInfo.environment.merging(env) { $1 })) { $1 }
        // A host that drops packets or a credential helper waiting on nobody is stopped at the time limit, with its children.
        do {
            let result = try Subprocess.checked(
                [argv0] + args, cwd: cwd, env: env, stdin: stdin, ok: ok, timeLimit: timeLimit, limit: limit)
            return (result.stdout, result.truncated)
        } catch let error as ProgramError {
            // Exit status 255 is ssh's own failure (git's exit codes are 1 or 128), so what's missing is the host, not
            // git.
            if let host = remote, error.status == 255 {
                let why = error.stderr.split(whereSeparator: \.isNewline).last.map { ": " + $0 } ?? "."   // ssh's words
                throw GitError.refused("Can't reach \(host.host)" + why)
            }
            throw GitError.failed(args: args, status: error.status, stderr: error.stderr)
        }
    }

    /// Builds the command that runs `git args` on a host, as ssh hands it to the login shell there. It runs in sh,
    /// whatever that login shell is, with `env`, while this Mac's environment stays here. A commit, a push or a switch
    /// runs the repository's hooks (husky, pre-commit), so those commands run in the login shell as a terminal there
    /// has it, whose PATH includes nvm's and npm's (`RemoteHost.command`).
    static func onHost(_ args: [String], env: [String: String], path: String, hooks: Bool) -> String {
        let git =
            (["env"] + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + ["git"] + args)
            .map(ShellQuote.word).joined(separator: " ")
        return "sh -c "
            + ShellQuote.word(
                "cd \(RemoteHost.cdArg(path)) && exec " + (hooks ? "\"$SHELL\" -ilc " + ShellQuote.word(git) : git))
    }
    static let runsHooks: Set<String> = ["commit", "merge", "pull", "push", "switch", "checkout", "rebase", "am"]

    /// No password prompt that nobody would see, and no index rewrite by a status, which would wake the file watchers
    /// again.
    static let gitEnv = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]

    /// The environment for a program that runs git itself (gh, glab): `gitEnv`, with a repository's own fsmonitor and
    /// signature program turned off there too.
    public static var toolEnv: [String: String] {
        let off = [("core.fsmonitor", "false"), ("log.showSignature", "false")]
        return gitEnv.merging(configEnv(off, after: ProcessInfo.processInfo.environment)) { $1 }
    }

    /// Config for the commands Kelp runs by itself (watches, panels), which only read. They never run a repository's
    /// own signature programs or its filters (`RepoFilters`).
    static let noSignatures = [
        "-c", "log.showSignature=false", "-c", "gpg.program=false", "-c", "gpg.ssh.program=false", "-c",
        "gpg.x509.program=false"
    ]
    static let readOnly: Set<String> = [
        "status", "diff", "show", "log", "blame", "ls-files", "grep", "diff-files", "diff-index"
    ]

    /// Config for one run, as environment variables numbered after those that `env` holds already. Unlike `-c`, this
    /// takes any key, because a filter can be called `a=b`, and `-c` would split that at its first `=`. A submodule's
    /// git still gets it.
    static func configEnv(_ pairs: [(String, String)], after env: [String: String]) -> [String: String] {
        guard !pairs.isEmpty else { return [:] }
        let start = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
        var out = ["GIT_CONFIG_COUNT": String(start + pairs.count)]
        for (index, (key, value)) in pairs.enumerated() {
            out["GIT_CONFIG_KEY_\(start + index)"] = key
            out["GIT_CONFIG_VALUE_\(start + index)"] = value
        }
        return out
    }

    /// Returns the output as text. Output cut off mid-entry keeps its whole entries: up to and including its last
    /// `separator`.
    static func wholeEntries(_ output: (data: Data, truncated: Bool), _ separator: UInt8) -> String {
        let data = output.data
        let whole = output.truncated ? data.lastIndex(of: separator).map { data[...$0] } ?? Data() : data
        return String(decoding: whole, as: UTF8.self)
    }

    /// File names as pathspecs that mean just those files: "[id].tsx" isn't a pattern for "i.tsx" or "d.tsx".
    /// (Not `--literal-pathspecs`: `stash -u` uses pathspec magic of its own and then leaves untracked files behind.)
    static func literal(_ files: [String]) -> [String] { files.map { ":(literal)" + $0 } }

    public static func root(of path: String, remotes: Remotes) throws -> String {
        try line(["rev-parse", "--show-toplevel"], cwd: path, remotes: remotes)
    }

    /// A branch name Kelp may pass to git as a revision: never one that reads as an option. Git won't create such a
    /// name, but a cloned repository's HEAD can point at one (refs/heads/--output=/some/file), and `git diff <it>` would
    /// take it as --output and overwrite that file. Names read from git go through this; names from clients through
    /// the daemon's `ref`.
    public static func isRevision(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix("-") }

    /// Returns `name` for use as a revision or branch argument, wherever it came from (a client, the database, git's
    /// own output). Every GitKit call that puts a name where git reads options goes through this, so no name can become
    /// an option.
    static func rev(_ name: String) throws -> String {
        guard isRevision(name) else {
            throw GitError.refused("“\(name)” isn't a branch or commit name.")
        }
        return name
    }

    /// Returns the default branch: origin/HEAD if set, or else main or master if one exists, or else the current branch
    /// of the main checkout.
    public static func defaultBranch(repo: String, remotes: Remotes) -> String {
        if let ref = try? line(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: repo, remotes: remotes) {
            let branch = String(ref.drop(while: { $0 != "/" }).dropFirst())
            if isRevision(branch) { return branch }
        }
        for branch in ["main", "master"] where succeeds(["rev-parse", "--verify", branch], cwd: repo, remotes: remotes)
        {
            return branch
        }
        return (try? currentBranch(repo, remotes: remotes)) ?? "main"
    }

    /// Returns the current branch. Every workspace list asks this for each project, and each PR and CI read for each
    /// workspace, so a local checkout's HEAD file answers without a git process, a linked worktree's too. For a
    /// detached HEAD, a reftable repository or a remote project, git itself answers.
    public static func currentBranch(_ path: String, remotes: Remotes) throws -> String {
        var name = ""
        if remotes.of(path) == nil, let head = headBranch(path),
            head != ".invalid"   // a reftable repository's stub HEAD, whose real HEAD is in its tables
        {
            name = head
        }
        if name.isEmpty {
            name = try line(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path, remotes: remotes)
        }
        guard isRevision(name) else {
            throw GitError.refused("The branch's name reads as an option: \(name)")
        }
        return name
    }
}

/// The filter drivers that a repository's own config defines (`filter.<name>.clean` / `process` in .git/config, an
/// include of it, or config.worktree). A folder that came as a download, not a clone, can carry one with
/// `.gitattributes`, and every `git status` Kelp runs as files change would start it. Reads and Kelp's snapshots turn
/// these filters off. What the user does (add, commit, checkout) keeps them, so git-crypt and the like still encrypt.
/// Filters from the user's own (global) config are left alone.
/// Limit: with its filter off, a file whose stat changed reads as modified in a git-crypt-style repo until it's added.
enum RepoFilters {
    /// The filter names for each config file, with the stamp of every file they were read from (the config and what it
    /// includes).
    private static let cache = OSAllocatedUnfairLock<[String: (stamps: [String: Date], names: [String])]>(
        initialState: [:])

    /// The config that turns the repository's filters off for one run in `cwd` (`Git.configEnv`).
    static func off(_ cwd: String) -> [(String, String)] {
        names(cwd).flatMap { filter in
            [("clean", ""), ("smudge", ""), ("process", ""), ("required", "false")].map {
                ("filter.\(filter).\($0)", $1)
            }
        }
    }

    /// Returns the filter that a config key is about, if the key runs something. The key is split from both ends,
    /// because a filter's name can hold dots, spaces and `=`.
    static func name(ofKey key: Substring) -> String? {
        guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."),
            ["clean", "smudge", "process"].contains(key[key.index(after: dot)...])
        else { return nil }
        let start = key.index(key.startIndex, offsetBy: 7)
        return start < dot ? String(key[start..<dot]) : nil
    }

    /// Returns the repository's filter names. They are read again only when the repository's config, or a file it
    /// includes, changed (by their stamps), and on every run when the config can't be found.
    /// Limit: an included file with nothing in it yet isn't watched until the config is read again.
    static func names(_ cwd: String) -> [String] {
        guard let file = configFile(cwd) else { return read(cwd).names }
        if let hit = cache.withLock({ $0[file] }), hit.stamps.allSatisfy({ stamp($0.key) == $0.value }) {
            return hit.names
        }
        let own = read(cwd), subs = submodules(of: file)
        let names = Array(Set(own.names + subs.names)).sorted()
        let stamps = Dictionary((own.files + subs.files + [file]).compactMap { path in stamp(path).map { (path, $0) } })
        { first, _ in
            first
        }
        cache.withLock { $0[file] = (stamps, names) }
        return names
    }

    /// The filters that the repository's submodules define in their own config (.git/modules/…/config), because `git
    /// status` runs in each populated submodule too, and Kelp's `-c` reaches them (GIT_CONFIG_PARAMETERS). Their config
    /// files are stamped as well.
    private static func submodules(of config: String) -> (names: [String], files: [String]) {
        let modules = URL(fileURLWithPath: config).deletingLastPathComponent().appendingPathComponent("modules")
        let all =
            (FileManager.default.enumerator(at: modules, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        let files = all.filter { $0.lastPathComponent == "config" }.map(\.path)
        var names = Set<String>()
        for file in files {
            let args = [
                "/usr/bin/git", "config", "-z", "--file", file, "--includes", "--get-regexp",
                #"^filter\..*\.(clean|smudge|process)$"#
            ]
            guard
                let result = try? Subprocess.run(
                    args, cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 10, limit: 1 << 20)
            else { continue }
            for entry in String(decoding: result.stdout, as: UTF8.self).split(separator: "\0") {   // "key\nvalue"
                if let filter = name(ofKey: entry.prefix { $0 != "\n" }) { names.insert(filter) }
            }
        }
        return (Array(names), files)
    }

    private static func stamp(_ path: String) -> Date? { FileManager.default.modified(path) }

    /// The repository's own filter names, and the files its config was read from (includes followed).
    private static func read(_ cwd: String) -> (names: [String], files: [String]) {
        let args = [
            "/usr/bin/git", "-c", "core.fsmonitor=false", "config", "-z", "--show-scope", "--show-origin", "--list"
        ]
        guard
            let result = try? Subprocess.run(
                args, cwd: cwd, env: ProcessInfo.processInfo.environment, timeLimit: 10, limit: 1 << 20)
        else { return ([], []) }
        var names = Set<String>(), files = Set<String>()
        // Scope, origin and "key\nvalue" each end with a NUL, so nothing a name holds can pass for the next field.
        let fields = String(decoding: result.stdout, as: UTF8.self).split(
            separator: "\0", omittingEmptySubsequences: false)
        for index in stride(from: 0, to: fields.count - 2, by: 3)
        where fields[index] == "local" || fields[index] == "worktree" {
            if fields[index + 1].hasPrefix("file:") { files.insert(String(fields[index + 1].dropFirst(5))) }
            if let filter = name(ofKey: fields[index + 2].prefix { $0 != "\n" }) { names.insert(filter) }
        }
        let root = URL(fileURLWithPath: cwd)
        return (names.sorted(), files.map { URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL.path })
    }

    /// The config file of the repository `cwd` is in: .git/config, or the main one's for a linked worktree.
    static func configFile(_ cwd: String) -> String? {
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return Git.commonDir(dir.path)?.appendingPathComponent("config").path
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return nil }
            dir = up
        }
    }
}
