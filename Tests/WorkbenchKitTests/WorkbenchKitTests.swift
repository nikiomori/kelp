import Foundation
import Testing
import WorkbenchKit
import Core

@Test func addPutsTabsInTheFocusedGroup() throws {
    var l = WorkspaceLayout()
    let a = l.add("session:a")   // the first tab makes the first group
    let g = try #require(l.focused)
    let b = l.add("file:///x")
    let c = l.add("file:///y", to: g, at: 0)
    #expect(l.root == .pane(g))
    #expect(l.groups[g]?.tabs == [c, a, b])
    #expect(l.focusedGroup?.selectedTab == c)
    #expect(l.tab(uri: "file:///x") == b)
}

@Test func splitMovesATabIntoANewGroupBeside() throws {
    var l = WorkspaceLayout()
    let a = l.add("a"), b = l.add("b")
    let g = try #require(l.focused)
    l.split(b.id, from: g, vertical: true, before: false)
    let h = try #require(l.group(of: b.id))
    #expect(h != g && l.focused == h)
    #expect(l.root == .split(vertical: true, children: [.pane(g), .pane(h)]))
    #expect(l.groups[g]?.tabs == [a])
    // A group's only tab split off that same group changes nothing.
    let before = l
    l.split(b.id, from: h, vertical: false, before: true)
    #expect(l == before)
}

@Test func edgeDropSpansTheWholeSide() throws {
    var l = WorkspaceLayout()
    _ = l.add("a")
    let b = l.add("b")
    let g = try #require(l.focused)
    l.split(b.id, from: g, vertical: true, before: false)
    let h = try #require(l.focused)
    let c = l.add("c", to: h)
    l.splitRoot(c.id, vertical: false, before: false)
    let k = try #require(l.group(of: c.id))
    #expect(l.root == .split(vertical: false, children: [.split(vertical: true, children: [.pane(g), .pane(h)]), .pane(k)]))
}

@Test func movingToAGroupThatIsGoneKeepsTheTab() throws {
    var l = WorkspaceLayout()
    let a = l.add("a")
    let g = try #require(l.focused)
    l.move(a.id, to: "no-such-group")   // a drop target from a layout that has changed since
    #expect(l.groups[g]?.tabs == [a])
}

@Test func movingTheLastTabOutRemovesItsGroup() throws {
    var l = WorkspaceLayout()
    let a = l.add("a"), b = l.add("b")
    let g = try #require(l.focused)
    l.split(b.id, from: g, vertical: true, before: false)
    let h = try #require(l.focused)
    l.move(a.id, to: h, index: 0)
    #expect(l.groups[g] == nil)
    #expect(l.root == .pane(h))
    #expect(l.groups[h]?.tabs == [a, b])
    #expect(l.groups[h]?.selected == a.id && l.focused == h)
}

@Test func closingTabsCollapsesSplitsButKeepsTheLastGroup() throws {
    var l = WorkspaceLayout()
    let a = l.add("a"), b = l.add("b"), c = l.add("c")
    let g = try #require(l.focused)
    l.select(b.id)
    l.remove(b.id)
    #expect(l.groups[g]?.selected == c.id)   // the neighbour that took its place
    l.split(c.id, from: g, vertical: false, before: false)
    let h = try #require(l.focused)
    l.remove(c.id)
    #expect(l.groups[h] == nil)
    #expect(l.root == .pane(g) && l.focused == g)
    l.remove(a.id)
    #expect(l.root == .pane(g) && l.allTabs.isEmpty)
}

@Test func fileURIsRoundTrip() {
    let u = TabURI.file("/tmp/my dir/a.swift", line: 12)
    #expect(u == "file:///tmp/my%20dir/a.swift#L12")
    #expect(TabURI.scheme(u) == "file")
    let (path, line) = TabURI.filePath(u)
    #expect(path == "/tmp/my dir/a.swift" && line == 12)
    #expect(TabURI.filePath("/tmp/x").line == nil)
    #expect(TabURI.body("ext:my.ext/view") == "my.ext/view")
}

@Test func diffURIsCarryWhatTheyShow() {
    #expect(TabURI.diff("w1") == "diff:w1")
    #expect(TabURI.diff("w1", file: "my dir/a&b.swift", source: "staged") == "diff:w1?file=my%20dir/a%26b.swift&source=staged")
    #expect(TabURI.scheme(TabURI.diff("w1", commit: "abc")) == "diff")
}

@Test func normalizeTakesWhatPeopleType() {
    #expect(TabURI.normalize("Sources/a.swift:12", cwd: "/repo") == "file:///repo/Sources/a.swift#L12")
    #expect(TabURI.normalize("/abs/b.swift", cwd: "/repo") == "file:///abs/b.swift")
    #expect(TabURI.normalize("localhost:3000", cwd: "/repo") == "http://localhost:3000")
    #expect(TabURI.normalize("https://x.dev/a:1", cwd: "/repo") == "https://x.dev/a:1")
    #expect(TabURI.normalize("session:abc", cwd: "/repo") == "session:abc")
}

@Test func keySpecsParseAndFormat() throws {
    #expect(KeySpec("cmd+shift+k") == KeySpec(key: "K", mods: [.command, .shift]))
    #expect(KeySpec("Command+Alt+S") == KeySpec(key: "s", mods: [.command, .option]))
    #expect(KeySpec("opt+cmd+return")?.key == "\r")
    #expect(KeySpec("ctrl+up")?.key == "\u{F700}")
    #expect(KeySpec("cmd+plus")?.key == "+")
    #expect(KeySpec("cmd+") == nil)
    for s in ["shift+cmd+k", "opt+cmd+return", "ctrl+up", "shift+cmd+plus", "ctrl+opt+shift+cmd+left", "cmd+1", "esc"] {
        #expect(KeySpec(s)?.description == s)
    }
    #expect(KeySpec(key: "\u{7f}", mods: [.command]).description == "cmd+delete")
}

@Test func layoutSplitMoveRemove() {
    var l = LayoutNode.pane("a")
    l = l.inserting("b", beside: "a", vertical: true, before: false)
    l = l.inserting("c", beside: "b", vertical: false, before: false)
    #expect(l.sessions == ["a", "b", "c"])
    let moved = l.removing("c")!.inserting("c", beside: "a", vertical: true, before: true)
    #expect(moved.sessions == ["c", "a", "b"])
    #expect(LayoutNode.pane("a").removing("a") == nil)
    #expect(l.removing("a")?.removing("b")?.removing("c") == nil)
}

/// Divider positions are kept per split: the key survives tab changes and changes when the split gets another pane.
@Test func layoutSplitKeys() {
    let l = LayoutNode.pane("a").inserting("b", beside: "a", vertical: true, before: false).inserting("c", beside: "b", vertical: false, before: false)
    #expect(l.splitKeys == ["a,b", "b,c"])
    #expect(LayoutNode.pane("a").splitKeys.isEmpty)
    #expect(l.removing("c")?.splitKeys == ["a,b"])
}

@Test func languageForAPath() throws {
    let json = #"""
    [{ "id": "python", "extensions": ["py"],
       "server": { "command": "pyright-langserver", "args": ["--stdio"], "install": "npm i -g pyright" } },
     { "id": "dockerfile", "extensions": [], "fileNames": ["Dockerfile"] }]
    """#
    let specs = try JSONDecoder().decode([LanguageSpec].self, from: Data(json.utf8))
    #expect(specs[0] == LanguageSpec(id: "python", extensions: ["py"],
                                     server: .init(command: "pyright-langserver", args: ["--stdio"], install: "npm i -g pyright")))
    #expect(LanguageSpec.find("/a/b/main.PY", in: specs)?.id == "python")
    #expect(LanguageSpec.find("/a/Dockerfile", in: specs)?.id == "dockerfile")
    #expect(LanguageSpec.find("/a/b/main.rb", in: specs) == nil)
    #expect(LanguageSpec.find("/a/b/Makefile", in: specs) == nil)
    // A later language with the same id replaces the earlier one, files and server.
    let mine = LanguageSpec(id: "python", extensions: ["pyi"], server: .init(command: "pylsp"))
    #expect(LanguageSpec.find("x.pyi", in: specs + [mine])?.server?.command == "pylsp")
    #expect(LanguageSpec.find("x.py", in: specs + [mine]) == nil)
}

@Test func languageCommands() throws {
    let json = #"{ "id": "python", "extensions": ["py"], "run": "python3 ${file}", "test": "pytest ${file} -k ${symbol}", "format": "ruff format -" }"#
    let py = try JSONDecoder().decode(LanguageSpec.self, from: Data(json.utf8))
    #expect(py == LanguageSpec(id: "python", extensions: ["py"], run: "python3 ${file}", test: "pytest ${file} -k ${symbol}", format: "ruff format -"))
    #expect(py[command: "test"] == "pytest ${file} -k ${symbol}" && py[command: "lint"] == nil)
    // Values arrive as one argument each, spaces and quotes included; unknown names stay for the shell.
    let vars = ["file": "/My Code/it's.py", "symbol": "", "line": "12"]
    let cmd = ShellTemplate.fill("printf '<%s>' ${file} -k ${symbol} ${HOME} '${line}' # ${line}") { vars[$0] }
    #expect(try sh("/bin/zsh", cmd) == "</My Code/it's.py><-k><><\(NSHomeDirectory())><12>")
}

private func sh(_ shell: String, _ cmd: String) throws -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: shell); p.arguments = ["-c", cmd]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

/// Wherever a template puts a placeholder (bare, in quotes, in $(…), in a comment, in a here-document), a value with
/// $(…), backticks, quotes or a newline never runs, in zsh (Shell.run) or sh.
@Test func aValueInAShellTemplateNeverRuns() throws {
    let marker = NSTemporaryDirectory() + "kelp-pwned-\(UUID().uuidString.prefix(6))"
    let evil = "x\nEOF\ntouch \(marker)\n$(touch \(marker)) `touch \(marker)`; touch \(marker) \" ' \\ end"
    let templates = ["printf %s ${v}", "printf %s \"${v}\"", "printf %s '${v}'", "printf %s \"PR: ${v}!\"",
                     "printf %s \"$(printf %s ${v})\"", "printf %s ${v}#${v}", "# don't\nprintf %s ${v}", "true # ${v}",
                     "cat <<EOF\n${v}\nEOF", "cat <<'EOF'\n${v}\nEOF", "cat <<-EOF\n${v}\nEOF"]
    for shell in ["/bin/zsh", "/bin/sh"] {
        for t in templates {
            let printed = try sh(shell, ShellTemplate.fill(t) { $0 == "v" ? evil : nil })
            #expect(!FileManager.default.fileExists(atPath: marker), "\(shell) ran from \(t.debugDescription)")
            if !t.contains("#"), !t.contains("'EOF'") { #expect(printed.contains(evil), "\(shell) \(t.debugDescription): \(printed.debugDescription)") }
        }
    }
}

@Test func wordAtCursor() {
    let text = "def test_parse(x):\n    assert parse(x)\n"
    #expect(LanguageSpec.word(in: text, line: 1, column: 8) == "test_parse")
    #expect(LanguageSpec.word(in: text, line: 1, column: 15) == "test_parse")   // just after it
    #expect(LanguageSpec.word(in: text, line: 2, column: 1) == "")
    #expect(LanguageSpec.word(in: text, line: 9, column: 1) == "")
    #expect(LanguageSpec.word(in: "é_1 b", line: 1, column: 2) == "é_1")
}

@Test func indentationOfAFile() {
    #expect(Indentation.detect("a {\n    b {\n        c\n    }\n    // d\n}\n") == .spaces(4))
    #expect(Indentation.detect("a:\n  b:\n    c\n  d\n") == .spaces(2))
    #expect(Indentation.detect("func f() {\n\tx\n\t\ty\n}\n") == .tabs)
    #expect(Indentation.detect("one\ntwo\n") == nil)
    #expect(Indentation.detect("a {\r\n    b\r\n    c\r\n}\r\n") == .spaces(4))   // Windows line endings
    #expect(Indentation.detect(String(repeating: "\tx\n\n", count: 2000) + String(repeating: "  y\n", count: 5000)) == .tabs)   // the first 2000 lines decide
    #expect(LanguageSpec.word(in: "x\r\ndef test_a():\r\n", line: 2, column: 6) == "test_a")
}

@Test func reorderingInsideAGroupDropsWhereTheBarShows() throws {
    var l = WorkspaceLayout()
    let a = l.add("session:a"), b = l.add("session:b"), c = l.add("session:c")
    let g = try #require(l.focused)
    l.move(a.id, to: g, index: 2)   // the gap before c, counted with a still in place
    #expect(l.groups[g]?.tabs == [b, a, c])
    l.move(c.id, to: g, index: 0)
    #expect(l.groups[g]?.tabs == [c, b, a])
    l.move(c.id, to: g)             // no index: the end
    #expect(l.groups[g]?.tabs == [b, a, c])
}

@Test func tilingGivesEachPickedTabAPaneAndTheRestOneMore() throws {
    var l = WorkspaceLayout()
    let a = l.add("session:a"), f = l.add("file:///x"), b = l.add("session:b")
    l.tile([a.id, b.id])
    let ga = try #require(l.group(of: a.id)), gb = try #require(l.group(of: b.id)), gf = try #require(l.group(of: f.id))
    #expect(l.root == .split(vertical: true, children: [.pane(ga), .pane(gb), .pane(gf)]))
    #expect(l.focused == gb)   // b was selected
    #expect(l.groups.count == 3)
    let tiled = l
    l.tile([a.id, b.id])
    #expect(l == tiled)   // the same panes: their views and dividers stay
    l.tile([])
    #expect(l.root == .pane(gb) && l.groups[gb]?.tabs == [a, b, f] && l.groups[gb]?.selected == b.id)
    l.tile([a.id, b.id])
    // Four panes make a 2×2 grid, five a row of three over a row of two.
    let files = try #require(l.group(of: f.id))
    let c = l.add("session:c", to: files), d = l.add("session:d", to: files)
    l.tile([a.id, b.id, c.id, d.id])
    guard case .split(false, let rows)? = l.root else { Issue.record("not in rows"); return }
    #expect(rows.map(\.sessions.count) == [3, 2])
    l.remove(f.id); l.tile([a.id, b.id, c.id, d.id])
    guard case .split(false, let grid)? = l.root else { Issue.record("not in rows"); return }
    #expect(grid.map(\.sessions.count) == [2, 2])
}

/// Back and Forward walk the workspaces as shown, skip closed ones and the one on screen, and a new visit after going
/// back drops what was ahead (a browser's history).
@Test func backAndForwardWalkTheWorkspacesShown() throws {
    var h = WorkspaceHistory()
    for id in ["a", "b", "c", "d"] { h.visit(id) }
    let open: Set = ["a", "b", "d"]   // c was closed
    let back = try #require(h.target(-1, current: "d", exists: open.contains))
    #expect(h.visits[back] == "b")
    #expect(h.go(to: back) == "b")
    #expect(h.visits[try #require(h.target(1, current: "b", exists: open.contains))] == "d")
    #expect(h.target(-1, current: "b", exists: open.contains).map { h.visits[$0] } == "a")
    h.visit("e")
    #expect(h.visits == ["a", "b", "e"])
    #expect(h.target(1, current: "e", exists: { _ in true }) == nil)
    for i in 0..<60 { h.visit("w\(i)") }
    #expect(h.visits.count == 50 && h.visits.last == "w59")
}

/// ⌘N goes to the chat nobody has started: empty, or with its agent still waiting for the first prompt.
@Test func aNewChatNobodyStartedIsUsedAgain() {
    let named = Worktree(repoId: "r", branch: "main", path: "/p", note: "Graph")
    let blank = Worktree(repoId: "r", branch: "main", path: "/p", note: "Workspace 2")
    func agent(_ status: AgentStatus, title: String = "") -> Session {
        Session(worktreeId: blank.id, cwd: "/", command: "claude", agent: "claude", status: status, title: title)
    }
    #expect(unstartedChat(rows: [named, blank], sessions: []) == blank)
    #expect(unstartedChat(rows: [named, blank], sessions: [agent(.idle)]) == blank)
    #expect(unstartedChat(rows: [named, blank], sessions: [agent(.exited, title: "Old")]) == blank)
    #expect(unstartedChat(rows: [named, blank], sessions: [agent(.working)]) == nil)
    #expect(unstartedChat(rows: [named, blank], sessions: [agent(.idle, title: "Fix login")]) == nil)
    #expect(unstartedChat(rows: [named], sessions: []) == nil)
}

/// Closing several workspaces: a project whose every open workspace was picked keeps its oldest; desks (in the project's
/// folder) are removed, workspaces on a branch of their own archived; a project with others open loses only the picked.
@Test func closingSeveralWorkspacesKeepsOnePerProject() {
    let a = Repo(name: "a", path: "/a"), b = Repo(name: "b", path: "/b")
    let t = Date(timeIntervalSince1970: 0)
    let a1 = Worktree(repoId: a.id, branch: "main", path: "/a", createdAt: t)
    let a2 = Worktree(repoId: a.id, branch: "main", path: "/a", createdAt: t + 1)
    let a3 = Worktree(repoId: a.id, branch: "feat", path: "/wt/a3", createdAt: t + 2)
    let b1 = Worktree(repoId: b.id, branch: "main", path: "/b", createdAt: t), b2 = Worktree(repoId: b.id, branch: "x", path: "/wt/b2", createdAt: t + 1)
    let plan = WorkspaceClosing(picked: [a3, a2, a1, b2], open: [a1, a2, a3, b1, b2], repos: [a, b])
    #expect(plan.remove == [a2.id])          // a desk
    #expect(plan.archive == [a3.id, b2.id])  // their own branches
    #expect(plan.keptSome)                   // a1, the oldest of a, stays
    let one = WorkspaceClosing(picked: [b2], open: [a1, b1, b2], repos: [a, b])
    #expect(one.ids == [b2.id] && !one.keptSome)
    #expect(WorkspaceClosing(picked: [b1], open: [b1], repos: [b]).ids.isEmpty)   // a project's last workspace stays
    #expect(WorkspaceClosing.afterLastTab(of: a1, rows: [a1, a2, a3], repos: [a, b]) == a2)   // its row goes: the one under it
    #expect(WorkspaceClosing.afterLastTab(of: a2, rows: [a1, a2], repos: [a, b]) == a1)       // the last one: the one over it
    #expect(WorkspaceClosing.afterLastTab(of: a3, rows: [a1, a2, a3], repos: [a, b]) == nil)  // on a branch of its own it stays
    #expect(WorkspaceClosing.afterLastTab(of: a1, rows: [a1], repos: [a, b]) == nil)          // and so does a project's only one
}

@Test func replacePutsTheNewURIInTheOldTabsPlace() {
    var l = WorkspaceLayout()
    let a = l.add("session:a"), b = l.add("file:///x")
    #expect(l.replace("session:a", with: "session:b")?.id == a.id)
    #expect(l.focusedGroup?.tabs.map(\.uri) == ["session:b", "file:///x"] && l.focusedGroup?.tabs.last == b)
    #expect(l.replace("session:gone", with: "session:c") == nil)
}
