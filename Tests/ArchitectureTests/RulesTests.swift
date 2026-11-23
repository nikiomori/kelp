import Foundation
import Testing

// More of the rules, read from the sources as ArchitectureTests.swift does (`sources`, `codeOnly`).

/// `@unchecked Sendable` tells the compiler to stop checking: each one is listed with the lock or the thread that makes it
/// safe, and a new one is added here with its own, or it fails. One that goes comes off the list.
@Test func uncheckedSendablesSayWhatGuardsThem() throws {
    let guarded: [String: String] = [
        "Sources/Core/System/FileWatcher.swift: FileWatcher":
            "an FSEventStream, started here and stopped on its own queue",
        "Sources/LSPKit/LSPClient.swift: LSPClient": "Process and Pipe; what changes is under `state`'s lock",
        "Sources/Daemon/Daemon.swift: Running": "the sources, set up and cancelled under `running`'s lock",
        "Sources/Daemon/Sessions/Live/PTY.swift: PTY":
            "its phases under `phase`'s lock, the read source (set on `queue`) too",
        "Sources/EditorKit/SyntaxHighlighter.swift: Worker":
            "the parser and its tree: the main thread's for a short text, `queue`'s alone once long",
        "Sources/EditorKit/SyntaxHighlighter.swift: Text": "an immutable copy of the text, or read under `queue.sync`",
        "Sources/EditorKit/Folding.swift: Folds": "the main thread only: the layout manager asks for glyphs there",
        "Sources/EditorKit/SuggestionGhost.swift: GhostRoom": "the main thread only: the layout manager lays out there",
        "Sources/Builtins/Files/FileNode.swift: FileNode":
            "a tree built off the main actor (`FileNode.update`) and handed over whole: read and changed on main only"
    ]
    // Up to the declaration's brace, so a conformance wrapped onto a line of its own counts too.
    let declaration = try NSRegularExpression(
        pattern: #"\b(?:class|struct|enum|actor|extension)\s+(\w+)\b[^{]*@unchecked\s+Sendable"#)
    func named(_ re: NSRegularExpression) -> Set<String> {
        Set(
            sources(["Sources"]).flatMap { f in
                let code = codeOnly(f.text)
                return re.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { m in
                    Range(m.range(at: 1), in: code).map { "\(f.path): \(code[$0])" }
                }
            })
    }
    let found = named(declaration)
    #expect(found.subtracting(guarded.keys).sorted() == [], "new: list each with what guards it")
    #expect(Set(guarded.keys).subtracting(found).sorted() == [], "gone: take it off the list")
    // `nonisolated(unsafe)` stops the same checks for one value. The daemon's code has none
    // (`theDaemonKeepsNoProcessGlobals`); the rest's are listed the same way.
    let unsafeGuarded: [String: String] = [
        "Sources/kelpd/main.swift: sources": "top-level code on the main thread; the handlers only keep it alive",
        "Sources/kelp/kelp.swift: args": "the CLI's top-level code, on its one thread",
        "Sources/DesignKit/Glyph.swift: symbolCache": "NSCache is thread-safe; the images it hands out aren't changed",
        "Sources/DesignKit/Formatting.swift: spanFormatters": "NSCache is thread-safe, and so is formatting",
        "Sources/DesignKit/LoadingView.swift: patience": "a test's knob, set and read on the main thread",
        "Sources/Builtins/Databases/EnginePresets.swift: text": "made once and only read by the image's drawing block",
        "Sources/KelpKit/App/Updates.swift: install":
            "Sparkle's block, called on the main thread where it was handed over"
    ]
    let unsafe = named(
        try NSRegularExpression(
            pattern:
                #"nonisolated\(unsafe\)\s+(?:(?:private|fileprivate|public|package|static)\s+)*(?:let|var)\s+(\w+)"#
        ))
    #expect(unsafe.subtracting(unsafeGuarded.keys).sorted() == [], "new: list each with what guards it")
    #expect(Set(unsafeGuarded.keys).subtracting(unsafe).sorted() == [], "gone: take it off the list")
}

/// Every method is called by a test, by its type or its name: one no test calls can break unseen. The ones no test calls
/// yet are listed; the list only shrinks (a new method comes with its test, and one that gets a test comes off it). A
/// call is made in code: `Name(…)` or `Name.name` handed to a function (`c.call(Name(…))`, `vms.create(Name(…))`, a
/// `let` of one handed on), `Name(…).handle(`, or its wire name as a string. One only made (`_ = Name()`), built only
/// for the agent rules' tables (AgentRules*Tests.swift) or to read its `.fence` runs no handler.
@Test func everyMethodIsCalledByATest() throws {
    let untested: Set<String> = [
        "DaemonBackgroundAllowed", "ProcessRefreshPath",   // their answer in a test is the harness's (no app, PATH given)
        "RepoCloneCancel",   // a clone that runs isn't cancelled in any test yet
        "EditorNextEditStart"   // it starts the real llama-server: the app's Turn On, not a test's
    ]
    let declaration = try NSRegularExpression(
        pattern: #"(?:struct|enum) (\w+): [^{\n]*\b(?:RPCMethod|InternalMethod)\b[^{]*\{"#)
    var methods: [String: String] = [:]   // type → wire name
    for f in sources(["Sources/Core"]) {
        for m in declaration.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)) {
            guard let type = Range(m.range(at: 1), in: f.text), let end = Range(m.range, in: f.text) else { continue }
            let name = f.text[end.upperBound...].firstMatch(of: /static let name = "([^"]+)"/).map { String($0.1) }
            methods[String(f.text[type])] = name ?? ""
        }
    }
    #expect(methods.count > 150, "the methods weren't found: \(methods.count)")
    let tests = sources(["Tests"]).filter {
        !$0.path.hasPrefix("Tests/ArchitectureTests/") && !$0.path.hasPrefix("Tests/DaemonTests/AgentRules")
    }
    let handed = #"(?:[\w?!)]\(\s*|\w:\s*)(?:try\s+)?(?:await\s+)?"#   // a call's first argument, or a labelled one
    let made = try NSRegularExpression(
        pattern: handed + #"([A-Z]\w*)(?:\(|\.name\b)|\b([A-Z]\w*)\((?:[^()]|\([^()]*\))*\)\.handle\("#)
    let fenceOnly = try NSRegularExpression(pattern: #"\b[A-Z]\w*\((?:[^()]|\([^()]*\))*\)\.fence\b"#)
    let names = Set(
        tests.flatMap { f in
            let all = codeOnly(f.text)
            let code = fenceOnly.stringByReplacingMatches(
                in: all, range: NSRange(all.startIndex..., in: all), withTemplate: "")
            let direct = made.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { m in
                [1, 2].lazy.compactMap { Range(m.range(at: $0), in: code) }.first.map { String(code[$0]) }
            }
            // `let add = ArtifactAdd(…)`, then `c.call(add)`.
            let kept = code.matches(of: #/\blet (\w+) = ([A-Z]\w*)\(/#).filter { m in
                code.range(of: handed + "\\b\(m.1)\\s*[,)]", options: .regularExpression) != nil
            }.map { String($0.2) }
            return direct + kept
        })
    // Strings kept, comments gone (a `//` after a space or at a line's start: not the one in "https://").
    let comment = #"(?m)(^|\s)//.*$"#
    let text = tests.map { $0.text.replacingOccurrences(of: comment, with: "", options: .regularExpression) }
        .joined(separator: "\n")
    let called = Set(
        methods.filter { type, name in names.contains(type) || (!name.isEmpty && text.contains("\"\(name)\"")) }.keys)
    let uncalled = Set(methods.keys).subtracting(called)
    #expect(uncalled.subtracting(untested).sorted() == [], "no test calls these: add one")
    #expect(untested.subtracting(uncalled).sorted() == [], "called by a test now, or gone: take them off the list")
}

/// Every `RPCEvent` is in `rpcEvents`: one left out is sent by the daemon, dropped by every client and missing from
/// rpc.json, and nothing says so.
@Test func everyEventIsListed() throws {
    let declaration = try NSRegularExpression(pattern: #"\b(?:struct|enum|extension) (\w+):[^{\n]*\bRPCEvent\b"#)
    var declared: Set<String> = []
    for f in sources(["Sources/Core"]) {
        for m in declaration.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)) {
            if let type = Range(m.range(at: 1), in: f.text) { declared.insert(String(f.text[type])) }
        }
    }
    let events = try #require(sources(["Sources/Core"]).first { $0.path.hasSuffix("/Events.swift") }?.text)
    let list = try #require(events.firstMatch(of: /rpcEvents: \[any RPCEvent\.Type\] = \[([^\]]*)\]/)?.1)
    let listed = Set(list.matches(of: /(\w+)\.self/).map { String($0.1) })
    #expect(declared.count > 20, "the events weren't found: \(declared.count)")
    #expect(declared.subtracting(listed).sorted() == [], "add these to rpcEvents (Core/Wire/Events.swift)")
    #expect(listed.subtracting(declared).sorted() == [], "listed but not an RPCEvent")
}

/// "Is this path in that folder" is `Paths.inside`, which follows links and `..`: by hand (`a == b || a.hasPrefix(b +
/// "/")`, a workspace found by `hasPrefix($0.path + "/")`) a path spelled another way (/tmp for /private/tmp, a link)
/// isn't in its own project. (A `hasPrefix(root + "/")` that then drops the root to show the rest is a string's, not
/// this question, so it isn't counted.)
@Test func pathsAreCheckedForAFolderOneWay() throws {
    let byHand = try NSRegularExpression(
        pattern: #"\.hasPrefix\(\$0\.path \+ \)|\b([\w.$]+) == ([\w.$]+) \|\| \1\.hasPrefix\(\2 \+ \)"#)
    let found = sources(["Sources"]).flatMap { f in
        let code = codeOnly(f.text)
        return byHand.matches(in: code, range: NSRange(code.startIndex..., in: code)).map { m in
            "\(f.path):\(code[..<(Range(m.range, in: code)?.lowerBound ?? code.startIndex)].filter { $0 == "\n" }.count + 1)"
        }
    }
    #expect(found == [], "use Paths.inside")
    // Any other `x.hasPrefix(y + "/")`: each file that has one says why it isn't this question, or it fails.
    let spelled: [String: String] = [
        "Sources/Core/System/Paths.swift": "`Paths.relative`, given a root it then drops",
        "Sources/Core/System/RemoteHost.swift": "a host's path, which this Mac can't resolve",
        "Sources/Core/Extensions/ExtensionFiles.swift": "both sides resolved first (`Paths.real`)",
        "Sources/Core/VM/VMs.swift": "a standardized path against the home folder, then the part below it",
        "Sources/Builtins/Agents/Addons/AddonTexts.swift": "an item's path against folders built from the same root",
        "Sources/Builtins/Browser/BrowserHistory.swift": "addresses, not paths",
        "Sources/Builtins/Files/FilesPanel+Outline.swift": "the file tree's keys, all spelled from its root",
        "Sources/Builtins/Files/FilesSearch.swift": "the search's keys, spelled from its root",
        "Sources/Builtins/Files/FileNode.swift": "the file tree's keys, all spelled from its root",
        "Sources/Daemon/Databases/DatabaseCopy.swift": "both sides resolved first, after `Paths.inside`",
        "Sources/Daemon/Hosts/HostFiles.swift": "a host's path, which this Mac can't resolve",
        "Sources/Daemon/Workspaces/DiskUsage+Host.swift": "a host's paths, rebased from one root to another",
        "Sources/Daemon/Workspaces/DiskUsage.swift": "paths of one listing (git's, du's), relative or spelled alike",
        "Sources/KelpKit/Extensions/ExtPages.swift": "both sides resolved first (`resolvingSymlinksInPath`)"
    ]
    let prefix = try NSRegularExpression(pattern: #"\.hasPrefix\([\w.$]+ \+ "/"\)"#)
    let files = Set(
        sources(["Sources"]).filter { f in
            let code = f.text.replacingOccurrences(of: #"(?m)(^|\s)//.*$"#, with: "", options: .regularExpression)
            return prefix.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        }.map(\.path))
    #expect(files.subtracting(spelled.keys).sorted() == [], "use Paths.inside, or say here why it's not that question")
    #expect(Set(spelled.keys).subtracting(files).sorted() == [], "none left: take it off the list")
}

/// The main window is Workbench's to reach (`Shell/Workbench*.swift`): the rest of the shell asks it (`editors`,
/// `mainWindow`, `showPanel`…), as the built-ins do, so what acts on the window has one way in. The window hands itself
/// over (MainWindow.swift), the one place outside that names it.
@Test func theWindowIsReachedThroughTheWorkbench() throws {
    let reach = try NSRegularExpression(pattern: #"\bworkbench\.window\b(?!\s*=\s*self\b)"#)
    let found = sources(["Sources/KelpKit", "Sources/Builtins"]).filter {
        !(($0.path as NSString).lastPathComponent.hasPrefix("Workbench") && $0.path.contains("/Shell/"))
    }.flatMap { f in
        let code = codeOnly(f.text)
        return reach.matches(in: code, range: NSRange(code.startIndex..., in: code)).map { _ in f.path }
    }
    #expect(found == [], "the window reached around Workbench: \(found)")
}

/// Only TerminalKit touches libghostty: its C API moves with every Ghostty, and a second place that calls it is a second
/// place to fix. (The app's target is given GhosttyKit too, to link it, so the compiler alone doesn't hold this.)
@Test func onlyTerminalKitTouchesGhostty() throws {
    let found = try matches(#"^import GhosttyKit\b|\bghostty_\w+\("#, in: ["Sources"])
    #expect(found.filter { !$0.hasPrefix("Sources/TerminalKit/") } == [])
}

/// State is `@Observable` and AppKit follows it with `track`: a notification of the app's own ("go read X again")
/// reaches whoever remembered to listen, and nothing says who didn't. AppKit's own (a window resized) aren't these.
@Test func theAppSendsNoNotificationsOfItsOwn() throws {
    let below = ["Sources/DesignKit", "Sources/EditorKit", "Sources/WorkbenchKit", "Sources/Core"]
    let names = try matches(#"Notification\.Name\("#, in: appDirs + below)
    #expect(names == [])
}

/// `MainActor.assumeIsolated` crashes off the main thread and nothing checks it before it runs: each says, on its line or
/// the one above, which callback of AppKit, WebKit or FileWatcher brought it there. The count is the ones that don't
/// say yet. (TerminalKit's aren't counted: it changes only when asked.)
@Test func anAssumedMainThreadSaysWhoCalled() {
    let bare = sources(["Sources"]).filter { !$0.path.hasPrefix("Sources/TerminalKit/") }.flatMap { f in
        let lines = f.text.components(separatedBy: "\n")
        return lines.indices.filter { i in
            lines[i].contains("MainActor.assumeIsolated") && !lines[i].contains("//")
                && !(i > 0 && lines[i - 1].contains("//"))
        }.map { "\(f.path):\($0 + 1)" }
    }
    #expect(bare.count <= 37, "say which callback delivers it on the main thread: \(bare)")
    #expect(bare.count >= 37, "\(bare.count) say nothing now: lower this")
}

/// UserDefaults holds what one Mac likes to see (a width, a fold, the agent asked last). What names a daemon's record
/// (a workspace, a session, a project) is the daemon's (`UIState`, `state.get|set`), where a second window, the phone
/// and a restored home find it; the daemon and the libraries keep no defaults at all. A budget, not a ratchet: a new
/// per-Mac preference raises it, said in the commit; state that names a record goes to `UIState` instead.
@Test func defaultsHoldOnlyWhatOneMacPrefers() throws {
    // SwiftUI's `@AppStorage` and `@SceneStorage` are UserDefaults by another name.
    let all = try matches(#"\bUserDefaults\b|@AppStorage\b|@SceneStorage\b"#, in: ["Sources"])
    let app = all.filter { f in appDirs.contains { f.hasPrefix($0 + "/") } }
    #expect(app.count <= 72, "names a workspace, session or project? UIState. A per-Mac preference: raise this")
    #expect(app.count >= 72, "\(app.count) now: lower this")
    #expect(all.count == app.count, "defaults under the app: \(all.filter { !app.contains($0) })")
}

/// A wait (`asyncAfter`) where an event says the thing is ready works on the Mac it was timed on and nowhere slower:
/// follow the event (`track`, a delegate call, a completion); a wait that is motion takes `Motion`'s time through
/// `Debounce` or a timer its owner can cancel. The count is the ones there are; it only goes down.
@Test func theAppWaitsForEventsNotForTime() throws {
    let waits = try matches(#"\.asyncAfter\("#, in: appDirs)
    // +2 that are timers, not waits: a command the user's page holds gives up (`AgentDrive.handedBack`), and the strip
    // asks whether to hand a page back that the user left alone (`BrowserTab.remindAfter`).
    #expect(waits.count <= 19, "a wait in place of the event that says it's ready: \(waits)")
    #expect(waits.count >= 19, "\(waits.count) now: lower this")
}

/// A test waits for what it waits on (`waitFor`), not for a time: a sleep guesses how long something takes, too long on
/// a quiet machine and too short on a busy one, and a "nothing happened" after one passes whatever happened later. The
/// count holds both ways: a sleep that goes lowers it. A wait handed to a clock (`asyncAfter`, a timer) is one too.
@Test func testsSleepOnlyWhereTimeIsTheSubject() throws {
    let sleep = try NSRegularExpression(
        pattern: #"Task\.sleep|usleep\(|Thread\.sleep|sleep\(for:|\.asyncAfter\(|\bscheduledTimer\(|\bTimer\("#)
    let count = sources(["Tests"]).map { f in
        let code = codeOnly(f.text)
        return sleep.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }.reduce(0, +)
    #expect(count == 23, "sleeps in the tests: wait for the event instead (`waitFor`), or lower the count")
}

/// A test's limit grows with its waits (`.timeLimit(minutes:)` from TestSupport): a fixed one beside waits stretched by
/// KELP_TEST_SLOW failed CI runs whose waits all held.
@Test func testLimitsGrowWithTheirWaits() throws {
    let fixed = try matches(#"\.timeLimit\(\.minutes"#, in: ["Tests"]).filter { !$0.hasPrefix("Tests/TestSupport/") }
    #expect(fixed.isEmpty, "a fixed time limit: use .timeLimit(minutes:) \(fixed)")
}

/// What `try?` drops, spelled out: a `catch {}`, or one that only returns a stand-in (`return`, `return nil`, `[]`,
/// `false`, a string…) or goes on (`continue`, `break`). `failuresAreNotSwallowed` counts the `try?`s. Each module's
/// count is a ceiling that holds both ways.
@Test func emptyCatchesAreCounted() throws {
    let ceilings = [
        "Daemon": 39, "Core": 16, "Builtins": 29, "KelpKit": 7, "DesignKit": 6, "EditorKit": 3, "kelp": 2, "KelpVM": 2,
        "Agents": 1, "LSPKit": 1, "GitKit": 1, "Integrations": 1
    ]
    let modules = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources").path)
        .filter { !$0.hasPrefix(".") }
    // Strings are gone from the code read (`codeOnly`): `return "none"` reads as `return`.
    let emptyCatch = try NSRegularExpression(
        pattern:
            #"catch(?:\s+_|\s+let\s+\w+)?\s*\{\s*(?:(?:return(?:\s+(?:nil|\[\]|\[:\]|false|true|0|\.none))?|continue|break)\s*)?\}"#
    )
    for module in modules {
        let ceiling = ceilings[module] ?? 0
        let n = sources(["Sources/" + module]).map { f in
            let code = codeOnly(f.text)
            return emptyCatch.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
        }.reduce(0, +)
        #expect(n <= ceiling, "empty catches in \(module): \(n), over its ceiling")
        #expect(n >= ceiling, "empty catches in \(module): \(n), under its ceiling \(ceiling): lower it")
    }
}
