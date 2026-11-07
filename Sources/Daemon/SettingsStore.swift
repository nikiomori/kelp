import Foundation
import os
import Core

/// `settings.json` in the Kelp home: one flat object with dotted keys (VS Code style).
/// Hand edits are picked up by `reloadIfChanged`; a file that doesn't parse is ignored and the last good settings stay,
/// also when it broke while Kelp wasn't running (`lastGood`): extensions turned off mustn't start again because of a comma.
final class SettingsStore: Sendable {
    let url: URL
    /// The settings and the file's date as last read or written, held only to copy them: the ticker reads settings twice
    /// a second, and must not wait on a disk.
    private let state = OSAllocatedUnfairLock<(values: [String: JSONValue], mtime: Date?)>(initialState: ([:], nil))
    /// The file's reads and writes, one at a time (a set's read, merge and write stay together).
    let file = NSLock()
    private var lastGood: URL { url.deletingLastPathComponent().appendingPathComponent("settings.last-good.json") }

    init(root: URL) {
        url = root.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: url.path) { _ = reloadIfChanged(); return }
        file.withLock { _ = Log.store.attempt("writing a new settings.json") { try write([:]) } }
    }

    var values: [String: JSONValue] { state.withLock { $0 }.values }
    var all: JSONValue { .object(values) }
    subscript(key: String) -> JSONValue? { state.withLock { $0 }.values[key] }
    func number(_ key: String) -> Double? { self[key]?.number }

    /// nil or .null removes the key.
    func set(_ key: String, _ value: JSONValue?) throws -> [String: JSONValue] {
        try file.withLock {
            // A hand edit saved before this is merged, not overwritten; a file that doesn't parse is the user's work in
            // progress, so nothing is written over it. One saved while this merged (an editor's save) is read again.
            for _ in 0..<3 {
                let seen = modified()
                var values = self.values
                if let d = try? Data(contentsOf: url) {
                    guard case .object(let onDisk)? = try? JSONDecoder().decode(JSONValue.self, from: d) else {
                        throw RPCError.invalidParams("settings.json has an error, so the change wasn't saved. Fix the file (or remove it) and try again.")
                    }
                    values = onDisk
                }
                values[key] = value == .null ? nil : value
                guard modified() == seen else { continue }
                try write(values)
                return values
            }
            throw RPCError.invalidParams("settings.json keeps changing, so the change wasn't saved. Try again.")
        }
    }

    /// true when the file changed on disk and parsed. After a set writing now has finished: a hand edit saved meanwhile
    /// is read then (no later event may come to read it).
    func reloadIfChanged() -> Bool {
        file.lock()
        defer { file.unlock() }
        let m = modified()
        guard m != state.withLock({ $0.mtime }) else { return false }
        let read = Self.read(url), o = read?.values
        if let read, o != state.withLock({ $0.values }) { remember(read.data) }
        // Nothing read yet, so nothing to stay: the start of a daemon with a broken file.
        let kept = o == nil && state.withLock({ $0.values.isEmpty }) ? Self.read(lastGood)?.values : nil
        if kept != nil { Log.store.fault("settings.json doesn't parse: running on the last settings that did") }
        state.withLock { st in st.mtime = m; if let v = o ?? kept { st.values = v } }
        return o != nil
    }

    private static func read(_ u: URL) -> (data: Data, values: [String: JSONValue])? {
        guard let d = try? Data(contentsOf: u), case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: d) else { return nil }
        return (d, o)
    }

    private func remember(_ d: Data) {
        Log.store.attempt("keeping the last good settings") { try d.write(to: lastGood, options: .atomic) }
    }

    /// The date of the file a symlink points at: the link's own never changes on an edit.
    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    /// Under `file`; the values change only once they're on disk.
    private func write(_ values: [String: JSONValue]) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // To where a symlink points (settings.json kept in a dotfiles repo): an atomic write would replace the link itself.
        let data = try e.encode(JSONValue.object(values)) + Data("\n".utf8)
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
        remember(data)
        let m = modified()   // our own write isn't a hand edit
        state.withLock { $0 = (values, m) }
    }
}

/// The settings as clients hear of them (`event.settings`): as they are when it's their turn, one change after another,
/// so two sets close together can't announce themselves the wrong way round (the app takes each event as the whole of
/// the settings). Keep Mac Awake follows at once.
final class SettingsEvents: Sendable {
    let store: SettingsStore
    private let clients: Clients, sessions: Sessions
    private let queue = DispatchQueue(label: "kelp.settings-events")

    init(store: SettingsStore, clients: Clients, sessions: Sessions) {
        self.store = store
        self.clients = clients
        self.sessions = sessions
    }

    func changed() { queue.async(execute: announce) }

    /// A set's event goes out before its reply: the app stops holding a key back at the reply, and an event after it
    /// would put an older value back, for the next ⌘+ to count from. (Never from `queue`, as the file watch delivers.)
    func changedBeforeReply() { queue.sync(execute: announce) }

    private var announce: @Sendable () -> Void {
        { [self] in
            clients.notify(SettingsEvent(settings: store.values))
            sessions.applyKeepAwake()
        }
    }

    /// Hand edits of settings.json, as they're saved: FSEvents on the folder of the file it resolves to (a symlink into
    /// someone's dotfiles too). Limit: a symlink pointed elsewhere later is followed after the daemon restarts; FSEvents
    /// watches a folder with what's under it, so the home's other writes (history, the store) wake this too, coalesced
    /// and dropped by name at once.
    private let watcher = OSAllocatedUnfairLock<FileWatcher?>(initialState: nil)
    func watch() {
        let file = store.url.resolvingSymlinksInPath(), name = "/" + file.lastPathComponent
        let fw = FileWatcher(root: file.deletingLastPathComponent().path, deliver: queue) { [weak self] paths in
            guard let self, paths.contains(where: { $0.hasSuffix(name) }), store.reloadIfChanged() else { return }
            changed()
        }
        if fw == nil { Log.store.error("settings.json isn't watched: hand edits are read when the daemon restarts") }
        let old = watcher.withLock { w in defer { w = fw }; return w }
        _ = old   // stopped here, off the lock (its deinit waits on its own queue)
    }
    func stopWatching() {
        let old = watcher.withLock { w in defer { w = nil }; return w }
        _ = old
    }
}

extension SettingsGet: Handled { func handle(_ settings: SettingsStore) throws -> [String: JSONValue] { settings.values } }
extension SettingsSet: Handled {
    /// A colour dragged or a stepper held sends these quickly: the last one sent is the one that stays.
    static var inOrder: Bool { true }
    /// What an agent may not set (`kelp settings set`, its settings skill): where Kelp sends what agents did off this Mac
    /// (`phone.*`), whose accounts agents run as (`accounts.*`), where extensions come from and which are on (one the user
    /// turned off stays off), whether terminals are tmux sessions (whose panes are told apart only by who's attached),
    /// whether agents hear from those they start, where every workspace's folder goes; and the keyboard (`keys`: a key on
    /// a command of the user's, git.push on ⌘S, would have them run it unawares).
    static let usersOnly = ["phone.", "accounts.", "extensions.library", "extensions.disabled", "terminal.tmux", "agents.childReports",
                            "worktrees.folder"]
    var notForAgents: String? {
        Self.usersOnly.contains { key.hasPrefix($0) } || key == "keys"
            ? "“\(key)” is the user's to set: in Settings, or `kelp settings set` in a terminal of theirs." : nil
    }
    func handle(_ settings: SettingsEvents) throws -> [String: JSONValue] {
        let all = try settings.store.set(key, value)
        settings.changedBeforeReply()
        return all
    }
}
