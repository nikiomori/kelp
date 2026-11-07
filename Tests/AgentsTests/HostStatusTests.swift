import Core
import Foundation
import Testing

@testable import Agents

/// A host's hooks, run as Claude Code runs them, with a stand-in for tmux and for `ps` naming fd 3 as the agent's tty.
@Test func aHostsHooksWriteThroughTmuxAndKeepTheReport() throws {
    let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bin) }
    let kept = bin.appendingPathComponent("kept"), tty = bin.appendingPathComponent("tty")
    for (name, body) in [("tmux", "echo \"$@\" > \(kept.path)"), ("ps", "echo fd/3")] {
        let f = bin.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    }
    let settings = try JSONDecoder().decode(JSONValue.self, from: Data(Hooks.hostSettingsJSON().utf8))
    func run(_ event: String, _ payload: String, inTmux: Bool = true) throws -> String {
        try? FileManager.default.removeItem(at: tty)
        let command = try #require(settings["hooks"]?[event]?.array?.first?["hooks"]?.array?.first?["command"]?.string)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s \"$PAYLOAD\" | /bin/sh -c \"$HOOK\" 3>\(tty.path)"]
        p.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin", "PAYLOAD": payload, "HOOK": command, "TMUX": inTmux ? "x" : ""
        ]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return (try? String(contentsOf: tty, encoding: .utf8)) ?? ""
    }
    let wrapped = { (r: String) in "\u{1B}Ptmux;\u{1B}\u{1B}]7501;\(r)\u{07}\u{1B}\\" }
    #expect(try run("Stop", #"{"background_tasks":[]}"#) == wrapped("state=done"))
    #expect(try String(contentsOf: kept, encoding: .utf8) == "set-option -q @kelp_status state=done\n")
    #expect(try run("PermissionRequest", "{}") == wrapped("state=blocked:kind=permission"))
    #expect(try run("Stop", #"{"background_tasks":[{"id":"a","type":"subagent"}]}"#) == "")   // the turn isn't over
    #expect(try run("Stop", #"{"background_tasks": [{"id": "a", "type": "workflow"}]}"#) == "")
    #expect(
        try run("Stop", #"{"background_tasks":[{"id":"a","type":"shell"},{"id":"b","type":"memory"}]}"#)
            == wrapped("state=done"))   // nothing wakes it
    #expect(
        try run("Stop", #"{"last_assistant_message":"\"type\":\"subagent\"","background_tasks":[]}"#)
            == wrapped("state=done"))
    let title = Data("Explore".utf8).base64EncodedString()
    #expect(
        try run("SubagentStart", #"{"agent_id":"a1","agent_type":"Explore"}"#)
            == wrapped("state=working:id=a1:title=\(title)"))
    #expect(try run("SubagentStop", #"{"agent_id":"a1"}"#) == wrapped("state=clear:id=a1"))
    #expect(try run("Stop", "{}", inTmux: false) == "")
    // tmux takes the whole command as one message, about 16 KB at most.
    #expect(try Hooks.hostSettingsJSON().utf8.count < 6000)
}

/// The bytes tmux sent for Claude Code's permission dialog: the options have cursor moves between them, not line ends.
@Test func aMenuFromTmuxHasItsOptionsOnLines() {
    let screen =
        "Do you want to proceed?\n ❯\n 1. Yes  2. Yes, and switch to auto mode · it handles these  3. No\n\n Esc to cancel"
    #expect(
        StartupQuestion.optionsOnLines(screen).components(separatedBy: "\n").filter { $0.contains(". ") }.map {
            $0.prefix(2)
        } == ["1.", "2.", "3."])
}
