import Core
import Foundation

/// Links to a file on the repository's website (GitHub, GitLab, Bitbucket) at the commit checked out now.
extension Git {
    /// `path` absolute; `lines` 1-based. Fails when origin isn't on a website Kelp knows how to link to.
    public static func webURL(path: String, lines: ClosedRange<Int>?, remotes: Remotes = .none) throws -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let top = try run(["rev-parse", "--show-toplevel"], cwd: dir, remotes: remotes).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let remote = try run(["remote", "get-url", "origin"], cwd: dir, remotes: remotes).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let sha = try run(["rev-parse", "HEAD"], cwd: dir, remotes: remotes).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
            root = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
        let file =
            real.hasPrefix(root + "/") ? String(real.dropFirst(root.count + 1)) : (path as NSString).lastPathComponent
        guard let url = webURL(remote: remote, sha: sha, file: file, lines: lines) else {
            throw GitError(
                args: ["remote", "get-url", "origin"], status: 1,
                stderr: "origin (\(remote)) isn't a GitHub, GitLab or Bitbucket address")
        }
        return url
    }

    static func webURL(remote: String, sha: String, file: String, lines: ClosedRange<Int>?) -> String? {
        guard let (host, repo) = webRepo(remote) else { return nil }
        let encoded = file.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let base = "https://\(host)/\(repo)"
        if host.contains("gitlab") {
            return "\(base)/-/blob/\(sha)/\(encoded)"
                + (lines.map { $0.count == 1 ? "#L\($0.lowerBound)" : "#L\($0.lowerBound)-\($0.upperBound)" } ?? "")
        }
        if host.contains("bitbucket") {
            return "\(base)/src/\(sha)/\(encoded)"
                + (lines.map { $0.count == 1 ? "#lines-\($0.lowerBound)" : "#lines-\($0.lowerBound):\($0.upperBound)" }
                    ?? "")
        }
        return "\(base)/blob/\(sha)/\(encoded)"
            + (lines.map { $0.count == 1 ? "#L\($0.lowerBound)" : "#L\($0.lowerBound)-L\($0.upperBound)" } ?? "")
    }

    /// The repository's home, CI, pull/merge requests and issues on its site.
    public static func webPages(remote: String) -> GitWebPages.Pages? {
        guard let (host, repo) = webRepo(remote) else { return nil }
        let base = "https://\(host)/\(repo)"
        if host.contains("gitlab") {
            return .init(
                forge: "gitlab", repo: base, ci: base + "/-/pipelines", pulls: base + "/-/merge_requests",
                issues: base + "/-/issues")
        }
        if host.contains("bitbucket") {
            return .init(
                forge: "bitbucket", repo: base, ci: base + "/pipelines", pulls: base + "/pull-requests",
                issues: base + "/issues")
        }
        return .init(
            forge: "github", repo: base, ci: base + "/actions", pulls: base + "/pulls", issues: base + "/issues")
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
