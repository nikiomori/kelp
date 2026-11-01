import Foundation
import Core
import os

/// `contributes.events` (docs/extensions.md): a command an extension runs when an agent asks, finishes or fails, or a
/// workspace is added. kelpd runs them, so they work with the window closed: a push to a phone needs nothing more.
/// What they're about comes in environment variables, never into the command's text: it's what agents print, and a
/// shell would run it.
final class ExtensionEvents: Sendable {
    private let told = OSAllocatedUnfairLock(initialState: [String: AgentStatus]())
    /// A status from before this daemon was told before it.
    private let started = Date()

    /// The event a saved session is, once per stop. A child's result is its parent's to read, as it is for notifications.
    func event(of s: Session) -> String? {
        told.withLock { told in
            if s.status == .working { told[s.id] = nil }
            guard s.agent != nil, s.agent != "shell", s.agent != "custom", told[s.id] != s.status, (s.statusAt ?? .distantPast) >= started,
                  let name = [.waiting: "agent.waiting", .done: "agent.done", .error: "agent.failed"][s.status],
                  s.parent == nil || s.status != .done else { return nil }
            told[s.id] = s.status
            return name
        }
    }
}

extension Sessions {
    /// A status has to stand this long: a program may say idle for a second as a turn starts (Codex), and a question answered
    /// at once asked nobody away from the Mac.
    static let eventDelay = 2.5

    func eventsHeard(_ s: Session) {
        guard let event = events.event(of: s) else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.eventDelay) { [weak self] in
            guard let self, existing(s.id)?.snapshot.status == s.status else { return }
            let asks = s.status != .done
            fire(event, cwd: s.currentDir, values: ["KELP_SESSION_ID": s.id, "KELP_AGENT": s.agent ?? "", "KELP_TITLE": s.displayTitle,
                                                    "KELP_SUMMARY": asks ? s.summary : "", "KELP_WORKSPACE_ID": s.worktreeId ?? ""])
        }
    }

    func workspaceAdded(_ w: Worktree) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.fire("workspace.created", cwd: w.path, values: ["KELP_TITLE": w.displayName, "KELP_WORKSPACE_ID": w.id])
        }
    }

    /// Read from disk each time: events are rare, and what's installed takes effect without a reload. Blocks: never on a
    /// session's queue or a reader.
    private func fire(_ event: String, cwd: String, values: [String: String]) {
        let env = ProcessInfo.processInfo.environment.merging(values.merging(["KELP_EVENT": event]) { a, _ in a }) { _, new in new }
        // On a remote project the folder isn't on this Mac.
        let folder = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        for (id, run) in handlers(of: event) {
            let argv = ["/bin/zsh", "-lc", run]
            let r = Log.session.attempt("running \(id)'s \(event)") { try Subprocess.run(argv, cwd: folder, env: env, timeLimit: 30) }
            if let r, r.status != 0 { Log.session.error("\(id, privacy: .public)'s \(event, privacy: .public) exited \(r.status)") }
        }
    }

    private func handlers(of event: String) -> [(id: String, run: String)] {
        struct Manifest: Decodable {
            struct Contributes: Decodable { var events: [Handler]? }
            struct Handler: Decodable { var on: String, run: String }
            var id: String, contributes: Contributes?
        }
        let dir = root.appendingPathComponent("extensions"), off = Set(settings["extensions.disabled"]?.array?.compactMap(\.string) ?? [])
        let found = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
        let folders = found?.allObjects as? [URL] ?? []
        return folders.sorted { $0.path < $1.path }.flatMap { folder -> [(id: String, run: String)] in
            let file = folder.appendingPathComponent("extension.json")
            guard FileManager.default.fileExists(atPath: file.path), let m = Log.session.attempt("reading \(file.path)", {
                try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
            }), !off.contains(m.id) else { return [] }
            return (m.contributes?.events ?? []).filter { $0.on == event }.map { (m.id, $0.run) }
        }
    }
}
