import AppKit
import Foundation
import Testing
import Core
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

/// Language servers run a project's own code (build scripts, Package.swift, its node_modules' TypeScript): none starts
/// in a project until the user trusts it, and the tabs that wanted one start it then.
extension OneAtATime {
    @Test func languageServersWaitForTheUsersTrustInTheProject() async throws {
        _ = testHome
        _ = NSApplication.shared   // the question is a banner in the window
        let root = "/tmp/cloned-\(UUID().uuidString.prefix(6))"
        let app = AppModel(builtins: Builtins.all), lsp = app.lsp
        var started = 0
        #expect(!lsp.whenTrusted(app, root) { started += 1 })        // asks; nothing starts
        #expect(!lsp.whenTrusted(app, root) { started += 1 })        // a second tab of it waits too (asked once)
        #expect(await !lsp.open(app, root: root, path: root + "/main.rs", text: "", retry: {}))   // no server is given the file
        #expect(started == 0 && !lsp.trusted(app, root))
        await lsp.trust(app, root)                                    // the banner's "Trust and Start"
        #expect(started == 2 && lsp.trusted(app, root))
        #expect(lsp.whenTrusted(app, root) { started += 1 } && started == 2)   // trusted from now on: no waiting
        #expect(!lsp.trusted(app, Paths.scratch.path))   // the scratch workspace is asked about like any project: a clone may land there
    }

    /// Only Kelp's own window may record trust (the daemon checks who's asking): refused, the project stays untrusted and
    /// nothing starts. It used to be written without an answer and taken as given.
    @Test func trustTheDaemonRefusesIsntTakenAsGiven() async throws {
        _ = NSApplication.shared
        let rig = try await AppRig(); defer { rig.done() }
        let me = ProcessInfo.processInfo.environment["KELP_APP_EXECUTABLE"]   // this test runner stands in for the app…
        setenv("KELP_APP_EXECUTABLE", "/nowhere/KelpApp", 1)                   // …not now: another copy of Kelp is asking
        defer { if let me { setenv("KELP_APP_EXECUTABLE", me, 1) } }
        let root = "/tmp/refused-\(UUID().uuidString.prefix(6))", app = rig.app, lsp = app.lsp
        var started = 0
        _ = lsp.whenTrusted(app, root) { started += 1 }
        await lsp.trust(app, root)
        #expect(!lsp.trusted(app, root) && started == 0)
    }
}
