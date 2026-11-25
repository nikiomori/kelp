import Agents
import Core
import Foundation
import TestSupport
import Testing
import os

@testable import Daemon

/// A host's `kelp browser`, end to end but for ssh: the sh script that goes to the host (`HostKelp.shim`) talks to
/// the session's socket here, as the forwarded socket would bring it, and kelpd answers as the agent's session.
/// The stand-in ssh (`localSSH`) runs what goes to the host on this Mac and logs what goes to the connection (`-O`).
private struct HostPage {
    let home = tmp(), session: String
    let browser: HostBrowser, remote: RemoteHost
    /// What kelpd was asked, with the page it told (`HostBrowser.page`), and what it answers.
    let asked = OSAllocatedUnfairLock<[(method: any Answered, page: JSONValue?)]>(initialState: [])

    init(answer: @escaping @Sendable (any Answered) throws -> JSONValue) throws {
        let remotes = Remotes(home: home, ssh: localSSH)
        try FileManager.default.createDirectory(atPath: remotes.controlDir, withIntermediateDirectories: true)
        remote = remotes.host("box", path: home.path)
        let store = try Store()   // the session, whose workspace its page opens in
        session = try store.save(
            Session(worktreeId: "w1", cwd: home.path, command: "claude", agent: "claude", argv: [])
        ).id
        browser = HostBrowser(root: home, remotes: remotes, forwards: Forwards(store: store), store: store)
        let asked = asked
        browser.answer.withLock {
            $0 = { _, method in
                asked.withLock { $0.append((method, HostBrowser.page)) }
                return try answer(method)
            }
        }
        try browser.listen(session, remote: remote, dir: "")
    }

    /// Runs `kelp <words>` on the "host" in `cwd`, with `stdin`, as the agent's Bash tool would.
    func kelp(_ words: [String], stdin: String? = nil, cwd: URL? = nil, socket: String? = nil) throws -> (
        status: Int32, out: String, err: String
    ) {
        // The source of `HostKelp.shim`: the sanitized run in CI can't see Core's resource bundle.
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Core/Resources/kelp-on-host.sh")
        let sh = FileManager.default.isExecutableFile(atPath: "/bin/dash") ? "/bin/dash" : "/bin/sh"   // as on Linux
        var env = ProcessInfo.processInfo.environment
        env["KELP_SOCKET"] = socket ?? browser.macSocket(session)
        let run = try Subprocess.run(
            [sh, script.path] + words, cwd: (cwd ?? home).path, env: env, stdin: stdin.map { Data($0.utf8) },
            timeLimit: 30)
        return (run.status, String(decoding: run.stdout, as: UTF8.self), String(decoding: run.stderr, as: UTF8.self))
    }
}

private let shop: JSONValue = .object(["title": "Shop", "url": "http://localhost:3000/"])

/// A command's words reach kelpd whole (spaces, quotes, an empty one), and its answer prints as the CLI prints it.
@Test func aHostsKelpBrowserIsAnsweredAsTheSessionsAgent() throws {
    let page = try HostPage { _ in .object(["element": .string(#"textbox "Name""#)]) }
    defer { page.browser.end(page.session) }
    let typed = try page.kelp(["browser", "type", "e3", #"it's "a b""#, "--submit"])
    #expect(typed.status == 0 && typed.out == "type e3 textbox \"Name\" → done\n", "\(typed)")
    let call = try #require(page.asked.withLock { $0.first?.method } as? UIBrowser)
    #expect(call.action == .type && call.worktreeId == "w1")
    #expect(call.args == .object(["ref": "e3", "text": .string(#"it's "a b""#), "submit": true]))
}

/// With no words, stdin's lines are the steps: each answered under its own line, and the first that fails stops the
/// rest, as `kelp browser <<'EOF'` does on the Mac. An eval line keeps its script as written.
@Test func aHostsListOfStepsStopsAtTheFirstThatFails() throws {
    let page = try HostPage { method in
        guard let call = method as? UIBrowser, call.action != .click else { throw RPCError.internalError("No e9") }
        return call.action == .eval ? .string("2") : shop
    }
    defer { page.browser.end(page.session) }
    let run = try page.kelp(["browser"], stdin: "info\neval 1 + 'a b'.length\nclick e9\nreload\n")
    #expect(run.status == 1)
    #expect(run.out == "› info\npage \"Shop\" http://localhost:3000/\n› eval 1 + 'a b'.length\n2\n› click e9\n")
    #expect(run.err == "error: No e9\n")
    let evals = page.asked.withLock { $0.compactMap { ($0.method as? UIBrowser)?.args?["js"]?.string } }
    #expect(evals == ["1 + 'a b'.length"])
}

/// When the Mac isn't there (no socket, or a socket the dropped connection left), the agent hears so, at once; any
/// other command than browser says it runs on the Mac.
@Test func aHostsKelpSaysWhenKelpIsNotThere() throws {
    let page = try HostPage { _ in shop }
    defer { page.browser.end(page.session) }
    let stale = page.home.appendingPathComponent("stale.sock").path
    close(try Unix.listen(stale))   // the file stays, nobody listens
    for socket in [page.home.appendingPathComponent("none.sock").path, stale] {
        let run = try page.kelp(["browser", "info"], socket: socket)
        #expect(run.status == 1 && run.err.hasPrefix("Kelp isn't connected to this host"), "\(run)")
    }
    let other = try page.kelp(["open", "x"])
    #expect(other.status == 2 && other.err.contains("only kelp browser"))
}

/// The host's localhost is the host's: open forwards its port and tells the page its network (the SOCKS proxy on the
/// connection, the ports it may reach here). What would hand the Mac to the host is refused.
@Test func aHostsOpenForwardsItsPortAndPutsThePageOnTheHost() throws {
    let page = try HostPage { _ in shop }
    defer { page.browser.end(page.session) }
    let opened = try page.kelp(["browser", "open", "localhost:3000"])
    #expect(opened.status == 0 && opened.out == "page \"Shop\" http://localhost:3000/\n", "\(opened)")
    let (method, told) = try #require(page.asked.withLock { $0.first })
    #expect((method as? UIBrowser)?.args?["url"] == "http://localhost:3000")
    #expect(told?["host"] == "box" && told?["ports"] == .array([3000]) && told?["proxy"]?.int != nil)
    let ssh = try String(contentsOfFile: (localSSH as NSString).deletingLastPathComponent + "/ssh.log", encoding: .utf8)
    #expect(ssh.contains("-O forward -L 127.0.0.1:3000:localhost:3000") && ssh.contains("-O forward -D 127.0.0.1:"))
    let refused = [(["x.com", "--shared"], "--shared isn't there"), (["preview:/a.html"], "preview: shows a file")]
    for (words, refusal) in refused {
        let run = try page.kelp(["browser", "open"] + words)
        #expect(run.status == 1 && run.err.hasPrefix(refusal), "\(run)")
    }
}

/// A screenshot the app took here goes to the path the agent named on the host, and only there.
@Test func aHostsScreenshotLandsOnTheHost() throws {
    let picture = tmp().appendingPathComponent("kelp-page-1.png")
    try Data("png".utf8).write(to: picture)
    let page = try HostPage { _ in .object(["path": .string(picture.path)]) }
    defer { page.browser.end(page.session) }
    let folder = tmp()
    let run = try page.kelp(["browser", "screenshot", "shots/a.png"], cwd: folder)
    let there = try #require(Paths.real(folder.path)) + "/shots/a.png"   // the host's shell says /private/tmp
    #expect(run.status == 0 && run.out == there + "\n", "\(run)")
    #expect(FileManager.default.contents(atPath: there) == Data("png".utf8))
    #expect(!FileManager.default.fileExists(atPath: picture.path))
    #expect(page.asked.withLock { ($0.first?.method as? UIBrowser)?.args?["path"] } == nil)   // the app's own path
}

/// What the host prints after setting up reads as its folder, and the file that says the project is a web app.
@Test func theHostsSetupIsReadAsItsFolderAndWebApp() {
    #expect(HostKelp.parse("/tmp/kelp-1000\nweb/package.json\n")! == ("/tmp/kelp-1000", "web/package.json"))
    #expect(HostKelp.parse("/tmp/kelp-1000\n")! == ("/tmp/kelp-1000", nil))
    #expect(HostKelp.parse("mkdir: no room\n") == nil)
}

/// The agent's command runs with Kelp's socket in its environment, the skill as a plugin folder, and Kelp's `kelp`
/// first on PATH, whatever the login shell set before it.
@Test func aHostAgentStartsWithKelpBrowser() throws {
    let dir = tmp()
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let kelp = dir.appendingPathComponent("bin/kelp")
    try "#!/bin/sh\n".write(to: kelp, atomically: true, encoding: .utf8)
    chmod(kelp.path, 0o700)
    var own: [String: String] = [:]
    let browsing = SessionSetup.HostBrowsing(dir: dir.path, socket: dir.path + "/s.sock", skill: true)
    let argv = SessionSetup.withHostKelp(
        ["sh", "-c", #"command -v kelp; echo "$1 $2""#, "-"], &own, browsing, flag: "--plugin-dir")
    #expect(own == ["KELP_SOCKET": dir.path + "/s.sock"])
    let found = try Subprocess.output(["/bin/sh"] + argv.dropFirst(), cwd: dir.path, env: ["PATH": "/usr/bin:/bin"])
    #expect(String(decoding: found, as: UTF8.self) == kelp.path + "\n--plugin-dir \(dir.path)/plugin\n")
}
