import Agents
import Core
import Foundation

extension Conversations {
    /// pi launches with a pinned ID; OMP normally has no such flag, but holds its JSONL file open. Never use the
    /// newest file in the project: two agents in the same workspace can be replying at the same time.
    static func piTailScript(_ session: Session, localPID: Int32?) -> String? {
        guard let agent = session.agent, agent == "pi" || agent == "omp" else { return nil }
        let read = #"if [ -f "$f" ] && [ ! -L "$f" ]; then tail -c \#(remoteTailBytes) < "$f"; exit; fi"#
        var parts: [String] = []
        if agent == "omp" {
            let pid =
                session.tmux.flatMap { Tmux.isOwn($0) ? panePID($0) : nil }
                ?? localPID.flatMap { $0 > 0 ? String($0) : nil }
            if let pid {
                let uuid = "[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}"
                parts += [
                    openAgentFile(pid: pid, executable: "^omp$", filename: "^/.*/[0-9T:.-]+Z_\(uuid)[.]jsonl$"), read
                ]
            }
        }
        let argv = session.argv.prefix { $0 != "--" }
        if let index = argv.lastIndex(where: { ["--session-id", "--session", "--resume"].contains($0) }),
            let value = argv.dropFirst(index + 1).first
        {
            if value.hasPrefix("/"), value.hasSuffix(".jsonl"), argv[index] != "--session-id" {
                // An explicit file, e.g. a Kelp hand-off, need not have the agent's usual filename.
                parts += ["f=" + ShellQuote.word(value), read]
            } else if let uuid = UUID(uuidString: value) {
                let root = #""${PI_CODING_AGENT_DIR:-$HOME/.\#(agent)/agent}/sessions""#
                parts += [
                    #"set -- \#(root)/*/*_\#(uuid.uuidString.lowercased()).jsonl"#, #"[ "$#" -eq 1 ] || exit 0"#,
                    "f=$1", read
                ]
            }
        }
        return parts.isEmpty ? nil : (parts + ["exit 0"]).joined(separator: "\n")
    }
}
