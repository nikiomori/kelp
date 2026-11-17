import Foundation

extension SessionHook {
    /// How long an agent waits for its hook's reply. A kelpd that hasn't answered by then is stopped or being replaced.
    /// The hook's message is already in the socket for that kelpd or the next one to read, and the agent has work to go
    /// on with.
    public static let replyWait: TimeInterval = 3

    /// Sends the hook from the agent's side. During an update, kelpd refuses every call for a few seconds and then
    /// hangs up on calls it hadn't answered. The agent never runs a hook a second time, so the hook retries on a new
    /// connection, which waits in the socket's queue for the next kelpd. A hook sent twice only says the same thing
    /// twice. Limit: that queue (128 connections) is the only buffer, with no file behind it. That is enough because a
    /// hook is for a running session, and a session outlives its daemon only by being handed over, which keeps the
    /// socket open.
    public func send(socket: String, within seconds: TimeInterval = 10) async throws {
        let end = Date().addingTimeInterval(seconds)
        while true {
            do {
                let client = try RPCClient(socket: socket, patience: 2)
                defer { client.close() }
                _ = try await client.call(self, timeout: Self.replyWait)
                return
            } catch let error as RPCError where error == .noReply(Self.name, in: Self.replyWait) {
                return
            } catch let error as RPCError where (error == .updating || error == .connectionClosed) && Date() < end {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Returns the file that a file tool changed, read from its PostToolUse hook. nil for any other tool or event.
    public static func edited(of payload: JSONValue) -> String? {
        guard payload["hook_event_name"]?.string == "PostToolUse",
            ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(payload["tool_name"]?.string)
        else { return nil }
        let input = payload["tool_input"]
        return (input?["file_path"]?.string ?? input?["notebook_path"]?.string).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Returns what a prompt sets as the /goal. `/goal` alone shows the current goal, and `/goal clear` ends it.
    public static func goal(of payload: JSONValue) -> String? {
        guard payload["hook_event_name"]?.string == "UserPromptSubmit", let prompt = payload["prompt"]?.string,
            prompt.hasPrefix("/goal ")
        else { return nil }
        let condition = prompt.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        return condition.isEmpty || condition == "clear" ? nil : condition
    }

    /// Returns the ids in a prompt that says background work ended. Claude Code wakes the agent with a
    /// `<task-notification>` prompt, whether the agent sits at its prompt or keeps working. This prompt is the only
    /// sign that a background shell ended, because no hook reports it.
    public static func endedTasks(of payload: JSONValue) -> [String]? {
        guard payload["hook_event_name"]?.string == "UserPromptSubmit", let prompt = payload["prompt"]?.string,
            prompt.hasPrefix("<task-notification>")
        else { return nil }
        return prompt.matches(of: /<(?:task|tool-use)-id>([^<]+)</).map { String($0.1) }
    }

    /// Returns what a Claude Code hook's JSON says beyond its event name, for the session's row or for how the turn
    /// ended.
    public static func notification(of payload: JSONValue) -> JSONValue? {
        switch payload["hook_event_name"]?.string {
        case "PermissionRequest":   // The dialog's tool input says more than any notice text.
            .obj([
                "notification_type": "permission_request", "tool_name": payload["tool_name"] ?? .null,
                "tool_input": payload["tool_input"] ?? .null, "cwd": payload["cwd"] ?? .null
            ])
        case "StopFailure":   // An API error ended the turn: the text names it, and `error` is its kind.
            .obj([
                "notification_type": "stop_failure", "message": payload["last_assistant_message"] ?? .null,
                "error": payload["error"] ?? .null
            ])
        default:
            payload["notification_type"] != nil || payload["message"] != nil
                ? .obj([
                    "notification_type": payload["notification_type"] ?? .null, "message": payload["message"] ?? .null
                ]) : nil
        }
    }
}
