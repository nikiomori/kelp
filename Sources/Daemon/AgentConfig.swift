import Core
import Foundation
import GitKit

/// What a trusted folder lets an agent run on its own: hooks, MCP servers, its settings. A branch (someone else's PR)
/// that changes these against the base asks the user, though the project is trusted; so does one Kelp can't compare.
enum AgentConfig {
    static let files = [".claude", ".mcp.json", ".codex", ".gemini", ".cursor"]
    /// At any depth: a session can start in a folder inside the workspace, and the agent reads that folder's config.
    static let specs = files.flatMap { [":(glob)**/" + $0, ":(glob)**/" + $0 + "/**"] }
    static func changed(_ path: String, base: String, remotes: Remotes) -> Bool {
        guard Git.isRevision(base) else { return true }   // a base that reads as an option can't be compared: the user is asked
        // exit 1: differs (base: checked above)
        let committed =
            (try? Git.run(["diff", "--quiet", base, "HEAD", "--"] + specs, cwd: path, remotes: remotes)) == nil
        let pending =
            (try? Git.run(["status", "--porcelain", "--"] + specs, cwd: path, remotes: remotes))?.isEmpty != true
        return committed || pending
    }
}
