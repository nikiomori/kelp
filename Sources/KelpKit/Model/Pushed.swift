import Core

/// A value the daemon pushes for a watched topic, as the app keeps it. The app keeps the latest value by `key` (a
/// workspace, a session or a path, or "" for a topic with one value). How the app keeps it is the app's business, not
/// the wire format's in Core, so a built-in conforms its own kinds and Watching.swift names none of them.
package protocol Pushed: RPCEvent, Equatable {
    var key: String { get }
    /// The topic whose last watcher letting go drops the value, so it isn't shown stale when watched again. With nil
    /// the value is kept, because something else may still watch it, and an old value only says how things were.
    static var forgottenWith: WatchTopic? { get }
    /// Whether this value takes `old`'s place. Each change re-renders the value's readers.
    func replaces(_ old: Self?) -> Bool
}

extension Pushed {
    package func replaces(_ old: Self?) -> Bool { old != self }
}

extension GitEvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .git }
}
/// A workspace's files, for the Files tree and for Quick Open's list while that tree is watched.
extension FilesEvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .files }
}
extension PortsEvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .ports }
}
/// A project's open pull requests, for the Issues panel and its count, ⌘P's "#" and the new-branch sheet.
extension PRsEvent: Pushed {
    package var key: String { repo }
    package static var forgottenWith: WatchTopic? { .prs }

    /// Returns a project's open pull requests as the project's watch last read them (the project on screen is watched
    /// while Issues is on). With `again`, they are asked for again. Before any reading has landed (for a project not
    /// on screen), they are read once from gh.
    @MainActor package static func open(_ repo: String, in app: AppModel, again: Bool = false) async throws -> [GitHub
        .PullRequest]
    {
        guard let read = app.latest(PRsEvent.self, repo) else {
            return try await app.get(GitHubPRs(repoId: repo, filter: .open))
        }
        if again { app.watchAgain(.prs, repo) }   // the new reading lands in the store, and its readers follow
        if let error = read.error { throw RPCError.internalError(error) }
        return read.prs ?? []
    }
}
/// The pull request of a folder's branch: Git's marks and cards, and the Agents Overview's stages.
extension PREvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .pr }
}
extension CIEvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .ci }
}
extension LimitsEvent: Pushed {
    package var key: String { "" }
    package static var forgottenWith: WatchTopic? { .limits }
}
extension SubagentsEvent: Pushed {
    package var key: String { session }
    package static var forgottenWith: WatchTopic? { .subagents }
}
extension RoutinesEvent: Pushed {
    package var key: String { "" }
    package static var forgottenWith: WatchTopic? { nil }
}   // routines are always pushed, watched or not
extension HostEvent: Pushed {
    package var key: String { stats.host }
    package static var forgottenWith: WatchTopic? { nil }
}
extension ContextEvent: Pushed {
    package var key: String { session }
    package static var forgottenWith: WatchTopic? { .context }
    /// The usage the context ring shows. With none (not Claude Code, ended, or just compacted), the ring goes away.
    package var shown: SessionContextWindow.Usage? { usage.flatMap { $0.window > 0 ? $0 : nil } }
    /// Replaces the old value only when the window changes or the share used moves by more than a percent, because
    /// redrawing the ring for every token would re-render each reader.
    package func replaces(_ old: ContextEvent?) -> Bool {
        func share(_ usage: SessionContextWindow.Usage?) -> Double {
            usage.map { Double($0.used) / Double($0.window) } ?? -1
        }
        return shown?.window != old?.shown?.window || abs(share(shown) - share(old?.shown)) > 0.01
    }
}
extension TasksEvent: Pushed {
    package var key: String { repo }
    package static var forgottenWith: WatchTopic? { .tasks }

    /// The task a chat was started for, as its project's tasks were last read (while something watches them).
    @MainActor
    package static func task(of session: Session, in app: AppModel) -> TaskLine? {
        guard let repo = app.worktree(session.worktreeId)?.repoId else { return nil }
        return TaskViews.task(of: session.id, in: app.latest(TasksEvent.self, repo)?.pages ?? [])
    }
}
