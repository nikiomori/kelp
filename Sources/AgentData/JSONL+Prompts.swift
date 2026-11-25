import Foundation

extension JSONL {
    /// The first user text block supplies the session title and work-log prompt.
    static func promptText(_ content: Any?) -> String? {
        texts(content).lazy.compactMap(typed).first
    }

    /// Codex puts an opening and closing text block around an attachment. The same tags alone can be genuine HTML.
    static func texts(_ content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        let items = content as? [[String: Any]] ?? []
        return items.indices.compactMap { i in
            guard let text = items[i]["text"] as? String else { return nil }
            if let marker = text.wholeMatch(of: /<(\/?)(image|audio)(?: name=[^>]*)?>/) {
                let media = marker.1.isEmpty ? i + 1 : i - 1
                if items.indices.contains(media), items[media]["type"] as? String == "input_\(marker.2)" { return nil }
            }
            return text
        }
    }

    private static let generatedTags: Set<Substring> = [
        "environment_context", "user_instructions", "turn_aborted", "subagent_notification", "user_shell_command",
        "user_action", "skill", "codex_internal_context", "agent_message_board_notification", "image_resize_notice",
        "system-reminder", "task-notification", "teammate-message", "artifact-content-authored-by-others",
        "command-name", "command-message", "command-args", "local-command-caveat", "local-command-stdout",
        "local-command-stderr", "bash-input", "bash-stdout", "bash-stderr", "ide_opened_file", "ide_selection"
    ]

    /// Skips leading transcript wrappers. User text can follow a wrapper in the same block or start with markup itself.
    static func typed(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        while let tag = text.prefixMatch(of: /<([\w-]+)(?=[>\s])/),
            generatedTags.contains(tag.1) || text.hasPrefix("<kelp from=\"")
        {
            if tag.1.hasPrefix("command-"), let name = text.firstMatch(of: /<command-name>(.*?)<\/command-name>/)?.1,
                let args = text.firstMatch(of: /<command-args>([\s\S]*?)<\/command-args>/)?.1,
                !args.allSatisfy(\.isWhitespace)
            {
                return "\(name) \(args)"
            }
            guard let end = text.range(of: "</\(tag.1)>") else { return nil }
            text = text[end.upperBound...].drop(while: \.isWhitespace)
            if tag.1 == "task-notification", text.hasPrefix("Read the output file to retrieve the result:") {
                return nil
            }
        }
        guard !text.isEmpty, !text.hasPrefix("# AGENTS.md"), !text.hasPrefix("[Request interrupted") else { return nil }
        return String(text)
    }
}
