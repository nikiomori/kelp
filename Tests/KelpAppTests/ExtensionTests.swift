import AppKit
import Core
import Foundation
import Testing
import WorkbenchKit

@testable import BuiltinActivity
@testable import BuiltinAgents
@testable import BuiltinBrowser
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinIssues
@testable import KelpApp
@testable import KelpKit

private func folder(_ files: [String: String]) throws -> URL {
    _ = testHome
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("kx-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    for (name, text) in files { try text.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    return d
}

@MainActor @Test func templatesTakeFieldsAndQuoteThem() {
    let item = JSONValue.object(["name": .string("it's"), "n": .int(3), "pr": .object(["id": .int(7)])])
    let actions = ExtActions(AppModel(builtins: Builtins.all))
    #expect(actions.expand("echo ${name}", item: item, quote: false) == "echo it's")
    #expect(actions.expand("echo ${name}", item: item, quote: true) == #"export KELP_V1='it'\''s'; echo "${KELP_V1}""#)   // a variable, not text
    // Exported: a shell the command starts reads it as data too.
    let cmd = actions.expand(#"true ${name}; sh -c 'printf %s "$KELP_V1"'"#, item: item, quote: true)
    let sh = Process(), out = Pipe()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", cmd]
    sh.standardOutput = out
    try? sh.run()
    sh.waitUntilExit()
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "it's")
    #expect(actions.expand("${pr.id}-${n}-${missing}", item: item, quote: false) == "7-3-")
    #expect(actions.expand("no placeholders $ {x", item: item, quote: false) == "no placeholders $ {x")
}

@MainActor @Test func valuesPrintTheWayTheyRead() {
    #expect(ExtActions.text(.double(2)) == "2")
    #expect(ExtActions.text(.double(2.5)) == "2.5")
    #expect(ExtActions.text(.bool(true)) == "true")
    #expect(ExtActions.text(.null) == "")
}

@MainActor @Test func listOutputIsAnArrayOrOneObjectPerLine() {
    #expect(ExtListView.parse(#"[{"a":1},{"a":2}]"#).count == 2)
    #expect(ExtListView.parse("{\"a\":1}\n{\"a\":2}\nnot json\n").count == 2)   // a line that isn't JSON is skipped, not fatal
    #expect(ExtListView.parse("  \n").isEmpty)
}

/// Off by default is the built-in's to say (Activity), not a list the shell keeps of them.
@MainActor @Test func disabledListFallsBackToTheDefaultOnlyWhenUnset() {
    let reg = AppModel(builtins: Builtins.all).extensions
    #expect(reg.disabled(nil) == ["kelp.activity"])
    #expect(reg.disabled(SettingKeys.disabledExtensions.read(.array([.string("a"), .int(1)]))) == ["a"])
    #expect(reg.disabled([]).isEmpty)   // an explicit empty list switches everything on
}

@MainActor @Test func aManifestFolderBecomesContributions() throws {
    let d = try folder([
        "extension.json":
            #"{"id":"t.one","name":"One","contributes":{"commands":[{"title":"Hi","terminal":"echo hi"}],"panels":[{"id":"p","title":"P","web":"p.html"}]}}"#
    ])
    let (info, c) = DeclarativeExtension.load(d, app: AppModel(builtins: Builtins.all))
    #expect(info.id == "t.one" && info.error == nil && info.unavailable == nil)
    #expect(c.commands.map(\.title) == ["Hi"])
    #expect(c.panels.map(\.id) == ["t.one.p"])
}

@MainActor @Test func aBrokenManifestIsReportedNotThrown() throws {
    let d = try folder(["extension.json": #"{"name":"no id"}"#])
    let (info, c) = DeclarativeExtension.load(d, app: AppModel(builtins: Builtins.all))
    #expect(info.error != nil)
    #expect(info.id == d.lastPathComponent)   // still listed, so it can be fixed or removed
    #expect(c.commands.isEmpty && c.panels.isEmpty)
}

@MainActor @Test func missingRequirementKeepsTheExtensionInactive() throws {
    let d = try folder([
        "extension.json":
            #"{"id":"t.req","name":"R","requires":["kelp-no-such-tool"],"contributes":{"commands":[{"title":"X","run":"x"}]}}"#
    ])
    let (info, c) = DeclarativeExtension.load(
        d, tools: ["kelp-no-such-tool": false], app: AppModel(builtins: Builtins.all))
    #expect(info.unavailable?.contains("kelp-no-such-tool") == true)
    #expect(c.commands.isEmpty)
    // Until the daemon has said (it may still be reading the login shell's PATH), a tool counts as there.
    #expect(DeclarativeExtension.load(d, app: AppModel(builtins: Builtins.all)).info.unavailable == nil)
}

@MainActor @Test func aVSCodePackageIsReadForItsIconThemes() throws {
    let d = try folder([
        "package.json":
            #"{"name":"icons","publisher":"me","displayName":"Icons","contributes":{"iconThemes":[{"id":"i","label":"I","path":"./i.json"}]}}"#
    ])
    let (info, c) = DeclarativeExtension.load(d, app: AppModel(builtins: Builtins.all))
    #expect(info.id == "me.icons" && info.name == "Icons")
    #expect(c.iconThemes.map(\.id) == ["i"])
}

/// An action's command takes item fields as variables: a title with $(…) or a newline never runs (all the quoting
/// cases are in WorkbenchKitTests.aValueInAShellTemplateNeverRuns).
extension OneAtATime {
    @Test func aFieldNeverRunsInAnActionsCommand() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }   // the daemon runs it
        let marker = NSTemporaryDirectory() + "kelp-pwned-\(UUID().uuidString.prefix(6))"
        let evil = "a\ntouch \(marker)\n$(touch \(marker)) end"
        let cmd = ExtActions(rig.app).expand(
            #"printf %s "${title}""#, item: .object(["title": .string(evil)]), quote: true)
        let r = await Shell.run(rig.app, cmd, cwd: NSTemporaryDirectory())
        #expect(r.code == 0 && !FileManager.default.fileExists(atPath: marker) && r.stdout == evil)
    }
}

/// A tab's own items in its context menu come from its provider (an agent's, a file's); a tab whose provider adds none
/// gets the shell's alone.
extension OneAtATime {
    @Test func aTabsMenuHasWhatItsProviderAdds() {
        _ = testHome
        _ = NSApplication.shared   // reload applies the theme to NSApp
        let app = AppModel(builtins: Builtins.all)
        app.extensions.reload()
        let area = EditorArea(app: app, workspaceId: "menu-test")
        let agent = area.layout.add("session:s1"), page = area.layout.add(TabURI.file("/tmp/a.html")),
            web = area.layout.add("https://example.com")
        func titles(_ id: String) -> [String] { area.tabMenu(id).items.map { $0.isSeparatorItem ? "-" : $0.title } }
        let splits = ["Split Right", "Split Down", "-", "Close Tab", "Close Other Tabs"]
        #expect(
            titles(agent.id) == ["Rename…", "Hand Off to", "Copy Context", "Changes in Its Last Turn", "Restart", "-"]
                + splits + ["Close Tabs to the Right"])
        let open = WorkspaceActions.installedEditors.isEmpty ? [] : ["Open In"]
        #expect(
            titles(page.id) == ["Send to Agent", "Open Preview to the Side", "-", "Reveal in Finder"] + open + [
                "Copy", "-"
            ] + splits + ["Close Tabs to the Right"])
        #expect(titles(web.id) == splits)   // nothing to its right
    }
}

/// A value in a string another shell runs as code (`sh -c '…'`) stays data there too: that shell expands it from the
/// environment, quoted, instead of reading it as its own code.
@MainActor @Test func aValueInANestedShellStaysData() {
    let item = JSONValue.object(["title": .string("x$(echo PWNED)")])
    let actions = ExtActions(AppModel(builtins: Builtins.all))
    let shapes = [
        #"sh -c 'printf %s ${title}'"#, #"bash -lc 'printf %s ${title}'"#, #"eval 'printf %s ${title}'"#,
        #"/bin/sh -c 'printf %s ${title}'"#, #"env bash -c 'printf %s ${title}'"#, #"sh -c "printf %s ${title}""#,
        #"/bin/bash -c "printf %s ${title}""#, "sh <<EOF\nprintf %s ${title}\nEOF",
        "cat <<EOF | sh\nprintf %s ${title}\nEOF",
        #"ssh -o x=y host 'printf %s ${title}'"#, #"ssh host "printf %s ${title}""#, #"ssh host printf %s ${title}"#,
        #"ssh -o x=y host 'cd /' \; printf %s ${title}"#,
        #"printf %s "$KELP_title""#, #"sh -c 'printf %s "$KELP_title"'"#,
        #"python3 -c 'import os; print(os.environ["KELP_title"], end="")'"#
    ]
    for template in shapes {
        let sh = Process(), out = Pipe()
        // ssh is a stand-in that joins the words after the host into one command line for sh, as ssh does for a host.
        let shim = "ssh() { [ \"$1\" = -o ] && shift 2; shift; sh -c \"$*\"; }; "
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-c", shim + actions.expand(template, item: item, quote: true)]
        sh.standardOutput = out
        try? sh.run()
        sh.waitUntilExit()
        #expect(
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "x$(echo PWNED)",
            "\(template)")
    }
    // Bare after `sh -c` or `eval`, the value is the script's one word, not its code.
    let script = JSONValue.object(["title": .string("echo PWNED")])
    for template in ["sh -c ${title}", "eval ${title}"] {
        let sh = Process(), out = Pipe()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-c", actions.expand(template, item: script, quote: true)]
        sh.standardOutput = out
        sh.standardError = Pipe()
        try? sh.run()
        sh.waitUntilExit()
        #expect(
            !String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("PWNED"),
            "\(template)")
    }
    // An ordinary single-quoted string still reads the value as text in it.
    #expect(
        actions.expand("echo 'Issue: ${title}'", item: item, quote: true).hasSuffix(#"echo 'Issue: '"${KELP_V1}"''"#))
}

/// A hidden terminal lets go of its surface once two others were shown after it and it was hidden a while; the one on
/// screen and files stay built.
@MainActor @Test func terminalsHiddenLongestAreReleased() {
    final class Fake: TabContent {
        let uri: String
        let view = NSView()
        var title: String { uri }
        var icon: NSImage? { nil }
        init(_ uri: String) { self.uri = uri }
        func focus() {}
    }
    let area = EditorArea(app: AppModel(builtins: Builtins.all), workspaceId: "release-test")
    let file = area.layout.add(TabURI.file("/tmp/a.txt"))
    area.contents[file.id] = Fake(file.uri)
    area.noteShown(file.id)
    let tabs = (1...4).map { area.layout.add("session:s\($0)") }
    for t in tabs {
        area.contents[t.id] = Fake(t.uri)
        if let g = area.layout.group(of: t.id) { area.layout.groups[g]?.selected = t.id }
        area.noteShown(t.id)
    }
    #expect(area.contents[tabs[0].id] != nil)   // a quick look at the others: its scrollback stays whole
    area.noteShown(nil, now: Date().addingTimeInterval(EditorArea.releaseAfter + 1))
    #expect(area.contents[tabs[0].id] == nil && area.contents[tabs[1].id] != nil && area.contents[tabs[3].id] != nil)
    #expect(area.contents[file.id] != nil)
}

/// An extension that runs a command, made before Kelp asked (`ExtensionTrust.askedSince`) or now.
@MainActor private func commandExtension(old: Bool) throws -> URL {
    let d = try folder([
        "extension.json": #"{"id":"t.trust","name":"T","contributes":{"commands":[{"title":"Hi","run":"./hi.sh"}]}}"#,
        "hi.sh": "echo hi"
    ])
    if old {
        try FileManager.default.setAttributes(
            [.creationDate: ExtensionTrust.askedSince.addingTimeInterval(-86_400)], ofItemAtPath: d.path)
    }
    return d
}

/// What was installed before Kelp asked is allowed as it is; once one changes (an agent edits its script), its commands
/// aren't loaded until it's allowed again.
extension OneAtATime {
    @Test func aChangedExtensionWaitsToBeAllowed() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        rig.app.connected = true
        let d = try commandExtension(old: true)
        let adoptedUnknown = await ExtensionTrust.adopt([d], rig.app)
        #expect(ExtensionTrust.waits(d, rig.app) && !adoptedUnknown)   // what was allowed isn't known yet
        await rig.app.uiState.load()
        #expect(ExtensionTrust.waits(d, rig.app))   // nothing recorded yet: nothing allowed
        #expect(await ExtensionTrust.adopt([d], rig.app))
        #expect(
            !ExtensionTrust.waits(d, rig.app)
                && DeclarativeExtension.load(d, app: rig.app).contributions.commands.count == 1)
        try "rm -rf ~".write(to: d.appendingPathComponent("hi.sh"), atomically: true, encoding: .utf8)
        let (info, c) = DeclarativeExtension.load(d, app: rig.app)
        #expect(info.waitsToBeAllowed && c.commands.isEmpty)
        #expect(await ExtensionTrust.allow([d], rig.app))
        #expect(!ExtensionTrust.waits(d, rig.app))
    }

    /// The first look adopts what was there before Kelp asked, once: one made since waits, and so does an old one that
    /// turns up after (copied in, or written by an agent with its dates set back).
    @Test func extensionsFromBeforeAskingAreAdoptedOnce() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        rig.app.connected = true
        await rig.app.uiState.load()
        let old = try commandExtension(old: true), new = try commandExtension(old: false)
        #expect(await ExtensionTrust.adopt([old, new], rig.app))
        #expect(!ExtensionTrust.waits(old, rig.app) && ExtensionTrust.waits(new, rig.app))
        let later = try commandExtension(old: true)
        #expect(!(await ExtensionTrust.adopt([old, new, later], rig.app)))
        #expect(ExtensionTrust.waits(later, rig.app) && ExtensionTrust.waits(new, rig.app))
    }
}

/// The app's commands an agent may run (`UICommand.forAgents`) are commands the app has: a renamed one would leave a
/// stale name behind and its new one closed. The window's picture and an extensions reload the app answers itself.
@MainActor @Test func theCommandsAgentsMayRunExist() {
    _ = testHome
    _ = NSApplication.shared
    let app = AppModel(builtins: Builtins.all)
    app.extensions.reload()
    let have = Set(app.extensions.all.commands.map(\.id))
    #expect(UICommand.forAgents.subtracting(have).subtracting(["window.shot", "extensions.reload"]) == [])
}
