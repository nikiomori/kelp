import AppKit
import Core

/// What the views watch (`WatchTopic`), counted here so the daemon hears once per topic and key: on the first watcher
/// and after the last. What it pushes lands in one store per kind (`latest(CIEvent.self, key)`), which views `track`.
extension AppModel {
    package func watch(_ topic: WatchTopic, _ key: String = "") {
        let start = WatchStart(topic, key)
        watching[start, default: 0] += 1
        if watching[start] == 1, let client, !paused(start) { tell(start, client) }
    }

    /// What only the window shows, polled for it alone (ports, CPU, machines, hosts, subagents' steps): not read while the
    /// window isn't seen. CI, git, sessions and the limits go on (the Dock, notifications and parked agents follow them).
    static let seenOnly: Set<WatchTopic> = [
        .ports, .activity, .machines, .machineDetail, .host, .hostDetail, .subagents
    ]
    private func paused(_ start: WatchStart) -> Bool { away && Self.seenOnly.contains(start.topic) }

    /// Kelp's window was hidden, minimized or covered (`away`), or seen again: what only it shows stops or starts again,
    /// and the daemon hears it (its token scan waits too).
    func setAway(_ now: Bool) {
        guard now != away else { return }
        away = now
        for start in watching.keys where Self.seenOnly.contains(start.topic) {
            if now {
                told.remove(start)
                notify { WatchStop(start.topic, start.key) }
            } else if let client {
                tell(start, client)
            }
        }
        publishUIState()
    }

    /// `start` sent on `connection`, unless that connection heard it already.
    private func tell(_ start: WatchStart, _ connection: RPCClient) {
        if toldTo !== connection {
            toldTo = connection
            told = []
        }
        if told.insert(start).inserted { connection.notify(start) }
    }

    /// What the views watch, told to a connection that hasn't heard it: all of it for a new daemon, and nothing twice for
    /// the first one, whose lists' refresh and first views watched over it already. Returns what it sent.
    @discardableResult func tellWatches(_ connection: RPCClient) -> [WatchStart] {
        let unheard = watching.keys.filter { (toldTo !== connection || !told.contains($0)) && !paused($0) }
        for start in unheard { tell(start, connection) }
        return unheard
    }

    package func unwatch(_ topic: WatchTopic, _ key: String = "") { unwatch(topic, key, forgetting: true) }

    private func unwatch(_ topic: WatchTopic, _ key: String, forgetting: Bool) {
        let start = WatchStart(topic, key)
        guard let count = watching[start] else { return }
        if count > 1 {
            watching[start] = count - 1
            return
        }
        watching[start] = nil
        told.remove(start)
        notify { WatchStop(topic, key) }
        if forgetting { forget(topic, key) }   // not shown anywhere now: no stale value when it's watched again
    }

    /// Read it again now, and (CI) keep looking for a while: after a push, its run shows up within seconds.
    package func watchAgain(_ topic: WatchTopic, _ key: String = "") {
        let start = WatchStart(topic, key)
        if watching[start] != nil { notify { start } }
    }

    /// The latest pushed `E` by key (`Pushed`): one observable box per kind, so a view reading CI re-renders for CI only.
    package func latest<E: Pushed>(_: E.Type) -> Latest<E> {
        part {
            let box = Latest<E>()
            if let topic = E.forgottenWith {
                forgetters[topic, default: []].append { [weak box] key in box?.byKey[key] = nil }
            }
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
        landed(e)
        return true
    }

    private func forget(_ topic: WatchTopic, _ key: String) { forgetters[topic]?.forEach { $0(key) } }

    /// What the daemon pushed for a watched topic.
    func watched(_ event: any RPCEvent) {
        guard let pushed = event as? any Pushed else { return }
        func open<E: Pushed>(_ pushed: E) { land(pushed) }
        open(pushed)
    }

    /// A project or workspace as it is now: the lists follow the daemon's records without reading them again.
    func record<R: Revised & Equatable>(_ r: R, in list: ReferenceWritableKeyPath<AppModel, [R]>) {
        recordEvents[r.id, default: 0] += 1
        if let index = self[keyPath: list].firstIndex(where: { $0.id == r.id }) {
            let old = self[keyPath: list][index]
            if old != r, !r.isOlder(than: old) { self[keyPath: list][index] = r }
        } else {
            self[keyPath: list].append(r)
        }
    }

    /// A project, workspace or session that's gone.
    func removed(_ e: RemovedEvent) {
        if let id = e.repo {
            for x in [id] + worktrees.filter({ $0.repoId == id }).map(\.id) { recordEvents[x, default: 0] += 1 }
            arrangement.forget([id] + worktrees.filter { $0.repoId == id }.map(\.id))
            repos.removeAll { $0.id == id }
            worktrees.removeAll { $0.repoId == id }
        }
        if let id = e.worktree {
            recordEvents[id, default: 0] += 1
            arrangement.forget([id])
            worktrees.removeAll { $0.id == id }
        }
        if let id = e.session { removed(session: id) }
    }

    /// The context ring on an agent's tab: watched for the agents of the workspace on screen (the tabs there are) that
    /// haven't ended, let go as another workspace is shown or the agent ends. A ring read before stays for the next time
    /// its workspace shows, so it's there at once, until its agent ends.
    func syncContextWatches() {
        let shown = workbench.workspaceId
        let live = Set(sessions.filter { $0.agent != "shell" && $0.status != .exited }.map(\.id))
        let want = live.filter { session($0)?.worktreeId == shown }
        let have = Set(watching.keys.filter { $0.topic == .context }.map(\.key))
        for id in want.subtracting(have) { watch(.context, id) }
        for id in have.subtracting(want) { unwatch(.context, id, forgetting: !live.contains(id)) }
    }
}

/// The latest pushed of one kind, by key (`AppModel.latest`).
@MainActor
@Observable
package final class Latest<E: Pushed> {
    /// Written only where it lands (`AppModel.land`): a built-in reads it.
    package internal(set) var byKey: [String: E] = [:]
}

/// One key of a topic watched at a time (the workspace a panel shows): set `key`, nil lets go; so does the owner going.
@MainActor
package final class Watched {
    let topic: WatchTopic, app: AppModel
    package var key: String? {
        didSet {
            guard key != oldValue else { return }
            if let old = oldValue { app.unwatch(topic, old) }
            if let key { app.watch(topic, key) }
        }
    }
    package init(_ topic: WatchTopic, in app: AppModel) {
        self.topic = topic
        self.app = app
    }
    isolated deinit { if let key { app.unwatch(topic, key) } }
}
