import Core
import Foundation

/// Kelp's background fetch (Settings › Source Control): the fetch that Fetch runs, made where nobody watches.
extension Git {
    /// The longest a background fetch may take. A fetch that works takes seconds; one held by a network that drops
    /// packets would otherwise hold a thread for the five minutes any git run gets.
    static let quietTimeLimit: TimeInterval = 30

    /// Fetches what Fetch fetches (`remote(.fetch)`), without asking: no password prompt (`gitEnv`), no key passphrase
    /// or unknown host key prompt from ssh (BatchMode), and no sign-in window from a credential manager. A fetch that
    /// fails is the answer, not an error. It still rewrites FETCH_HEAD, so its time is put back: the popover's
    /// "fetched … ago" stays the last fetch that worked.
    public static func fetchQuietly(_ path: String, remotes: Remotes) throws -> QuietFetch {
        let before = try lastFetch(path, remotes: remotes), started = Date()
        do {
            try runData(
                ["fetch", "--all", "--prune"], cwd: path, env: try quietEnv(path, remotes: remotes),
                timeLimit: quietTimeLimit, remotes: remotes)
        } catch let error as GitError {
            if let before {
                let back: [FileAttributeKey: Any] = [.modificationDate: Date(timeIntervalSince1970: before)]
                try FileManager.default.setAttributes(back, ofItemAtPath: try fetchHead(path, remotes: remotes))
            }
            // A fetch stopped at its time limit waited on a network that didn't answer.
            let said = error.stderr ?? error.description
            let late = Date().timeIntervalSince(started) >= quietTimeLimit
            return QuietFetch(ran: true, trouble: late ? .offline : trouble(said), host: host(said), fetched: before)
        }
        return QuietFetch(ran: true, fetched: try lastFetch(path, remotes: remotes))
    }

    /// The environment that keeps a fetch from asking: ssh in batch mode, after the repository's own ssh command
    /// (core.sshCommand), and a credential manager that never opens a window.
    static func quietEnv(_ path: String, remotes: Remotes) throws -> [String: String] {
        let ssh = try line(["config", "--get", "core.sshCommand"], cwd: path, ok: [0, 1], remotes: remotes)
        return ["GIT_SSH_COMMAND": (ssh.isEmpty ? "ssh" : ssh) + " -o BatchMode=yes", "GCM_INTERACTIVE": "never"]
            .merging(configEnv([("credential.interactive", "never")], after: ProcessInfo.processInfo.environment)) {
                $1
            }
    }

    /// Reads why a fetch failed from what git said. Words that mean no network come first, because a host that can't
    /// be reached can't ask for a sign-in either.
    static func trouble(_ said: String) -> QuietFetch.Trouble {
        let offline = [
            "Could not resolve host", "Network is unreachable", "No route to host", "timed out", "Connection refused",
            "Failed to connect", "Couldn't connect to server", "Temporary failure in name resolution", "Can't reach "
        ]
        let signIn = [
            "Authentication failed", "Permission denied (publickey", "could not read Username",
            "could not read Password", "terminal prompts disabled", "Host key verification failed",
            "Invalid username or password", "HTTP Basic: Access denied", "The requested URL returned error: 401",
            "The requested URL returned error: 403"
        ]
        if offline.contains(where: said.localizedCaseInsensitiveContains) { return .offline }
        if signIn.contains(where: said.localizedCaseInsensitiveContains) { return .signIn }
        return .other
    }

    /// Returns the host git named in its error: an address's (https://github.com/…), ssh's ("Could not resolve hostname
    /// github.com", "git@github.com: Permission denied"), or Kelp's own for a remote project's host.
    static func host(_ said: String) -> String? {
        let patterns = [
            #/https?://(?:[^@/\s']+@)?([A-Za-z0-9][A-Za-z0-9.-]*)/#,
            #/resolve host(?:name)?:? ([A-Za-z0-9][A-Za-z0-9.-]*)/#, #/connect to host ([A-Za-z0-9][A-Za-z0-9.-]*)/#,
            #/@([A-Za-z0-9][A-Za-z0-9.-]*): Permission denied/#, #/Can't reach ([A-Za-z0-9][A-Za-z0-9.-]*)/#
        ]
        return patterns.lazy.compactMap { said.firstMatch(of: $0).map { String($0.output.1) } }.first
    }

    /// Returns FETCH_HEAD's path, which git writes on every fetch and pull.
    static func fetchHead(_ path: String, remotes: Remotes) throws -> String {
        try line(["rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD"], cwd: path, remotes: remotes)
    }
}
