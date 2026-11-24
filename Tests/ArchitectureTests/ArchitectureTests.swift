import Foundation
import Testing

// The rules in docs/architecture.md, read from the sources. Each number is a ceiling: when a change brings a count under it,
// lower it to the new count in the same commit, so nothing creeps back. The `try?` ones are exact (lowered or the test fails).
// KelpKit's `package` count is a budget, not a ratchet: it rises with a feature that needs more of the shell, said beside it.

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// The app: its target (main.swift and the list of built-ins), the shell (KelpKit) and the built-ins' modules.
let appDirs = ["Sources/KelpApp", "Sources/KelpKit", "Sources/Builtins"]

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

func matches(_ pattern: String, in dirs: [String]) throws -> [String] {
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
/// AppModel.swift itself is the way, DaemonLink.swift manages the connection and Watching.swift tells each connection
/// its watches, so they aren't counted. A call on anything but the app (`app.`, `model.`, `self.app.`, AppModel's
/// `self`) is the raw client, whatever its name or the chain it's reached through (`app.client?.call`). A `try?` counts
/// wrapped too: `try?` and `await` on lines of their own, or the call on the line after its receiver.
@Test func daemonErrorsAreNotSwallowed() throws {
    let way = [
        "Sources/KelpKit/Model/AppModel.swift:", "Sources/KelpKit/Model/DaemonLink.swift:",
        "Sources/KelpKit/Model/Watching.swift:"
    ]
    func outside(_ found: [String]) -> [String] { found.filter { f in !way.contains { f.hasPrefix($0) } } }
    let swallowed = outside(
        try matches(#"try\?\s+await\s+(?:[^=\n]*(?:\n\s*)?\.)?(call|get|tryCall)\("#, in: appDirs))
    let receiver = try NSRegularExpression(
        pattern:
            #"(?<![\w.?!])(?!(?:self[?!]?\.)?(?:app|model)[?!]?\.(?:call|notify)\(|self[?!]?\.(?:call|notify)\()(?:\w+[?!]?\.)+(?:call|notify)\("#
    )
    let raw = outside(
        sources(appDirs).flatMap { f in
            let code = codeOnly(f.text)
            return receiver.matches(in: code, range: NSRange(code.startIndex..., in: code)).map { m in
                "\(f.path):\(code[..<(Range(m.range, in: code)?.lowerBound ?? code.startIndex)].filter { $0 == "\n" }.count + 1)"
            }
        })
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
        let code = codeOnly(f.text)
        return modules.contains { code.range(of: #"\bimport\s+\#($0)\b"#, options: .regularExpression) != nil }
    }
    #expect(importing.map(\.path) == [], "a built-in imported by the shell or by another built-in")
    // Each target of the shell or a built-in, read whole to its closing parenthesis: its dependencies can go on over
    // lines (KelpKit's do).
    let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        .replacingOccurrences(of: #"(?m)(^|\s)//.*$"#, with: "", options: .regularExpression)
    var checked: [String] = []
    for start in manifest.matches(of: #/\.(?:target|executableTarget)\(\s*name:\s*"(\w+)"/#)
    where start.1 == "KelpKit" || start.1.hasPrefix("Builtin") {
        var depth = 1, end = start.range.upperBound   // inside the target's parenthesis
        while depth > 0, end < manifest.endIndex {
            depth += manifest[end] == "(" ? 1 : manifest[end] == ")" ? -1 : 0
            end = manifest.index(after: end)
        }
        let target = manifest[start.range.lowerBound..<end]
        #expect(!modules.contains { $0 != start.1 && target.contains("\"\($0)\"") }, "depends on a built-in: \(target)")
        checked.append(String(start.1))
    }
    #expect(Set(checked) == Set(modules + ["KelpKit"]), "the targets weren't all found: \(checked)")
    // The window's own parts stay the shell's: nothing in them is declared for a built-in to reach.
    let windowParts =
        sources(["Sources/KelpKit/Sidebar", "Sources/KelpKit/Inspector"])
        + sources(["Sources/KelpKit/Shell"]).filter { ($0.path as NSString).lastPathComponent.hasPrefix("MainWindow") }
    #expect(windowParts.filter { codeOnly($0.text).contains("package ") }.map(\.path) == [])
    // What the built-ins may reach of the shell. It goes down when a built-in stops using one (that goes too), and up only
    // with a built-in feature that needs the shell, said beside the number: what the feature does itself stays in its
    // module, and the number counts what the shell had to open, not a goal it's kept under.
    // Every `package` a declaration carries, wherever it stands in it (`private(set) package var`, `override package
    // func`, a one-line extension's members), not only lines that start with one.
    let token = try NSRegularExpression(
        pattern:
            #"\bpackage\s+(?:(?:internal|private|fileprivate)\(set\)|(?:static|final|override|lazy|nonisolated|convenience|required|init|mutating|nonmutating|weak|unowned|dynamic|indirect|prefix|postfix|infix)\b|(?:func|var|let|class|struct|enum|protocol|typealias|subscript|actor|macro)\b|init\b)|\bpackage\(set\)"#
    )
    let declared = sources(["Sources/KelpKit"]).map { f in
        let code = codeOnly(f.text)
        return token.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }.reduce(0, +)
    // A `package extension` makes each member it holds `package` unsaid, where the count doesn't see them.
    let wholesale = try matches(#"\bpackage\s+extension\b"#, in: ["Sources/KelpKit"])
    #expect(wholesale == [], "mark each member `package` instead, so each is counted")
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
    // +4: its tile shows a workspace's CI as the sidebar's row does (`FolderCI`'s `mark`, `row`, `line`, `open`): the
    // mark is Git's to draw (`CIMark`), the shell only places it.
    // +1: the browser's pointer wears the agent's colour, as its tile in the catalog does (`AgentCatalog.color`).
    // +5: the Databases panel colours a database and a group as the sidebar does a project (`ProjectColor`, its `color`,
    // `read`, `value`, and the menu's Color row `addColor`).
    // +3: Open Database lists its rows in the palette (`QuickItem`, its `init`, `showList`), not in a palette of its
    // own.
    // +5: a SwiftUI tab (`HostedTabContent`), which Servers, Routines and Machines each wrote as a class of their own.
    // +4: a panel the inspector hides redraws once it shows, not on every change meanwhile (`WhenShown`: Artifacts,
    // Source Control, Files, Activity).
    // +1: a workspace's git and CI are watched and read under its folder's key (`gitKey`), as the sidebar's, so
    // workspaces sharing a folder share one watch.
    // +2: what an agent edited is pushed as the commands are (`EditsEvent`'s `key`, `forgottenWith`).
    // +1: a session a built-in starts other than by `starter` is asked at its terminal's size too (`sized`).
    // 350 → 347: three no built-in reached (BranchChip's `init(frame:)`, GitFix's `type`, a sheet's `close`).
    // +1: an agent's bar lists the commands on its line from the shell's index (`onLine(of:)`), not a scan of all sessions.
    // +2: ⌘P lists the files the Files panel was last told (`FilesEvent`'s `key`, `forgottenWith`, moved from Files).
    // +1: a server's and a machine's rows open their page in a window of its own (`openInOwnWindow`).
    // +16 so an agent's page shows outside its tab: what the browser tells the shell of each page it drives (`AgentPages`,
    // its `Page`, `Holder`, `drives` / `change` / `acted` / `closed`), and what the shell asks of a page (`DrivenPage`).
    // +4: one kind of mark on a row for every built-in (`RowMark`, its place, view, tip, key, open, `==`), the session
    // marks' type and the four of `FolderCI` the Dock strip read gone.
    // 371 → 359: an agent's page is the Browser built-in's again: it shows on the row, the tab and the card through the
    // shell's generic places (`RowMark`, `TabProvider.driven`, `agentCards`, `subagentSteps`, `browser`), and acts in a
    // loaded workspace's tabs through Workbench (`loadedTabs`, `content`, `openBeside`); a subagent's `title` is read.
    // +3: a project's open pull requests are read from their watch by the Issues panel, ⌘P's "#" (Issues', through
    // `quickPrefixes`) and the new-branch sheet alike (`PRsEvent`'s `key`, `forgottenWith`, `open`).
    // +3: a .kelp.yaml's trust is the shell's to ask (`KelpFile`, its `init`, `trusted`), so a layout template and a new
    // workspace's setup run with Run turned off; Run asks it there too.
    // +2: one rule for which agent text goes to (`FileActions.agents`, `agent`, `pickAgent` for `targetAgent`), so a
    // diff's findings, a pull request's fixes and Send to Agent pick alike and none goes to a reviewer.
    // +1 −1: a folder made from Issues asks about its setup (`KelpFile.setup`); the editor's sample is Files' own.
    // −1: a notification's Continue to the sessions it is about is the shell's (`notifyUser`'s `goingOn`), so a
    // built-in no longer names its category and calls `goOn` itself.
    // +2: a built-in's tooltip or sentence that names a command's key reads the key as it stands (`hint`, `keyText`),
    // so a key rebound in Settings › Keyboard isn't still the old one on Git's, Run's and the editor's buttons.
    // +3: a file's status bar card turns code suggestions off in its language's files and says which
    // (`setOwn`, `LanguageName`, its `of`), as Settings' language picker does.
    // +3, nothing new: a `package internal(set)` is counted too (`inFocusMode`, `page`, `byKey`), as it is surface.
    // 2026-11-19: making every one internal and putting back what the compiler asked for took none away: the built-ins
    // use all 374. +1: Files waits for the settings to have been read (`SettingsStore.loaded`).
    // +2: the commit agent's mark follows its session as every mark does (`StatusMark.follow`), and a CI tooltip
    // names the site a ⌘-click opens (`CIRunLook.clickTip`).
    #expect(declared == 377, "\(declared) package declarations in KelpKit: fewer now, lower the count")
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

/// A line too long to take in at once: a call, a condition or a chain split over lines reads better. Lines that are one
/// long string (UI text) don't count, nor do comments past 160; lint warns past 180.
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
    // counted, and so are comments, which swift-format leaves as they are; the count only goes down.
    let over120 = sources(["Sources"]).flatMap { f in
        f.text.split(separator: "\n").filter { l in
            l.count > 120 && longString.firstMatch(in: String(l), range: NSRange(l.startIndex..., in: l)) == nil
        }
    }.count
    #expect(over120 <= 374, "lines over 120: \(over120)")
    #expect(over120 >= 374, "fewer now (\(over120)): lower the ceiling")
}

/// A setting is declared once, its default with it (`SettingKeys`), and read by that declaration: a key spelled out
/// where it's read can drift from its row's and repeats the default by hand.
@Test func settingsAreReadByTheirDeclaration() throws {
    let named = try matches(
        #"settings(?:\[|\.(?:string|bool|number|int|double|value)\()\s*"[a-z]+\.[\w.]+"#, in: ["Sources"])
    #expect(named == [], "settings read by a key literal")
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
    // Past 400 lines, comments and all, is the review's mark (`files_over_400` in scripts/metrics.py): those there are
    // the debt, a count that only goes down.
    let over400 = sources(["Sources"]).filter { f in
        f.text.split(separator: "\n", omittingEmptySubsequences: false).count > 400
    }.count
    #expect(over400 == 10, "files over 400 lines: \(over400); fewer now: lower the count")
}

/// The daemon starts every program (an extension's command, a formatter, a notebook run, an agent's --version:
/// `process.run`), with its time limits, its process-tree kill and its trust checks; the app starts none. Two exceptions:
/// the app launching kelpd itself, and DevAids' `sample` of a stuck main thread (a developer's tool). Core's helpers that
/// start one count too: LoginPath runs the login shell (the app asks the daemon: `process.which`), the library's index and
/// download run curl and tar.
/// The daemon runs a program through `offload` (its slots cap how many at once), or VM making's `blocking`: never the
/// async `Subprocess.run`, which starts a thread of its own past every cap.
@Test func theDaemonRunsProgramsThroughItsSlots() throws {
    #expect(try matches(#"await\s+Subprocess\.run\("#, in: ["Sources/Daemon"]) == [])
}

@Test func theAppStartsNoPrograms() throws {
    let allowed = ["Sources/KelpKit/Model/DaemonLink.swift", "Sources/KelpKit/DevAids/DevAids.swift"]
    let starter =
        #"\bProcess\(\)|\bProcess\.run\(|\blaunchedProcess\(|posix_spawn|\bNSTask\b|(?<![.\w])(?:popen|system)\("#
    let found = try matches(
        starter + #"|\bSubprocess\.|\bLoginPath\.|\bfetchExtension\(|\blibrary\(index"#, in: appDirs
    )
    .filter { f in !allowed.contains { f.hasPrefix($0 + ":") } }
    #expect(found == [])
    // A new Core helper that starts a program: add what the app could call to the pattern above.
    let starters = Set(
        try matches(starter + #"|\bSubprocess\.run\("#, in: ["Sources/Core"]).map {
            String($0.split(separator: ":")[0])
        })
    let core = ["System/Subprocess", "System/LoginPath", "Extensions/ExtensionFiles"].map { "Sources/Core/\($0).swift" }
    #expect(starters == Set(core))
}

/// A handler that types into a session, stops one or a process, ends a workspace's agents or answers a question says on
/// what in its `fence` (`actsOn`, `answersQuestion`, `reportsFor`, `inWorkspace`, `ends`, `onlyFromKelp`), so
/// `Daemon.allow` checks it before an agent's call gets that far. One that doesn't is a way around the check.
@Test func whatActsOnASessionSaysOnWhich() throws {
    let acts =
        #/SessionSend\(|\.submit\(|\.userInput\(|\.write\(data\)|\.continueAt\(|answerPermission\(|\.terminate\(|\bkill\(/#
    let ends = #/pauseSessions\(|sessions\.discard\(|\.archive\(|removeWorkspace\(/#
    let says = #/\b(actsOn|answersQuestion|reportsFor|inWorkspace|ends|onlyFromKelp):/#
    // What types text in (a send, raw input) names that session as `typesInto` too: a question there refuses an agent's.
    let types = #/SessionSend\(|\.submit\(|\.userInput\(/#
    // Ends only what it made itself in the same call, never something the caller names: nothing for a fence to check.
    let endsOnlyItsOwn = ["TaskFromIssue"]   // the group made for an agent that then didn't start
    var unsaid: [String] = [], untyped: [String] = []
    for f in sources(["Sources/Daemon"]) {
        for piece in f.text.components(separatedBy: "\nextension ").dropFirst() {
            let head = String(piece.prefix { $0 != "\n" })
            guard head.contains(#/: [^{]*\b(Handled|AsyncHandled|SessionInput)\b/#) else { continue }
            let oneLine = head.hasSuffix("}") && head.filter { $0 == "{" }.count == head.filter { $0 == "}" }.count
            let body = oneLine ? head : piece.components(separatedBy: "\n}").first ?? piece
            let name = String(head.prefix { $0 != ":" })
            if body.contains(acts) || (body.contains(ends) && !endsOnlyItsOwn.contains(name)), !body.contains(says) {
                unsaid.append("\(f.path): \(head.prefix { $0 != ":" })")
            }
            if body.contains(types), !body.contains(#/\btypesInto:/#) {
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
        // The editor and DesignKit run in the app too: each of theirs is a one-shot wait that a newer event cancels.
        "EditorKit/CodeEditor+Suggestion.swift": (2, "the pause in typing before a suggestion or a next edit is asked"),
        "EditorKit/CodeEditor+Hover.swift": (1, "a short wait before a signature is asked for"),
        "DesignKit/HoverPopover.swift": (1, "the hover delay before a popover shows"),
        "DesignKit/Latency.swift": (1, "`whileSlow`: a spinner only once a wait passes a second"),
        "DesignKit/LoadingView.swift": (
            4, "when the loading note (and a SwiftUI page's `LoadingPage`) shows, how long it can stay, its least time"
        ),
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
        "Builtins/Files/MarkdownTab+Render.swift": (1, "typing settles before the preview renders again"),
        "Builtins/Databases/DatabaseForm.swift": (1, "typing settles before Add Database connects to check it"),
        "Builtins/Databases/DatabaseTab+Table.swift": (
            1, "a read says Reading… only past half a second: a quick one doesn't flicker"
        ),
        "Builtins/Agents/Addons/AddonsPanel+Loading.swift": (2, "a read shows past 150 ms and stays 400 ms"),
        "Builtins/Databases/DatabaseTab+Opening.swift": (
            1, "Connecting to … shows past half a second: a quick open doesn't flicker"
        ),
        "KelpKit/Extensions/ExtListView.swift": (1, "an extension's refresh interval"),
        "KelpKit/Extensions/ExtListView+Rows.swift": (1, "a row's shown busy spinner stays 0.4 s"),
        "KelpKit/Sidebar/HoverCardViews.swift": (1, "a card's shown wait stays 0.4 s, so a quick read doesn't flicker"),
        "Builtins/Files/EditorStatusBar.swift": (1, "a shown \"Finding the definition…\" stays 0.4 s"),
        "Builtins/Files/Disk/DiskFoot.swift": (1, "a measure on this Mac shows its wait only after a second"),
        "Builtins/Databases/DatabaseSheet.swift": (1, "a shown look for other apps' connections stays 0.4 s"),
        "KelpKit/Extensions/DeclarativeExtension.swift": (
            1, "an extension's own refresh interval for its panel's badge command"
        ),
        "KelpKit/Model/UIState.swift": (
            1,
            "the daemon's state read again, three times at most, after a read that failed, while that daemon is still there"
        ),
        "KelpKit/Inspector/InspectorParts.swift": (
            1, "a menu the pointer opened looks, while it's open, whether the pointer left it: tracking sends no exit"
        ),
        "Builtins/Browser/AgentPages.swift": (1, "a page an agent acted on stays lit for ten seconds, then goes grey"),
        "Builtins/Browser/BrowserRecording.swift": (
            1, "a recording's frames, ten a second: WebKit says when it drew none"
        ),
        "Builtins/Browser/BrowserAutomation.swift": (
            4,
            "kelp browser waits for a page to load, to go quiet after an action, or to show what it was told to wait for: "
                + "WebKit says none of them"
        )
    ]
    let all = try matches(
        #"repeats: true|Task\.sleep\(|makeTimerSource|publish\(every:|[Cc]lock\(\)?\.sleep\(|Thread\.sleep|usleep\("#,
        in: appDirs + ["Sources/EditorKit", "Sources/DesignKit"])
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
    let byRoot = try handlersByRoot(byService)   // a wrapper handed all of Sessions counts as Sessions
    #expect(byRoot.values.allSatisfy { $0 <= 40 }, "a service answers more than 40 methods: \(byRoot)")
    // 40, at the cap: Sessions' own 36 and those of what keeps all of it (Routines starts its runs' agents, ChatMoves
    // hands a chat to a new one). The rest keep a part (`WorkspaceSessions`, `AgentAsks`, SourceControl's `send`).
    let most = byRoot.values.max() ?? 0
    #expect(most <= 40, "the busiest service's handlers: \(byRoot)")
    #expect(most >= 40, "fewer now: lower the ceiling")
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
    // The nearest condition above each call is `#if DEBUG` itself, not its `#else`, an `#endif` or another `#if`.
    let directive = #/^\s*#(if|elseif|else|endif)\b/#
    #expect(
        !calls.isEmpty
            && calls.allSatisfy { i in
                lines[..<i].last { $0.contains(directive) }?.trimmingCharacters(in: .whitespaces) == "#if DEBUG"
            })
}

/// A `try?` turns a failure into nothing, unseen: right for a probe ("is it there", "does it parse"), wrong for a write,
/// a cleanup or a store change, which say what failed with `Log.attempt` instead. Each module's count is a ceiling.
@Test func failuresAreNotSwallowed() throws {
    let ceilings = [
        "Daemon": 37, "KelpKit": 41, "Core": 27, "GitKit": 13, "AgentData": 4, "Agents": 13, "kelp": 10,
        "Builtins": 8,
        "Integrations": 7, "LSPKit": 2, "Markdown": 4, "TerminalKit": 3, "KelpVM": 9, "KelpGuest": 4, "EditorKit": 3,
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
    #expect(try matches(#"Fence\(\s*onlyFromKelp:"#, in: ["Sources/Daemon"]).count == 5)
}

/// Who may call a method is its `fence` (`Fence`, whose gates are labels the compiler checks); what else a protocol
/// extension gives defaults for (`Handled.inOrder`, `quick`, `RPCMethod.timeout`) compiles as a property of its own
/// when spelled with another type or name (`static let timeout: TimeInterval` for `TimeInterval?`, `var fenc: Fence`),
/// and the default answers instead, quietly. Each is spelled as its requirement is.
@Test func gatePropertiesHaveTheirRequirementsTypes() throws {
    var wrong = try matches(#"\b(?:static )?(?:var|let) (?!fence\b)\w+: Fence\b"#, in: ["Sources/Daemon"])
    wrong += try matches(#"\b(?:static (?:var|let)|let) fence\b|\bvar fence\b(?!: Fence \{)"#, in: ["Sources/Daemon"])
    wrong += try matches(#"\bstatic (?:var|let) (?:inOrder|quick)\b(?!: Bool \{)"#, in: ["Sources/Daemon"])
    wrong += try matches(
        #"\bstatic (?:var|let) timeout\b(?!: TimeInterval\? \{)"#, in: ["Sources/Core", "Sources/Daemon"])
    #expect(wrong.isEmpty, "spelled unlike their requirements: \(wrong)")
}

/// A requirement with a default misspelled (`static var inOrdr`) is a property of its own, and the protocol's default
/// answers in its place: no property in the daemon is named one or two letters off one.
@Test func noPropertyIsNamedNearlyLikeAGate() throws {
    let gates = ["inOrder", "timeout"]
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
            let words: Set = ["timedOut"]   // a word of its own, a letter or two from a requirement's name
            if !gates.contains(name), !words.contains(name), let g = gates.first(where: { distance($0, name) <= 2 }) {
                near.append("\(f.path): \(name) ~ \(g)")
            }
        }
    }
    #expect(near == [])
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
        "KelpKit/DevAids/DevAids.swift": (1, "snapshots for tests"),
        "KelpKit/DevAids/DevAids+Snapshot.swift": (2, "snapshots for tests"),
        "KelpKit/Sheets/CloneSheet.swift": (2, "whether the folder new projects go in is there"),
        "KelpKit/Settings/IconTheme.swift": (2, "an icon theme an extension brings"),
        "KelpKit/Settings/ExtensionsSettings.swift": (1, "an extension's own folder"),
        "KelpKit/Extensions/Registry.swift": (4, "extensions' folders, Kelp's own"),
        "KelpKit/Extensions/ExtensionInstall.swift": (4, "an extension installed into Kelp's folder, or taken out"),
        "KelpKit/Extensions/DeclarativeExtension.swift": (5, "an extension's manifest, and whether its page is there"),
        "KelpKit/Extensions/ExtensionReview.swift": (1, "an extension's manifest, before it's installed"),
        "KelpKit/Extensions/ExtPages.swift": (1, "an extension's own page, served to its web view"),
        "KelpKit/Extensions/AgentSkills.swift": (6, "the skills Kelp gives agents, and which are there"),
        "KelpKit/Shell/Help.swift": (1, "the guide, written to Kelp's home"),
        "KelpKit/Shell/WorkbenchActions.swift": (1, "a dropped path: a file, a folder, or nothing"),
        "KelpKit/Shell/KelpLinks.swift": (2, "a linked path: a file, a folder, or nothing"),
        "KelpKit/Shell/WorkspaceActions+OpenIn.swift": (1, "whether Open In was handed a file or a folder"),
        "KelpKit/Shell/ProjectIcon.swift": (1, "a project's icon, shown (a remote one's from the copy kelpd keeps)"),
        "Builtins/Agents/Session/PathPreview.swift": (3, "a path a terminal printed is a file, before it's a link"),
        "Builtins/Browser/BrowserTab.swift": (1, "a local page, shown: it reloads as its folder changes"),
        "Builtins/Browser/BrowserRecording.swift": (1, "a recording written over the file it was asked to go to"),
        "Builtins/Browser/BrowserDownloads.swift": (
            2, "a download's folder (~/Downloads, or Kelp's temporary one) and a name not taken there"
        ),
        "Builtins/Files/Preview.swift": (1, "an image's bytes, shown"),
        "Builtins/Databases/DatabaseTab+Table.swift": (1, "rows exported to a file the user picked in a save panel"),
        "Builtins/Files/MarkdownTab+Motion.swift": (
            2, "a video written over the file the user picked in a save panel, or its half taken away on Cancel"
        ),
        "Builtins/Files/Artifacts/PageExport.swift": (
            8,
            "a page exported where the user picked (a save panel, or kelp artifact export's path), and a video's check "
                + "left in the temporary folder for kelp artifact export"
        ),
        "Builtins/Files/Artifacts/PowerPoint.swift": (
            3, "a PowerPoint's parts in a temporary folder, and a page's pictures put inside its one-file export"
        )
    ]
    let all = try matches(
        #"FileManager\.default\.(contents|createFile|moveItem|trashItem|copyItem|removeItem|createDirectory|fileExists|isWritableFile"#
            + #"|enumerator|attributesOfItem|destinationOfSymbolicLink)|FileWatcher\(|FileHandle\(|(String|Data|NSImage|NSDictionary)\(\s*contentsOf"#
            + #"|\.write\(\s*to(File)?:|\bstat\([^()]*&"#
            // `FileManager.default` kept or handed on (`let fm = FileManager.default`) touches files out of sight.
            + #"|FileManager\.default\b(?!\s*\.)"#, in: appDirs)
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
            // however it's spelled: `package extension AppModel`, `@MainActor extension AppModel`
            && file.text.range(of: #"(?m)^(@\w+ +)*(\w+ +)?extension AppModel\b"#, options: .regularExpression)
                != nil
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

/// The design's values come from DesignKit, not typed in where they're used: a size, a radius, a duration (`Metrics`,
/// `Motion`), a text size (`TextSize`), a fill's opacity (`fillRest` / `fillHover` / `fillSelected` or `fillTint(_:)`).
/// What still types one is counted, and each count is a ceiling that only goes down. What's left: a tile's fixed glyph,
/// an icon row's point size, radii concentric with another (9 in a row, 14 and 16 in glass), the colourful icons that
/// need a weight (`NSImage.symbol` itself is DesignKit's), the glass panels, a row's glow, the backdrop's drift, a
/// duration of 0, a shadow, a stroke, a drawn icon, a grid's own densities, a title, a big number.
/// Settings' pictures draw mock windows and aren't chrome.
@Test func designValuesComeFromDesignKit() throws {
    let chromeDirs = ["Sources/KelpKit", "Sources/Builtins"]
    func exactly(_ found: [String], _ count: Int, _ what: String) {
        #expect(found.count <= count, "\(what) typed by hand: \(found)")
        #expect(found.count >= count, "\(what): fewer now (\(found.count)): lower the ceiling")
    }
    exactly(try matches(#"\.font\(\.system\(size"#, in: chromeDirs), 0, "system font sizes")
    exactly(try matches(#"cornerRadius( =|:) *[0-9]"#, in: chromeDirs), 0, "corner radii")
    exactly(try matches(#"systemFont\(ofSize"#, in: chromeDirs), 4, "system fonts at a size")   // a tile's letters
    exactly(try matches(#"xRadius: *[0-9]"#, in: chromeDirs), 5, "drawn radii")   // icon tiles
    exactly(
        try matches(#"\.ui(Mono|Digits)?\(\d"#, in: chromeDirs + ["Sources/DesignKit", "Sources/EditorKit"]), 0,
        "text sizes")
    exactly(try matches(#"NSImage\(systemSymbolName"#, in: chromeDirs), 1, "symbols made by hand")
    // The system's text styles stay at their size whatever Text size says: SwiftUI text takes `Font.ui` too.
    exactly(
        try matches(
            #"\.font\(\.(headline|subheadline|caption|footnote|title|body|callout)"#,
            in: chromeDirs + ["Sources/EditorKit"]),
        0, "system text styles")
    exactly(try matches(#"(cornerRadius|[dD]uration) = \d"#, in: chromeDirs), 2, "radii and durations")
    // A dev aid's, and key bindings read back: neither is motion.
    exactly(try matches(#"\.now\(\) \+ 0\.\d"#, in: chromeDirs), 2, "delays")
    let pictures = ["SettingPictures", "SettingPreviews", "ThemeGallery", "DockStripPicture"]
    let alphas = try matches(#"withAlphaComponent\(0?\.[0-9]|\.opacity\(0?\.[0-9]"#, in: appDirs)
    exactly(alphas.filter { path in !pictures.contains { path.contains($0) } }, 20, "opacities")
    // The editor's too: a fold's plate and its dots.
    exactly(
        try matches(#"withAlphaComponent\(0?\.[0-9]|\.opacity\(0?\.[0-9]"#, in: ["Sources/EditorKit"]), 2,
        "opacities in the editor")
}
