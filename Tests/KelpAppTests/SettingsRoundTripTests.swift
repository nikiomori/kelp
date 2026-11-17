import AppKit
import Core
import Daemon
import EditorKit
import Foundation
import TestSupport
import Testing

@testable import BuiltinActivity
@testable import BuiltinAgents
@testable import BuiltinBrowser
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinIssues
@testable import KelpApp
@testable import KelpKit

/// Settings as the app and everything else share them: a change made in the app lands in settings.json through the
/// daemon, and one made elsewhere (`kelp settings set`, an agent) shows in the app without a restart.
extension OneAtATime {
    @Test func settingsGoBothWaysThroughTheDaemon() async throws {
        _ = testHome
        _ = NSApplication.shared   // the theme applies to NSApp
        let root = URL(fileURLWithPath: "/tmp/kst-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try Daemon(root: root)
        try d.start()
        defer { d.stop() }
        let app = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let cli = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let m = AppModel(builtins: Builtins.all), s = m.settings
        m.daemon.use(app)
        m.listen(app)
        await s.load()

        s.set("editor.autoSave", .bool(true))   // in the app
        let file = root.appendingPathComponent("settings.json")
        func onDisk() -> JSONValue? {
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }
        #expect(try await waitFor(5) { !(onDisk()?["editor.autoSave"]?.bool != true) })
        #expect(onDisk()?["editor.autoSave"]?.bool == true)

        _ = try await cli.call("settings.set", .obj(["key": "editor.lsp", "value": false]))   // elsewhere
        #expect(try await waitFor(5) { !(s.bool("editor.lsp") != false) })
        #expect(s.bool("editor.lsp") == false && s.bool("editor.autoSave") == true)
    }

    /// A Markdown tab opens in the mode the setting names (the setting's way to and from settings.json is the one above).
    @Test func aMarkdownTabOpensInTheModeTheSettingNames() {
        _ = testHome
        _ = NSApplication.shared
        let m = AppModel(builtins: Builtins.all), s = m.settings
        m.extensions.reload()
        let url = URL(fileURLWithPath: "/tmp/test.md"), editor = CodeEditor(text: "# Preview", url: url)
        func opened() -> String {
            let tab = MarkdownTab(editor: editor, url: url, app: m)
            _ = tab.view
            return tab.currentMode
        }
        #expect(opened() == "preview")   // nothing set: the default
        for mode in ["split", "edit"] {
            s.apply(s.values.merging(["markdown.defaultMode": .string(mode)]) { $1 })
            #expect(opened() == mode)
        }
    }

    /// A stepper held sends 14 then 15: the daemon's answer to 14 arriving after 15 was shown doesn't put 14 back.
    @Test func anOlderSettingsEchoDoesntUndoANewerChange() async throws {
        _ = NSApplication.shared   // the theme applies to NSApp
        let m = AppModel(builtins: Builtins.all), s = m.settings   // no daemon: its set fails later, on a task of its own: what matters is what's shown meanwhile
        s.set("terminal.fontSize", .int(15))
        s.received(s.values.merging(["terminal.fontSize": .int(14)]) { $1 })   // the echo of the set before it
        #expect(s.values["terminal.fontSize"] == .int(15))
        s.received(s.values.merging(["editor.lsp": .bool(false)]) { $1 })   // other keys still follow the daemon
        #expect(s.values["editor.lsp"] == .bool(false))
    }
}

/// Restart Background Service stops hearing the old connection: its events' reader ends (it used to wait for good, one
/// more task left at each restart).
@MainActor @Test func aConnectionLeftByARestartIsNoLongerHeard() async throws {
    let path = NSTemporaryDirectory() + "kelp-hear-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    let c = try RPCClient(socket: path), m = AppModel(builtins: [])
    m.listen(c)
    c.onEvent?(Repo(id: "r1", name: "one", path: "/one"))
    #expect(try await waitFor(5) { !(m.repos.isEmpty) })
    m.stopHearing(c)
    c.onEvent?(Repo(id: "r2", name: "two", path: "/two"))
    await mainActorTurns()   // heard, it would be handled by now
    #expect(m.repos.map(\.id) == ["r1"])
}
