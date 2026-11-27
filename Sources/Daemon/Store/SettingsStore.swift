import Core
import Foundation
import os

/// `settings.json` in the Kelp home: one flat object with dotted keys (VS Code style).
/// Hand edits are picked up by `reloadIfChanged`. A file that doesn't parse is ignored and the last good settings stay,
/// even when it broke while Kelp wasn't running (`lastGood`), because extensions turned off mustn't start again because
/// of a comma.
final class SettingsStore: Sendable {
    let url: URL
    /// The settings and the file's date as last read or written. The lock is held only to copy them, because the ticker
    /// reads settings twice a second and must not wait on a disk.
    private let state = OSAllocatedUnfairLock<(values: [String: JSONValue], mtime: Date?)>(initialState: ([:], nil))
    /// Takes the file's reads and writes one at a time (a set's read, merge and write stay together).
    let file = NSLock()
    private var lastGood: URL { url.deletingLastPathComponent().appendingPathComponent("settings.last-good.json") }
    /// Runs in `set` between the merge and the look that the file didn't change meanwhile: a test saves a hand edit
    /// there, as an editor might.
    private let merged: @Sendable () -> Void

    init(root: URL, merged: @escaping @Sendable () -> Void = {}) {
        url = root.appendingPathComponent("settings.json")
        self.merged = merged
        if FileManager.default.fileExists(atPath: url.path) {
            // Upgrade only a file that parsed, because a broken one is the user's and is not to be written over.
            if reloadIfChanged(), let upgraded = Self.upgraded(values) {
                file.withLock { _ = Log.store.attempt("upgrading settings.json") { try write(upgraded) } }
            }
            return
        }
        file.withLock { _ = Log.store.attempt("writing a new settings.json") { try write([:]) } }
    }

    var values: [String: JSONValue] { state.withLock { $0 }.values }
    var all: JSONValue { .object(values) }
    subscript(key: String) -> JSONValue? { state.withLock { $0 }.values[key] }
    func number(_ key: String) -> Double? { self[key]?.number }
    /// A declared setting: its value in settings.json, else its default.
    subscript<Value>(_ setting: Setting<Value>) -> Value { setting.read(self[setting.key]) }

    /// Sets `key` and returns all the settings. nil or .null removes the key.
    func set(_ key: String, _ value: JSONValue?) throws -> [String: JSONValue] {
        try file.withLock {
            // A hand edit saved before this is merged, not overwritten. A file that doesn't parse is the user's work in
            // progress, so nothing is written over it. A file saved while this merged (an editor's save) is read again.
            for _ in 0..<3 {
                let seen = modified()
                var values = self.values
                if let data = Data(contentsIfAny: url) {
                    guard case .object(let onDisk)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                        throw RPCError.invalidParams(
                            "settings.json has an error, so the change wasn't saved. Fix the file (or remove it) and try again."
                        )
                    }
                    values = onDisk
                }
                values[key] = value == .null ? nil : value
                // Limit: an editor's save between this look and the write's rename (encoding and writing the file,
                // well under a millisecond) is written over, and the last good copy then holds Kelp's, not the hand
                // edit. Editors don't lock the file, so there is nothing to wait on that would close it.
                merged()
                guard modified() == seen else { continue }
                try write(values)
                return values
            }
            throw RPCError.invalidParams("settings.json keeps changing, so the change wasn't saved. Try again.")
        }
    }

    /// Returns true when the file changed on disk and parsed. It waits until a set that is writing has finished, so a
    /// hand edit saved meanwhile is read then (no later event may come to read it).
    func reloadIfChanged() -> Bool {
        file.lock()
        defer { file.unlock() }
        let mtime = modified()
        guard mtime != state.withLock({ $0.mtime }) else { return false }
        let read = Self.read(url), onDisk = read?.values
        if let read, onDisk != state.withLock({ $0.values }) { remember(read.data) }
        // When nothing was read yet (a daemon starting with a broken file), there are no settings to keep, so the last
        // good copy is used.
        let kept = onDisk == nil && state.withLock({ $0.values.isEmpty }) ? Self.read(lastGood)?.values : nil
        if kept != nil { Log.store.fault("settings.json doesn't parse: running on the last settings that did") }
        state.withLock { st in
            st.mtime = mtime
            if let loaded = onDisk ?? kept { st.values = loaded }
        }
        return onDisk != nil
    }

    /// Converts what older Kelps wrote into today's settings; nil when there's nothing to change. The artifacts switch
    /// and `artifacts.where` became one choice: switched off is "off", Claude Code's pages kept on this Mac is "all".
    static func upgraded(_ values: [String: JSONValue]) -> [String: JSONValue]? {
        let key = SettingKeys.skillArtifacts.key, place = "artifacts.where"
        var was: Bool?
        if case .bool(let on)? = values[key] { was = on }
        guard was != nil || values[place] != nil else { return nil }
        var out = values
        if was == false {
            out[key] = "off"
        } else if values[place] == "local" {
            out[key] = "all"
        } else if was == true {
            out[key] = nil   // the default
        }
        out[place] = nil
        return out
    }

    private static func read(_ file: URL) -> (data: Data, values: [String: JSONValue])? {
        guard let data = Data(contentsIfAny: file),
            case .object(let values)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return (data, values)
    }

    private func remember(_ data: Data) {
        Log.store.attempt("keeping the last good settings") { try data.write(to: lastGood, options: .atomic) }
    }

    /// The modification date of the file a symlink points at, because the link's own date never changes on an edit.
    private func modified() -> Date? { FileManager.default.modified(url.path) }

    /// Writes the settings while holding `file`. The values in memory change only once they're on disk.
    private func write(_ values: [String: JSONValue]) throws {
        // Writes to where a symlink points (settings.json kept in a dotfiles repo), because an atomic write would
        // replace the link itself.
        let data = try JSONEncoder.pretty.encode(JSONValue.object(values)) + Data("\n".utf8)
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
        remember(data)
        let mtime = modified()   // our own write isn't a hand edit
        state.withLock { $0 = (values, mtime) }
    }
}

/// Tells clients the settings (`event.settings`) one change after another, each with the settings as they are when its
/// turn comes. So two sets close together can't announce themselves the wrong way round (the app takes each event as
/// the whole of the settings). Keep Mac Awake follows at once.
final class SettingsEvents: Sendable {
    let store: SettingsStore
    private let clients: Clients
    /// What else follows each change, after the clients hear it (Keep Mac Awake, the phone).
    private let followed: @Sendable () -> Void
    private let queue = DispatchQueue(label: "kelp.settings-events")

    init(store: SettingsStore, clients: Clients, followed: @escaping @Sendable () -> Void) {
        self.store = store
        self.clients = clients
        self.followed = followed
    }

    func changed() { queue.async(execute: announce) }

    /// Sends a set's event before its reply. The app stops holding a key back at the reply, so an event after the reply
    /// would put an older value back for the next ⌘+ to count from. Never call this from `queue`, where the file watch
    /// delivers.
    func changedBeforeReply() { queue.sync(execute: announce) }

    private var announce: @Sendable () -> Void {
        { [self] in
            clients.notify(SettingsEvent(settings: store.values))
            followed()
        }
    }

    /// Watches for hand edits of settings.json as they're saved, with FSEvents on the folder of the file it resolves to
    /// (a symlink into someone's dotfiles too).
    /// Limit: a symlink pointed elsewhere later is followed only after the daemon restarts. FSEvents watches a folder
    /// with everything under it, so the home's other writes (history, the store) wake this too; they are coalesced and
    /// dropped by name at once.
    private let watcher = OSAllocatedUnfairLock<FileWatcher?>(initialState: nil)
    func watch() {
        let file = store.url.resolvingSymlinksInPath(), name = "/" + file.lastPathComponent
        let fw = FileWatcher(root: file.deletingLastPathComponent().path, deliver: queue) { [weak self] paths in
            guard let self, paths.contains(where: { $0.hasSuffix(name) }), store.reloadIfChanged() else { return }
            changed()
        }
        if fw == nil { Log.store.error("settings.json isn't watched: hand edits are read when the daemon restarts") }
        let old = watcher.withLock { current in
            defer { current = fw }
            return current
        }
        _ = old   // stopped here, off the lock (its deinit waits on its own queue)
    }
    func stopWatching() {
        let old = watcher.withLock { current in
            defer { current = nil }
            return current
        }
        _ = old
    }
}

extension SettingsGet: Handled {
    static let agents = AgentAccess.reads
    func handle(_ settings: SettingsStore) throws -> [String: JSONValue] { settings.values }
}
extension SettingsSet: Handled {
    static let agents = AgentAccess.acts
    /// A colour dragged or a stepper held sends these quickly: the last one sent is the one that stays.
    static var inOrder: Bool { true }
    /// The settings an agent may not change (through `kelp settings set` or its settings skill):
    /// - where Kelp sends what agents did off this Mac (`phone.*`) and which accounts agents run as (`accounts.*`);
    /// - where extensions come from and which are on (one the user turned off stays off);
    /// - whether terminals are tmux sessions (whose panes are told apart only by who is attached), whether agents hear
    /// from the agents they start, and where every workspace's folder goes;
    /// - the keyboard (`keys`): a key bound to one of the user's commands, such as git.push on ⌘S, would make the user
    /// run it unawares;
    /// - code suggestions (`editor.suggestion*`, `editor.nextEdit`): where the code around the cursor goes, with the
    /// key the user saved for it, and whether kelpd downloads and runs a model.
    static let usersOnly = [
        "phone.", "accounts.", SettingKeys.extensionLibrary.key, SettingKeys.disabledExtensions.key,
        SettingKeys.tmux.key, SettingKeys.childReports.key, SettingKeys.worktreesFolder.key,
        SettingKeys.resumeAfterCrash.key,   // agents going on by themselves after a crash spend the user's plans
        SettingKeys.databaseAccess.key,   // what agents may do to found databases; changing it lifts the Allow
        SettingKeys.databaseTimeout.key,   // how long an agent's read may hold a database
        // how an agent calls the user (waiting, done, failed) and whether the banner stays: not the agent's to quiet
        SettingKeys.onWaiting.key, SettingKeys.onFinish.key, SettingKeys.onError.key, SettingKeys.holdBanners.key,
        // every project's language servers, with their own settings: some name a program they run (a check command)
        SettingKeys.languageServers.key,
        "editor.suggestion", "editor.nextEdit",   // the Files built-in's keys, by prefix as `phone.`
        // the sites where agents act as the user: an agent adding one would let itself in. Limit: as for every key
        // here, the fence is on `settings.set`; a program running as the user can still edit settings.json.
        SettingKeys.agentSites.key
    ]
    var fence: Fence {
        Fence(
            notForAgents: Self.usersOnly.contains { key.hasPrefix($0) } || key == "keys"
                ? "“\(key)” is the user's to set: in Settings, or `kelp settings set` in a terminal of theirs." : nil)
    }
    func handle(_ settings: SettingsEvents) throws -> [String: JSONValue] {
        let all = try settings.store.set(key, value)
        settings.changedBeforeReply()
        return all
    }
}

extension Methods {
    static let settingsMethods: [any Answered.Type] = [SettingsGet.self, SettingsSet.self]
}
