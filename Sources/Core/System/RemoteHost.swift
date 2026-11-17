import Foundation

/// A project on another machine, reached over SSH. Kelp keeps a local folder for it that holds only `.kelp-remote`
/// (`{"host", "path"}`). Git in that folder runs on the host instead, so the git and file panels work unchanged, and
/// the project's agents and terminals run there too. All of it shares one SSH connection per host (ControlMaster),
/// which is kept for ten minutes after the last use. A dropped connection ends the sessions, and Restart connects
/// again.
public struct RemoteHost: Codable, Sendable, Equatable {
    public var host: String, path: String
    /// The folder for the sockets of the shared connections, and the `ssh` that makes them. Both come from the Kelp
    /// home (`Remotes`).
    public var controlDir = NSTemporaryDirectory(), ssh = "/usr/bin/ssh"
    public init(host: String, path: String) {
        self.host = host
        self.path = path
    }
    private enum CodingKeys: String, CodingKey { case host, path }

    public static let marker = ".kelp-remote"
    /// The tmux session option, on the host, that holds the agent's last status report.
    public static let statusOption = "@kelp_status"

    /// Whether `host` may follow `ssh`: it must not be an option or anything a shell would split.
    /// It is also a folder name under remote/, so "." or ".." or a "/" would put the folder somewhere else.
    public static func isHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && !host.contains(where: \.isWhitespace) && !host.contains("/")
            && host != "."
            && host != ".."
    }

    /// Returns the `Host` names in ~/.ssh/config and the files it includes, leaving out patterns. A host field offers
    /// these names.
    public static func configHosts(_ file: String = NSHomeDirectory() + "/.ssh/config", depth: Int = 0) -> [String] {
        let text: String
        do { text = try String(contentsOfFile: file, encoding: .utf8) } catch { return [] }
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let words = line.split { $0.isWhitespace || $0 == "=" }.map(String.init)
            switch words.first?.lowercased() {
            case "host":
                return words.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
            case "include" where depth < 4:   // ssh's own limit is 16; this stops an include loop
                return words.dropFirst().flatMap { pattern in
                    // A relative path is relative to ~/.ssh, as ssh reads it (OrbStack's, config.d/*).
                    let path =
                        pattern.hasPrefix("/")
                        ? pattern
                        : pattern.hasPrefix("~/")
                            ? NSHomeDirectory() + pattern.dropFirst() : NSHomeDirectory() + "/.ssh/" + pattern
                    return matches(path).sorted().flatMap { configHosts($0, depth: depth + 1) }
                }
            default: return []
            }
        }
        .filter { seen.insert($0).inserted }
    }

    /// Returns the files that a glob pattern (`*`, `?`) matches, or an empty list when none do.
    private static func matches(_ pattern: String) -> [String] {
        var found = glob_t()
        defer { globfree(&found) }
        guard glob(pattern, 0, nil, &found) == 0 else { return [] }
        return (0..<Int(found.gl_pathc)).compactMap { found.gl_pathv[$0].map { String(cString: $0) } }
    }

    /// Returns ssh's options for this host: the shared connection, and no password prompts where nobody can answer
    /// them. A host that went quiet (the network dropped, the Mac woke elsewhere) is given up on after 30 s instead of
    /// ssh's 90, because until then every read waits on it and its panels show it as connected.
    public func sshArgs(tty: Bool) -> [String] {
        (tty ? ["-tt"] : ["-T", "-o", "BatchMode=yes"])
            + [
                "-o", "ConnectTimeout=15", "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlDir)/%C", "-o",
                "ControlPersist=600",
                "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", "--", host
            ]
    }

    /// Returns the line the host's shell runs: `argv` in the project's folder, through an interactive login shell so
    /// the host's PATH applies. The shell is interactive as well, because nvm and npm's global bin are set in .bashrc,
    /// which `bash -lc` skips. A nil argv runs an interactive login shell.
    public func command(_ argv: [String]?, envFile: String? = nil, exports: [String: String] = [:]) -> String {
        let cd = "cd \(Self.cdArg(path)) && " + Self.prelude(envFile, exports)
        guard let argv, !argv.isEmpty else { return cd + "exec \"$SHELL\" -l" }
        // A local absolute path means nothing on the host, so the host finds the program by name.
        let words = [(argv[0] as NSString).lastPathComponent] + argv.dropFirst()
        return cd + "exec \"$SHELL\" -ilc " + ShellQuote.word(words.map(ShellQuote.word).joined(separator: " "))
    }

    /// Returns the sh path of the file on the host where a program's environment waits for the program to start
    /// (`prelude`). Only the user can read it (it is written with umask 077), and its name can't be guessed.
    public static func envFile(_ name: String) -> String { #""${TMPDIR:-/tmp}/kelp-env-\#(name)""# }

    /// Returns the sh that sets the program's environment. It sets `exports` first (Kelp's own variables, nothing
    /// secret), then the variables in the file `name` (`envFile`), and then removes that file. The file holds the
    /// agent's settings and secrets, which never go on the command line, where the host's `ps` would show them. A key
    /// that isn't a valid name, or a file name that isn't one, is left out.
    static func prelude(_ name: String?, _ exports: [String: String]) -> String {
        let set = exports.sorted { $0.key < $1.key }.filter { isName($0.key) }.map {
            "export \($0.key)=\(ShellQuote.word($0.value)); "
        }.joined()
        guard let name, name.wholeMatch(of: /[A-Za-z0-9-]+/) != nil else { return set }
        return set + "f=\(envFile(name)); " + #"[ -f "$f" ] && { . "$f"; rm -f "$f"; }; "#
    }

    /// Whether `key` is a valid environment variable name for sh.
    public static func isName(_ key: String) -> Bool { key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil }

    /// Returns the line that runs `argv` (as `command` does) inside the tmux session `name` on the host, or attaches to
    /// that session again while it still runs there. The session shows no status line, because its clock would read as
    /// output. The mouse wheel scrolls back through tmux's history. The program's title comes through, along with what
    /// agents report (`allow-passthrough`, set last, because a tmux before 3.3 has no such option and passes it
    /// anyway). A new connection starts with the status report it missed while no connection was there. Without tmux on
    /// the host, `argv` runs as it is.
    public func command(
        _ argv: [String], inTmux name: String, envFile: String? = nil, exports: [String: String] = [:]
    ) -> String {
        // An empty argv runs the host's login shell (a terminal kept in tmux, `terminal.tmux`).
        let words =
            argv.isEmpty
            ? "\"$SHELL\" -l"
            : ([(argv[0] as NSString).lastPathComponent] + argv.dropFirst()).map(ShellQuote.word).joined(separator: " ")
        // tmux runs a pane's command, given as one string, in a shell.
        let pane =
            Self.prelude(envFile, exports) + "exec "
            + (argv.isEmpty ? words : "\"$SHELL\" -ilc " + ShellQuote.word(words))
        // Use the pane title only once the program has set one. Until then tmux's title is the host's name, which would
        // end up as the tab's name.
        let options = [
            ["status", "off"], ["mouse", "on"], ["set-titles", "on"],
            ["set-titles-string", "#{?#{==:#{pane_title},#{host}},,#{pane_title}}"],
            ["allow-passthrough", "on"]
        ]
        // "=name:" targets exactly that session. An option's target is a pane, and "=name" alone isn't read as a
        // session there.
        let tmux =
            ["tmux", "new-session", "-A", "-s", name, pane]
            + options.flatMap { [";", "set-option", "-t", "=" + name + ":"] + $0 }
        let missed =
            "s=$(tmux show-options -qv -t \(ShellQuote.word("=" + name + ":")) \(Self.statusOption) 2>/dev/null); "
            + #"[ -z "$s" ] || printf '\033]7501;%s\007' "$s"; "#
        let cd = "cd \(Self.cdArg(path))"
        // When this attaches to a session that still runs, the environment file that waited for a start isn't needed,
        // so it is removed.
        let left =
            envFile.map {
                "tmux has-session -t \(ShellQuote.word("=" + name)) 2>/dev/null && rm -f \(Self.envFile($0)); "
            } ?? ""
        return cd + " && exec \"$SHELL\" -ilc "
            + ShellQuote.word(
                missed + left + "command -v tmux >/dev/null 2>&1 && exec "
                    + tmux.map(ShellQuote.word).joined(separator: " ")
                    + " || { " + Self.prelude(envFile, exports) + "exec " + words + "; }")
    }

    /// Returns the argument for `cd`: quoted, with a leading ~ left outside the quotes so the host's shell expands it.
    public static func cdArg(_ path: String) -> String {
        path == "~"
            ? "~" : path.hasPrefix("~/") ? "~/" + ShellQuote.word(String(path.dropFirst(2))) : ShellQuote.word(path)
    }

    /// Runs `script` in sh on the host, whatever the host's login shell is, and returns the bytes it wrote.
    @discardableResult
    public func run(_ script: String, stdin: Data? = nil, timeLimit: TimeInterval = 300) throws -> Data {
        try Subprocess.output(
            [ssh] + sshArgs(tty: false) + ["sh -c " + ShellQuote.word(script)], cwd: NSHomeDirectory(), stdin: stdin,
            timeLimit: timeLimit)
    }
}

/// The remote projects of one Kelp home. A `.kelp-remote` file counts only inside the home's `remote` folder. Anywhere
/// else (say, committed to a repository someone clones) it is just a file, and it must not send that project's git,
/// agents and terminals to a host it names. The sockets of the shared connections go in the home's `ssh` folder, whose
/// path is short because a Unix socket path has to fit in 104 bytes.
public struct Remotes: Sendable, Equatable {
    /// The folder that holds the local stand-ins for remote projects. nil means there are none, and every folder is on
    /// this Mac.
    public let folder: String?
    public let controlDir: String
    /// The `ssh` to run. Tests use a stand-in that runs the command locally.
    public let ssh: String

    public init(home: URL, ssh: String = ProcessInfo.processInfo.environment["KELP_SSH"] ?? "/usr/bin/ssh") {
        folder = home.appendingPathComponent("remote").standardizedFileURL.path
        controlDir = home.appendingPathComponent("ssh").path
        self.ssh = ssh
    }
    private init() {
        folder = nil
        controlDir = NSTemporaryDirectory()
        ssh = "/usr/bin/ssh"
    }
    /// No remote projects, so git and the rest run on this Mac whatever a folder holds.
    public static let none = Remotes()

    /// Returns `path` on `host`, reached through this home's shared connections.
    public func host(_ host: String, path: String) -> RemoteHost {
        var remote = RemoteHost(host: host, path: path)
        remote.controlDir = controlDir
        remote.ssh = ssh
        return remote
    }

    /// Returns the remote that a project folder stands for. Only the project's own folder counts, because a workspace
    /// is that folder.
    public func of(_ dir: String) -> RemoteHost? {
        let path = URL(fileURLWithPath: dir).standardizedFileURL.path
        guard let folder, path.hasPrefix(folder + "/"),
            let data = FileManager.default.contents(atPath: path + "/" + RemoteHost.marker),
            let remote = try? JSONDecoder().decode(RemoteHost.self, from: data), RemoteHost.isHost(remote.host)
        else { return nil }
        return host(remote.host, path: remote.path)
    }

    /// For a path inside a remote project's folder, returns the folder, its remote, and the path on the host.
    public func containing(_ path: String) -> (folder: String, remote: RemoteHost, remotePath: String)? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path   // So "x/../../y" can't leave the project.
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if let remote = of(dir) { return (dir, remote, remote.path + String(path.dropFirst(dir.count))) }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
