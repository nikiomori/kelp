import AppKit
import Core
import DesignKit
import KelpKit
import Observation
import WorkbenchKit
import os

/// The app's side of language servers, which run in the daemon (one per project and server command, shared by every
/// client, stopped once no file is open for it). Which servers a file gets comes from the extensions' `languages`; whether
/// a project may run one is the user's say, asked here once per project and checked again by the daemon.
@MainActor @Observable
final class LSPManager {
    /// The app's language servers' side (one per app).
    static func of(_ app: AppModel) -> LSPManager { app.part { LSPManager(app) } }
    /// The app it belongs to: one of its parts, so it lives as long.
    @ObservationIgnored unowned let app: AppModel
    private init(_ app: AppModel) { self.app = app }
    /// Server commands already reported missing this launch.
    @ObservationIgnored private var reported: Set<String> = []
    func enabled() -> Bool { app.settings[SettingKeys.lsp] }

    func language(_ path: String) -> LanguageSpec? {
        LanguageSpec.find(path, in: app.extensions.all.languages)
    }

    // Language servers run the project's own code — build scripts and proc macros (rust-analyzer), Package.swift
    // (sourcekit-lsp), the TypeScript in its node_modules — and formatters can (rustup takes the toolchain a repo's
    // rust-toolchain.toml names), so both run only in a project the user trusted for them, as VS Code's Workspace Trust
    // does: a cloned repository's files don't act as the user just by being opened or formatted.

    /// Projects whose language servers may run (the daemon's UI state: one list per KELP_HOME).
    static let trustKey = LSPOpen.trustKey
    /// The scratch workspace too is asked about once: something cloned into it is someone else's code like any other.
    func trusted(_ root: String) -> Bool {
        justTrusted.contains(root) || app.uiState.strings(Self.trustKey).contains(root)
    }
    /// Trusted this run: what a tab's bar and its "Restricted" follow (`UIState` isn't observed).
    private var justTrusted: Set<String> = []
    /// The project isn't trusted to run code, and a file of `language` has a language server or a formatter that would.
    func restricts(_ root: String, _ language: LanguageSpec?) -> Bool {
        guard let lang = language else { return false }
        // A server that's optional doesn't ask by itself: a JSON file opened in a clone isn't a question.
        let serves = lang.allServers.contains { $0.optional != true }
        return (serves && enabled() || lang.format != nil) && !trusted(root)
    }
    /// Roots asked about this run, and what starts once the user trusts them (the tabs that wanted a server).
    @ObservationIgnored private var waiting: [String: [@MainActor () -> Void]] = [:]
    /// Projects whose question the user put off (Not Now) until Kelp starts again: their tabs say "Restricted" only.
    private(set) var putOff: Set<String> = []
    func notNow(_ root: String) { putOff.insert(root) }
    /// A code tab's bar asks (`TrustBar`): the project isn't trusted for `language`, and the question wasn't put off.
    func asks(_ root: String, _ language: LanguageSpec?) -> Bool {
        restricts(root, language) && !putOff.contains(root)
    }

    /// Language servers on, and `root` trusted; else `start` runs once the user trusts it (`askTrust`).
    func whenTrusted(_ root: String, _ start: @escaping @MainActor () -> Void) -> Bool {
        enabled() && askTrust(root, start)
    }

    /// True when `root` is trusted to run its own code; else `then` runs once the user trusts it. The question is the
    /// tab's bar (`asks`); `again` (the user asked for it: Format) brings it back after Not Now.
    func askTrust(_ root: String, again: Bool = false, _ then: @escaping @MainActor () -> Void) -> Bool {
        if trusted(root) { return true }
        waiting[root, default: []].append(then)
        if again { putOff.remove(root) }
        return false
    }

    /// Recorded by the daemon first (a refusal shows, and nothing starts), then the tabs waiting for it start.
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

    /// What the daemon said of a server command when a file was last given to it: installed, or not.
    private(set) var installed: [String: Bool] = [:]
    /// What the daemon last said of every server command, by the project asked about ("": none).
    private(set) var states: [String: [String: LSPServerState]] = [:]
    /// Commands whose install was started here and isn't seen done yet.
    private(set) var installing: Set<String> = []
    /// The languages a project has files of, by its folder (`scan`).
    var used: [String: Set<String>] = [:]
    /// Tabs whose file a server that isn't installed would take, by its command and the file: opened again once it is.
    @ObservationIgnored private var absent: [String: [String: @MainActor () -> Void]] = [:]

    /// The daemon's word on the servers: one that has come since a tab asked for it gets that tab's file.
    func heard(_ found: [LSPServerState], of root: String?) {
        states[root ?? ""] = Dictionary(found.map { ($0.command, $0) }, uniquingKeysWith: { first, _ in first })
        for state in found where state.installed {
            installing.remove(state.command)
            if installed[state.command] == false { installed[state.command] = nil }
            (absent.removeValue(forKey: state.command) ?? [:]).values.forEach { $0() }
        }
    }
    func gaveUp(on command: String) { installing.remove(command) }

    /// What a file's status bar says of its servers: those that took the file, by name, or that none is installed.
    /// `missing`: one the language needs isn't. Nil while there's nothing to say (none, servers off, not trusted yet).
    func summary(_ root: String, _ language: LanguageSpec?) -> ServerSummary? {
        guard enabled(), let all = language?.allServers, trusted(root) else { return nil }
        let up = all.filter { installed[$0.command] == true }.map(Self.name)
        let absent = all.filter { installed[$0.command] == false }
        guard !up.isEmpty || !absent.isEmpty else { return nil }
        return ServerSummary(
            title: up.isEmpty ? String(localized: "No Language Server") : up.joined(separator: ", "),
            missing: absent.contains { $0.optional != true })
    }

    /// Gives a file a tab shows to its servers, which the daemon starts when they aren't running. False when there's
    /// none: no server for its language, servers off, or refused — the daemon's reason shows (trust the project, install
    /// the server; `retry` runs once the user trusts it).
    func open(root: String, path: String, text: String, retry: @escaping @MainActor () -> Void) async
        -> Bool
    {
        guard enabled(), let lang = language(path), !lang.allServers.isEmpty else { return false }
        await sent()   // after the file's close from a tab just closed, never before it
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
                case .untrusted?:   // the daemon doesn't have it as trusted (another copy of Kelp recorded it)
                    _ = askTrust(root, retry)
                    return false
                case .notInstalled?:
                    installed[server.command] = false
                    absent[server.command, default: [:]][path] = retry
                    if server.optional != true { reportMissing(server) }
                case nil: break   // no daemon now: a reconnect opens it again
                }
            }
        }
        return opened
    }

    /// The file's whole text, as typed. Encoded and sent off the main thread (5 MB took 140 ms to encode on it), from one
    /// queue, so they stay in order with each other and with the close; one still waiting takes the newer text instead.
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
    /// Once what's queued is on its way.
    func sent() async { await withCheckedContinuation { c in outbox.async { c.resume() } } }

    /// Completions at a 1-based position; none when the server can't say (quietly: they're offered while typing).
    func completion(root: String, path: String, line: Int, column: Int) async -> [CodeCompletion] {
        await app.quiet(LSPCompletion(root: root, path: path, line: line, column: column)) ?? []
    }
    func definition(root: String, path: String, line: Int, column: Int) async -> CodeLocation? {
        await app.quiet(LSPDefinition(root: root, path: path, line: line, column: column)) ?? nil
    }
    func symbol(root: String, path: String, line: Int) async -> String? {
        await app.quiet(LSPSymbol(root: root, path: path, line: line)) ?? nil
    }

    /// Once per command and launch; the button runs the language's `install` in a terminal tab.
    private func reportMissing(_ server: LanguageSpec.Server) {
        guard reported.insert(server.command).inserted else { return }
        let install = server.install.map { _ in
            (String(localized: "Install"), { @MainActor @Sendable [weak self] in self?.install(server) ?? () })
        }
        Banner.show(String(localized: "Language server \(server.command) isn't installed."), action: install)
    }

    /// The language's `install` for it, in a terminal tab.
    func install(_ server: LanguageSpec.Server) {
        guard let cmd = server.install else { return }
        if let workspace = app.workbench.workspaceId { app.workbench.show(workspace: workspace) }   // a page on screen gives way to it
        let command = server.command, app = app
        installing.insert(command)
        app.workbench.starter?.run(command: cmd, title: String(localized: "Install \(command)")) { [weak self] made in
            // Its terminal's session ending is the install ending.
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
    var title: String, missing: Bool
}

extension LSPManager {
    /// What a server is called: its program, not the `xcrun` that finds it.
    static func name(_ server: LanguageSpec.Server) -> String {
        server.command == "xcrun" ? server.args?.first ?? server.command : server.command
    }
}
