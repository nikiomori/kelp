import AppKit
import Foundation
import Testing
import Core
import Daemon
import EditorKit
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

/// Settings as the app and everything else share them: a change made in the app lands in settings.json through the
/// daemon, and one made elsewhere (`kelp settings set`, an agent) shows in the app without a restart.
extension OneAtATime {
    @Test func settingsGoBothWaysThroughTheDaemon() async throws {
        _ = testHome
        _ = NSApplication.shared   // the theme applies to NSApp
        let root = URL(fileURLWithPath: "/tmp/kst-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try Daemon(root: root); try d.start(); defer { d.stop() }
        let app = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let cli = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let m = AppModel(builtins: Builtins.all), s = m.settings
        m.client = app; m.listen(app)
        await s.load()

        s.set("editor.autoSave", .bool(true))   // in the app
        let file = root.appendingPathComponent("settings.json")
        func onDisk() -> JSONValue? { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
        for _ in 0..<100 where onDisk()?["editor.autoSave"]?.bool != true { try await Task.sleep(for: .milliseconds(50)) }
        #expect(onDisk()?["editor.autoSave"]?.bool == true)

        _ = try await cli.call("settings.set", .obj(["key": "editor.lsp", "value": false]))   // elsewhere
        for _ in 0..<100 where s.bool("editor.lsp") != false { try await Task.sleep(for: .milliseconds(50)) }
        #expect(s.bool("editor.lsp") == false && s.bool("editor.autoSave") == true)
    }

    @Test func markdownDefaultModeGoesBothWaysThroughTheDaemon() async throws {
        _ = testHome
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/kst-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try Daemon(root: root); try d.start(); defer { d.stop() }
        let app = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let cli = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let m = AppModel(builtins: Builtins.all), s = m.settings
        m.client = app; m.listen(app)
        m.extensions.reload()
        await s.load()

        let editorSection = m.extensions.all.settings.first { $0.id == "editor" }
        let spec = editorSection?.specs.first { $0.key == "markdown.defaultMode" }
        #expect(spec?.type == "enum")
        #expect(spec?.default == "preview")
        #expect(spec?.options == ["preview", "edit", "split"])
        #expect(s.string("markdown.defaultMode") == "preview")

        let testURL = URL(fileURLWithPath: "/tmp/test.md")
        let editor = CodeEditor(text: "# Preview", url: testURL)
        let tabPreview = MarkdownTab(editor: editor, url: testURL, app: m)
        _ = tabPreview.view
        #expect(tabPreview.currentMode == "preview")

        s.set("markdown.defaultMode", .string("split"))   // in the app
        let file = root.appendingPathComponent("settings.json")
        func onDisk() -> JSONValue? { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
        for _ in 0..<100 where onDisk()?["markdown.defaultMode"]?.string != "split" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(onDisk()?["markdown.defaultMode"]?.string == "split")

        let tabSplit = MarkdownTab(editor: editor, url: testURL, app: m)
        _ = tabSplit.view
        #expect(tabSplit.currentMode == "split")

        _ = try await cli.call("settings.set", .obj(["key": "markdown.defaultMode", "value": "edit"]))   // elsewhere
        for _ in 0..<100 where s.string("markdown.defaultMode") != "edit" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(s.string("markdown.defaultMode") == "edit")

        let tabEdit = MarkdownTab(editor: editor, url: testURL, app: m)
        _ = tabEdit.view
        #expect(tabEdit.currentMode == "edit")
    }

    /// A stepper held sends 14 then 15: the daemon's answer to 14 arriving after 15 was shown doesn't put 14 back.
    @Test func anOlderSettingsEchoDoesntUndoANewerChange() async throws {
        _ = NSApplication.shared   // the theme applies to NSApp
        let m = AppModel(builtins: Builtins.all), s = m.settings   // no daemon: its set fails later, on a task of its own: what matters is what's shown meanwhile
        s.set("terminal.fontSize", .int(15))
        s.received(s.values.merging(["terminal.fontSize": .int(14)]) { $1 })   // the echo of the set before it
        #expect(s.values["terminal.fontSize"] == .int(15))
        s.received(s.values.merging(["editor.lsp": .bool(false)]) { $1 })      // other keys still follow the daemon
        #expect(s.values["editor.lsp"] == .bool(false))
    }
}

/// Restart Background Service stops hearing the old connection: its events' reader ends (it used to wait for good, one
/// more task left at each restart).
@MainActor @Test func aConnectionLeftByARestartIsNoLongerHeard() async throws {
    let path = NSTemporaryDirectory() + "kelp-hear-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    let c = try RPCClient(socket: path), m = AppModel(builtins: [])
    m.listen(c)
    c.onEvent?(Repo(id: "r1", name: "one", path: "/one"))
    for _ in 0..<100 where m.repos.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    m.stopHearing(c)
    c.onEvent?(Repo(id: "r2", name: "two", path: "/two"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(m.repos.map(\.id) == ["r1"])
}
