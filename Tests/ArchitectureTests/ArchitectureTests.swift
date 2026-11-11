import Foundation
import Testing

// The rules in docs/architecture.md, read from the sources. Each number is a ceiling: when a change brings a count under it,
// lower it to the new count in the same commit, so nothing creeps back. The `try?` ones are exact (lowered or the test fails).
// KelpKit's `package` count is a budget, not a ratchet: it rises with a feature that needs more of the shell, said beside it.

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// The app: its target (main.swift and the list of built-ins), the shell (KelpKit) and the built-ins' modules.
private let appDirs = ["Sources/KelpApp", "Sources/KelpKit", "Sources/Builtins"]

/// Every .swift file under these folders (relative to the repo), with its text.
func sources(_ dirs: [String]) -> [(path: String, text: String)] {
    dirs.flatMap { dir -> [(path: String, text: String)] in
        let base = root.appendingPathComponent(dir)
        let files =
            FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "swift" }.compactMap { u in
            (try? String(contentsOf: u, encoding: .utf8)).map { (dir + u.path.dropFirst(base.path.count), $0) }
        }
    }
}

private func matches(_ pattern: String, in dirs: [String]) throws -> [String] {
    let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    return sources(dirs).flatMap { f in
        re.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)).map { m in
            "\(f.path):\(f.text[..<(Range(m.range, in: f.text)?.lowerBound ?? f.text.startIndex)].filter { $0 == "\n" }.count + 1)"
        }
    }
}

/// The app and the CLI name a method by its `RPCMethod` type: with a string and hand-built params, a renamed field still
/// compiles and only breaks when it runs.
@Test func theAppAndTheCLICallTheDaemonThroughItsTypes() throws {
    let app = try matches(#"\b(call|tryCall|notify)\(\s*""#, in: appDirs)
    let cli = try matches(#"\b(call|tryCall|notify)\(\s*""#, in: ["Sources/kelp"])
    #expect(app.count <= 0, "string-named calls in KelpApp: \(app)")
    #expect(cli.count <= 0, "string-named calls in the kelp CLI: \(cli)")
}

/// One way to the daemon, through AppModel: `call` (a banner), `tryCall` / `get` (the panel's error state) or `quiet`
/// (decorations, which say so). `try?` around a call turned a failure into an empty list; the raw client skipped all of it.
/// AppModel.swift itself is the way, and DaemonLink.swift manages the connection, so they aren't counted.
@Test func daemonErrorsAreNotSwallowed() throws {
    let way = ["Sources/KelpKit/Model/AppModel.swift:", "Sources/KelpKit/Model/DaemonLink.swift:"]
    func outside(_ found: [String]) -> [String] { found.filter { f in !way.contains { f.hasPrefix($0) } } }
    let swallowed = outside(try matches(#"try\? await (?:[^=\n]*\.)?(call|get|tryCall)\("#, in: appDirs))
    let raw = outside(try matches(#"\bclient\??\.(?:call|notify)\(|\bc\??\.call\("#, in: appDirs))
    #expect(swallowed == [], "try? around a call: \(swallowed)")
    #expect(raw == [], "the client called directly: \(raw)")
}

/// The app reads the daemon's records as Core's types: running git, gh, the agents' files and the daemon itself is the
/// daemon's job. (Package.swift enforces it too; this says why when someone adds the dependency back.)
@Test func theAppDoesNotImportTheDaemonsLibraries() {
    let banned = ["Daemon", "GitKit", "Integrations", "AgentData", "LSPKit"]
    let found = sources(appDirs).filter { f in
        banned.contains { f.text.hasPrefix("import \($0)\n") || f.text.contains("\nimport \($0)\n") }
    }
    #expect(found.map(\.path) == [])
}

/// A built-in is a module of its own (`Sources/Builtins/<Feature>`): it reaches the shell only through what KelpKit
/// declares `package` (tabs, panels, commands, `app.workbench`…, never the window, the sidebar or the inspector), and
/// the shell can't name it. The compiler holds that once the targets are wired so: the shell and every built-in depend
/// on no built-in, and only the app's target lists them.
@Test func builtinsAreModulesTheShellCantName() throws {
    let folders = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("Sources/Builtins").path
    ).filter { !$0.hasPrefix(".") }
    let modules = folders.map { "Builtin" + $0 }
    #expect(modules.contains("BuiltinAgents") && modules.contains("BuiltinFiles"), "\(modules)")   // the scan finds them
    let importing = sources(["Sources/KelpKit", "Sources/Builtins"]).filter { f in
        modules.contains { f.text.contains("import \($0)\n") }
    }
    #expect(importing.map(\.path) == [], "a built-in imported by the shell or by another built-in")
    let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
    for line in manifest.split(separator: "\n")
    where line.contains(".target(name: \"KelpKit\"") || line.contains(".target(name: \"Builtin") {
        let own = modules.first { line.contains("name: \"\($0)\"") }
        #expect(!modules.contains { $0 != own && line.contains("\"\($0)\"") }, "depends on a built-in: \(line)")
    }
    // The window's own parts stay the shell's: nothing in them is declared for a built-in to reach.
    let windowParts =
        sources(["Sources/KelpKit/Sidebar", "Sources/KelpKit/Inspector"])
        + sources(["Sources/KelpKit/Shell"]).filter { $0.path.hasSuffix("/MainWindow.swift") }
    #expect(windowParts.filter { codeOnly($0.text).contains("package ") }.map(\.path) == [])
    // What the built-ins may reach of the shell. It goes down when a built-in stops using one (that goes too), and up only
    // with a built-in feature that needs the shell, said beside the number: what the feature does itself stays in its
    // module, and the number counts what the shell had to open, not a goal it's kept under.
    // Every `package` a declaration carries, wherever it stands in it (`private(set) package var`, `override package
    // func`, a one-line extension's members), not only lines that start with one.
    let token = try NSRegularExpression(
        pattern:
            #"\bpackage\s+(?:(?:static|final|override|lazy|nonisolated|convenience|required|init)\b|(?:func|var|let|class|struct|enum|protocol|typealias|subscript|actor)\b|init\b)"#
    )
    let declared = sources(["Sources/KelpKit"]).map { f in
        let code = codeOnly(f.text)
        return token.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }.reduce(0, +)
    // Counted whole since 2026-11-08 (334; the line-start count said 286). Raised only with a reason beside it: +8 for
    // the branch chip's actions (`BranchActions`) and the folder and CI a workspace shows, so Git's sync popover is Git's.
    // +11 for the CI mark on rows and the chip (`FolderCI`, the folders, a page, a panel's role, the menu's choices), so
    // the CI marks are Git's. +13 so the plan limits are the Agents built-in's: each landed reading and the plan notes
    // (`pushed`, `plans`), a notification under the shell's rules and its Continue, and what the foot, the strip and
    // the warnings read of the shell (`PlanNote`, `LimitStop`, mutes, the warning level, the foot's menu, a hand-off).
    // +7 for the sidebar's server cards (`ServerCards`, `ServerRow`, `SidebarRow`), so the servers' headers are Servers'.
    // +17 so the agent strip is the Agents built-in's: started at launch, its Dock menu items (`launched`, `dockMenu`),
    // and what it reads of the shell (the Dock's cells, a session's shown status and permission question, place names,
    // mutes' choices, project icons, an answer from outside the window).
    // +12 so the run menu is Run's (two it needed the strip had made already): the contribution (`ProjectRuns`, `runs`, `WindowBarItem`), the "+" menu's rows
    // (`NewTabChoices.Action`, its keys), what the run code reads of the shell (UIState's subscript, a menu item's image
    // and note, hiding a tab, a tab in the background, the window's content, a screen's name) and which sessions have no
    // tab (`isHidden`); the shell's `ScriptsMenu`, `app.scripts` and `runFile` went.
    // +1 so Source Control marks a file another folder of the project changes too (`sharedFiles`), as the rows do.
    // +1 so an agent tab's menu offers Fork Chat as the row's does (`addFork`).
    // 2026-11-09: what no built-in used went internal (the compiler said which), the plan limits' words moved into Agents
    // (`LimitStop`, `PlanNote`; the shell keeps `PlanWords`, the places they show), and the raw client went (`notify`).
    // 2026-11-09, 368 → 327: a built-in hands its contributions over in one `Contributions(…)` (the vars no built-in
    // reads went internal), reaches the palette through `openQuickly` / `showTmuxSessions` (QuickOpen is the shell's),
    // conforms the pushed kinds only it reads (activity, PRs, files, artifacts, commands), keeps what only it does
    // (`copyWebLink`, `RemoteHost.containing`), and a session's tab menu is `addSessionItems`' too.
    // 327 → 299: the generic parts with no shell state moved to DesignKit, public (closure targets, `Debounce`, `pin` /
    // `stacked`, `track`, the menu item helpers, `NSImage.symbol` with its glyphs, awaited sheets, `shortAgo` / `bytes`).
    // +1 so a discard and its Undo are one flow for the diff and Source Control (Git) and a file's change bars
    // (Files): `discardWithUndo`.
    // +2 so a built-in's skill for agents is its own (`SkillSpec`): the guides to machines, databases, the browser,
    // artifacts, terminals and child agents left the shell.
    // +6 so the settings window names no built-in's section: a setting's choices are its own (`SettingChoices`), and the
    // terminal's and the editor's samples are the built-ins' to show (`SettingSamples`: the terminal, the editor, a cursor).
    // +6 so a row's kind and look are enums a built-in names (`SettingType`, `SettingLook`, with the decoding and encoding
    // that read a manifest's unknown one as `unknown`).
    // +8 for what several built-ins did each their own way: a tab's SwiftUI view (`HostedTab`), and a served page's
    // reach, copy, stop and forward (`PageActions`: Run, Browser and Servers).
    // +1 so a merged PR's switch in a project's menu is Git's own row item (`rowMenu`), with the folder the row stands
    // for (`gitFolder(project:)`).
    // 301 → 296: a built-in starts sessions through `SessionStarter` and acts on the tabs on screen through Workbench
    // (`starter`, `focusedContent`, `split`…); the editor area isn't the built-ins' any more.
    // +1, nothing new: `focusedTab` is computed from the layout now, and its `package internal(set)` wasn't counted.
    // +5: the Dock strip's card types the quick replies the row card and the banner do (`QuickReply`, Continue, `fits`).
    // +1: its tile mutes a chat as the chat's row does (`Mutes.mute`).
    // +4: its tile shows a workspace's CI as the sidebar's row does (`CIRunLook.mark`, `FolderCI`'s `row`, `line`,
    // `open`).
    // +1: the browser's pointer wears the agent's colour, as its tile in the catalog does (`AgentCatalog.color`).
    #expect(declared <= 330, "\(declared) package declarations in KelpKit")
    #expect(declared >= 330, "fewer now (\(declared)): lower the ceiling")
}

/// What the shell asks of every tab stays short: a question only one kind of tab answers is that tab's own (its provider's
/// menu, its badge), not one more requirement every tab carries a "not this one" default for.
@Test func tabContentAsksLittle() throws {
    let text = try #require(sources(["Sources/KelpKit/Editor"]).first { $0.path.hasSuffix("/TabContent.swift") }?.text)
    let start = try #require(text.range(of: "protocol TabContent: AnyObject {"))
    let end = try #require(text.range(of: "\n}", range: start.upperBound..<text.endIndex))
    let body = text[start.upperBound..<end.lowerBound]
    let declaration = try NSRegularExpression(
        pattern: #"^\s*(?:@\w+\s+)*(?:static\s+|mutating\s+)*(?:var|func|subscript|init|associatedtype)\b"#)
    let requirements = codeOnly(String(body)).split(separator: "\n").filter { l in
        let t = String(l)
        return declaration.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }
    #expect(requirements.count <= 14, "\(requirements)")
    #expect(requirements.count >= 14, "fewer now: lower the ceiling")
}

/// A Swift file's code without its comments and string literals (their words could be any name); lines stay where they were.
func codeOnly(_ s: String) -> String {
    var out = "", i = s.startIndex
    func skip(to end: String.Index) {
        out += s[i..<end].filter { $0 == "\n" }
        i = end
    }
    while i < s.endIndex {
        let rest = s[i...]
        if rest.hasPrefix("//") {
            skip(to: rest.firstIndex(of: "\n") ?? s.endIndex)
        } else if rest.hasPrefix("/*") {
            skip(to: rest.range(of: "*/")?.upperBound ?? s.endIndex)
        } else if rest.hasPrefix("\"\"\"") {
            skip(to: rest.dropFirst(3).range(of: "\"\"\"")?.upperBound ?? s.endIndex)
        } else if rest.first == "\"" {
            var j = rest.index(after: rest.startIndex)
            while j < s.endIndex, s[j] != "\"", s[j] != "\n" {
                j = s.index(j, offsetBy: s[j] == "\\" && s.index(after: j) < s.endIndex ? 2 : 1)
            }
            skip(to: j < s.endIndex && s[j] == "\"" ? s.index(after: j) : j)
        } else {
            out.append(s[i])
            i = s.index(after: i)
        }
    }
    return out
}

/// The daemon's events reach the app as their types (`RPCClient.onEvent`, decoded once on the client's reader thread):
/// the app doesn't switch on their names or decode them from JSON on the main thread.
@Test func theAppTakesEventsByType() throws {
    #expect(
        try matches(
            #"onNotification|case [A-Z]\w*\.name\b|\.decode\(\w*(Event|Session|Repo|Worktree)\.self"#, in: appDirs)
            == [])
}

/// Questions are sheets that are awaited: a nested modal loop (runModal for a sheet) runs every timer, event and task of
/// the app inside it, and a semaphore on the main thread stops them all. (The hang watcher's semaphore is on a thread of
/// its own: it's what notices a stuck main thread.)
@Test func theMainThreadNeverWaitsInALoopOfItsOwn() throws {
    #expect(try matches(#"runAsSheet|NSApp\.runModal\(for"#, in: appDirs) == [])
    #expect(
        try matches(#"DispatchSemaphore"#, in: appDirs).filter {
            !$0.hasPrefix("Sources/KelpKit/DevAids/DevAids.swift")
        } == [])
    // Until a `.terminateLater` reply AppKit runs a modal mode in which the main actor's tasks don't run: an async
    // question asked from there never shows (quitting with an unsaved file closed nothing and asked nothing).
    #expect(try matches(#"\.terminateLater"#, in: appDirs) == [])
    // One loop of its own, on purpose: a logout's quit needs its answer before applicationShouldTerminate returns.
    #expect(
        try matches(#"nextEvent\(matching: \.any"#, in: appDirs).map { $0.split(separator: ":")[0] } == [
            "Sources/KelpKit/App/AppDelegate.swift"
        ])
}

/// A line too long to take in at once: a call, a condition or a chain split over lines reads better. Comment lines and
/// lines that are one long string (UI text) don't count; lint warns past 180.
@Test func linesStayShort() throws {
    let longString = try NSRegularExpression(pattern: ##""[^"]{100,}"|#".{100,}"#|'[^']{100,}'"##)
    let long = sources(["Sources"]).flatMap { f in
        f.text.split(separator: "\n").filter { l in
            l.count > 160 && !l.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && longString.firstMatch(in: String(l), range: NSRange(l.startIndex..., in: l)) == nil
        }.map { _ in f.path }
    }
    #expect(long == [], "lines over 160: \(Dictionary(long.map { ($0, 1) }, uniquingKeysWith: +))")
    // The code is wrapped at 120 (swift-format, .swift-format): what it can't wrap (a long chain, a long condition) is
    // counted, and the count only goes down.
    let over120 = sources(["Sources"]).flatMap { f in
        f.text.split(separator: "\n").filter { l in
            l.count > 120 && !l.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && longString.firstMatch(in: String(l), range: NSRange(l.startIndex..., in: l)) == nil
        }
    }.count
    #expect(over120 <= 420, "lines over 120: \(over120)")
    #expect(over120 >= 420, "fewer now (\(over120)): lower the ceiling")
}

/// A setting is declared once, its default with it (`SettingKeys`), and read by that declaration: a key spelled out
/// where it's read can drift from its row's and repeats the default by hand.
@Test func settingsAreReadByTheirDeclaration() throws {
    let named = try matches(
        #"settings(?:\[|\.(?:string|bool|number|int|double|value)\()\s*"[a-z]+\.[\w.]+"#, in: ["Sources"])
    #expect(named.count <= 0, "settings read by a key literal: \(named)")
    #expect(named.count >= 0, "fewer now (\(named.count)): lower the ceiling")
}

/// Three statements on one line (`a; b; c`) are read as one: the daemon's code has one or two a line. String and regex
/// literals and comments don't count.
@Test func theDaemonSaysOneThingALine() {
    let dense = sources(["Sources/Daemon"]).flatMap { f in
        f.text.split(separator: "\n").enumerated().compactMap { i, l -> String? in
            let code = String(l.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .replacingOccurrences(of: #""(?:\\.|[^"\\])*""#, with: "\"\"", options: .regularExpression)
                .replacingOccurrences(of: #"/\\x1B.*/"#, with: "", options: .regularExpression)
            return code.filter { $0 == ";" }.count >= 2 ? "\(f.path):\(i + 1)" : nil
        }
    }
    #expect(dense == [])
    // The app's too, its multi-line strings (a page's script) aside.
    let app = sources(["Sources/KelpKit", "Sources/Builtins"]).flatMap { f in
        codeOnly(f.text).split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { i, l in
            l.filter { $0 == ";" }.count >= 2 ? "\(f.path):\(i + 1)" : nil
        }
    }
    #expect(app == [])
}

/// A contraction a rename went through ("isn't" made "isn'handler"): English has only n't, 's, 'll, 're, 've, 'd, 'm.
@Test func noWordWasRenamedInsideAContraction() throws {
    let broken = try matches(#"[A-Za-z]'(?!(t|s|ll|re|ve|d|m)\b)[a-z]{2,}\b"#, in: ["Sources"])
        .filter { !$0.hasPrefix("Sources/Markdown/Resources") }
    let inText = broken.filter { hit in
        let parts = hit.split(separator: ":"), path = String(parts[0]), line = Int(parts[1]) ?? 0
        let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))?.split(
            separator: "\n", omittingEmptySubsequences: false)
        let l = text.flatMap { line - 1 < $0.count ? String($0[line - 1]) : nil } ?? ""
        return l.contains("//") || l.contains("\"")
    }
    #expect(inText.isEmpty, "\(inText)")
}

/// A file past 600 lines of code (blank and comment lines aside) is two things: split it. (450 at 160 characters a line;
/// the same code wrapped at 120 since 2026-11-08 runs to about a third more lines.)
@Test func filesStaySmall() {
    let big = sources(["Sources"]).compactMap { f -> String? in
        let code = f.text.split(separator: "\n").filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("//")
        }
        return code.count > 600 ? "\(f.path): \(code.count)" : nil
    }
    #expect(big == [])
}

/// The daemon starts every program (an extension's command, a formatter, a notebook run, an agent's --version:
/// `process.run`), with its time limits, its process-tree kill and its trust checks; the app starts none. Two exceptions:
/// the app launching kelpd itself, and DevAids' `sample` of a stuck main thread (a developer's tool). Core's helpers that
/// start one count too: LoginPath runs the login shell (the app asks the daemon: `process.which`), the library's index and
/// download run curl and tar.
@Test func theAppStartsNoPrograms() throws {
    let allowed = ["Sources/KelpKit/Model/DaemonLink.swift", "Sources/KelpKit/DevAids/DevAids.swift"]
    let found = try matches(
        #"\bProcess\(\)|\bSubprocess\.|posix_spawn|\bNSTask\b|\bLoginPath\.|\bfetchExtension\(|\blibrary\(index"#,
        in: appDirs
    )
    .filter { f in !allowed.contains { f.hasPrefix($0 + ":") } }
    #expect(found == [])
    // A new Core helper that starts a program: add what the app could call to the pattern above.
    let starters = Set(
        try matches(#"\bProcess\(\)|\bSubprocess\.run\("#, in: ["Sources/Core"]).map {
            String($0.split(separator: ":")[0])
        })
    let core = ["System/Subprocess", "System/LoginPath", "Extensions/ExtensionFiles"].map { "Sources/Core/\($0).swift" }
    #expect(starters == Set(core))
}

/// `workbench.open` takes links from forges and trackers, so it only shows things. What runs a `terminal:` or `agent:` URI has
/// a name of its own and these callers, each with a URI Kelp made or a person asked for; data from elsewhere is never among them.
@Test func onlyKelpsOwnURIsRunAnything() throws {
    let callers = Set(try matches(#"\.runURI\("#, in: appDirs).map { String($0.split(separator: ":")[0]) })
    #expect(
        callers == [
            "Sources/KelpKit/DevAids/DevAids.swift", "Sources/KelpKit/Editor/EditorArea.swift",
            "Sources/KelpKit/Extensions/ExtActions.swift",
            "Sources/KelpKit/QuickOpen/QuickOpenTmux.swift", "Sources/KelpKit/Shell/EditorHost.swift",
            "Sources/KelpKit/Shell/KelpLinks.swift", "Sources/KelpKit/Shell/WorkbenchActions.swift"
        ])
}

/// A handler that types into a session, stops one or a process, ends a workspace's agents or answers a question says on
/// what (`actsOn`, `answersQuestion`, `reportsFor`, `inWorkspace`, `ends`, `onlyFromKelp`), so `Daemon.allow` checks it
/// before an agent's call gets that far. One that doesn't is a way around the check.
@Test func whatActsOnASessionSaysOnWhich() throws {
    let acts =
        #/SessionSend\(|\.submit\(|\.userInput\(|\.write\(data\)|\.continueAt\(|answerPermission\(|\.terminate\(|\bkill\(/#
    let ends = #/pauseSessions\(|sessions\.discard\(|\.archive\(|removeWorkspace\(/#
    let says = #/var (actsOn|answersQuestion|reportsFor|inWorkspace|ends|onlyFromKelp)\b/#
    // What types text in (a send, raw input) names that session as `typesInto` too: a question there refuses an agent's.
    let types = #/SessionSend\(|\.submit\(|\.userInput\(/#
    var unsaid: [String] = [], untyped: [String] = []
    for f in sources(["Sources/Daemon"]) {
        for piece in f.text.components(separatedBy: "\nextension ").dropFirst() {
            let head = String(piece.prefix { $0 != "\n" })
            guard head.contains(#/: [^{]*\b(Handled|AsyncHandled|SessionInput)\b/#) else { continue }
            let oneLine = head.hasSuffix("}") && head.filter { $0 == "{" }.count == head.filter { $0 == "}" }.count
            let body = oneLine ? head : piece.components(separatedBy: "\n}").first ?? piece
            if body.contains(acts) || body.contains(ends), !body.contains(says) {
                unsaid.append("\(f.path): \(head.prefix { $0 != ":" })")
            }
            if body.contains(types), !body.contains(#/var typesInto\b/#) {
                untyped.append("\(f.path): \(head.prefix { $0 != ":" })")
            }
        }
    }
    #expect(unsaid == [])
    #expect(untyped == [], "types into a session without saying which (`typesInto`)")
}

/// A URL goes to another app through `PreviewLinks.openOutside` only, which lets web pages, mail and System Settings
/// through: links come from pages, forges and agents, and a file or another app's scheme would run something.
/// (TerminalKit's fallback is unused: Kelp's terminals hand their links to `PaneView.openLink`.)
@Test func urlsLeaveKelpThroughOneDoor() throws {
    let opens = try matches(#"NSWorkspace\.shared\.open\((?!\s*\[)|\.open\(\s*\w+, configuration:"#, in: appDirs)
    #expect(opens.map { String($0.split(separator: ":")[0]) } == ["Sources/KelpKit/Shared/PreviewLinks.swift"])
}

/// Outside text reaches an agent in one frame (`Untrusted.frame`): a second hand-made one would differ in what it escapes.
@Test func outsideTextIsFramedInOnePlace() throws {
    let frames = try matches(#"<untrusted"#, in: ["Sources"]).map { String($0.split(separator: ":")[0]) }
    #expect(Set(frames) == ["Sources/Daemon/Project/RepoConfig.swift"])
}

/// The app doesn't ask the daemon again and again: views watch (`watch.start`) and the daemon pushes what changed.
/// A clock left in the app is the app's own, each listed with why and how many; a new one that polls the daemon belongs
/// in a watch. Counted per file: a second clock in a listed file is a new one, not the one it was listed for.
/// Limit: a one-shot `asyncAfter` isn't counted (the app has dozens, for motion); one that schedules itself again polls.
@Test func theAppDoesntPollTheDaemon() throws {
    let clocks: [String: (Int, String)] = [
        "KelpKit/App/AppDelegate.swift": (
            2, "a finished agent counts as read after a second on screen; a 30 ms wait for the window at launch"
        ),
        "KelpKit/Sidebar/SidebarController.swift": (1, "relative times on the rows (\"now\" becomes \"1m\")"),
        "KelpKit/Model/AppModel.swift": (1, "things asked for at launch wait for the first connection, up to 5 s"),
        "KelpKit/Model/DaemonLink.swift": (
            6, "connecting: the socket, retries, backoff; a look every 30 s for a hung kelpd"
        ),
        "KelpKit/Notifications/Notifier.swift": (
            3,
            "a notification's summary waits a moment for the agent's last line; a question is reminded of once, minutes later"
        ),
        "KelpKit/DevAids/DevAids.swift": (1, "a snapshot waits for the window to draw (debug builds only)"),
        "Builtins/Agents/Usage/LimitStrip.swift": (
            1, "\"in 38 min\" counts down to a limit's reset, which nothing announces"
        ),
        "Builtins/Agents/Usage/LimitWatch.swift": (
            1, "a limit that stopped agents is waited out, to tell them they can go on: nothing announces its reset"
        ),
        "KelpKit/Sidebar/Parking.swift": (1, "a park for an hour ends when its hour is up, which nothing announces"),
        "Builtins/Agents/Strip/StripCardParts.swift": (
            1,
            "Allow takes clicks a moment after its card comes up, as the card can land under a click meant for something else"
        ),
        "KelpKit/Shell/WorkspaceSwitcher.swift": (
            1, "the ⌃Tab panel shows once ⌃ is held a moment, so a quick flip doesn't flash it"
        ),
        "Builtins/Git/RowMarks.swift": (1, "a passed CI's ✓ leaves the branch chip after a minute on screen"),
        "Builtins/Agents/Session/PaneView.swift": (
            1, "a terminal out of sight lets go of its agent once it could pause idle"
        ),
        "Builtins/Agents/Session/CommandsBar.swift": (1, "a running command's time goes on (\"12s\" becomes \"13s\")"),
        "Builtins/Issues/CIRunRow.swift": (1, "a running job's time goes on, counted from when it began"),
        "Builtins/Files/FileTab+Saving.swift": (1, "typing settles before the language server hears it"),
        "Builtins/Files/MarkdownTab.swift": (1, "typing settles before the preview renders again"),
        "Builtins/Databases/DatabaseForm.swift": (1, "typing settles before Add Database connects to check it"),
        "Builtins/Databases/DatabaseTab+Table.swift": (
            1, "a read says Reading… only past half a second: a quick one doesn't flicker"
        ),
        "Builtins/Databases/DatabaseTab+Opening.swift": (
            1, "Connecting to … shows past half a second: a quick open doesn't flicker"
        ),
        "Builtins/Git/CommitCard.swift": (
            2, "a commit's card opens once the pointer rests on its row, and closes a moment after it leaves"
        ),
        "KelpKit/Extensions/ExtListView.swift": (1, "an extension's own refresh interval for its command's list"),
        "KelpKit/Extensions/DeclarativeExtension.swift": (
            1, "an extension's own refresh interval for its panel's badge command"
        ),
        "KelpKit/Model/UIState.swift": (
            1,
            "the daemon's state read again, three times at most, after a read that failed, while that daemon is still there"
        ),
        "Builtins/Browser/BrowserAutomation.swift": (
            4,
            "kelp browser waits for a page to load, to go quiet after an action, or to show what it was told to wait for: "
                + "WebKit says none of them"
        )
    ]
    let all = try matches(
        #"repeats: true|Task\.sleep\(|makeTimerSource|publish\(every:|[Cc]lock\(\)?\.sleep\(|Thread\.sleep|usleep\("#,
        in: appDirs)
    var found: [String: Int] = [:]
    for m in all { found[String(m.dropFirst("Sources/".count).split(separator: ":")[0]), default: 0] += 1 }
    let new = found.filter { f, n in n > clocks[f]?.0 ?? 0 }
    #expect(new == [:], "a clock asking the daemon: watch a topic instead (WatchTopic)")
    let gone = clocks.filter { found[$0.key, default: 0] < $0.value.0 }.keys.sorted()
    #expect(gone == [], "a count above its file's clocks now: lower it (to 0: take it off the list) \(found)")
}

/// The daemon is its connections and the services it puts together; what each service keeps is its own, under its own
/// locks, and a service is given what it uses instead of reaching back into `Daemon`. Counted: `Daemon`'s stored
/// properties, the extensions that add to it from other files, and state kept outside any instance (a file-scope value
/// or a static object other than a logger), which every daemon in one process (tests) would share.
@Test func theDaemonKeepsItsStateInItsServices() throws {
    let daemon = try #require(sources(["Sources/Daemon"]).first { $0.path == "Sources/Daemon/Daemon.swift" })
    let stored = try NSRegularExpression(pattern: #"^    (?:public |private )?let "#, options: [.anchorsMatchLines])
        .numberOfMatches(in: daemon.text, range: NSRange(daemon.text.startIndex..., in: daemon.text))
    let extensions = try matches(#"^extension Daemon\b"#, in: ["Sources/Daemon"])
    let shared = try matches(
        #"^(?:private |fileprivate |public )?(?:let|var) \w+|^\s+(?:private |public )?static let \w+ = (?!Logger\()[A-Z]\w*(?:<[^\n]*>)?\("#,
        in: ["Sources/Daemon"])
    // 15: who calls (`Callers`) is the connections' and the fence's, not a session's.
    #expect(stored <= 15, "Daemon's stored properties: \(stored)")
    #expect(stored >= 15, "fewer now: lower the ceiling")
    // Nor does it go into `Sessions` instead, the service the most comes near: what isn't a session's goes in a type of
    // its own (`ChildReports`, `SessionSetup`, `SessionProcesses`, `Turns`, `KeepAwake`…), which `Sessions` holds as one.
    let sessions = try #require(
        sources(["Sources/Daemon"]).first { $0.path == "Sources/Daemon/Sessions/Sessions.swift" })
    let held = try NSRegularExpression(
        pattern: #"^    (?:public |private |package )?let "#, options: [.anchorsMatchLines]
    )
    .numberOfMatches(in: sessions.text, range: NSRange(sessions.text.startIndex..., in: sessions.text))
    #expect(held <= 22, "Sessions' stored properties: \(held)")
    #expect(held >= 22, "fewer now: lower the ceiling")
    // Nor its methods: a feature gets a type of its own that's handed what it uses, not one more `extension Sessions`.
    let grown = try matches(#"^extension Sessions\b"#, in: ["Sources/Daemon"])
    #expect(grown.count <= 6, "extensions of Sessions: \(grown.count)")
    #expect(grown.count >= 6, "fewer now: lower the ceiling")
    // Nor its handlers, nor any one service's: a handler is handed the part it uses (`SourceControl`, `Turns`…), and no
    // service answers more than 40 methods. Counted by the type each `handle(_:)` and `handle(_:conn:)` takes.
    let services = sources(["Sources/Daemon"]).flatMap { f in
        f.text.matches(of: #/func handle\(_ \w+: (\w+)(?:, conn: Int)?\)/#).map { String($0.1) }
    }
    let byService = Dictionary(grouping: services) { $0 }.mapValues(\.count)
    #expect(byService.values.allSatisfy { $0 <= 40 }, "a service answers more than 40 methods: \(byService)")
    let most = byService.values.max() ?? 0
    // 36 since `handle(_:conn:)` counts too (Sessions' two were missed: 34 then, really 36).
    #expect(most <= 36, "the busiest service's handlers: \(most)")
    #expect(most >= 36, "fewer now: lower the ceiling")
    // 3: the connections' side (Server.swift) is the daemon's own, beside its dispatch (Handlers.swift).
    #expect(extensions.count <= 3, "extensions of Daemon: \(extensions)")
    #expect(extensions.count >= 3, "fewer now: lower the ceiling")
    #expect(shared.count <= 0, "state outside an instance: \(shared)")
}

/// A method's handler is handed one service (`Handled.Service`), never the daemon, so it reaches only what that service
/// holds; and a service gets what it uses at init instead of reaching back. So only the daemon's own files name it: the
/// class, its connections (Server.swift), the dispatch with each service's projection (Handlers.swift), and the watch
/// reader, which answers methods as a client would (WatchHandlers.swift). Everything else (handlers, services, their
/// helpers) doesn't.
@Test func handlersAreHandedAServiceNotTheDaemon() throws {
    let own: Set<String> = [
        "Sources/Daemon/Daemon.swift", "Sources/Daemon/Server/Handlers.swift", "Sources/Daemon/Server/Server.swift",
        "Sources/Daemon/Server/WatchHandlers.swift"
    ]
    let naming = sources(["Sources/Daemon"]).filter { f in
        !own.contains(f.path) && codeOnly(f.text).range(of: #"\bDaemon\b"#, options: .regularExpression) != nil
    }
    #expect(naming.map(\.path).sorted() == [], "files that reach the daemon")
    let taking = try matches(#"func handle\(_ \w+: Daemon\b|extension Daemon: DaemonService"#, in: ["Sources/Daemon"])
    #expect(taking == [], "handlers that take the daemon")
}

/// Snapshots and the input they drive (KELP_SNAPSHOT, KELP_CLICK, KELP_TYPE) are a debug build's: in a release, any
/// program could start the real app and have it press its own buttons (Trust) as the window `onlyFromKelp` trusts.
@Test func devAidsAreDebugOnly() throws {
    let text = try #require(sources(["Sources/KelpKit"]).first { $0.path.hasSuffix("/AppDelegate.swift") }?.text)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let calls = lines.indices.filter {
        lines[$0].contains("snapshotLater(") && !lines[$0].contains("func snapshotLater")
    }
    #expect(
        !calls.isEmpty
            && calls.allSatisfy { i in
                let before = lines[..<i], open = before.lastIndex { $0.contains("#if DEBUG") },
                    close = before.lastIndex { $0.contains("#endif") }
                return open != nil && (close == nil || close! < open!)
            })
}

/// Sizes come from DesignKit, not from a number at the call. Each count is a ceiling that only goes down: what's left is a
/// tile's fixed glyph, an icon row's point size, radii concentric with another (9 in a row, 14 and 16 in glass), and
/// the colourful icons that need a weight (`NSImage.symbol` itself is DesignKit's).
@Test func chromeTakesItsSizesFromDesignKit() throws {
    let chrome = ["Sources/KelpKit", "Sources/Builtins"]
    #expect(try matches(#"\.font\(\.system\(size"#, in: chrome).count <= 1)
    #expect(try matches(#"\.font\(\.system\(size"#, in: chrome).count >= 1, "fewer now: lower the ceiling")
    #expect(try matches(#"cornerRadius( =|:) *[0-9]"#, in: chrome).count <= 1)
    // Drawn by hand too: a system font at a size of its own (a tile's letters, scaled to the tile), a rounded path's
    // radius typed in (icon tiles). The debt as it is: each ceiling is today's count.
    #expect(try matches(#"systemFont\(ofSize"#, in: chrome).count <= 4)
    #expect(try matches(#"xRadius: *[0-9]"#, in: chrome).count <= 5)
    // Text sizes by name (`TextSize.caption`); what's left is a title, a big number, a tile's glyph, a grid's NULL.
    let typed = try matches(#"\.ui(Mono|Digits)?\(\d"#, in: chrome + ["Sources/DesignKit", "Sources/EditorKit"])
    #expect(typed.count <= 12, "\(typed)")
    #expect(try matches(#"NSImage\(systemSymbolName"#, in: chrome).count <= 1)
    #expect(try matches(#"NSImage\(systemSymbolName"#, in: chrome).count >= 1, "fewer now: lower the ceiling")
    // The system's text styles stay at their size whatever Text size says: SwiftUI text takes `Font.ui` too.
    let styles = try matches(
        #"\.font\(\.(headline|subheadline|caption|footnote|title|body|callout)"#, in: chrome + ["Sources/EditorKit"])
    #expect(styles.count <= 0, "\(styles)")
}

/// A `try?` turns a failure into nothing, unseen: right for a probe ("is it there", "does it parse"), wrong for a write,
/// a cleanup or a store change, which say what failed with `Log.attempt` instead. Each module's count is a ceiling.
@Test func failuresAreNotSwallowed() throws {
    let ceilings = [
        "Daemon": 58, "KelpKit": 50, "Core": 27, "GitKit": 15, "AgentData": 8, "Agents": 13, "kelp": 10,
        "Builtins": 10,
        "Integrations": 7, "LSPKit": 2, "Markdown": 4, "TerminalKit": 3, "KelpVM": 10, "KelpGuest": 4, "EditorKit": 3,
        "WorkbenchKit": 0, "DesignKit": 0
    ]
    // Every module is in it: a new one gets its count here, not none.
    let modules = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources").path)
        .filter { !["kelpd", "KelpApp"].contains($0) && !$0.hasPrefix(".") }
    #expect(
        Set(modules).subtracting(ceilings.keys).isEmpty,
        "modules with no try? ceiling: \(Set(modules).subtracting(ceilings.keys).sorted())")
    // Counted in code: a `try?` a comment or a string mentions swallows nothing.
    let tryQuestion = try NSRegularExpression(pattern: #"\btry\?"#)
    for (module, ceiling) in ceilings {
        let n = sources(["Sources/" + module]).map { f in
            let code = codeOnly(f.text)
            return tryQuestion.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
        }.reduce(0, +)
        #expect(n <= ceiling, "try? in \(module): \(n), over its ceiling")
        #expect(n >= ceiling, "try? in \(module): \(n), under its ceiling \(ceiling): lower it")
    }
}

/// A radius or a duration comes from DesignKit (`Metrics`, `Motion`). What's left has no token: the glass panels, a row's glow,
/// the backdrop's drift, and a duration of 0.
@Test func looksComeFromTheDesignSystem() throws {
    let typed = try matches(#"(cornerRadius|[dD]uration) = \d"#, in: ["Sources/KelpKit", "Sources/Builtins"])
    #expect(typed.count <= 2, "\(typed)")
    #expect(typed.count >= 2, "fewer now: lower the ceiling")
    let delays = try matches(#"\.now\(\) \+ 0\.\d"#, in: ["Sources/KelpKit", "Sources/Builtins"])
    #expect(delays.count <= 2, "\(delays)")   // a dev aid's, and key bindings read back: neither is motion
    #expect(delays.count >= 2, "fewer now: lower the ceiling")
}

/// Who may call a method is the method's to say (`onlyFromKelp`), checked in one place for every call: a handler that
/// checked for itself could forget, or check after it had already acted.
@Test func whoMayCallAMethodIsCheckedInOnePlace() throws {
    let checks = try matches(#"\.requireApp\("#, in: ["Sources/Daemon"])
    let dispatch = ["Sources/Daemon/Server/Handlers.swift:"]
    #expect(
        checks.allSatisfy { c in dispatch.contains { c.hasPrefix($0) } },
        "who-may-call checks outside the dispatcher: \(checks)")
    // Params are read as a method's type only where the caller is checked too: `checked`, or a session's input, which
    // checks `onlyFromKelp` itself right after (SessionLanes).
    let reads = try matches(#"\bdecoded\("#, in: ["Sources/Daemon"]).filter {
        !$0.hasPrefix("Sources/Daemon/Server/Handlers.swift:")
    }
    #expect(
        reads.map { $0.split(separator: ":")[0] } == ["Sources/Daemon/Sessions/SessionLanes.swift"],
        "params read without the caller check: \(reads)")
    // ui.publish, scripts.trust, state.set, session.annotate, ui.browser.reply
    #expect(try matches(#"var onlyFromKelp: String\? \{(?!\s*(?:nil|get)\s*\})"#, in: ["Sources/Daemon"]).count == 5)
}

/// Who may call a method is said by properties a protocol extension gives defaults for (`Answered`, `Handled`,
/// `RPCMethod`): one spelled with another type (`static let timeout: TimeInterval` for `TimeInterval?`) compiles as a
/// property of its own, and the default answers instead, quietly. Each is spelled as its requirement is.
@Test func gatePropertiesHaveTheirRequirementsTypes() throws {
    let gates = "onlyFromKelp|reportsFor|actsOn|inWorkspace|notForAgents|typesInto|shows|makesInProject"
    var wrong = try matches(#"\b(?:static )?(?:var|let) (?:\#(gates))\b(?!: String\? \{)"#, in: ["Sources/Daemon"])
    wrong += try matches(
        #"\bstatic (?:var|let) (?:\#(gates))\b|\b(?:let|static var|static let) (?:answersQuestion|signs|ends)\b"#,
        in: ["Sources/Daemon"])
    wrong += try matches(
        #"\bvar (?:answersQuestion|signs)\b(?!: Bool \{)|\bvar ends\b(?!: Ending\? \{)"#, in: ["Sources/Daemon"])
    wrong += try matches(#"\bstatic (?:var|let) (?:inOrder|quick)\b(?!: Bool \{)"#, in: ["Sources/Daemon"])
    wrong += try matches(
        #"\bstatic (?:var|let) timeout\b(?!: TimeInterval\? \{)"#, in: ["Sources/Core", "Sources/Daemon"])
    #expect(wrong.isEmpty, "spelled unlike their requirements: \(wrong)")
}

/// A gate misspelled (`var inWorkpace`) is a property of its own, and the protocol's default answers in its place: no
/// property in the daemon is named one or two letters off a gate's name.
@Test func noPropertyIsNamedNearlyLikeAGate() throws {
    let gates = [
        "onlyFromKelp", "reportsFor", "actsOn", "answersQuestion", "inWorkspace", "ends", "notForAgents", "typesInto",
        "shows", "signs", "makesInProject",
        "inOrder", "quick", "timeout"
    ]
    func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased()), b = Array(b.lowercased())
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var next = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            row = next
        }
        return row[b.count]
    }
    let re = try NSRegularExpression(pattern: #"\b(?:static )?var (\w+):"#)
    var near: [String] = []
    for f in sources(["Sources/Daemon", "Sources/Core"]) {
        for m in re.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)) {
            guard let r = Range(m.range(at: 1), in: f.text) else { continue }
            let name = String(f.text[r])
            let words: Set = ["action", "timedOut"]   // words of their own, a letter or two from a gate's name
            if !gates.contains(name), !words.contains(name),
                let g = gates.first(where: { $0.count > 5 && distance($0, name) <= 2 })
            {
                near.append("\(f.path): \(name) ~ \(g)")
            }
        }
    }
    #expect(near == [])
}

/// What the daemon runs on is handed to it (`Daemon(root:)`, its `Remotes`, `LSPHost`'s delays): nothing in the code it
/// runs reads KELP_HOME's folders from the environment, keeps state in a static or opts out of the isolation checks. Two
/// daemons in one process (tests) shared those, and the one set last won. (GitKit runs git on a remote project's host
/// only when it's given the daemon's `Remotes`: no GitKit function has a default for it, so the compiler checks that.)
@Test func theDaemonKeepsNoProcessGlobals() throws {
    let modules = [
        "Sources/Daemon", "Sources/Core", "Sources/GitKit", "Sources/LSPKit", "Sources/Agents", "Sources/AgentData",
        "Sources/Integrations"
    ]
    let files = sources(modules).map { (path: $0.path, code: codeOnly($0.text)) }
    func found(_ pattern: String, in files: [(path: String, code: String)]) throws -> [(
        path: String, code: String, at: Range<String.Index>
    )] {
        let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return files.flatMap { f in
            re.matches(in: f.code, range: NSRange(f.code.startIndex..., in: f.code)).compactMap { m in
                Range(m.range, in: f.code).map { (f.path, f.code, $0) }
            }
        }
    }
    func named(_ hits: [(path: String, code: String, at: Range<String.Index>)]) -> [String] {
        hits.map { "\($0.path):\($0.code[..<$0.at.lowerBound].filter { $0 == "\n" }.count + 1)" }
    }
    let unsafe = try found(#"nonisolated\(unsafe\)"#, in: files)
    let statics = try found(#"\bstatic var \w+(?:\s*:\s*[^={\n]+)?\s*="#, in: files)
    let home = try found(
        #"\bPaths\.(?:root|socket|agents|extensions|agentSkills|scratch)\b|\bfunc daemonError\(in root: URL ="#,
        in: files.filter { $0.path != "Sources/Core/System/Paths.swift" })
    #expect(named(unsafe) == [], "nonisolated(unsafe)")
    #expect(named(statics) == [], "state in a static var")
    #expect(named(home) == [], "KELP_HOME's folders from the environment")
}

/// A project's files are read, written, watched, moved and made by the daemon (`files.*`, `WatchTopic.file(s)`), with a
/// tab's rules and the same way for a project on another machine. What the app still touches itself is listed with
/// why and how often (a ceiling per file): its own folders, a viewer's bytes, whether a path is there. Nothing else does.
@Test func theAppDoesntTouchProjectFiles() throws {
    let own: [String: (Int, String)] = [
        "KelpKit/Model/AgentCatalog.swift": (
            1, "an agent CLI's date: it isn't asked its version again until it changes"
        ),
        "KelpKit/Model/AgentIcons.swift": (4, "agents' icons, cached in Kelp's home"),
        "KelpKit/Model/AppModel.swift": (1, "whether the projects' folders are there, off the main thread"),
        "KelpKit/Model/DaemonLink.swift": (2, "why kelpd didn't start, in Kelp's home; the bundled kelpd's date"),
        "KelpKit/DevAids/DevAids.swift": (3, "snapshots for tests"),
        "KelpKit/Sheets/CloneSheet.swift": (2, "whether the folder new projects go in is there"),
        "KelpKit/Settings/IconTheme.swift": (2, "an icon theme an extension brings"),
        "KelpKit/Settings/ExtensionsSettings.swift": (1, "an extension's own folder"),
        "KelpKit/Extensions/Registry.swift": (4, "extensions' folders, Kelp's own"),
        "KelpKit/Extensions/ExtensionInstall.swift": (3, "an extension installed into Kelp's folder, or taken out"),
        "KelpKit/Extensions/DeclarativeExtension.swift": (4, "an extension's manifest"),
        "KelpKit/Extensions/ExtensionReview.swift": (1, "an extension's manifest, before it's installed"),
        "KelpKit/Extensions/ExtPages.swift": (1, "an extension's own page, served to its web view"),
        "KelpKit/Extensions/AgentSkills.swift": (5, "the skills Kelp gives agents, and which are there"),
        "KelpKit/Shell/Help.swift": (1, "the guide, written to Kelp's home"),
        "KelpKit/Shell/WorkbenchActions.swift": (1, "a dropped path: a file, a folder, or nothing"),
        "KelpKit/Shell/KelpLinks.swift": (2, "a linked path: a file, a folder, or nothing"),
        "KelpKit/Shell/WorkspaceActions+OpenIn.swift": (1, "whether Open In was handed a file or a folder"),
        "KelpKit/Shell/ProjectIcon.swift": (1, "a project's icon, shown (a remote one's from the copy kelpd keeps)"),
        "Builtins/Machines/Machines.swift": (
            2,
            "whether this Mac has Xcode (the apps in /Applications, and each one's developer folder), for the Add menu's iOS machine"
        ),
        "Builtins/Agents/Session/PathPreview.swift": (3, "a path a terminal printed is a file, before it's a link"),
        "Builtins/Browser/BrowserTab.swift": (1, "a local page, shown: it reloads as its folder changes"),
        "Builtins/Browser/BrowserTab+Design.swift": (1, "a page's screenshot"),
        "Builtins/Browser/BrowserDownloads.swift": (
            2, "a download's folder (~/Downloads, or Kelp's temporary one) and a name not taken there"
        ),
        "Builtins/Files/Preview.swift": (2, "an image's bytes, shown"),
        "Builtins/Databases/DatabaseTab+Table.swift": (1, "rows exported to a file the user picked in a save panel")
    ]
    let all = try matches(
        #"FileManager\.default\.(contents|createFile|moveItem|trashItem|copyItem|removeItem|createDirectory|fileExists|isWritableFile"#
            + #"|enumerator|attributesOfItem|destinationOfSymbolicLink)|FileWatcher\(|FileHandle\(|(String|Data|NSImage|NSDictionary)\(\s*contentsOf"#
            + #"|\.write\(\s*to(File)?:|\bstat\([^()]*&"#, in: appDirs)
    var found: [String: Int] = [:]
    for m in all { found[String(m.dropFirst("Sources/".count).split(separator: ":")[0]), default: 0] += 1 }
    let left = found.filter { f, n in n > own[f]?.0 ?? 0 }
    #expect(left == [:], "a project's files touched by the app: go through the daemon (files.*)")
    let gone = own.filter { found[$0.key, default: 0] < $0.value.0 }.keys.sorted()
    #expect(gone == [], "a ceiling above its file's count now: lower it (to 0: take it off the list) \(found)")
}

/// The app is made once, by its delegate (main.swift makes that), and handed down: the window to its panels and editor
/// areas, the registry to the built-ins' contributions, and on to their views; what acts on the window is reached as
/// `app.workbench`. Nothing reaches for it instead: no `static let shared` of the app's own, no static facade over one
/// (Workbench's statics: `files` alone reads nothing but a drag), no `IDEContext.current`, no `NSApp.delegate`. A view
/// that reached one could only ever show the one app, and every test that makes its own would share it.
@Test func theAppIsHandedItsModel() throws {
    let made = try matches(#"^\s*(?:@\w+\s+)*(?:private\s+|fileprivate\s+)?static (?:let|var) shared\b"#, in: appDirs)
    #expect(made == [], "a singleton of the app's own: make it the app's (`AppModel`) and hand it down")
    let starts = ["Sources/KelpApp/main.swift", "Sources/KelpKit/App/AppDelegate.swift"]
    let reach = try NSRegularExpression(
        pattern: #"\bWorkbench\.(?!files\b)[a-z]\w*|\bIDEContext\.current\b|\bNSApp(?:lication\.shared)?\.delegate\b"#)
    let found = sources(appDirs).filter { !starts.contains($0.path) }.flatMap { f in
        let code = codeOnly(f.text)
        return reach.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range, in: code).map { "\(f.path): \(code[$0])" }
        }
    }
    #expect(found == [], "take it from what's handed down (`app`, `app.workbench`)")
}

/// What the daemon pushes for a watched topic lands in one store, `AppModel.latest(E.self)`, by the event's `Pushed`
/// conformance (in KelpKit, or in the built-in whose kind it is): a new kind touches no file of the shell (no property, no case in a switch), so a
/// feature's data needn't live in KelpKit. And the model's own observed state stays what every part reads: the
/// connection, projects, workspaces, sessions and the sidebar's arrangement.
/// AppModel mirrors the daemon; what a feature does is its own type's. The files that add to it outside AppModel.swift
/// only read the daemon's records (the watch, a workspace's git folder, the projects by server).
@Test func appModelIsTheDaemonsMirror() {
    let names = sources(["Sources/KelpKit", "Sources/Builtins"]).filter { file in
        !file.path.hasSuffix("/AppModel.swift")
            && file.text.range(of: #"(?m)^extension AppModel\b"#, options: .regularExpression) != nil
    }.map(\.path).sorted()
    #expect(names.count <= 3, "files extending AppModel: \(names)")
    #expect(names.count >= 3, "fewer now (\(names)): lower the ceiling")
}

@Test func pushedStateLandsInOneStore() throws {
    let watching = try String(
        contentsOf: root.appendingPathComponent("Sources/KelpKit/Model/Watching.swift"), encoding: .utf8)
    // Any kind named (`RPCEvent`, the protocol, and `RemovedEvent`, the records' own, aside).
    let kinds = try NSRegularExpression(pattern: #"\b(?!RPCEvent\b|RemovedEvent\b)[A-Z]\w*Event\b|case let \w+ as"#)
    let code = codeOnly(watching)
    let named = kinds.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    #expect(named == 0, "event kinds named one by one in Watching.swift: \(named)")
    // AppModel's stored, observed properties: every `var` at its top level that isn't computed, nor marked
    // @ObservationIgnored (on its line, or on an attribute line of its own just above).
    let model = try String(
        contentsOf: root.appendingPathComponent("Sources/KelpKit/Model/AppModel.swift"), encoding: .utf8)
    let lines = codeOnly(model).components(separatedBy: "\n")
    let stored = try NSRegularExpression(
        pattern: #"^    (?:(?:package|private|fileprivate|private\(set\)|package\(set\))\s+)*(?:lazy\s+)?var\s+\w+"#)
    let observed = lines.indices.filter { i in
        let l = lines[i]
        guard stored.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil,
            !l.contains("@ObservationIgnored")
        else { return false }
        if i > 0, lines[i - 1].trimmingCharacters(in: .whitespaces).hasPrefix("@ObservationIgnored"),
            !lines[i - 1].contains("var ")
        {
            return false
        }
        guard let brace = l.firstIndex(of: "{") else { return true }   // `{ didSet` keeps it stored; any other brace: computed
        return l[brace...].contains("didSet") || l[brace...].contains("willSet")
    }
    #expect(observed.count <= 5, "AppModel's observed stored properties: \(observed.count)")
    #expect(observed.count >= 5, "fewer now: lower the ceiling to \(observed.count)")
}

/// The shell doesn't know its built-ins: no id of one, nor of a panel or command one contributes, written in KelpKit as
/// a string (an import of one fails to build already, `builtinsAreModulesTheShellCantName`; a string named one around
/// that). The menu bar is laid out by command id on purpose (MainMenu.swift, AppDelegate's validation of it): the
/// shell's own layout, as Zed's app menus are. The rest is a ceiling that only goes down.
@Test func theShellNamesNoBuiltinByString() throws {
    var names: Set<String> = []
    for f in sources(["Sources/Builtins"]) {
        for p in [
            #"Builtin\("([\w.]+)""#, #"PanelSpec\(\s*id:\s*"([\w.]+)""#, #"(?:CommandSpec\(id:|cmd\()\s*"([\w.]+)""#
        ] {
            let re = try NSRegularExpression(pattern: p)
            for m in re.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)) {
                if let r = Range(m.range(at: 1), in: f.text) { names.insert(String(f.text[r])) }
            }
        }
    }
    #expect(names.count > 50, "the built-ins' names weren't found: \(names.count)")
    let layout: Set<String> = ["Sources/KelpKit/App/MainMenu.swift", "Sources/KelpKit/App/AppDelegate.swift"]
    var named: [String] = []
    for f in sources(["Sources/KelpKit"]) where !layout.contains(f.path) {
        // Strings kept (they're what's looked for), comments not.
        let code = f.text.components(separatedBy: "\n").map { $0.components(separatedBy: "// ").first ?? "" }.joined(
            separator: "\n")
        // Used as one: run, looked up, shown or keyed by it (a setting that shares a command's name isn't the command).
        for n in names {
            let use = try NSRegularExpression(
                pattern: #"(?:command|run|showPanel|key|panel)\(\s*""# + NSRegularExpression.escapedPattern(for: n)
                    + "\"")
            named += use.matches(in: code, range: NSRange(code.startIndex..., in: code)).map { _ in "\(f.path): \(n)" }
        }
    }
    #expect(named.count <= 5, "the shell names built-ins: \(named.sorted())")
    #expect(named.count >= 5, "fewer now (\(named.count)): lower the ceiling")
}

/// The design's values come from DesignKit, not typed in where they're used: a fill's opacity is `fillRest` / `fillHover`
/// / `fillSelected` or `fillTint(_:)`, a text size is one of `TextSize`'s. What still types one (a shadow, a stroke, a
/// drawn icon, a grid's own densities) is counted, and the counts only go down. Settings' pictures draw mock windows and
/// aren't chrome.
@Test func designValuesComeFromDesignKit() throws {
    let pictures = ["SettingPictures", "SettingPreviews", "ThemeGallery", "DockStripPicture"]
    let chrome = { (found: [String]) in found.filter { path in !pictures.contains { path.contains($0) } } }
    let alphas = chrome(try matches(#"withAlphaComponent\(0?\.[0-9]|\.opacity\(0?\.[0-9]"#, in: appDirs))
    #expect(alphas.count <= 23, "opacities typed by hand: \(alphas)")
    #expect(alphas.count >= 23, "fewer now (\(alphas.count)): lower the ceiling")
    let sizes = chrome(try matches(#"\.ui(Digits|Mono)?\([0-9]"#, in: appDirs))
    #expect(sizes.count <= 4, "text sizes typed by hand: \(sizes)")
    #expect(sizes.count >= 4, "fewer now (\(sizes.count)): lower the ceiling")
}
