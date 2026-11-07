import AppKit
import Core
import Observation
import os
import WorkbenchKit
import KelpKit

/// The app's side of language servers, which run in the daemon (one per project and server command, shared by every
/// client, stopped once no file is open for it). Which server a file gets comes from the extensions' `languages`; whether
/// a project may run one is the user's say, asked here once per project and checked again by the daemon.
@MainActor @Observable
final class LSPManager {
    /// Server commands already reported missing this launch.
    @ObservationIgnored private var reported: Set<String> = []
    func enabled(_ app: AppModel) -> Bool { app.settings.bool("editor.lsp") != false }

    func language(_ app: AppModel, _ path: String) -> LanguageSpec? { LanguageSpec.find(path, in: app.extensions.all.languages) }

    // Language servers run the project's own code — build scripts and proc macros (rust-analyzer), Package.swift
    // (sourcekit-lsp), the TypeScript in its node_modules — and formatters can (rustup takes the toolchain a repo's
    // rust-toolchain.toml names), so both run only in a project the user trusted for them, as VS Code's Workspace Trust
    // does: a cloned repository's files don't act as the user just by being opened or formatted.

    /// Projects whose language servers may run (the daemon's UI state: one list per KELP_HOME).
    static let trustKey = LSPOpen.trustKey
    /// The scratch workspace too is asked about once: something cloned into it is someone else's code like any other.
    func trusted(_ app: AppModel, _ root: String) -> Bool { app.uiState.strings(Self.trustKey).contains(root) }
    /// The project isn't trusted to run code, and a file of `language` has a language server or a formatter that would.
    func restricts(_ app: AppModel, _ root: String, _ language: LanguageSpec?) -> Bool {
        guard let lang = language else { return false }
        return (lang.server != nil && enabled(app) || lang.format != nil) && !trusted(app, root)
    }
    /// Roots asked about this run, and what starts once the user trusts them (the tabs that wanted a server).
    @ObservationIgnored private var waiting: [String: [@MainActor () -> Void]] = [:]
    /// Projects whose question the user put off (Not Now) until Kelp starts again: their tabs say "Restricted" only.
    private(set) var putOff: Set<String> = []
    func notNow(_ root: String) { putOff.insert(root) }
    /// A code tab's bar asks (`TrustBar`): the project isn't trusted for `language`, and the question wasn't put off.
    func asks(_ app: AppModel, _ root: String, _ language: LanguageSpec?) -> Bool {
        restricts(app, root, language) && !putOff.contains(root)
    }

    /// Language servers on, and `root` trusted; else `start` runs once the user trusts it (`askTrust`).
    func whenTrusted(_ app: AppModel, _ root: String, _ start: @escaping @MainActor () -> Void) -> Bool {
        enabled(app) && askTrust(app, root, start)
    }

    /// True when `root` is trusted to run its own code; else `then` runs once the user trusts it. The question is the
    /// tab's bar (`asks`); `again` (the user asked for it: Format) brings it back after Not Now.
    func askTrust(_ app: AppModel, _ root: String, again: Bool = false, _ then: @escaping @MainActor () -> Void) -> Bool {
        if trusted(app, root) { return true }
        waiting[root, default: []].append(then)
        if again { putOff.remove(root) }
        return false
    }

    /// Recorded by the daemon first (a refusal shows, and nothing starts), then the tabs waiting for it start.
    func trust(_ app: AppModel, _ root: String) async {
        if !trusted(app, root) {
            guard await app.uiState.save(Self.trustKey, .array((app.uiState.strings(Self.trustKey) + [root]).map(JSONValue.string))) else { return }
        }
        (waiting.removeValue(forKey: root) ?? []).forEach { $0() }
    }

    /// Gives a file a tab shows to its server, which the daemon starts when it isn't running. False when there's none: no
    /// server for its language, servers off, or refused — the daemon's reason shows (trust the project, install the server;
    /// `retry` runs once the user trusts it).
    func open(_ app: AppModel, root: String, path: String, text: String, retry: @escaping @MainActor () -> Void) async -> Bool {
        guard enabled(app), let lang = language(app, path), let server = lang.server else { return false }
        await sent()   // after the file's close from a tab just closed, never before it
        do {
            _ = try await app.get(LSPOpen(root: root, path: path, languageId: lang.id, command: server.command, args: server.args, text: text))
            return true
        } catch {
            switch LSPRefusal(error) {
            case .untrusted?: _ = askTrust(app, root, retry)   // the daemon doesn't have it as trusted (another copy of Kelp recorded it)
            case .notInstalled?: reportMissing(app, server)
            case nil: break   // no daemon now: a reconnect opens it again
            }
            return false
        }
    }

    /// The file's whole text, as typed. Encoded and sent off the main thread (5 MB took 140 ms to encode on it), from one
    /// queue, so they stay in order with each other and with the close; one still waiting takes the newer text instead.
    func change(_ app: AppModel, root: String, path: String, text: String) {
        guard let c = app.client else { return }
        let key = root + "\n" + path
        let waiting = changes.withLock { q in defer { q[key] = LSPChange(root: root, path: path, text: text) }; return q[key] != nil }
        guard !waiting else { return }
        outbox.async { [changes] in if let m = changes.withLock({ $0.removeValue(forKey: key) }) { c.notify(m) } }
    }
    func close(_ app: AppModel, root: String, path: String) {
        guard let c = app.client else { return }
        outbox.async { c.notify(LSPClose(root: root, path: path)) }
    }
    private let outbox = DispatchQueue(label: "dev.kelp.lsp-changes")
    private let changes = OSAllocatedUnfairLock<[String: LSPChange]>(initialState: [:])
    /// Once what's queued is on its way.
    func sent() async { await withCheckedContinuation { c in outbox.async { c.resume() } } }

    /// Completions at a 1-based position; none when the server can't say (quietly: they're offered while typing).
    func completion(_ app: AppModel, root: String, path: String, line: Int, column: Int) async -> [CodeCompletion] {
        await app.quiet(LSPCompletion(root: root, path: path, line: line, column: column)) ?? []
    }
    func definition(_ app: AppModel, root: String, path: String, line: Int, column: Int) async -> CodeLocation? {
        await app.quiet(LSPDefinition(root: root, path: path, line: line, column: column)) ?? nil
    }
    func symbol(_ app: AppModel, root: String, path: String, line: Int) async -> String? {
        await app.quiet(LSPSymbol(root: root, path: path, line: line)) ?? nil
    }

    /// Once per command and launch; the button runs the language's `install` in a terminal tab.
    private func reportMissing(_ app: AppModel, _ server: LanguageSpec.Server) {
        guard reported.insert(server.command).inserted else { return }
        let name = server.command
        var install: (String, @MainActor @Sendable () -> Void)?
        if let cmd = server.install {
            install = (String(localized: "Install"), {
                if let w = app.workbench.workspaceId { app.workbench.show(workspace: w) }   // a page on screen gives way to it
                app.workbench.editor?.run(command: cmd, title: String(localized: "Install \(name)"))
            })
        }
        Banner.show(String(localized: "Language server \(name) isn't installed."), action: install)
    }
}

extension AppModel {
    /// Its language servers' side here (one per app).
    var lsp: LSPManager { part { LSPManager() } }
}
