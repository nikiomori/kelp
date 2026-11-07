import AppKit
import Core

/// What the views watch (`WatchTopic`), counted here so the daemon hears once per topic and key: on the first watcher
/// and after the last. What it pushes lands in one store per kind (`latest(CIEvent.self, key)`), which views `track`.
extension AppModel {
    package func watch(_ topic: WatchTopic, _ key: String = "") {
        let w = WatchStart(topic, key)
        watching[w, default: 0] += 1
        if watching[w] == 1 { client?.notify(w) }
    }

    package func unwatch(_ topic: WatchTopic, _ key: String = "") {
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

    /// The latest pushed `E` by key (`Pushed`): one observable box per kind, so a view reading CI re-renders for CI only.
    package func latest<E: Pushed>(_: E.Type) -> Latest<E> {
        part {
            let box = Latest<E>()
            if let t = E.forgottenWith { forgetters[t, default: []].append { [weak box] key in box?.byKey[key] = nil } }
            return box
        }
    }
    /// The latest pushed `E` for `key` (a workspace, a session, a path; "" for one of a kind).
    package func latest<E: Pushed>(_ t: E.Type, _ key: String = "") -> E? { latest(t).byKey[key] }

    /// Kept as the latest of its kind, if it differs (each change re-renders its readers): whether it did.
    /// Only what the daemon pushed (`watched`) and the shell's own refresh: a built-in asks again (`watchAgain`) rather than
    /// writing its own copy, so the store holds one source.
    @discardableResult func land<E: Pushed>(_ e: E) -> Bool {
        let box = latest(E.self)
        guard e.replaces(box.byKey[e.key]) else { return false }
        box.byKey[e.key] = e
        return true
    }

    private func forget(_ topic: WatchTopic, _ key: String) { forgetters[topic]?.forEach { $0(key) } }

    /// What the daemon pushed for a watched topic.
    func watched(_ event: any RPCEvent) {
        guard let e = event as? any Pushed else { return }
        func open<E: Pushed>(_ e: E) { land(e) }
        open(e)
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

/// The latest pushed of one kind, by key (`AppModel.latest`).
@MainActor
@Observable
package final class Latest<E: Pushed> {
    package var byKey: [String: E] = [:]
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
