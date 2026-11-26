import Core
import Foundation

extension Artifacts {
    /// Codex rollouts store the invocation and its result on separate lines, joined by call ID.
    static func codexPublications(inTranscript data: Data) -> [Published] {
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var calls: [String: (tool: String, input: JSONValue?)] = [:]
        var found: [Published] = []
        for line in data.split(separator: 0x0A) {
            // A line that doesn't parse stays text, and has no fields.
            let entry = codexToolJSON(.string(String(decoding: line, as: UTF8.self)))
            guard entry["type"]?.string == "response_item", let item = entry["payload"],
                let id = item["call_id"]?.string
            else { continue }
            switch item["type"]?.string {
            case "function_call":
                guard let name = item["name"]?.string else { continue }
                let tool = item["namespace"]?.string.map { $0 + "__" + name } ?? name
                guard codexPublishers[tool] != nil else { continue }
                calls[id] = (tool, item["arguments"].map(codexToolJSON))
            case "function_call_output":
                guard let call = calls.removeValue(forKey: id), let output = item["output"],
                    let at = entry["timestamp"]?.string.flatMap(timestamp.date(from:)),
                    let page = published(
                        hook: .obj([
                            "hook_event_name": "PostToolUse", "tool_name": .string(call.tool),
                            "tool_input": call.input ?? .null, "tool_response": output
                        ]))
                else { continue }
                found.append(.init(url: page.url, title: page.title, type: page.type, page: page.page, at: at))
            default: continue
            }
        }
        return found
    }
}
