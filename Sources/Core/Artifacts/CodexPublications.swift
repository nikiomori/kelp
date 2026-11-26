import Foundation

extension Artifacts {
    package enum CodexPublication: String {
        case doc, slides, visualization, site

        var artifactType: String {
            switch self {
            case .site: "page"
            case .visualization: "doc"
            case .doc, .slides: rawValue
            }
        }
    }

    /// The canonical MCP names used by Codex's hooks. A deployment may finish in its status poll.
    package static let codexPublishers: [String: CodexPublication] = [
        "mcp__codex_apps__chatgpt_space_create_page": .doc,
        "mcp__codex_apps__chatgpt_space_create_presentation": .slides,
        "mcp__codex_apps__chatgpt_space_create_page_visualization": .visualization,
        "mcp__codex_apps__sites_deploy_site_version": .site,
        "mcp__codex_apps__sites_deploy_private_site_version": .site,
        "mcp__codex_apps__sites_save_version_and_deploy_private": .site,
        "mcp__codex_apps__sites_get_deployment_status": .site
    ]

    static func codexPublication(_ kind: CodexPublication, input: JSONValue?, response: JSONValue)
        -> (url: String, title: String, type: String, page: PublishedPage?)?
    {
        let response = codexToolJSON(response)
        guard response["isError"]?.bool != true, response["is_error"]?.bool != true else { return nil }
        let result =
            response["structuredContent"].flatMap { $0 == .null ? nil : $0 }
            ?? (response["content"]?.array ?? response.array)?.lazy.compactMap { item -> JSONValue? in
                guard let text = item["text"], case .object(let fields) = codexToolJSON(text) else { return nil }
                return .object(fields)
            }.first ?? response
        guard (result["error"] ?? .null) == .null else { return nil }

        if kind == .site {
            guard result["status"]?.string == "succeeded", let url = result["url"]?.string, httpsURL(url) != nil
            else { return nil }
            return (url, result["title"]?.string ?? url, kind.artifactType, nil)
        }

        // The Space connector can return a Page ID in place of its URL, including for native slides.
        let page = result["content"], metadata = result["metadata"]
        let hasVisualization = (result["visualization"] ?? .null) != .null
        let visualizationID = kind == .visualization && hasVisualization ? input?["page_id"]?.string : nil
        let id =
            metadata?["page_id"]?.string ?? page?["page_id"]?.string ?? result["page_id"]?.string ?? visualizationID
        let href = metadata?["url"]?.string ?? page?["url"]?.string ?? result["url"]?.string
        let url =
            href.flatMap { href -> String? in
                guard let parts = httpsURL(href), parts.host == "chatgpt.com",
                    parts.path.wholeMatch(of: /\/space\/[A-Za-z0-9_-]+/) != nil
                else { return nil }
                return "https://chatgpt.com" + parts.path
            } ?? id.flatMap { $0.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil ? "https://chatgpt.com/space/" + $0 : nil }
        guard let url else { return nil }
        // The embed's title is separate from the parent Page's title.
        let createdTitle = kind == .visualization ? nil : result["title"]?.string ?? input?["title"]?.string
        let title = metadata?["title"]?.string ?? page?["title"]?.string ?? createdTitle ?? url
        return (url, title, kind.artifactType, nil)
    }

    /// Tool output can be JSON in an MCP text block or a JSON string in a Codex rollout.
    package static func codexToolJSON(_ value: JSONValue) -> JSONValue {
        guard var text = value.string else { return value }
        if text.hasPrefix("Wall time: "),
            let output = text.range(of: "\n Output:\n") ?? text.range(of: "\nOutput:\n")
        {
            text = String(text[output.upperBound...])
        }
        do { return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) } catch { return value }
    }

    private static func httpsURL(_ url: String) -> URLComponents? {
        guard let parts = URLComponents(string: url), parts.scheme == "https", let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil
        else { return nil }
        return parts
    }
}
