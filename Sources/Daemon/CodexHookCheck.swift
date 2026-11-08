import Agents
import Darwin
import Foundation
import os

/// Whether Codex trusts Kelp's hooks as `CodexHooks` passes them: asked once per Codex binary (its path, size and date)
/// of `codex app-server` (`hooks/list`, about 0.1 s). Only then do its sessions get them. A hash Codex doesn't agree
/// with would stop the start at its "review these hooks" question, where the prompt Kelp types would land. Until then,
/// and with a Codex that has no hooks, its status comes from its screen as before.
final class CodexHookCheck: Sendable {
    private let known = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
    private let ask: @Sendable (String) -> [String: Any]?

    init(ask: @escaping @Sendable (String) -> [String: Any]? = CodexHookCheck.hooksList) { self.ask = ask }

    func agrees(_ path: String) -> Bool {
        let id = Self.fingerprint(path)
        if let answer = known.withLock({ $0[id] }) { return answer }
        let answer = Self.agrees(ask(path))
        if !answer {
            Log.session.error("codex at \(path, privacy: .public) doesn't take Kelp's hooks: its screen is read")
        }
        known.withLock { $0[id] = answer }
        return answer
    }

    /// Every Kelp hook listed as trusted.
    static func agrees(_ answer: [String: Any]?) -> Bool {
        let entries = (answer?["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        let trusted = Set(
            entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .filter { $0["trustStatus"] as? String == "trusted" }.compactMap { $0["key"] as? String })
        return CodexHooks.events.allSatisfy { trusted.contains(CodexHooks.key($0.label)) }
    }

    @Sendable static func hooksList(_ path: String) -> [String: Any]? {
        // Its own folder: a project's .codex hooks are another question, Kelp's are the same everywhere.
        let cwd = NSTemporaryDirectory()
        let params = #"{"cwds":["# + CodexHooks.quoted(cwd) + "]}"
        return AgentUsage.askCodex(path: path, args: CodexHooks.args, method: "hooks/list", params: params, within: 5)
    }

    /// A new Codex (an update replaces the file) is asked again.
    static func fingerprint(_ path: String) -> String {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard stat(real, &info) == 0 else { return real }
        return "\(real)|\(info.st_size)|\(info.st_mtimespec.tv_sec)"
    }
}
