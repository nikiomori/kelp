import Core
import Foundation
import os

/// `contributes.events` (docs/extensions.md): a command an extension runs when an agent asks, finishes or fails, or a
/// workspace is added. kelpd runs them, so they work with the window closed: a push to a phone needs nothing more.
/// What they're about comes in environment variables, never into the command's text: it's what agents print, and a
/// shell would run it. Kelp's own push to a phone goes out from here too (PhonePush.swift).
final class ExtensionEvents: Sendable {
    let root: URL, live: SessionTable, store: Store, settings: SettingsStore, clients: Clients
    let setup: SessionSetup   // which extensions the user allowed, and an agent's name
    let phone: PhoneBridge   // the phones that take pushes
    private let told = OSAllocatedUnfairLock(initialState: [String: AgentStatus]())
    /// One thread however many fire. Limit: a command that hangs holds the next back for its 30 s.
    let queue = DispatchQueue(label: "dev.kelp.extension-events", qos: .utility)
    /// A status from before this daemon was told before it.
    private let started = Date()

    init(
        root: URL, live: SessionTable, store: Store, settings: SettingsStore, clients: Clients, setup: SessionSetup,
        phone: PhoneBridge
    ) {
        self.root = root
        self.live = live
        self.store = store
        self.settings = settings
        self.clients = clients
        self.setup = setup
        self.phone = phone
    }

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

    /// A status has to stand this long: a program may say idle for a second as a turn starts (Codex), and a question answered
    /// at once asked nobody away from the Mac.
    /// KELP_TEST_SLOW stretches it with the tests' waits (a sanitizer's run): what has to stand still does, in its time.
    static let eventDelay = 2.5 * (ProcessInfo.processInfo.environment["KELP_TEST_SLOW"].flatMap(Double.init) ?? 1)

    /// Every saved change of a session (`Sessions.said`), told once per stop.
    func heard(_ session: Session) {
        guard let event = event(of: session) else { return }
        queue.asyncAfter(deadline: .now() + Self.eventDelay) { [weak self] in
            guard let self else { return }
            // Gone since: a result still stands, and a question has nobody left to answer it.
            let now = live[session.id]?.snapshot.status
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
        queue.async { [weak self] in
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
        func manifest(_ data: Data?, _ folder: URL) -> Manifest? {
            guard let data else { return nil }
            return Log.session.attempt("reading \(folder.path)/extension.json") {
                try JSONDecoder().decode(Manifest.self, from: data)
            }
        }
        return folders.sorted { $0.path < $1.path }.flatMap { folder -> [(id: String, run: String)] in
            // A first look, for whether it handles the event at all; then what runs comes from the same read as the
            // digest checked against what the user allowed, so a manifest swapped in between runs nothing unseen.
            // Limit: a script of the folder that the command runs is read again as it runs.
            let file = folder.appendingPathComponent("extension.json")
            guard let first = manifest(FileManager.default.contents(atPath: file.path), folder),
                first.contributes?.events?.contains(where: { $0.on == event }) == true
            else { return [] }
            let read = ExtensionFiles.extensionFiles(folder)
            guard let manifest = manifest(read["/extension.json"], folder), !off.contains(manifest.id) else {
                return []
            }
            let mine = (manifest.contributes?.events ?? []).filter { $0.on == event }
            guard mine.isEmpty || setup.trustsExtension(folder.lastPathComponent, read: read) else {
                Log.session.info(
                    "\(manifest.id, privacy: .public)'s \(event, privacy: .public) waits to be allowed in Settings › Extensions"
                )
                return []
            }
            return mine.map { (manifest.id, $0.run) }
        }
    }
}
