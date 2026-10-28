import Foundation

/// A project on another machine, over SSH. Kelp keeps a local folder for it that holds only `.kelp-remote`
/// (`{"host", "path"}`); git in that folder runs on the host instead (so the git and file panels work as they are),
/// and so do its agents and terminals. All of it shares one SSH connection per host (ControlMaster), kept for ten
/// minutes after the last use; a dropped connection ends the sessions, and Restart connects again.
public struct RemoteHost: Codable, Sendable, Equatable {
    public var host: String, path: String
    /// Where the shared connections' sockets live, and the `ssh` that makes them: its home's (`Remotes`).
    public var controlDir = NSTemporaryDirectory(), ssh = "/usr/bin/ssh"
    public init(host: String, path: String) { self.host = host; self.path = path }
    private enum CodingKeys: String, CodingKey { case host, path }

    public static let marker = ".kelp-remote"

    /// What may follow `ssh`: not an option, nothing a shell would split.
    /// Also a folder name under remote/: "." / ".." or a "/" would put it somewhere else.
    public static func isHost(_ h: String) -> Bool {
        !h.isEmpty && !h.hasPrefix("-") && !h.contains(where: \.isWhitespace) && !h.contains("/") && h != "." && h != ".."
    }

    /// ssh's options for this host: the shared connection; no password prompts where nobody can answer them.
    public func sshArgs(tty: Bool) -> [String] {
        (tty ? ["-tt"] : ["-T", "-o", "BatchMode=yes"])
            + ["-o", "ConnectTimeout=15", "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlDir)/%C", "-o", "ControlPersist=600", "-o", "ServerAliveInterval=30", "--", host]
    }

    /// What the host's shell runs: `argv` in the project's folder, through an interactive login shell so the host's PATH
    /// applies (interactive too: nvm and npm's global bin go in .bashrc, which `bash -lc` skips);
    /// nil argv is an interactive login shell.
    public func command(_ argv: [String]?) -> String {
        let cd = "cd \(Self.cdArg(path))"
        guard let argv, !argv.isEmpty else { return cd + " && exec \"$SHELL\" -l" }
        // A local absolute path means nothing there: the host finds the program by name.
        let words = [(argv[0] as NSString).lastPathComponent] + argv.dropFirst()
        return cd + " && exec \"$SHELL\" -ilc " + Self.quote(words.map(Self.quote).joined(separator: " "))
    }

    /// `argv` as `command` runs it, inside tmux session `name` on the host, or attached to that session again while it still
    /// runs there. The session shows no status line (its clock would read as output), the mouse wheel scrolls back through
    /// tmux's history, and the program's title comes through. Without tmux on the host, `argv` runs as it is.
    public func command(_ argv: [String], inTmux name: String) -> String {
        guard !argv.isEmpty else { return command(nil) }
        let words = ([(argv[0] as NSString).lastPathComponent] + argv.dropFirst()).map(Self.quote).joined(separator: " ")
        let pane = "exec \"$SHELL\" -ilc " + Self.quote(words)   // tmux runs a pane's one-string command in a shell
        // The title only once the program set one: until then tmux's is the host's name, which would name the tab.
        let options = [["status", "off"], ["mouse", "on"], ["set-titles", "on"], ["set-titles-string", "#{?#{==:#{pane_title},#{host}},,#{pane_title}}"]]
        // "=name:": exactly that session (an option's target is a pane, and "=name" alone isn't read as a session there).
        let tmux = ["tmux", "new-session", "-A", "-s", name, pane] + options.flatMap { [";", "set-option", "-t", "=" + name + ":"] + $0 }
        let cd = "cd \(Self.cdArg(path))"
        return cd + " && exec \"$SHELL\" -ilc "
            + Self.quote("command -v tmux >/dev/null 2>&1 && exec " + tmux.map(Self.quote).joined(separator: " ") + " || exec " + words)
    }

    /// A server on the host at `url` (its localhost) reached from this Mac over the shared connection: the same port here
    /// when it's free, else the next free one of ten → the URL to open here, and the forwarding (`cancel` takes it).
    /// Nothing forwarded (no shared connection, every port taken): the URL as it was, and nil.
    public func forward(_ url: String) -> (url: String, spec: String?) {
        guard var u = URLComponents(string: url), let port = u.port else { return (url, nil) }
        let target = u.host == "127.0.0.1" ? "127.0.0.1" : "localhost"
        for here in port..<port + 10 {
            let spec = "\(here):\(target):\(port)"
            guard control("forward", spec) else { continue }
            u.host = "localhost"; u.port = here
            return (u.string ?? url, spec)
        }
        return (url, nil)
    }
    public func cancel(_ spec: String) { _ = control("cancel", spec) }

    /// `ssh -O`: asks the shared connection's master, which adds or drops a forwarding without a new login.
    private func control(_ op: String, _ spec: String) -> Bool {
        let argv = [ssh, "-o", "ControlPath=\(controlDir)/%C", "-O", op, "-L", spec, "--", host]
        return (try? Subprocess.run(argv, cwd: NSHomeDirectory(), env: ProcessInfo.processInfo.environment, timeLimit: 10))?.status == 0
    }

    /// `cd`'s argument: quoted, with a leading ~ left outside the quotes so the host's shell expands it.
    public static func cdArg(_ path: String) -> String {
        path == "~" ? "~" : path.hasPrefix("~/") ? "~/" + quote(String(path.dropFirst(2))) : quote(path)
    }

    /// One shell word, single-quoted.
    public static func quote(_ s: String) -> String { IDE.shellWord(s) }
}

/// The remote projects of one Kelp home. A `.kelp-remote` counts only in its `remote` folder: one anywhere else (say,
/// committed to a repository someone clones) is just a file, and must not send that project's git, agents and terminals
/// to a host it names. Their shared connections' sockets go in its `ssh` folder (short: a Unix socket path has to fit
/// in 104 bytes).
public struct Remotes: Sendable, Equatable {
    /// The folder remote projects' local stand-ins are in; nil: none (every folder is on this Mac).
    public let folder: String?
    public let controlDir: String
    /// `ssh` (tests use a stand-in that runs the command locally).
    public let ssh: String

    public init(home: URL, ssh: String = ProcessInfo.processInfo.environment["KELP_SSH"] ?? "/usr/bin/ssh") {
        folder = home.appendingPathComponent("remote").standardizedFileURL.path
        controlDir = home.appendingPathComponent("ssh").path
        self.ssh = ssh
    }
    private init() { folder = nil; controlDir = NSTemporaryDirectory(); ssh = "/usr/bin/ssh" }
    /// No remote projects: git and the rest run here, whatever a folder holds.
    public static let none = Remotes()

    /// `path` on `host`, reached through this home's shared connections.
    public func host(_ host: String, path: String) -> RemoteHost {
        var r = RemoteHost(host: host, path: path)
        r.controlDir = controlDir; r.ssh = ssh
        return r
    }

    /// The remote a project folder stands for (its own folder only: a workspace is that folder).
    public func of(_ dir: String) -> RemoteHost? {
        let path = URL(fileURLWithPath: dir).standardizedFileURL.path
        guard let folder, path.hasPrefix(folder + "/"), let d = FileManager.default.contents(atPath: path + "/" + RemoteHost.marker),
              let r = try? JSONDecoder().decode(RemoteHost.self, from: d), RemoteHost.isHost(r.host) else { return nil }
        return host(r.host, path: r.path)
    }

    /// For a path inside a remote project's folder: the folder, its remote, and the path on the host.
    public func containing(_ path: String) -> (folder: String, remote: RemoteHost, remotePath: String)? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path   // "x/../../y" can't reach past the project
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if let r = of(dir) { return (dir, r, r.path + String(path.dropFirst(dir.count))) }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
