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
        "Sources/Builtins/Files/FileNode.swift: FileNode":
            "a tree built off the main actor (`FileNode.update`) and handed over whole: read and changed on main only"
    ]
    let declaration = try NSRegularExpression(
        pattern: #"\b(?:class|struct|enum|actor|extension)\s+(\w+)\b[^{\n]*@unchecked\s+Sendable"#)
    let found = Set(
        sources(["Sources"]).flatMap { f in
            let code = codeOnly(f.text)
            return declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { m in
                Range(m.range(at: 1), in: code).map { "\(f.path): \(code[$0])" }
            }
        })
    #expect(found.subtracting(guarded.keys).sorted() == [], "new: list each with what guards it")
    #expect(Set(guarded.keys).subtracting(found).sorted() == [], "gone: take it off the list")
}

/// Every method is called by a test, by its type or its name: one no test calls can break unseen. The ones no test calls
/// yet are listed; the list only shrinks (a new method comes with its test, and one that gets a test comes off it).
@Test func everyMethodIsCalledByATest() throws {
    let untested: Set<String> = []
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
    let tests = sources(["Tests"]).filter { !$0.path.hasPrefix("Tests/ArchitectureTests/") }
    let word = try NSRegularExpression(pattern: #"\b[A-Z]\w*"#)
    let names = Set(
        tests.flatMap { f in
            let code = codeOnly(f.text)
            return word.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
                Range($0.range, in: code).map { String(code[$0]) }
            }
        })
    let text = tests.map(\.text).joined(separator: "\n")
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
/// The one left is the Issues panel's, until the daemon pushes what changed on a pull request.
@Test func theAppSendsNoNotificationsOfItsOwn() throws {
    let below = ["Sources/DesignKit", "Sources/EditorKit", "Sources/WorkbenchKit", "Sources/Core"]
    let names = try matches(#"Notification\.Name\("#, in: appDirs + below)
    #expect(names.map { String($0.split(separator: ":")[0]) } == ["Sources/Builtins/Issues/PRWork.swift"])
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
}

/// UserDefaults holds what one Mac likes to see (a width, a fold, the agent asked last). What names a daemon's record
/// (a workspace, a session, a project) is the daemon's (`UIState`, `state.get|set`), where a second window, the phone
/// and a restored home find it; the daemon and the libraries keep no defaults at all. A budget, not a ratchet: a new
/// per-Mac preference raises it, said in the commit; state that names a record goes to `UIState` instead.
@Test func defaultsHoldOnlyWhatOneMacPrefers() throws {
    let all = try matches(#"\bUserDefaults\b"#, in: ["Sources"])
    let app = all.filter { f in appDirs.contains { f.hasPrefix($0 + "/") } }
    #expect(app.count <= 68, "names a workspace, session or project? UIState. A per-Mac preference: raise this")
    #expect(all.count == app.count, "defaults under the app: \(all.filter { !app.contains($0) })")
}

/// A wait (`asyncAfter`) where an event says the thing is ready works on the Mac it was timed on and nowhere slower:
/// follow the event (`track`, a delegate call, a completion); a wait that is motion takes `Motion`'s time through
/// `Debounce` or a timer its owner can cancel. The count is the ones there are; it only goes down.
@Test func theAppWaitsForEventsNotForTime() throws {
    let waits = try matches(#"\.asyncAfter\("#, in: appDirs)
    #expect(waits.count <= 18, "a wait in place of the event that says it's ready: \(waits)")
}
