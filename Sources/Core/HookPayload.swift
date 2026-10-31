import Foundation

extension SessionHook {
    /// Sends it, from the agent's side. An update refuses every call for seconds, then hangs up on what it hadn't answered,
    /// and a hook gets no second chance from its agent: so it goes again on a new connection, which waits in the socket's
    /// queue for the next kelpd. Sent twice, it only says the same thing twice.
    /// Limit: that queue (128 connections) is the only buffer, and no file behind it: a hook is for a running session, and
    /// one outlives its daemon only by being handed over, which keeps the socket open. Its agent waits here meanwhile.
    public func send(socket: String, within seconds: TimeInterval = 10) async throws {
        let end = Date().addingTimeInterval(seconds)
        while true {
            do {
                let c = try RPCClient(socket: socket, patience: 2)
                defer { c.close() }
                _ = try await c.call(self)
                return
            } catch let e as RPCError where (e == .updating || e == .connectionClosed) && Date() < end {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// What a Claude Code hook's JSON says beyond its event, for the row or for how the turn ended.
    public static func notification(of v: JSONValue) -> JSONValue? {
        switch v["hook_event_name"]?.string {
        case "PermissionRequest":   // the dialog: what it would run says more than any notice
            .obj(["notification_type": "permission_request", "tool_name": v["tool_name"] ?? .null,
                  "tool_input": v["tool_input"] ?? .null, "cwd": v["cwd"] ?? .null])
        case "StopFailure":   // the turn died on an API error: its text says which
            .obj(["notification_type": "stop_failure", "message": v["last_assistant_message"] ?? .null])
        default:
            v["notification_type"] != nil || v["message"] != nil
                ? .obj(["notification_type": v["notification_type"] ?? .null, "message": v["message"] ?? .null]) : nil
        }
    }
}
