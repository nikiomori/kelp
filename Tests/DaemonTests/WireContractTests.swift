import Foundation
import Testing

@testable import Core
@testable import Daemon

/// The events' params are wire contract, as their names and the methods' are (`rpcSchemaOnlyGrows`): an older app and
/// people's scripts read them as they always were.
@Test func eventsKeepTheirShape() throws {
    func wire(_ e: some RPCEvent) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Wire.line(RPCNotification(e)))
    }
    #expect(
        try wire(ChangedEvent.worktree) == .obj(["jsonrpc": "2.0", "method": "event.changed", "params": "worktree"]))
    #expect(
        try wire(OutputEvent(session: "s", data: Data("hi".utf8)))["params"] == .obj(["session": "s", "data": "aGk="]))
    #expect(try wire(SettingsEvent(settings: ["a": 1]))["params"] == .obj(["settings": .obj(["a": 1])]))
    #expect(
        try wire(UIEvent(UIOpen(uri: "file:///x", split: "right")))["params"]
            == .obj(["action": "open", "uri": "file:///x", "split": "right"]))
}

/// gh and glab run in the project's folder, which for a remote project is only a marker here: every GitHub, GitLab and CI
/// method is in `Methods.localForge`, so it's refused for one.
@Test func everyForgeMethodIsRefusedForARemoteProject() {
    let forge = Daemon.methods.filter { $0.key.hasPrefix("github.") || $0.key.hasPrefix("ci.") }
    #expect(forge.count > 10)
    #expect(forge.keys.filter { !Methods.localForge.contains($0) }.sorted() == [])
}

/// A typed reply goes out as its result's JSON with the id around it, and reads back as the same value.
@Test func aReplyCarriesItsResultAsEncoded() throws {
    let line = Daemon.replyLine(id: 7, result: try JSONEncoder().encode(["a", "b"]))
    #expect(
        try JSONDecoder().decode(JSONValue.self, from: line)
            == .obj(["jsonrpc": "2.0", "id": 7, "result": .array(["a", "b"])]))
    #expect(line.last == 0x0A)
}

/// The client matches a reply to its call from the daemon's layout of it without parsing it (`RPCClient.resultID`): a
/// change to `replyLine` that the client no longer recognises would cost every reply a second parse.
@Test func theClientRecognisesTheDaemonsReplies() {
    #expect(RPCClient.resultID(Daemon.replyLine(id: .int(5), result: Data("[1]".utf8))) == 5)
}
