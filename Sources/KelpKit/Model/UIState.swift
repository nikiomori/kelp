import Core
import Foundation

/// The UI state the app restores that names the daemon's records. That is each workspace's layout (`layout/<id>`), the
/// sidebar's order, pins and folds, and the last workspace. It lives in the daemon's database (`state.*`), like Zed's
/// workspace DB, so every KELP_HOME has its own, and removing a workspace takes its layout with it. Per-Mac view
/// preferences stay in UserDefaults. The state is loaded on connect, before the window restores anything. Reads are
/// synchronous, and writes go to the daemon.
@MainActor
package final class UIState {
    private let app: AppModel
    private var values: [String: JSONValue] = [:]
    init(app: AppModel) { self.app = app }

    /// Reads or writes a key, and setting nil deletes it. Without a daemon, a write is kept for this run only.
    package subscript(key: String) -> JSONValue? {
        get { values[key] }
        set {
            guard values[key] != newValue else { return }
            values[key] = newValue
            app.notify { StateSet(key: key, value: newValue) }
        }
    }
    package func strings(_ key: String) -> [String] { values[key]?.array?.compactMap(\.string) ?? [] }
    func all(prefix: String) -> [String: JSONValue] { values.filter { $0.key.hasPrefix(prefix) } }

    /// Writes a key and waits for the answer, for values the daemon may refuse (trust, which only Kelp's own window may
    /// record). Returns false, with a banner saying why, when the daemon refused. Without a daemon the value is kept
    /// for this run only, as the subscript does. The value reads back as saved at once, because a second change made
    /// from the old value meanwhile would drop this one. If the daemon refuses, the old value is put back.
    @discardableResult
    package func save(_ key: String, _ value: JSONValue?) async -> Bool {
        let before = values[key]
        values[key] = value
        guard app.hasDaemon, await app.call(StateSet(key: key, value: value)) == nil else { return true }
        if values[key] == value { values[key] = before }   // unless the key was saved again meanwhile
        return false
    }

    /// Whether the daemon's state was read. Until then a missing key may just not be known yet (`ExtensionTrust`).
    private(set) var loaded = false

    /// Reads the daemon's state. When the read fails, a banner says why once, and the state is read again quietly 10,
    /// 30 and 90 s later while the same daemon is there. Extensions that waited for the state (because they run
    /// commands) load then. A new connection reads the state anyway.
    func load(again: Int = 0) async {
        let connection = app.client
        let read = again == 0 ? await app.call(StateGet(prefix: "")) : await app.quiet(StateGet(prefix: ""))
        guard case .object(let all)? = read else {
            guard again < 3 else { return }
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds([10, 30, 90][again])) } catch { return }
                guard let self, !loaded, let connection, app.client === connection else { return }
                await load(again: again + 1)
                if loaded { app.extensions.reload() }
            }
            return
        }
        values = all
        loaded = true
    }
}
