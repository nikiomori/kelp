import Core
import Foundation

/// What was pasted into Add a Skill or MCP Server, read: a skill's folder, a repository of skills, or a server (a
/// command, an address, JSON). A repository is told from a server's address by its host or its `.git`.
enum AddonPaste: Equatable {
    case server(name: String, entry: ServerEntry)
    case folder(String)
    case repository(String)

    static let forges = ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"]

    static func read(_ pasted: String) -> AddonPaste? {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") || text.hasPrefix("~") { return .folder(text) }
        if text.hasPrefix("git@") || text.hasPrefix("ssh://") || text.hasPrefix("git://") { return .repository(text) }
        if !text.contains(" "), let url = URL(string: text), let host = url.host,
            forges.contains(host) || url.pathExtension == "git"
        {
            return .repository(text)
        }
        return ServerEntry.parse(text).map { .server(name: $0.name, entry: $0.entry) }
    }

    var isServer: Bool {
        if case .server = self { return true }
        return false
    }

    /// The agents Kelp can hand it to: a server goes on two agents' command lines; a skill sits where all of these read.
    var agents: [String] {
        isServer ? ["claude", "codex"] : ["claude", "codex", "cursor", "pi", "copilot", "kimi", "opencode"]
    }
}
