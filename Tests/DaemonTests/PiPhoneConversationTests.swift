import AgentData
import Agents
import Core
import Foundation
import Testing

@testable import Daemon

@Test func ompPhoneReadsTheOpenTranscriptNotAnotherChatInTheWorkspace() throws {
    let folder = tmp(), executable = folder.appendingPathComponent("omp")
    let name = "2026-11-27T00-12-15-001Z_\(UUID().uuidString.lowercased()).jsonl"
    let file = folder.appendingPathComponent(name)
    try Data("mine".utf8).write(to: file)
    let neighbor = folder.appendingPathComponent("2026-11-27T00-12-16-001Z_\(UUID().uuidString.lowercased()).jsonl")
    try Data("other chat".utf8).write(to: neighbor)
    // Give the process a real descriptor and the same executable name, without starting an agent or using its home.
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
    let p = Process(), input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    p.executableURL = executable
    p.arguments = ["60"]
    p.standardInput = input
    try p.run()
    defer {
        p.terminate()
        p.waitUntilExit()
    }
    let session = Session(cwd: folder.path, command: "omp", agent: "omp", argv: ["omp"])
    let script = try #require(Conversations.piTailScript(session, localPID: p.processIdentifier))
    #expect(try Subprocess.output(["/bin/sh", "-c", script], cwd: folder.path) == Data("mine".utf8))
    #expect(Conversations.piTailScript(session, localPID: nil) == nil)
}

@Test func piPhoneReadsPinnedSessionsAndHandoffs() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let folder = tmp(), file = folder.appendingPathComponent("hand-off ' example.jsonl")
    try Data(#"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The answer"}]}}"#.utf8)
        .write(to: file)
    for (agent, flag) in [("pi", "--session"), ("omp", "--resume")] {
        let session = Session(cwd: folder.path, command: agent, agent: agent, argv: [agent, flag, file.path])
        let fields = await d.sessions.phone.conversationFields(of: session)
        #expect(fields["turns"]?.array?.first?["text"]?.string == "The answer")
        #expect(fields["lastReply"] == .null)
    }
    let hostname = "omp-" + UUID().uuidString
    let remote = try await remoteProject(c, host: hostname)
    let remoteSession = Session(
        cwd: remote.repo.path, command: "omp", agent: "omp", argv: ["omp", "--resume", file.path])
    let fields = await d.sessions.phone.conversationFields(of: remoteSession)
    #expect(fields["turns"]?.array?.first?["text"]?.string == "The answer")
    let down = URL(fileURLWithPath: localSSH).deletingLastPathComponent().appendingPathComponent("down-" + hostname)
    try Data().write(to: down)
    #expect(await d.sessions.phone.conversationFields(of: remoteSession) == ["lastReply": .null])

    let id = UUID().uuidString.lowercased(), root = tmp()
    let dir = root.appendingPathComponent("sessions/--project--")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("expected".utf8).write(to: dir.appendingPathComponent("time_\(id).jsonl"))
    let session = Session(cwd: "/project", command: "pi", agent: "pi", argv: ["pi", "--session-id", id])
    let script = try #require(Conversations.piTailScript(session, localPID: nil))
    #expect(
        try Subprocess.output(["/bin/sh", "-c", script], cwd: "/", env: ["PI_CODING_AGENT_DIR": root.path])
            == Data("expected".utf8))
}
