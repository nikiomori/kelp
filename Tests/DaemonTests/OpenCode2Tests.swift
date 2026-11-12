import Foundation
import Testing

@testable import Daemon

@Test func openCode2VersionAndArgv() {
    #expect(OpenCode2.major("opencode v2.2.7\n") == 2 && OpenCode2.major("1.17.11") == 1 && OpenCode2.major("") == 0)
    let picked = OpenCode2.argv(["opencode", "-m", "zai/glm", "--continue"])
    #expect(picked.argv == ["opencode", "--standalone", "--continue"] && picked.config == #"{"model":"zai\/glm"}"#)
    let again = OpenCode2.argv(["opencode", "--standalone"])
    #expect(again.argv == ["opencode", "--standalone"] && again.config == nil)
}

/// Kelp's plugin after the person's own, from cli.json, else the tui.jsonc OpenCode 2 hasn't migrated yet.
@Test func openCode2KeepsThePersonsPlugins() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let kelp = URL(fileURLWithPath: "/k/hooks-opencode/tui")
    func plugins() throws -> [Any] {
        let text = OpenCode2.cliConfig(plugin: kelp, config: dir)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])["plugins"]
            as? [Any] ?? []
    }
    #expect(try plugins() as? [String] == ["/k/hooks-opencode/tui"])
    try "{ // theirs\n\"plugin\": [\"./a.js\", [\"pkg\", {\"x\": 1}]] }".write(
        to: dir.appendingPathComponent("tui.jsonc"), atomically: true, encoding: .utf8)
    let legacy = try plugins()
    #expect(legacy.first as? String == "./a.js" && (legacy[1] as? [String: Any])?["package"] as? String == "pkg")
    try #"{"plugins": ["./b.js"]}"#.write(to: dir.appendingPathComponent("cli.json"), atomically: true, encoding: .utf8)
    #expect(try plugins() as? [String] == ["./b.js", "/k/hooks-opencode/tui"])
}
