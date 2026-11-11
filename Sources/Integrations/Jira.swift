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
        let data = try await request("GET", "/rest/api/3/myself")
        guard let name = try JSONDecoder().decode(JSONValue.self, from: data)["displayName"]?.string else {
            throw IntegrationError(description: "unexpected /myself response")
        }
        return name
    }

    public func search(jql: String = JiraClient.myOpenJQL, max: Int = 100) async throws -> [JiraIssue] {
        var components = URLComponents()
        components.queryItems = [
            .init(name: "jql", value: jql), .init(name: "maxResults", value: "\(max)"),
            .init(name: "fields", value: "summary,status,description,issuetype,project")
        ]
        return try Self.parseSearch(
            await request("GET", "/rest/api/3/search/jql?" + (components.percentEncodedQuery ?? "")), site: site)
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
        if let target = ts.first(where: { $0.name.lowercased().contains(hint) })
            ?? ts.first(where: { $0.toCategory == category })
        {
            try await transition(key: key, id: target.id)
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

    static func parseSearch(_ data: Data, site: String) throws -> [JiraIssue] {
        guard let issues = try JSONDecoder().decode(JSONValue.self, from: data)["issues"]?.array else {
            throw IntegrationError(description: "unexpected search response")
        }
        return issues.compactMap { issue in
            guard let key = issue["key"]?.string, let fields = issue["fields"], case .object = fields else {
                return nil
            }
            let st = fields["status"]
            return JiraIssue(
                key: key, title: fields["summary"]?.string ?? "", description: adfText(fields["description"]),
                url: site.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/browse/" + key,
                status: st?["name"]?.string ?? "", statusCategory: st?["statusCategory"]?["key"]?.string ?? "",
                type: fields["issuetype"]?["name"]?.string ?? "", project: fields["project"]?["key"]?.string ?? "")
        }
    }

    static func parseTransitions(_ data: Data) throws -> [JiraTransition] {
        guard let ts = try JSONDecoder().decode(JSONValue.self, from: data)["transitions"]?.array else {
            throw IntegrationError(description: "unexpected transitions response")
        }
        return ts.compactMap { transition in
            guard let id = transition["id"]?.string, let name = transition["name"]?.string else { return nil }
            return JiraTransition(
                id: id, name: name, toCategory: transition["to"]?["statusCategory"]?["key"]?.string ?? "")
        }
    }

    /// Atlassian Document Format → plain text (paragraph breaks kept); plain strings pass through (API v2).
    static func adfText(_ value: JSONValue?) -> String {
        guard let node = value else { return "" }
        if let text = node.string ?? node["text"]?.string { return text }
        let kids = (node["content"]?.array ?? []).map(adfText)
        switch node["type"]?.string {
        case "paragraph", "heading", "codeBlock", "blockquote": return kids.joined() + "\n"
        case "listItem": return "- " + kids.joined()
        case "hardBreak": return "\n"
        default: return kids.joined()
        }
    }
}
