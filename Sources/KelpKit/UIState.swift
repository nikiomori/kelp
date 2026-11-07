import Core
import Foundation

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

    /// Whether the daemon's state was read: until then a key that's missing may only not be known yet (`ExtensionTrust`).
    private(set) var loaded = false

    /// Not read: a banner says why, once; read again quietly 10, 30 and 90 s later while the same daemon is there, and
    /// extensions that waited for it (they run commands) load then. A new connection reads it anyway.
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
