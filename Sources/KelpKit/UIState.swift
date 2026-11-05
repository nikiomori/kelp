import Foundation
import Core

/// What the app restores that names the daemon's records — each workspace's layout (`layout/<id>`), the sidebar's
/// order, pins and folds, the last workspace — lives in the daemon's database (`state.*`), like Zed's workspace DB:
/// every KELP_HOME has its own, and removing a workspace takes its layout with it. Per-Mac view preferences stay in
/// UserDefaults. Loaded on connect, before the window restores anything; reads are synchronous, writes go to the daemon.
@MainActor
package final class UIState {
    private let app: AppModel
    private var values: [String: JSONValue] = [:]
    init(app: AppModel) { self.app = app }

    /// nil deletes. Without a daemon it's kept for this run only.
    subscript(key: String) -> JSONValue? {
        get { values[key] }
        set {
            guard values[key] != newValue else { return }
            values[key] = newValue
            app.client?.notify(StateSet(key: key, value: newValue))
        }
    }
    package func strings(_ key: String) -> [String] { values[key]?.array?.compactMap(\.string) ?? [] }
    func all(prefix: String) -> [String: JSONValue] { values.filter { $0.key.hasPrefix(prefix) } }

    /// Written with an answer, for what the daemon may refuse (trust: only Kelp's own window may record it). False, and a
    /// banner saying why, when it did; kept for this run only without a daemon, as the subscript does.
    @discardableResult
    package func save(_ key: String, _ value: JSONValue?) async -> Bool {
        if app.client != nil, await app.call(StateSet(key: key, value: value)) == nil { return false }
        values[key] = value
        return true
    }

    /// A daemon too old for `state.*` leaves it empty (quiet: the window just opens as new).
    func load() async {
        guard case .object(let all)? = await app.quiet(StateGet(prefix: "")) else { return }
        values = all
    }
}
