import AppKit
import Core

/// Counts what the views watch (`WatchTopic`), so the daemon hears once per topic and key: when the first watcher
/// starts and after the last one stops. What the daemon pushes lands in one store per kind
/// (`latest(CIEvent.self, key)`), which views `track`.
extension AppModel {
    package func watch(_ topic: WatchTopic, _ key: String = "") {
        let start = WatchStart(topic, key)
        watching[start, default: 0] += 1
        if watching[start] == 1, let client, !paused(start) { tell(start, client) }
    }

    /// Topics that only the window shows and that are polled for it alone (ports, CPU, machines, hosts, subagents'
    /// steps). They aren't read while the window can't be seen. CI, git, sessions and the limits go on, because the
    /// Dock, notifications and parked agents follow them.
    static let seenOnly: Set<WatchTopic> = [
        .ports, .activity, .machines, .machineDetail, .host, .hostDetail, .subagents
    ]
    private func paused(_ start: WatchStart) -> Bool { away && Self.seenOnly.contains(start.topic) }

    /// Called when Kelp's windows are all hidden, minimized or covered, or one is seen again (`away`, set by
    /// `Workbench.sightChanged`). The topics only the windows show stop or start again, and the daemon hears it (its
    /// token scan waits too).
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

    /// Sends `start` on `connection`, unless that connection heard it already.
    private func tell(_ start: WatchStart, _ connection: RPCClient) {
        if toldTo !== connection {
            toldTo = connection
            told = []
        }
        if told.insert(start).inserted { connection.notify(start) }
    }

    /// Tells a connection what the views watch that it hasn't heard yet. A new daemon hears all of it. The first
    /// connection hears nothing twice, because its list refresh and its first views already watched over it. Returns
    /// what it sent.
    @discardableResult func tellWatches(_ connection: RPCClient) -> [WatchStart] {
        let unheard = watching.keys.filter { (toldTo !== connection || !told.contains($0)) && !paused($0) }
        for start in unheard { tell(start, connection) }
        return unheard
    }

    /// Stops one watcher. When the last one is gone, the daemon stops, and what it pushed is dropped unless
    /// `forgetting` is false (then a view shown again soon has the value at once).
    package func unwatch(_ topic: WatchTopic, _ key: String = "", forgetting: Bool = true) {
        let start = WatchStart(topic, key)
        guard let count = watching[start] else { return }
        if count > 1 {
            watching[start] = count - 1
            return
        }
        watching[start] = nil
        told.remove(start)
        notify { WatchStop(topic, key) }
        if forgetting { forget(topic, key) }   // shown nowhere now, so no stale value shows when it's watched again
    }

    /// Asks the daemon to read a topic again now. For CI it also keeps looking for a while, because a run shows up
    /// within seconds of a push.
    package func watchAgain(_ topic: WatchTopic, _ key: String = "") {
        let start = WatchStart(topic, key)
        if watching[start] != nil { notify { start } }
    }

    /// Returns the latest pushed `E` by key (`Pushed`). There is one observable box per kind, so a view reading CI
    /// re-renders for CI only.
    package func latest<E: Pushed>(_: E.Type) -> Latest<E> {
        part {
            let box = Latest<E>()
            if let topic = E.forgottenWith {
                forgetters[topic, default: []].append { [weak box] key in box?.byKey[key] = nil }
            }
            return box
        }
    }
    /// Returns the latest pushed `E` for `key` (a workspace, a session or a path, or "" for a kind with one value).
    package func latest<E: Pushed>(_ type: E.Type, _ key: String = "") -> E? { latest(type).byKey[key] }

    /// Keeps `e` as the latest of its kind if it differs (each change re-renders its readers), and returns whether it
    /// did. Only what the daemon pushed (`watched`) and the shell's own refresh land here. A built-in asks again
    /// (`watchAgain`) rather than writing its own copy, so the store holds one source.
    @discardableResult func land<E: Pushed>(_ event: E) -> Bool {
        let box = latest(E.self)
        guard event.replaces(box.byKey[event.key]) else { return false }
        box.byKey[event.key] = event
        landed(event)
        return true
    }

    private func forget(_ topic: WatchTopic, _ key: String) { forgetters[topic]?.forEach { $0(key) } }

    /// Takes what the daemon pushed for a watched topic.
    func watched(_ event: any RPCEvent) {
        guard let pushed = event as? any Pushed else { return }
        func open<E: Pushed>(_ pushed: E) { land(pushed) }
        open(pushed)
    }

    /// Stores a project or workspace as it is now, so the lists follow the daemon's records without reading them again.
    func record<R: Revised & Equatable>(_ item: R, in list: ReferenceWritableKeyPath<AppModel, [R]>) {
        recordEvents[item.id, default: 0] += 1
        if let index = self[keyPath: list].firstIndex(where: { $0.id == item.id }) {
            let old = self[keyPath: list][index]
            if old != item, !item.isOlder(than: old) { self[keyPath: list][index] = item }
        } else {
            self[keyPath: list].append(item)
        }
    }

    /// Removes a project, workspace or session that's gone.
    func removed(_ removedEvent: RemovedEvent) {
        if let id = removedEvent.repo {
            for x in [id] + worktrees.filter({ $0.repoId == id }).map(\.id) { recordEvents[x, default: 0] += 1 }
            arrangement.forget([id] + worktrees.filter { $0.repoId == id }.map(\.id))
            repos.removeAll { $0.id == id }
            worktrees.removeAll { $0.repoId == id }
        }
        if let id = removedEvent.worktree {
            recordEvents[id, default: 0] += 1
            arrangement.forget([id])
            worktrees.removeAll { $0.id == id }
        }
        if let id = removedEvent.session { removed(session: id) }
    }
}

/// The latest pushed values of one kind, by key (`AppModel.latest`).
@MainActor
@Observable
package final class Latest<E: Pushed> {
    /// Written only by `AppModel.land`. A built-in only reads it.
    package internal(set) var byKey: [String: E] = [:]
}

/// Watches one key of a topic at a time, such as the workspace a panel shows. Setting `key` watches it, and nil stops
/// watching, as does the owner going away.
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
