import AppKit
import Core

/// What the views watch (`WatchTopic`), counted here so the daemon hears once per topic and key: on the first watcher
/// and after the last. What it pushes lands in AppModel's observed state (`git`, `ports`…), which views `track`.
extension AppModel {
    func watch(_ topic: WatchTopic, _ key: String = "") {
        let w = WatchStart(topic, key)
        watching[w, default: 0] += 1
        if watching[w] == 1 { client?.notify(w) }
    }

    func unwatch(_ topic: WatchTopic, _ key: String = "") {
        let w = WatchStart(topic, key)
        guard let n = watching[w] else { return }
        if n > 1 { watching[w] = n - 1; return }
        watching[w] = nil
        client?.notify(WatchStop(topic, key))
        forget(topic, key)   // not shown anywhere now: no stale value when it's watched again
    }

    /// Read it again now, and (CI) keep looking for a while: after a push, its run shows up within seconds.
    package func watchAgain(_ topic: WatchTopic, _ key: String = "") {
        let w = WatchStart(topic, key)
        if watching[w] != nil { client?.notify(w) }
    }

    private func forget(_ topic: WatchTopic, _ key: String) {
        switch topic {
        case .git: git[key] = nil
        case .ports: ports[key] = nil
        case .activity: activity = nil
        case .ci: ci[key] = nil
        case .pr: prs[key] = nil
        case .context: contextUsage[key] = nil
        case .limits: limits = nil
        case .file: fileVersions[key] = nil
        case .files: fileLists[key] = nil
        case .commands: commands[key] = nil
        }
    }

    /// What the daemon pushed for a watched topic. Assigned only when it differs: every assignment re-renders its readers.
    func watched(_ event: any RPCEvent) {
        switch event {
        case let e as GitEvent: if git[e.worktree] != e { git[e.worktree] = e }
        case let e as PortsEvent: if ports[e.worktree] != e.ports { ports[e.worktree] = e.ports }
        case let e as ActivityEvent: if activity != e { activity = e }
        case let e as CIEvent: if ci[e.worktree] != e { ci[e.worktree] = e }
        case let e as PREvent: if prs[e.worktree] != e.pr { prs[e.worktree] = e.pr }
        case let e as LimitsEvent: if limits != e.usage { forecast.record(e.usage); limits = e.usage }
        case let e as FileEvent: if fileVersions[e.path] != e { fileVersions[e.path] = e }
        case let e as FilesEvent: if fileLists[e.worktree] != e { fileLists[e.worktree] = e }
        case let e as CommandsEvent: if commands[e.session] != e.commands { commands[e.session] = e.commands }
        case let e as ContextEvent:
            // No usage (not Claude Code, ended, just compacted) takes the ring away.
            let usage = e.usage.flatMap { $0.window > 0 ? $0 : nil }, old = contextUsage[e.session]
            func share(_ u: SessionContextWindow.Usage?) -> Double { u.map { Double($0.used) / Double($0.window) } ?? -1 }
            if usage?.window != old?.window || abs(share(usage) - share(old)) > 0.01 { contextUsage[e.session] = usage }   // a percent at a time
        default: break
        }
    }

    /// A project or workspace as it is now: the lists follow the daemon's records without reading them again.
    func record(_ r: Repo) {
        recordEvents[r.id, default: 0] += 1
        if let i = repos.firstIndex(where: { $0.id == r.id }) { if repos[i] != r, !r.isOlder(than: repos[i]) { repos[i] = r } } else { repos.append(r) }
    }
    func record(_ w: Worktree) {
        recordEvents[w.id, default: 0] += 1
        if let i = worktrees.firstIndex(where: { $0.id == w.id }) { if worktrees[i] != w, !w.isOlder(than: worktrees[i]) { worktrees[i] = w } }
        else { worktrees.append(w) }
    }

    /// A project, workspace or session that's gone.
    func removed(_ e: RemovedEvent) {
        if let id = e.repo {
            for x in [id] + worktrees.filter({ $0.repoId == id }).map(\.id) { recordEvents[x, default: 0] += 1 }
            repos.removeAll { $0.id == id }; worktrees.removeAll { $0.repoId == id }
        }
        if let id = e.worktree { recordEvents[id, default: 0] += 1; worktrees.removeAll { $0.id == id } }
        if let id = e.session { removed(session: id) }
    }

    /// The context ring of every agent that hasn't ended: watched while it runs, let go when it ends.
    func syncContextWatches() {
        let want = Set(sessions.filter { $0.agent != "shell" && $0.status != .exited }.map(\.id))
        let have = Set(watching.keys.filter { $0.topic == .context }.map(\.key))
        for id in want.subtracting(have) { watch(.context, id) }
        for id in have.subtracting(want) { unwatch(.context, id) }
    }
}

/// One key of a topic watched at a time (the workspace a panel shows): set `key`, nil lets go; so does the owner going.
@MainActor
package final class Watched {
    let topic: WatchTopic, app: AppModel
    package var key: String? {
        didSet {
            guard key != oldValue else { return }
            if let o = oldValue { app.unwatch(topic, o) }
            if let k = key { app.watch(topic, k) }
        }
    }
    package init(_ topic: WatchTopic, in app: AppModel) { self.topic = topic; self.app = app }
    isolated deinit { if let k = key { app.unwatch(topic, k) } }
}
