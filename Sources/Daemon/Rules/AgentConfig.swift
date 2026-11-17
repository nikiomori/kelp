import Core
import Foundation
import GitKit

/// The files in a trusted folder that let an agent run things on its own: hooks, MCP servers, its settings. A branch
/// (someone else's PR) that changes them against the base asks the user, even though the project is trusted. So does a
/// branch Kelp can't compare.
enum AgentConfig {
    static let files = [".claude", ".mcp.json", ".codex", ".gemini", ".cursor"]
    /// The pathspecs match at any depth, because a session can start in a folder inside the workspace and the agent
    /// reads that folder's config.
    static let specs = files.flatMap { [":(glob)**/" + $0, ":(glob)**/" + $0 + "/**"] }
    static func changed(_ path: String, base: String, remotes: Remotes) -> Bool {
        guard Git.isRevision(base) else { return true }   // a base that reads as an option can't be compared: the user is asked
        // `diff --quiet` exits 1 when they differ (`base` was checked above)
        let committed =
            (try? Git.run(["diff", "--quiet", base, "HEAD", "--"] + specs, cwd: path, remotes: remotes)) == nil
        let pending =
            (try? Git.run(["status", "--porcelain", "--"] + specs, cwd: path, remotes: remotes))?.isEmpty != true
        return committed || pending
    }
}
