import Core
import Foundation

/// Jira Cloud REST v3 with an API token (Basic auth email:token), stored by the caller in the keychain. Its values
/// (`JiraIssue`, `JiraTransition`) are Core's.
public struct JiraClient: Sendable {
    public var site: String, email: String, token: String
    public init(site: String, email: String, token: String) {
        self.site = site.hasPrefix("http") ? site : "https://" + site
        self.email = email
        self.token = token
    }

    public static let myOpenJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"

    public func myself() async throws -> String {
        let d = try await request("GET", "/rest/api/3/myself")
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
            let n = o["displayName"] as? String
        else { throw IntegrationError(description: "unexpected /myself response") }
        return n
    }

    public func search(jql: String = JiraClient.myOpenJQL, max: Int = 100) async throws -> [JiraIssue] {
        var c = URLComponents()
        c.queryItems = [
            .init(name: "jql", value: jql), .init(name: "maxResults", value: "\(max)"),
            .init(name: "fields", value: "summary,status,description,issuetype,project")
        ]
        return try Self.parseSearch(
            await request("GET", "/rest/api/3/search/jql?" + (c.percentEncodedQuery ?? "")), site: site)
    }

    public func transitions(key: String) async throws -> [JiraTransition] {
        try Self.parseTransitions(await request("GET", "/rest/api/3/issue/\(key)/transitions"))
    }

    public func transition(key: String, id: String) async throws {
        _ = try await request("POST", "/rest/api/3/issue/\(key)/transitions", body: ["transition": ["id": id]])
    }

    /// Best-effort move: the first transition whose target matches the name hint, else the category.
    public func move(key: String, toName hint: String, category: String) async throws {
        let ts = try await transitions(key: key)
        if let t = ts.first(where: { $0.name.lowercased().contains(hint) })
            ?? ts.first(where: { $0.toCategory == category })
        {
            try await transition(key: key, id: t.id)
        }
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: site + path) else { throw IntegrationError(description: "bad Jira site URL") }
        // The request carries the email and API token: never over plain http.
        guard url.scheme?.lowercased() == "https" else {
            throw IntegrationError(description: "Jira needs an https:// address")
        }
        return try await basicAuthRequest("Jira", method, url, login: "\(email):\(token)", body: body)
    }

    // MARK: parsing

    public static func parseSearch(_ d: Data, site: String) throws -> [JiraIssue] {
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
            let issues = o["issues"] as? [[String: Any]]
        else {
            throw IntegrationError(description: "unexpected search response")
        }
        return issues.compactMap { i in
            guard let key = i["key"] as? String, let f = i["fields"] as? [String: Any] else { return nil }
            let st = f["status"] as? [String: Any]
            return JiraIssue(
                key: key, title: f["summary"] as? String ?? "", description: adfText(f["description"]),
                url: site.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/browse/" + key,
                status: st?["name"] as? String ?? "",
                statusCategory: (st?["statusCategory"] as? [String: Any])?["key"] as? String ?? "",
                type: (f["issuetype"] as? [String: Any])?["name"] as? String ?? "",
                project: (f["project"] as? [String: Any])?["key"] as? String ?? "")
        }
    }

    public static func parseTransitions(_ d: Data) throws -> [JiraTransition] {
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
            let ts = o["transitions"] as? [[String: Any]]
        else {
            throw IntegrationError(description: "unexpected transitions response")
        }
        return ts.compactMap { t in
            guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
            return JiraTransition(
                id: id, name: name,
                toCategory: (((t["to"] as? [String: Any])?["statusCategory"]) as? [String: Any])?["key"] as? String
                    ?? "")
        }
    }

    /// Atlassian Document Format → plain text (paragraph breaks kept); plain strings pass through (API v2).
    public static func adfText(_ v: Any?) -> String {
        if let s = v as? String { return s }
        guard let n = v as? [String: Any] else { return "" }
        if let t = n["text"] as? String { return t }
        let kids = (n["content"] as? [Any] ?? []).map(adfText)
        switch n["type"] as? String {
        case "paragraph", "heading", "codeBlock", "blockquote": return kids.joined() + "\n"
        case "listItem": return "- " + kids.joined()
        case "hardBreak": return "\n"
        default: return kids.joined()
        }
    }
}
