import Core
import Foundation

/// Where a repository lives, by its origin's host: whose links, pull requests, issues and CI it has.
public enum Forge: String, Sendable {
    case github, gitlab, bitbucket

    /// By the host's own labels: gitlab.com and gitlab.example.com are GitLab, bitbucket.org Bitbucket; anything else
    /// is GitHub (github.com, a GitHub Enterprise host). A path (github.com/someone/gitlab-ci-local) or a host like
    /// mygitlab.example.com doesn't count.
    public static func of(remote: String) -> Forge {
        guard let host = Git.webRepo(remote)?.0.lowercased() else { return .github }
        let labels = host.split(separator: ".")
        if labels.contains(where: { $0.hasPrefix("gitlab") }) { return .gitlab }
        if labels.contains(where: { $0.hasPrefix("bitbucket") }) { return .bitbucket }
        return .github
    }
}

/// Links to a file on the repository's website (GitHub, GitLab, Bitbucket) at the commit checked out now.
extension Git {
    /// The address of the checkout's `origin` remote.
    public static func origin(_ cwd: String, remotes: Remotes) throws -> String {
        try line(["remote", "get-url", "origin"], cwd: cwd, remotes: remotes)
    }

    /// `path` absolute; `lines` 1-based. Fails when origin isn't on a website Kelp knows how to link to.
    /// A remote project's file: git runs in the project's folder (on its host), the file named from its top there.
    public static func webURL(path: String, lines: ClosedRange<Int>?, remotes: Remotes) throws -> String {
        let onHost = remotes.containing(path)
        let dir = onHost?.folder ?? (path as NSString).deletingLastPathComponent
        let remote = try origin(dir, remotes: remotes)
        let sha = try line(["rev-parse", "HEAD"], cwd: dir, remotes: remotes)
        let file: String
        if let onHost {
            file = String(onHost.remotePath.dropFirst(onHost.remote.path.count).drop { $0 == "/" })
        } else {
            let top = try line(["rev-parse", "--show-toplevel"], cwd: dir, remotes: remotes)
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                root = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
            file =
                real.hasPrefix(root + "/")
                ? String(real.dropFirst(root.count + 1)) : (path as NSString).lastPathComponent
        }
        guard let url = webURL(remote: remote, sha: sha, file: file, lines: lines) else {
            throw GitError.refused("Origin (\(remote)) isn't a GitHub, GitLab or Bitbucket address")
        }
        return url
    }

    static func webURL(remote: String, sha: String, file: String, lines: ClosedRange<Int>?) -> String? {
        guard let (host, repo) = webRepo(remote) else { return nil }
        let encoded = file.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let base = "https://\(host)/\(repo)"
        switch Forge.of(remote: remote) {
        case .gitlab:
            return "\(base)/-/blob/\(sha)/\(encoded)"
                + (lines.map { $0.count == 1 ? "#L\($0.lowerBound)" : "#L\($0.lowerBound)-\($0.upperBound)" } ?? "")
        case .bitbucket:
            return "\(base)/src/\(sha)/\(encoded)"
                + (lines.map { $0.count == 1 ? "#lines-\($0.lowerBound)" : "#lines-\($0.lowerBound):\($0.upperBound)" }
                    ?? "")
        case .github:
            return "\(base)/blob/\(sha)/\(encoded)"
                + (lines.map { $0.count == 1 ? "#L\($0.lowerBound)" : "#L\($0.lowerBound)-L\($0.upperBound)" } ?? "")
        }
    }

    /// The repository's home, CI, pull/merge requests and issues on its site.
    public static func webPages(remote: String) -> GitWebPages.Pages? {
        guard let (host, repo) = webRepo(remote) else { return nil }
        let base = "https://\(host)/\(repo)", forge = Forge.of(remote: remote)
        switch forge {
        case .gitlab:
            return .init(
                forge: forge.rawValue, repo: base, ci: base + "/-/pipelines", pulls: base + "/-/merge_requests",
                issues: base + "/-/issues")
        case .bitbucket:
            return .init(
                forge: forge.rawValue, repo: base, ci: base + "/pipelines", pulls: base + "/pull-requests",
                issues: base + "/issues")
        case .github:
            return .init(
                forge: forge.rawValue, repo: base, ci: base + "/actions", pulls: base + "/pulls",
                issues: base + "/issues")
        }
    }

    /// `git@github.com:o/r.git`, `ssh://git@host:22/o/r`, `https://user@host/o/r.git` → (host, "o/r").
    public static func webRepo(_ remote: String) -> (String, String)? {
        var address = remote
        var hasScheme = false   // only `ssh://host:22/…` has a port; in `git@host:123/repo` the 123 is the owner
        if let scheme = address.range(of: "://") {
            address = String(address[scheme.upperBound...])
            hasScheme = true
        }
        if let at = address.firstIndex(of: "@"), address[..<at].contains("/") == false {
            address = String(address[address.index(after: at)...])
        }
        guard let sep = address.firstIndex(where: { $0 == "/" || $0 == ":" }) else { return nil }
        let host = String(address[..<sep])
        var path = String(address[address.index(after: sep)...])
        if hasScheme, address[sep] == ":", let first = path.split(separator: "/").first, Int(first) != nil {
            path = path.split(separator: "/").dropFirst().joined(separator: "/")
        }   // ssh port
        if path.hasSuffix(".git") { path.removeLast(4) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, path.contains("/") else { return nil }
        return (host, path)
    }
}
