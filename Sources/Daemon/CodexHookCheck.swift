import Agents
import Core
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
    private let askHost: @Sendable (RemoteHost) -> [String: Any]?

    init(
        ask: @escaping @Sendable (String) -> [String: Any]? = CodexHookCheck.hooksList,
        askHost: @escaping @Sendable (RemoteHost) -> [String: Any]? = CodexHookCheck.hooksList(on:)
    ) {
        self.ask = ask
        self.askHost = askHost
    }

    func agrees(_ path: String) -> Bool {
        check(Self.fingerprint(path), "codex at \(path)") { Self.agrees(ask(path)) }
    }

    /// The Codex on a remote project's host, with the hooks it gets there: asked over ssh, once per host while this
    /// kelpd runs (up to 10 s, at its first Codex session). None there, or none that knows hooks: its screen is read.
    /// Limit: a Codex updated on the host meanwhile isn't asked again until kelpd restarts.
    func agrees(on host: RemoteHost) -> Bool {
        check("ssh:" + host.host, "codex on \(host.host)") {
            Self.agrees(askHost(host), events: CodexHooks.hostEvents)
        }
    }

    private func check(_ id: String, _ what: String, _ ask: () -> Bool) -> Bool {
        if let answer = known.withLock({ $0[id] }) { return answer }
        let answer = ask()
        if !answer { Log.session.error("\(what, privacy: .public) doesn't take Kelp's hooks: its screen is read") }
        known.withLock { $0[id] = answer }
        return answer
    }

    /// Every Kelp hook listed as trusted.
    static func agrees(
        _ answer: [String: Any]?, events: [(name: String, label: String, command: String)] = CodexHooks.events
    ) -> Bool {
        let entries = (answer?["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        let trusted = Set(
            entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .filter { $0["trustStatus"] as? String == "trusted" }.compactMap { $0["key"] as? String })
        return events.allSatisfy { trusted.contains(CodexHooks.key($0.label)) }
    }

    @Sendable static func hooksList(_ path: String) -> [String: Any]? {
        // Its own folder: a project's .codex hooks are another question, Kelp's are the same everywhere.
        let cwd = NSTemporaryDirectory()
        let params = #"{"cwds":["# + CodexHooks.quoted(cwd) + "]}"
        return AgentUsage.askCodex(path: path, args: CodexHooks.args, method: "hooks/list", params: params, within: 5)
    }

    /// Its app server started on the host as its sessions are, with the hooks they get, asked about the project's folder.
    /// No terminal there and no password asked (BatchMode): one that would ask is a no, at once.
    @Sendable static func hooksList(on host: RemoteHost) -> [String: Any]? {
        let codex = host.command(["codex", "app-server"] + CodexHooks.hostArgs)
        let params = #"{"cwds":["# + CodexHooks.quoted(host.path) + "]}"
        return AgentUsage.askCodex(
            argv: [host.ssh] + host.sshArgs(tty: false) + [codex], method: "hooks/list", params: params, within: 10)
    }

    /// A new Codex (an update replaces the file) is asked again.
    static func fingerprint(_ path: String) -> String {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard stat(real, &info) == 0 else { return real }
        return "\(real)|\(info.st_size)|\(info.st_mtimespec.tv_sec)"
    }
}
