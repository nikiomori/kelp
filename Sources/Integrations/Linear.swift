import Core
import Foundation

/// Linear's GraphQL API (its values, `LinearIssue`…, are Core's).
public struct LinearClient: Sendable {
    public enum StateKind: Sendable { case inProgress, inReview, done }

    public var apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }

    static let issueFields =
        "id identifier title description url branchName state { id name type } team { id key name }"
    static let openFilter = #"filter: { state: { type: { nin: ["completed", "canceled"] } } }, orderBy: updatedAt"#

    public func viewer() async throws -> LinearUser {
        try Self.parse(LinearUser.self, from: await request("{ viewer { id name email } }"), at: "viewer")
    }

    /// Open issues assigned to the API key's user.
    public func myIssues() async throws -> [LinearIssue] {
        let query = "{ viewer { assignedIssues(first: 100, \(Self.openFilter)) { nodes { \(Self.issueFields) } } } }"
        return try Self.parse([LinearIssue].self, from: await request(query), at: "viewer", "assignedIssues", "nodes")
    }

    public func teamIssues(teamId: String) async throws -> [LinearIssue] {
        let query =
            "query($id: String!) { team(id: $id) { issues(first: 100, \(Self.openFilter)) { nodes { \(Self.issueFields) } } } }"
        return try Self.parse(
            [LinearIssue].self, from: await request(query, ["id": .string(teamId)]), at: "team", "issues", "nodes")
    }

    public func teams() async throws -> [LinearTeam] {
        try Self.parse(
            [LinearTeam].self, from: await request("{ teams { nodes { id key name } } }"), at: "teams", "nodes")
    }

    public func workflowStates(teamId: String) async throws -> [LinearState] {
        let query = "query($id: String!) { team(id: $id) { states { nodes { id name type } } } }"
        return try Self.parse(
            [LinearState].self, from: await request(query, ["id": .string(teamId)]), at: "team", "states", "nodes")
    }

    public func setState(issueId: String, stateId: String) async throws {
        let query = "mutation($id: String!, $s: String!) { issueUpdate(id: $id, input: { stateId: $s }) { success } }"
        let ok = try Self.parse(
            Bool.self, from: await request(query, ["id": .string(issueId), "s": .string(stateId)]), at: "issueUpdate",
            "success")
        if !ok { throw IntegrationError(description: "Linear issueUpdate returned success=false") }
    }

    func request(_ query: String, _ variables: [String: JSONValue] = [:]) async throws -> Data {
        guard let url = URL(string: "https://api.linear.app/graphql") else {
            throw IntegrationError(description: "bad Linear URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONValue.object(["query": .string(query), "variables": .object(variables)]))
        let (data, resp) = try await URLSession.shared.data(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // GraphQL errors come back as 400 with an `errors` body; let parse() report those.
        if code != 200, (try? JSONDecoder().decode(JSONValue.self, from: data))?["errors"] == nil {
            throw IntegrationError(description: "Linear HTTP \(code)")
        }
        return data
    }

    /// Decode `data.<path...>` from a GraphQL response, throwing on `errors`.
    public static func parse<T: Decodable>(_: T.Type, from data: Data, at path: String...) throws -> T {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        if let errs = root["errors"]?.array, !errs.isEmpty {
            throw IntegrationError(
                description: "Linear: " + errs.map { $0["message"]?.string ?? "error" }.joined(separator: "; "))
        }
        guard let value = path.reduce(root["data"], { $0?[$1] }), value != .null else {
            throw IntegrationError(description: "Linear: missing data." + path.joined(separator: "."))
        }
        return try value.decode(T.self)
    }

    /// Pick the team state to move an issue to. inReview is nil when the team has no review-like state.
    public static func stateFor(kind: StateKind, in states: [LinearState]) -> LinearState? {
        let isReview = { (state: LinearState) in state.name.lowercased().contains("review") }
        switch kind {
        case .inReview:
            return states.first(where: isReview)
        case .inProgress:
            let started = states.filter { $0.type == "started" && !isReview($0) }
            return started.first { $0.name.lowercased() == "in progress" } ?? started.first
        case .done:
            let done = states.filter { $0.type == "completed" }
            return done.first { $0.name.lowercased() == "done" } ?? done.first
        }
    }
}
