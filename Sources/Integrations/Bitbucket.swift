import Core
import Foundation
import GitKit

/// Bitbucket Cloud pull requests (REST 2.0, Basic auth user:token). Shapes map onto `GitHub.PullRequest` so the UI is shared.
public struct BitbucketClient: Sendable {
    public var user: String, token: String
    public init(user: String, token: String) {
        self.user = user
        self.token = token
    }

    /// "git@bitbucket.org:team/repo.git" / "https://bitbucket.org/team/repo" → ("team", "repo")
    /// Only when bitbucket.org is the remote's host: "https://example.com/bitbucket.org/x" or a fork named so isn't one.
    public static func slug(remote: String) -> (workspace: String, repo: String)? {
        guard let (host, path) = Git.webRepo(remote), host.lowercased() == "bitbucket.org" else { return nil }
        let parts = path.split(separator: "/")
        return parts.count >= 2 ? (String(parts[0]), String(parts[1])) : nil
    }

    public static func slug(cwd: String) -> (workspace: String, repo: String)? {
        (try? Git.origin(cwd)).flatMap { slug(remote: $0) }
    }

    public func pullRequests(workspace: String, repo: String) async throws -> [GitHub.PullRequest] {
        try Self.parsePullRequests(
            await request("GET", "/repositories/\(workspace)/\(repo)/pullrequests?state=OPEN&pagelen=50"))
    }

    // swiftlint:disable:next function_parameter_count
    public func createPR(
        workspace: String, repo: String, title: String, body: String, source: String, destination: String
    ) async throws -> String {
        let data = try await request(
            "POST", "/repositories/\(workspace)/\(repo)/pullrequests",
            body: [
                "title": title, "description": body,
                "source": ["branch": ["name": source]], "destination": ["branch": ["name": destination]]
            ])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let html = ((object["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String
        else { throw IntegrationError(description: "unexpected create response") }
        return html
    }

    public func merge(workspace: String, repo: String, id: Int) async throws {
        _ = try await request(
            "POST", "/repositories/\(workspace)/\(repo)/pullrequests/\(id)/merge", body: ["merge_strategy": "squash"])
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "https://api.bitbucket.org/2.0" + path) else {
            throw IntegrationError(description: "bad URL")
        }
        return try await basicAuthRequest("Bitbucket", method, url, login: "\(user):\(token)", body: body)
    }

    public static func parsePullRequests(_ data: Data) throws -> [GitHub.PullRequest] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let vals = object["values"] as? [[String: Any]]
        else {
            throw IntegrationError(description: "unexpected pullrequests response")
        }
        return vals.compactMap { pr in
            guard let id = pr["id"] as? Int else { return nil }
            let html = ((pr["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String ?? ""
            let branch = ((pr["source"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String ?? ""
            return GitHub.PullRequest(
                number: id, title: pr["title"] as? String ?? "", url: html,
                author: (pr["author"] as? [String: Any])?["display_name"] as? String ?? "", headRefName: branch,
                isDraft: pr["draft"] as? Bool ?? false, state: pr["state"] as? String ?? "OPEN", reviewDecision: nil,
                checks: .init())
        }
    }
}
