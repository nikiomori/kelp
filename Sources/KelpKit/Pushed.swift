import Core

/// What the daemon pushes for a watched topic, as the app keeps it: the latest by `key` (a workspace, a session, a path;
/// "" for one of a kind). How the app keeps it is the app's (not the wire's, in Core): a built-in conforms its own
/// kinds, and none is named in Watching.swift.
package protocol Pushed: RPCEvent, Equatable {
    var key: String { get }
    /// The topic whose last watcher letting go drops it, so it isn't shown stale when watched again; nil: kept (another
    /// may still watch it, and an old value says only how it was).
    static var forgottenWith: WatchTopic? { get }
    /// Whether it takes `old`'s place: each change re-renders its readers.
    func replaces(_ old: Self?) -> Bool
}

extension Pushed {
    package func replaces(_ old: Self?) -> Bool { old != self }
}

extension GitEvent: Pushed { package var key: String { worktree }; package static var forgottenWith: WatchTopic? { .git } }
extension PortsEvent: Pushed { package var key: String { worktree }; package static var forgottenWith: WatchTopic? { .ports } }
extension ActivityEvent: Pushed { package var key: String { "" }; package static var forgottenWith: WatchTopic? { .activity } }
extension CIEvent: Pushed { package var key: String { worktree }; package static var forgottenWith: WatchTopic? { .ci } }
extension PREvent: Pushed { package var key: String { worktree }; package static var forgottenWith: WatchTopic? { .pr } }
extension LimitsEvent: Pushed { package var key: String { "" }; package static var forgottenWith: WatchTopic? { .limits } }
extension FileEvent: Pushed { package var key: String { path }; package static var forgottenWith: WatchTopic? { .file } }
extension FilesEvent: Pushed { package var key: String { worktree }; package static var forgottenWith: WatchTopic? { .files } }
extension ArtifactsEvent: Pushed { package var key: String { worktree }; package static var forgottenWith: WatchTopic? { .artifacts } }
extension CommandsEvent: Pushed { package var key: String { session }; package static var forgottenWith: WatchTopic? { .commands } }
extension SubagentsEvent: Pushed { package var key: String { session }; package static var forgottenWith: WatchTopic? { .subagents } }
extension RoutinesEvent: Pushed { package var key: String { "" }; package static var forgottenWith: WatchTopic? { nil } }   // always pushed
extension HostEvent: Pushed { package var key: String { stats.host }; package static var forgottenWith: WatchTopic? { nil } }
extension ContextEvent: Pushed {
    package var key: String { session }
    package static var forgottenWith: WatchTopic? { .context }
    /// The ring's usage: none (not Claude Code, ended, just compacted) takes the ring away.
    package var shown: SessionContextWindow.Usage? { usage.flatMap { $0.window > 0 ? $0 : nil } }
    /// A percent at a time: a ring redrawn for every token would re-render each reader.
    package func replaces(_ old: ContextEvent?) -> Bool {
        func share(_ u: SessionContextWindow.Usage?) -> Double { u.map { Double($0.used) / Double($0.window) } ?? -1 }
        return shown?.window != old?.shown?.window || abs(share(shown) - share(old?.shown)) > 0.01
    }
}
