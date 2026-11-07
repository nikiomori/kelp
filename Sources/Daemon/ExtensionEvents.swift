import Core
import Foundation
import os

/// `contributes.events` (docs/extensions.md): a command an extension runs when an agent asks, finishes or fails, or a
/// workspace is added. kelpd runs them, so they work with the window closed: a push to a phone needs nothing more.
/// What they're about comes in environment variables, never into the command's text: it's what agents print, and a
/// shell would run it.
final class ExtensionEvents: Sendable {
    private let told = OSAllocatedUnfairLock(initialState: [String: AgentStatus]())
    /// One thread however many fire. Limit: a command that hangs holds the next back for its 30 s.
    let queue = DispatchQueue(label: "dev.kelp.extension-events", qos: .utility)
    /// A status from before this daemon was told before it.
    private let started = Date()

    /// The event a saved session is, once per stop. A child's result is its parent's to read, as it is for notifications.
    func event(of session: Session) -> String? {
        told.withLock { told in
            if session.status == .working || session.status == .exited { told[session.id] = nil }
            guard session.agent != nil, session.agent != "shell", session.agent != "custom",
                told[session.id] != session.status,
                (session.statusAt ?? .distantPast) >= started,
                let name = [.waiting: "agent.waiting", .done: "agent.done", .error: "agent.failed"][session.status],
                session.parent == nil || session.status != .done
            else { return nil }
            told[session.id] = session.status
            return name
        }
    }
}

extension Sessions {
    /// A status has to stand this long: a program may say idle for a second as a turn starts (Codex), and a question answered
    /// at once asked nobody away from the Mac.
    static let eventDelay = 2.5

    func eventsHeard(_ session: Session) {
        guard let event = events.event(of: session) else { return }
        events.queue.asyncAfter(deadline: .now() + Self.eventDelay) { [weak self] in
            guard let self else { return }
            // Gone since: a result still stands, and a question has nobody left to answer it.
            let now = existing(session.id)?.snapshot.status
            guard now == session.status || (now == nil && session.status != .waiting) else { return }
            let asks = session.status != .done
            fire(
                event, cwd: session.currentDir,
                values: [
                    "KELP_SESSION_ID": session.id, "KELP_AGENT": session.agent ?? "",
                    "KELP_TITLE": session.displayTitle,
                    "KELP_SUMMARY": asks ? session.summary : "", "KELP_WORKSPACE_ID": session.worktreeId ?? ""
                ])
            phoneHeard(session)
        }
    }

    func workspaceAdded(_ workspace: Worktree) {
        events.queue.async { [weak self] in
            self?.fire(
                "workspace.created", cwd: workspace.path,
                values: ["KELP_TITLE": workspace.displayName, "KELP_WORKSPACE_ID": workspace.id])
        }
    }

    /// Read from disk each time: events are rare, and what's installed takes effect without a reload. Blocks: never on a
    /// session's queue or a reader.
    private func fire(_ event: String, cwd: String, values: [String: String]) {
        let env = ProcessInfo.processInfo.environment.merging(values.merging(["KELP_EVENT": event]) { a, _ in a }) {
            _, new in new
        }
        // On a remote project the folder isn't on this Mac.
        let folder = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        for (id, run) in handlers(of: event) {
            let argv = ["/bin/zsh", "-lc", run]
            let result = Log.session.attempt("running \(id)'s \(event)") {
                try Subprocess.run(argv, cwd: folder, env: env, timeLimit: 30)
            }
            if let result, result.status != 0 {
                Log.session.error("\(id, privacy: .public)'s \(event, privacy: .public) exited \(result.status)")
            }
        }
    }

    private func handlers(of event: String) -> [(id: String, run: String)] {
        struct Manifest: Decodable {
            struct Contributes: Decodable { var events: [Handler]? }
            struct Handler: Decodable { var on: String, run: String }
            var id: String, contributes: Contributes?
        }
        let dir = root.appendingPathComponent("extensions"),
            off = Set(settings[SettingKeys.disabledExtensions] ?? [])
        let found = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
        let folders = found?.allObjects as? [URL] ?? []
        return folders.sorted { $0.path < $1.path }.flatMap { folder -> [(id: String, run: String)] in
            let file = folder.appendingPathComponent("extension.json")
            guard FileManager.default.fileExists(atPath: file.path),
                let manifest = Log.session.attempt(
                    "reading \(file.path)",
                    {
                        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
                    }), !off.contains(manifest.id)
            else { return [] }
            let mine = (manifest.contributes?.events ?? []).filter { $0.on == event }
            guard mine.isEmpty || trustsExtension(folder.lastPathComponent) else {
                Log.session.info(
                    "\(manifest.id, privacy: .public)'s \(event, privacy: .public) waits to be allowed in Settings › Extensions"
                )
                return []
            }
            return mine.map { (manifest.id, $0.run) }
        }
    }
}
