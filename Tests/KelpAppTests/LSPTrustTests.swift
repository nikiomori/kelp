import AppKit
import Core
import Foundation
import Testing
import WorkbenchKit
import os

@testable import BuiltinActivity
@testable import BuiltinAgents
@testable import BuiltinBrowser
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinIssues
@testable import KelpApp
@testable import KelpKit

/// Language servers run a project's own code (build scripts, Package.swift, its node_modules' TypeScript): none starts
/// in a project until the user trusts it, and the tabs that wanted one start it then.
extension OneAtATime {
    @Test func languageServersWaitForTheUsersTrustInTheProject() async throws {
        _ = testHome
        _ = NSApplication.shared   // the question is a banner in the window
        let root = "/tmp/cloned-\(UUID().uuidString.prefix(6))"
        let app = AppModel(builtins: Builtins.all), lsp = LSPManager.of(app)
        var started = 0
        #expect(!lsp.whenTrusted(root) { started += 1 })   // asks; nothing starts
        #expect(!lsp.whenTrusted(root) { started += 1 })   // a second tab of it waits too (asked once)
        #expect(await !lsp.open(root: root, path: root + "/main.rs", text: "", retry: {}))   // no server is given the file
        #expect(started == 0 && !lsp.trusted(root))
        let rust: LanguageSpec? = LanguageSpec(id: "rust", extensions: ["rs"], server: .init(command: "rust-analyzer"))
        #expect(lsp.asks(root, rust))   // its code tabs show the question
        // A language whose only server is optional (JSON's) doesn't make its files ask.
        let json = LanguageSpec(id: "json", extensions: ["json"], server: .init(command: "x", optional: true))
        #expect(!lsp.asks(root, json))
        // Kelp's own languages: no id twice, no file extension claimed by two.
        let all = Languages.all, extensions = all.flatMap(\.extensions)
        #expect(Set(all.map(\.id)).count == all.count && Set(extensions).count == extensions.count)
        lsp.notNow(root)
        #expect(!lsp.asks(root, rust) && lsp.restricts(root, rust))   // put off: "Restricted" alone says it
        #expect(!lsp.askTrust(root, again: true) {})   // Format asks again
        #expect(lsp.asks(root, rust))
        let followed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = lsp.asks(root, rust)
        } onChange: {
            followed.withLock { $0 = true }
        }
        await lsp.trust(root)   // the banner's "Trust and Start"
        #expect(started == 2 && lsp.trusted(root))
        #expect(followed.withLock { $0 } && !lsp.asks(root, rust))   // the bar that asked goes: it stayed, as if nothing was done
        #expect(lsp.summary(root, rust) == nil)   // no server asked for yet: the status bar names none
        #expect(lsp.whenTrusted(root) { started += 1 } && started == 2)   // trusted from now on: no waiting
        #expect(!lsp.trusted(Paths.scratch.path))   // the scratch workspace is asked about like any project: a clone may land there
    }

    /// Settings › Languages: languages of the same servers share a row, a project's own are found from its files, and
    /// a server is what the daemon last said of it, in the project asked about.
    @Test func languagesAreListedWithWhatTheDaemonSaysOfTheirServers() async throws {
        _ = NSApplication.shared
        let rig = try await AppRig()
        defer { rig.done() }
        let rows = LanguageRows.rows(Languages.all)
        let c = try #require(rows.first { $0.languages.contains("c") })
        #expect(c.name == "C, C++, Objective-C, Objective-C++" && c.files.hasPrefix(".c, .h, .cpp"))
        #expect(rows.first { $0.languages == ["python"] }?.servers.map(\.command) == ["pyright-langserver", "ruff"])
        #expect(LanguageRows.matching(rows, "ruff").map(\.name) == ["Python"])
        #expect(LanguageRows.matching(rows, ".tsx").count == 1 && LanguageRows.matching(rows, "nothing").isEmpty)
        let used = LanguageRows.used(Languages.all, in: ["Sources/a.swift", "Dockerfile", "docs/x.md", "web/b.tsx"])
        #expect(used == ["swift", "dockerfile", "typescriptreact"])

        let lsp = LSPManager.of(rig.app), root = "/tmp/languages-\(UUID().uuidString.prefix(6))"
        let gopls = LanguageSpec.Server(command: "gopls"), ruff = LanguageSpec.Server(command: "ruff")
        #expect(lsp.status(gopls, in: root) == .unknown)
        lsp.heard(
            [
                LSPServerState(command: "gopls", installed: true, running: true, files: 2),
                LSPServerState(command: "ruff", installed: false),
                LSPServerState(command: "clangd", installed: true),
                LSPServerState(command: "zls", installed: true, failed: true)
            ], of: root)
        #expect(lsp.status(gopls, in: root) == .running(files: 2) && lsp.status(ruff, in: root) == .missing)
        #expect(lsp.status(.init(command: "zls"), in: root) == .failed)
        #expect(lsp.status(.init(command: "clangd"), in: root) == .installed)
        #expect(lsp.status(.init(command: "clangd"), in: root, asks: true) == .untrusted)   // the project's own, not trusted
        #expect(lsp.status(gopls, in: nil) == .unknown)   // another project's answer isn't this one's
        await lsp.refresh(root)   // the daemon's own word: nothing runs there
        #expect(
            lsp.status(.init(command: "no-such-server"), in: root) == .unknown
                && lsp.status(gopls, in: root) != .running(files: 2))
    }

    /// Only Kelp's own window may record trust (the daemon checks who's asking): refused, the project stays untrusted and
    /// nothing starts. It used to be written without an answer and taken as given.
    @Test func trustTheDaemonRefusesIsntTakenAsGiven() async throws {
        _ = NSApplication.shared
        let rig = try await AppRig()
        defer { rig.done() }
        let me = ProcessInfo.processInfo.environment["KELP_APP_EXECUTABLE"]   // this test runner stands in for the app…
        setenv("KELP_APP_EXECUTABLE", "/nowhere/KelpApp", 1)   // …not now: another copy of Kelp is asking
        defer { if let me { setenv("KELP_APP_EXECUTABLE", me, 1) } }
        let root = "/tmp/refused-\(UUID().uuidString.prefix(6))", app = rig.app, lsp = LSPManager.of(app)
        var started = 0
        _ = lsp.whenTrusted(root) { started += 1 }
        await lsp.trust(root)
        #expect(!lsp.trusted(root) && started == 0)
    }
}
