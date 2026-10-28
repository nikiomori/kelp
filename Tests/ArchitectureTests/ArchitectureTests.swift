import Foundation
import Testing

// The rules in docs/architecture.md, read from the sources. Each number is a ceiling that only goes down: when a change brings a
// count under it, lower it to the new count in the same commit, so nothing creeps back.

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The app: its target (main.swift and the list of built-ins), the shell (KelpKit) and the built-ins' modules.
private let appDirs = ["Sources/KelpApp", "Sources/KelpKit", "Sources/Builtins"]

/// Every .swift file under these folders (relative to the repo), with its text.
private func sources(_ dirs: [String]) -> [(path: String, text: String)] {
    dirs.flatMap { dir -> [(path: String, text: String)] in
        let base = root.appendingPathComponent(dir)
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
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
/// AppModel.swift itself is the way (it also manages the connection), so it isn't counted.
@Test func daemonErrorsAreNotSwallowed() throws {
    func outside(_ found: [String]) -> [String] { found.filter { !$0.hasPrefix("Sources/KelpKit/AppModel.swift:") } }
    let swallowed = outside(try matches(#"try\? await (?:[^=\n]*\.)?(call|get|tryCall)\("#, in: appDirs))
    let raw = outside(try matches(#"\bclient\??\.call\(|\bc\??\.call\("#, in: appDirs))
    #expect(swallowed == [], "try? around a call: \(swallowed)")
    #expect(raw == [], "the client called directly: \(raw)")
}

/// The app reads the daemon's records as Core's types: running git, gh, the agents' files and the daemon itself is the
/// daemon's job. (Package.swift enforces it too; this says why when someone adds the dependency back.)
@Test func theAppDoesNotImportTheDaemonsLibraries() {
    let banned = ["Daemon", "GitKit", "Integrations", "AgentData", "LSPKit"]
    let found = sources(appDirs).filter { f in banned.contains { f.text.hasPrefix("import \($0)\n") || f.text.contains("\nimport \($0)\n") } }
    #expect(found.map(\.path) == [])
}

/// A built-in is a module of its own (`Sources/Builtins/<Feature>`): it reaches the shell only through what KelpKit
/// declares `package` (tabs, panels, commands, `app.workbench`…, never the window, the sidebar or the inspector), and
/// the shell can't name it. The compiler holds that once the targets are wired so: the shell and every built-in depend
/// on no built-in, and only the app's target lists them.
@Test func builtinsAreModulesTheShellCantName() throws {
    let folders = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/Builtins").path).filter { !$0.hasPrefix(".") }
    let modules = folders.map { "Builtin" + $0 }
    #expect(modules.contains("BuiltinAgents") && modules.contains("BuiltinFiles"), "\(modules)")   // the scan finds them
    let importing = sources(["Sources/KelpKit", "Sources/Builtins"]).filter { f in modules.contains { f.text.contains("import \($0)\n") } }
    #expect(importing.map(\.path) == [], "a built-in imported by the shell or by another built-in")
    let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
    for line in manifest.split(separator: "\n") where line.contains(".target(name: \"KelpKit\"") || line.contains(".target(name: \"Builtin") {
        let own = modules.first { line.contains("name: \"\($0)\"") }
        #expect(!modules.contains { $0 != own && line.contains("\"\($0)\"") }, "depends on a built-in: \(line)")
    }
    // The window's own parts stay the shell's: nothing in them is declared for a built-in to reach.
    let shared = ["UsageView.swift", "RowBadges.swift"]   // the sidebar's, shown by the Agents built-in too
    let windowParts = sources(["Sources/KelpKit/Sidebar", "Sources/KelpKit/Inspector"]).filter { !shared.contains(($0.path as NSString).lastPathComponent) }
        + sources(["Sources/KelpKit/Shell"]).filter { $0.path.hasSuffix("/MainWindow.swift") }
    #expect(windowParts.filter { codeOnly($0.text).contains("package ") }.map(\.path) == [])
    // What the built-ins may reach of the shell: a ceiling that only goes down (one a built-in stopped using goes).
    let declared = sources(["Sources/KelpKit"]).map { f in
        codeOnly(f.text).split(separator: "\n").filter { $0.range(of: #"^\s*(@\w+(\([^)]*\))?\s+)*package\s"#, options: .regularExpression) != nil }.count
    }.reduce(0, +)
    #expect(declared <= 252, "\(declared) package declarations in KelpKit")
}

/// What the shell asks of every tab stays short: a question only one kind of tab answers is that tab's own (its provider's
/// menu, its badge), not one more requirement every tab carries a "not this one" default for.
@Test func tabContentAsksLittle() throws {
    let text = try #require(sources(["Sources/KelpKit/Editor"]).first { $0.path.hasSuffix("/TabContent.swift") }?.text)
    let start = try #require(text.range(of: "protocol TabContent: AnyObject {"))
    let end = try #require(text.range(of: "\n}", range: start.upperBound..<text.endIndex))
    let body = text[start.upperBound..<end.lowerBound]
    let declaration = try NSRegularExpression(pattern: #"^\s*(?:@\w+\s+)*(?:static\s+|mutating\s+)*(?:var|func|subscript|init|associatedtype)\b"#)
    let requirements = codeOnly(String(body)).split(separator: "\n").filter { l in
        let t = String(l)
        return declaration.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }
    #expect(requirements.count <= 14, "\(requirements)")
}

/// A Swift file's code without its comments and string literals (their words could be any name); lines stay where they were.
private func codeOnly(_ s: String) -> String {
    var out = "", i = s.startIndex
    func skip(to end: String.Index) { out += s[i..<end].filter { $0 == "\n" }; i = end }
    while i < s.endIndex {
        let rest = s[i...]
        if rest.hasPrefix("//") { skip(to: rest.firstIndex(of: "\n") ?? s.endIndex) }
        else if rest.hasPrefix("/*") { skip(to: rest.range(of: "*/")?.upperBound ?? s.endIndex) }
        else if rest.hasPrefix("\"\"\"") { skip(to: rest.dropFirst(3).range(of: "\"\"\"")?.upperBound ?? s.endIndex) }
        else if rest.first == "\"" {
            var j = rest.index(after: rest.startIndex)
            while j < s.endIndex, s[j] != "\"", s[j] != "\n" { j = s.index(j, offsetBy: s[j] == "\\" && s.index(after: j) < s.endIndex ? 2 : 1) }
            skip(to: j < s.endIndex && s[j] == "\"" ? s.index(after: j) : j)
        } else { out.append(s[i]); i = s.index(after: i) }
    }
    return out
}

/// The daemon's events reach the app as their types (`RPCClient.onEvent`, decoded once on the client's reader thread):
/// the app doesn't switch on their names or decode them from JSON on the main thread.
@Test func theAppTakesEventsByType() throws {
    #expect(try matches(#"onNotification|case [A-Z]\w*\.name\b|\.decode\(\w*(Event|Session|Repo|Worktree)\.self"#, in: appDirs) == [])
}

/// Questions are sheets that are awaited: a nested modal loop (runModal for a sheet) runs every timer, event and task of
/// the app inside it, and a semaphore on the main thread stops them all. (The hang watcher's semaphore is on a thread of
/// its own: it's what notices a stuck main thread.)
@Test func theMainThreadNeverWaitsInALoopOfItsOwn() throws {
    #expect(try matches(#"runAsSheet|NSApp\.runModal\(for"#, in: appDirs) == [])
    #expect(try matches(#"DispatchSemaphore"#, in: appDirs).filter { !$0.hasPrefix("Sources/KelpKit/DevAids.swift") } == [])
    // Until a `.terminateLater` reply AppKit runs a modal mode in which the main actor's tasks don't run: an async
    // question asked from there never shows (quitting with an unsaved file closed nothing and asked nothing).
    #expect(try matches(#"\.terminateLater"#, in: appDirs) == [])
    // One loop of its own, on purpose: a logout's quit needs its answer before applicationShouldTerminate returns.
    #expect(try matches(#"nextEvent\(matching: \.any"#, in: appDirs).map { $0.split(separator: ":")[0] } == ["Sources/KelpKit/AppDelegate.swift"])
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
        let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false)
        let l = text.flatMap { line - 1 < $0.count ? String($0[line - 1]) : nil } ?? ""
        return l.contains("//") || l.contains("\"")
    }
    #expect(inText.isEmpty, "\(inText)")
}

/// A file past 450 lines of code (blank and comment lines aside) is two things: split it.
@Test func filesStaySmall() {
    let big = sources(["Sources"]).compactMap { f -> String? in
        let code = f.text.split(separator: "\n").filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("//")
        }
        return code.count > 450 ? "\(f.path): \(code.count)" : nil
    }
    #expect(big == [])
}

/// The daemon starts every program (an extension's command, a formatter, a notebook run, an agent's --version:
/// `process.run`), with its time limits, its process-tree kill and its trust checks; the app starts none. Two exceptions:
/// the app launching kelpd itself, and DevAids' `sample` of a stuck main thread (a developer's tool). Core's helpers that
/// start one count too: LoginPath runs the login shell (the app asks the daemon: `process.which`), the library's index and
/// download run curl and tar.
@Test func theAppStartsNoPrograms() throws {
    let allowed = ["Sources/KelpKit/AppModel.swift", "Sources/KelpKit/DevAids.swift"]
    let found = try matches(#"\bProcess\(\)|\bSubprocess\.|posix_spawn|\bNSTask\b|\bLoginPath\.|\bfetchExtension\(|\blibrary\(index"#, in: appDirs)
        .filter { f in !allowed.contains { f.hasPrefix($0 + ":") } }
    #expect(found == [])
    // A new Core helper that starts a program: add what the app could call to the pattern above.
    let starters = Set(try matches(#"\bProcess\(\)|\bSubprocess\.run\("#, in: ["Sources/Core"]).map { String($0.split(separator: ":")[0]) })
    #expect(starters == ["Sources/Core/Subprocess.swift", "Sources/Core/LoginPath.swift", "Sources/Core/Library.swift"])
}

/// The app doesn't ask the daemon again and again: views watch (`watch.start`) and the daemon pushes what changed.
/// A clock left in the app is the app's own, each listed with why; a new one that polls the daemon belongs in a watch.
@Test func theAppDoesntPollTheDaemon() throws {
    let clocks: [String: String] = [
        "KelpKit/AppDelegate.swift": "a finished agent counts as read after a second on screen; a 30 ms wait for the window at launch",
        "KelpKit/Sidebar/SidebarController.swift": "relative times on the rows (\"now\" becomes \"1m\")",
        "KelpKit/AppModel.swift": "connecting: waiting for the socket, retries and backoff",
        "KelpKit/Notifier.swift": "a notification's summary waits a moment for the agent's last line",
        "KelpKit/Shell/Latency.swift": "\"Loading…\" only once a wait is long enough to notice",
        "KelpKit/Shell/WorkspaceSwitcher.swift": "the ⌃Tab panel shows once ⌃ is held a moment, so a quick flip doesn't flash it",
        "KelpKit/Sidebar/RowBadges.swift": "a passed CI's ✓ leaves the branch chip after a minute on screen",
        "Builtins/Agents/UsageTab.swift": "a \"still reading\" hint after 3 s",
        "Builtins/Agents/PaneView.swift": "a terminal out of sight lets go of its agent once it could pause idle",
        "Builtins/Agents/CommandsBar.swift": "a running command's time goes on (\"12s\" becomes \"13s\")",
        "Builtins/Files/FileTab.swift": "typing settles before the language server hears it",
        "Builtins/Files/MarkdownTab.swift": "typing settles before the preview renders again",
        "Builtins/Git/CommitCard.swift": "a commit's card opens once the pointer rests on its row, and closes a moment after it leaves",
        "KelpKit/Extensions/ExtListView.swift": "an extension's own refresh interval for its command's list",
        "KelpKit/Extensions/DeclarativeExtension.swift": "an extension's own refresh interval for its panel's badge command"
    ]
    let all = try matches(#"repeats: true|Task\.sleep\("#, in: appDirs)
    let found = all.filter { m in !clocks.keys.contains { m.hasPrefix("Sources/" + $0 + ":") } }
    #expect(found == [], "a clock asking the daemon: watch a topic instead (WatchTopic)")
    let gone = clocks.keys.filter { k in !all.contains { $0.hasPrefix("Sources/" + k + ":") } }
    #expect(gone == [], "listed, but its clock is gone: take it off the list")
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
    let shared = try matches(#"^(?:private |fileprivate |public )?(?:let|var) \w+|^\s+(?:private |public )?static let \w+ = (?!Logger\()[A-Z]\w*(?:<[^>]*>)?\("#,
                             in: ["Sources/Daemon"])
    #expect(stored <= 14, "Daemon's stored properties: \(stored)")
    #expect(extensions.count <= 2, "extensions of Daemon: \(extensions)")
    #expect(shared.count <= 0, "state outside an instance: \(shared)")
}

/// A method's handler is handed one service (`Handled.Service`), never the daemon, so it reaches only what that service
/// holds; and a service gets what it uses at init instead of reaching back. So only the daemon's own files name it: the
/// class, the dispatch with each service's projection (Handlers.swift), and the watch reader, which answers methods as a
/// client would (WatchHandlers.swift). Everything else (handlers, services, their helpers) doesn't.
@Test func handlersAreHandedAServiceNotTheDaemon() throws {
    let own: Set<String> = ["Sources/Daemon/Daemon.swift", "Sources/Daemon/Handlers.swift", "Sources/Daemon/WatchHandlers.swift"]
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
    let calls = lines.indices.filter { lines[$0].contains("snapshotLater(") && !lines[$0].contains("func snapshotLater") }
    #expect(!calls.isEmpty && calls.allSatisfy { i in
        let before = lines[..<i], open = before.lastIndex { $0.contains("#if DEBUG") }, close = before.lastIndex { $0.contains("#endif") }
        return open != nil && (close == nil || close! < open!)
    })
}

/// A `try?` turns a failure into nothing, unseen: right for a probe ("is it there", "does it parse"), wrong for a write,
/// a cleanup or a store change, which say what failed with `Log.attempt` instead. Each module's count is a ceiling.
@Test func failuresAreNotSwallowed() throws {
    let ceilings = ["Daemon": 109, "KelpKit": 61, "Core": 33, "GitKit": 30, "AgentData": 32, "Agents": 22, "kelp": 20, "Builtins": 13,
                    "Integrations": 11, "LSPKit": 7, "Markdown": 4, "TerminalKit": 3]
    for (module, ceiling) in ceilings {
        let n = try matches(#"\btry\?"#, in: ["Sources/" + module]).count
        #expect(n <= ceiling, "try? in \(module): \(n), over its ceiling")
        #expect(n >= ceiling, "try? in \(module): \(n), under its ceiling \(ceiling): lower it")
    }
}

/// Who may call a method is the method's to say (`onlyFromKelp`), checked in one place for every call: a handler that
/// checked for itself could forget, or check after it had already acted.
@Test func whoMayCallAMethodIsCheckedInOnePlace() throws {
    let checks = try matches(#"\.requireApp\("#, in: ["Sources/Daemon"])
    let dispatch = ["Sources/Daemon/Handlers.swift:"]
    #expect(checks.allSatisfy { c in dispatch.contains { c.hasPrefix($0) } }, "who-may-call checks outside the dispatcher: \(checks)")
    // Params are read as a method's type only where the caller is checked too: `checked`, or a session's input, which
    // checks `onlyFromKelp` itself right after (SessionLanes).
    let reads = try matches(#"\bdecoded\("#, in: ["Sources/Daemon"]).filter { !$0.hasPrefix("Sources/Daemon/Handlers.swift:") }
    #expect(reads.map { $0.split(separator: ":")[0] } == ["Sources/Daemon/SessionLanes.swift"], "params read without the caller check: \(reads)")
    #expect(try matches(#"var onlyFromKelp: String\? \{ (?!nil \}|get \})"#, in: ["Sources/Daemon"]).count == 4)   // ui.publish, scripts.trust, state.set, session.annotate
}

/// What the daemon runs on is handed to it (`Daemon(root:)`, its `Remotes`, `LSPHost`'s delays): nothing in the code it
/// runs reads KELP_HOME's folders from the environment, keeps state in a static or opts out of the isolation checks. Two
/// daemons in one process (tests) shared those, and the one set last won. And GitKit runs git on a remote project's host
/// only when it's given the daemon's `Remotes`: in the daemon, a call that runs git (no other `executable:`) passes it.
/// (Integrations run gh and glab in local checkouts only: remote projects are refused before them, `refuseRemoteForge`.)
@Test func theDaemonKeepsNoProcessGlobals() throws {
    let modules = ["Sources/Daemon", "Sources/Core", "Sources/GitKit", "Sources/LSPKit", "Sources/Agents", "Sources/AgentData", "Sources/Integrations"]
    let files = sources(modules).map { (path: $0.path, code: codeOnly($0.text)) }
    func found(_ pattern: String, in files: [(path: String, code: String)]) throws -> [(path: String, code: String, at: Range<String.Index>)] {
        let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return files.flatMap { f in
            re.matches(in: f.code, range: NSRange(f.code.startIndex..., in: f.code)).compactMap { m in Range(m.range, in: f.code).map { (f.path, f.code, $0) } }
        }
    }
    func named(_ hits: [(path: String, code: String, at: Range<String.Index>)]) -> [String] {
        hits.map { "\($0.path):\($0.code[..<$0.at.lowerBound].filter { $0 == "\n" }.count + 1)" }
    }
    let unsafe = try found(#"nonisolated\(unsafe\)"#, in: files)
    let statics = try found(#"\bstatic var \w+(?:\s*:\s*[^={\n]+)?\s*="#, in: files)
    let home = try found(#"\bPaths\.(?:root|socket|agents|extensions|agentSkills|scratch)\b|\bfunc daemonError\(in root: URL ="#,
                         in: files.filter { $0.path != "Sources/Core/Paths.swift" })
    #expect(named(unsafe) == [], "nonisolated(unsafe)")
    #expect(named(statics) == [], "state in a static var")
    #expect(named(home) == [], "KELP_HOME's folders from the environment")
    // GitKit's functions that can run on a host, and the daemon's calls of them that don't say which home's remotes.
    let remoteAware = Set(try found(#"func (\w+)\([^{]*?remotes: Remotes"#, in: files.filter { $0.path.hasPrefix("Sources/GitKit/") })
        .compactMap { h in h.code[h.at].firstMatch(of: /func (\w+)\(/).map { String($0.1) } })
    #expect(remoteAware.count >= 30, "\(remoteAware)")
    let calls = try found(#"\b(?:Git|ProjectFiles)\.(\w+)\("#, in: files.filter { $0.path.hasPrefix("Sources/Daemon/") })
    let blind = calls.filter { h in
        guard let name = h.code[h.at].firstMatch(of: /\.(\w+)\(/).map({ String($0.1) }), remoteAware.contains(name) else { return false }
        var depth = 0, i = h.at.upperBound
        let open = h.code.index(before: i)
        i = open
        while i < h.code.endIndex {
            if h.code[i] == "(" { depth += 1 } else if h.code[i] == ")" { depth -= 1; if depth == 0 { break } }
            i = h.code.index(after: i)
        }
        let args = h.code[open..<min(i, h.code.endIndex)]
        return !args.contains("remotes:") && !args.contains("executable:")
    }
    #expect(named(blind) == [], "git run without the daemon's remotes")
}

/// A project's files are read, written, watched, moved and made by the daemon (`files.*`, `WatchTopic.file(s)`), with a
/// tab's rules and the same way for a project on another machine. What the app still touches itself is listed with
/// why and how often (a ceiling per file): its own folders, a viewer's bytes, whether a path is there. Nothing else does.
@Test func theAppDoesntTouchProjectFiles() throws {
    let own: [String: (Int, String)] = [
        "KelpKit/AgentCatalog.swift": (1, "an agent CLI's date: it isn't asked its version again until it changes"),
        "KelpKit/AgentIcons.swift": (4, "agents' icons, cached in Kelp's home"),
        "KelpKit/AppModel.swift": (2, "why kelpd didn't start, in Kelp's home"),
        "KelpKit/DevAids.swift": (3, "snapshots for tests"),
        "KelpKit/RemoteSheet.swift": (1, "the hosts in ~/.ssh/config"),
        "KelpKit/CloneSheet.swift": (2, "whether the folder new projects go in is there"),
        "KelpKit/Settings/IconTheme.swift": (2, "an icon theme an extension brings"),
        "KelpKit/Settings/SettingsWindow.swift": (1, "an extension's own folder"),
        "KelpKit/Extensions/Registry.swift": (7, "extensions' folders, Kelp's own"),
        "KelpKit/Extensions/DeclarativeExtension.swift": (4, "an extension's manifest"),
        "KelpKit/Extensions/ExtensionReview.swift": (1, "an extension's manifest, before it's installed"),
        "KelpKit/Extensions/AgentSkills.swift": (4, "the skills Kelp gives agents, in Kelp's home"),
        "KelpKit/Shell/Help.swift": (1, "the guide, written to Kelp's home"),
        "KelpKit/Shell/WorkbenchActions.swift": (4, "a dropped or linked path: a file, a folder, or nothing"),
        "KelpKit/Sidebar/ProjectIcon.swift": (1, "a project's icon, shown (a remote one's from the copy kelpd keeps)"),
        "KelpKit/Sidebar/SidebarCell.swift": (1, "a project folder that's gone"),
        "KelpKit/Sidebar/SidebarActions.swift": (1, "a project folder that's gone"),
        "Builtins/Agents/PathPreview.swift": (3, "a path a terminal printed is a file, before it's a link"),
        "Builtins/Browser/BrowserTab.swift": (2, "a local page, shown: it reloads as its folder changes; a page's screenshot"),
        "Builtins/Files/Preview.swift": (2, "an image's bytes, shown")
    ]
    let all = try matches(#"FileManager\.default\.(contents|createFile|moveItem|trashItem|copyItem|removeItem|createDirectory|fileExists|isWritableFile"#
        + #"|enumerator|attributesOfItem|destinationOfSymbolicLink)|FileWatcher\(|FileHandle\(|(String|Data|NSImage|NSDictionary)\(contentsOf"#
        + #"|\.write\(to(File)?:|\bstat\([^()]*&"#, in: appDirs)
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
    let starts = ["Sources/KelpApp/main.swift", "Sources/KelpKit/AppDelegate.swift"]
    let reach = try NSRegularExpression(pattern: #"\bWorkbench\.(?!files\b)[a-z]\w*|\bIDEContext\.current\b|\bNSApp(?:lication\.shared)?\.delegate\b"#)
    let found = sources(appDirs).filter { !starts.contains($0.path) }.flatMap { f in
        let code = codeOnly(f.text)
        return reach.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { Range($0.range, in: code).map { "\(f.path): \(code[$0])" } }
    }
    #expect(found == [], "take it from what's handed down (`app`, `app.workbench`)")
}
