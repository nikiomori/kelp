import AppKit
import Core
import DesignKit
import KelpKit
import Observation
import WorkbenchKit
import os

/// The app's side of the language servers, which run in the daemon. The daemon runs one server per project and server
/// command, shares it with every client, and stops it once no file is open for it. The extensions' `languages` say
/// which servers a file gets. Whether a project may run them is the user's choice, asked here once per project and
/// checked again by the daemon.
@MainActor @Observable
final class LSPManager {
    /// Returns the app's one `LSPManager`.
    static func of(_ app: AppModel) -> LSPManager { app.part { LSPManager(app) } }
    /// The app this manager belongs to. The manager is one of the app's parts, so it lives as long as the app.
    @ObservationIgnored unowned let app: AppModel
    private init(_ app: AppModel) { self.app = app }
    /// Server commands already reported missing this launch.
    @ObservationIgnored private var reported: Set<String> = []
    func enabled() -> Bool { app.settings[SettingKeys.lsp] }

    func language(_ path: String) -> LanguageSpec? {
        LanguageSpec.find(path, in: app.extensions.all.languages)
    }

    // Language servers run the project's own code: build scripts and proc macros (rust-analyzer), Package.swift
    // (sourcekit-lsp), and the TypeScript in node_modules. Formatters can too, because rustup takes the toolchain that
    // a repo's rust-toolchain.toml names. So both run only in a project the user trusted for them, as with VS Code's
    // Workspace Trust. That way a cloned repository's files don't act as the user just by being opened or formatted.

    /// The key of the list of projects whose language servers may run. The list is in the daemon's UI state, one list
    /// per KELP_HOME.
    static let trustKey = LSPOpen.trustKey
    /// Whether `root` is trusted. The scratch workspace is asked about once too, because something cloned into it is
    /// someone else's code like any other.
    func trusted(_ root: String) -> Bool {
        justTrusted.contains(root) || app.uiState.strings(Self.trustKey).contains(root)
    }
    /// Projects trusted during this run. A tab's trust bar and its "Restricted" label follow this set, because
    /// `UIState` isn't observed.
    private var justTrusted: Set<String> = []
    /// True when the project isn't trusted to run code, and a file of `language` has a language server or a formatter
    /// that would run it.
    func restricts(_ root: String, _ language: LanguageSpec?) -> Bool {
        guard let lang = language else { return false }
        // An optional server doesn't ask by itself, so a JSON file opened in a clone raises no question.
        let serves = lang.allServers.contains { $0.optional != true }
        return (serves && enabled() || lang.format != nil) && !trusted(root)
    }
    /// The projects asked about this run, each with what starts once the user trusts it (the tabs that wanted a
    /// server).
    @ObservationIgnored private var waiting: [String: [@MainActor () -> Void]] = [:]
    /// Projects whose question the user put off with Not Now, until Kelp starts again. Their tabs only say
    /// "Restricted".
    private(set) var putOff: Set<String> = []
    func notNow(_ root: String) { putOff.insert(root) }
    /// True when a code tab's bar (`TrustBar`) should ask, because the project isn't trusted for `language` and the
    /// question wasn't put off.
    func asks(_ root: String, _ language: LanguageSpec?) -> Bool {
        restricts(root, language) && !putOff.contains(root)
    }

    /// True when language servers are on and `root` is trusted. Otherwise, with servers on, `start` runs once the user
    /// trusts the project (`askTrust`).
    func whenTrusted(_ root: String, _ start: @escaping @MainActor () -> Void) -> Bool {
        enabled() && askTrust(root, start)
    }

    /// True when `root` is trusted to run its own code. Otherwise `then` runs once the user trusts it. The tab's bar
    /// asks the question (`asks`). `again`, for an action the user asked for (such as Format), brings the question back
    /// after Not Now.
    func askTrust(_ root: String, again: Bool = false, _ then: @escaping @MainActor () -> Void) -> Bool {
        if trusted(root) { return true }
        waiting[root, default: []].append(then)
        if again { putOff.remove(root) }
        return false
    }

    /// Trusts `root`. The daemon records it first (a refusal shows, and nothing starts), and then the tabs waiting for
    /// it start.
    func trust(_ root: String) async {
        if !trusted(root) {
            guard
                await app.uiState.save(
                    Self.trustKey, .array((app.uiState.strings(Self.trustKey) + [root]).map(JSONValue.string)))
            else { return }
        }
        justTrusted.insert(root)
        (waiting.removeValue(forKey: root) ?? []).forEach { $0() }
    }

    /// Whether each server command is installed, as the daemon said when a file was last given to it.
    private(set) var installed: [String: Bool] = [:]
    /// What the daemon last said of every server command, keyed by the project asked about ("" for no project).
    private(set) var states: [String: [String: LSPServerState]] = [:]
    /// Commands whose install was started here and isn't seen done yet.
    private(set) var installing: Set<String> = []
    /// The languages each project has files of, keyed by the project's folder (`scan`).
    var used: [String: Set<String>] = [:]
    /// Tabs whose file would go to a server that isn't installed, keyed by the server command and the file. Each file
    /// is opened again once its server is installed.
    @ObservationIgnored private var absent: [String: [String: @MainActor () -> Void]] = [:]

    /// Takes what the daemon says of the servers. A server installed since a tab asked for it gets that tab's file.
    func heard(_ found: [LSPServerState], of root: String?) {
        states[root ?? ""] = Dictionary(found.map { ($0.command, $0) }, uniquingKeysWith: { first, _ in first })
        for state in found where state.installed {
            installing.remove(state.command)
            if installed[state.command] == false { installed[state.command] = nil }
            (absent.removeValue(forKey: state.command) ?? [:]).values.forEach { $0() }
        }
    }
    func gaveUp(on command: String) { installing.remove(command) }

    /// Returns what a file's status bar says of its servers: the names of those that took the file, or that none is
    /// installed. `missing` is true when a server the language needs isn't installed, and `stopped` names those the
    /// daemon said ended on their own or didn't start (`LSPServerEvent`). Returns nil while there's nothing to say (no
    /// servers, servers off, or the project not trusted yet).
    func summary(_ root: String, _ language: LanguageSpec?) -> ServerSummary? {
        guard enabled(), let all = language?.allServers, trusted(root) else { return nil }
        let stopped = all.filter {
            app.latest(LSPServerEvent.self, LSPServerEvent.key(root, $0.command))?.failed == true
        }
        // A server that stopped ran here, so it is named even if this tab didn't see it installed.
        let up = all.filter { installed[$0.command] == true || stopped.contains($0) }.map(Self.name)
        let absent = all.filter { installed[$0.command] == false }
        guard !up.isEmpty || !absent.isEmpty else { return nil }
        return ServerSummary(
            title: up.isEmpty ? String(localized: "No Language Server") : up.joined(separator: ", "),
            missing: absent.contains { $0.optional != true }, stopped: stopped.map(Self.name))
    }

    /// Gives the file a tab shows to its servers, which the daemon starts when they aren't running. Returns false when
    /// no server took the file: its language has none, servers are off, or the daemon refused. The daemon's reason then
    /// shows (trust the project, or install the server), and `retry` runs once the user does that.
    func open(root: String, path: String, text: String, retry: @escaping @MainActor () -> Void) async
        -> Bool
    {
        guard enabled(), let lang = language(path), !lang.allServers.isEmpty else { return false }
        await sent()   // so this comes after the close from a tab just closed, never before it
        let own = app.settings[SettingKeys.languageServers]
        var opened = false
        for (order, listed) in lang.allServers.enumerated() {
            let server = listed.with(own[listed.command])
            do {
                _ = try await app.get(
                    LSPOpen(
                        root: root, path: path, languageId: lang.id, command: server.command, args: server.args,
                        text: text, rank: order, options: server.options, settings: server.settings))
                opened = true
                installed[server.command] = true
            } catch {
                switch LSPRefusal(error) {
                case .untrusted?:   // the daemon doesn't have the project as trusted (another Kelp recorded it)
                    _ = askTrust(root, retry)
                    return false
                case .notInstalled?:
                    installed[server.command] = false
                    absent[server.command, default: [:]][path] = retry
                    if server.optional != true { reportMissing(server) }
                case nil: break   // no daemon now; a reconnect opens the file again
                }
            }
        }
        return opened
    }

    /// Sends the file's whole text, as typed, to its servers. It is encoded and sent off the main thread (5 MB took 140
    /// ms to encode on it), from one queue, so changes stay in order with each other and with the close. A change still
    /// waiting in the queue takes the newer text instead.
    func change(root: String, path: String, text: String) {
        let key = root + "\n" + path
        let waiting = changes.withLock { queued in
            defer { queued[key] = LSPChange(root: root, path: path, text: text) }
            return queued[key] != nil
        }
        guard !waiting else { return }
        app.notify(on: outbox) { [changes] in changes.withLock { $0.removeValue(forKey: key) } }
    }
    func close(root: String, path: String) {
        app.notify(on: outbox) { LSPClose(root: root, path: path) }
    }
    private let outbox = DispatchQueue(label: "dev.kelp.lsp-changes")
    private let changes = OSAllocatedUnfairLock<[String: LSPChange]>(initialState: [:])
    /// Returns once everything queued is on its way.
    func sent() async { await withCheckedContinuation { c in outbox.async { c.resume() } } }

    /// Returns completions at a 1-based position, or none when the server can't say. Failures stay quiet, because
    /// completions are offered while typing.
    func completion(root: String, path: String, line: Int, column: Int) async -> [CodeCompletion] {
        await app.quiet(LSPCompletion(root: root, path: path, line: line, column: column)) ?? []
    }
    func definition(root: String, path: String, line: Int, column: Int) async -> CodeLocation? {
        await app.quiet(LSPDefinition(root: root, path: path, line: line, column: column)) ?? nil
    }
    func symbol(root: String, path: String, line: Int) async -> String? {
        await app.quiet(LSPSymbol(root: root, path: path, line: line)) ?? nil
    }

    /// Reports a missing server once per command and launch. The banner's button runs the server's `install` in a
    /// terminal tab.
    private func reportMissing(_ server: LanguageSpec.Server) {
        guard reported.insert(server.command).inserted else { return }
        let install = server.install.map { _ in
            (String(localized: "Install"), { @MainActor @Sendable [weak self] in self?.install(server) ?? () })
        }
        Banner.show(String(localized: "Language server \(server.command) isn’t installed."), action: install)
    }

    /// Runs the server's `install` command in a terminal tab.
    func install(_ server: LanguageSpec.Server) {
        guard let cmd = server.install else { return }
        if let workspace = app.workbench.workspaceId { app.workbench.show(workspace: workspace) }   // a page on screen gives way to it
        let command = server.command, app = app
        installing.insert(command)
        app.workbench.starter?.run(command: cmd, title: String(localized: "Install \(command)")) { [weak self] made in
            // The install ends when the session in its terminal ends.
            track(owner: self, now: false) {
                app.session(made.id).map { $0.status == .exited } ?? true
            } changed: { [weak self] ended in
                if ended { Task { await self?.installEnded(command) } }
            }
        }
    }
}

/// A file's language servers as its status bar names them.
struct ServerSummary: Equatable {
    var title: String, missing: Bool, stopped: [String] = []
}

/// Kept by project and command, and never forgotten: a server stopped stays stopped until the daemon says it runs.
extension LSPServerEvent: Pushed {
    package var key: String { Self.key(root, command) }
    package static var forgottenWith: WatchTopic? { nil }
    static func key(_ root: String, _ command: String) -> String { root + "\n" + command }
}

extension LSPManager {
    /// Returns the server's name: its program, not the `xcrun` that finds it.
    static func name(_ server: LanguageSpec.Server) -> String {
        server.command == "xcrun" ? server.args?.first ?? server.command : server.command
    }
}
