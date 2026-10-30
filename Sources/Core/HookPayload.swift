import Foundation

extension SessionHook {
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
