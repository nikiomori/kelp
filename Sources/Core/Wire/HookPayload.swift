import Foundation

/// Sent by a running agent's hooks (`kelp hook`): `event`, plus what Claude Code's hook payload says.
public struct SessionHook: InternalMethod {
    public static let name = "session.hook"
    public typealias Result = Done
    public var id: String, event: String?, transcript: String?, cwd: String?, trigger: String?, notification: JSONValue?
    public var backgroundTasks: [JSONValue]?
    /// For Stop, the agent's timers (CronCreate, ScheduleWakeup, /loop) that will wake it later.
    public var sessionCrons: [JSONValue]?
    /// For `command`, what the agent's shell tool started or finished.
    public var command: AgentCommand?
    /// The name of the agent's hook that sent this. `event` is what Kelp's hooks file makes of it.
    public var hookName: String?
    /// The subagent the hook comes from. nil means the agent's main thread.
    public var agentId: String?
    /// For `subagent`, the subagent's kind, when it starts.
    public var agentType: String?
    /// For Stop, the words the turn ended with.
    public var reply: String?
    /// What the prompt set as a /goal.
    public var goal: String?
    /// The background shells that a `<task-notification>` prompt says ended, by task id and tool call id.
    public var endedTasks: [String]?
    /// The file an agent's tool just changed (Claude Code's Edit, Write, MultiEdit or NotebookEdit, from PostToolUse).
    public var edited: String?
    /// The artifact page a tool starts on (`SessionHook.page(of:)`): a file in `.kelp/artifacts`, or a page on
    /// claude.ai by its id or link.
    public var page: PageTouch?
    public struct PageTouch: Codable, Sendable, Equatable {
        public var file: String?, service: String?
        public var doing: SessionPage.Doing
        public init(file: String? = nil, service: String? = nil, doing: SessionPage.Doing) {
            self.file = file
            self.service = service
            self.doing = doing
        }
    }
    /// When the hook ran, on the clock of this boot. Hooks arrive out of order when the agent doesn't wait for one (a
    /// Notification) or when kelpd was away, and a late hook says nothing about now.
    public var at: TimeInterval?
    enum CodingKeys: String, CodingKey {
        case id, event, transcript, cwd, trigger, notification, command, goal, at, reply, edited, page
        case backgroundTasks = "background_tasks", sessionCrons = "session_crons", endedTasks = "ended_tasks"
        case hookName = "hook_event_name", agentId = "agent_id", agentType = "agent_type"
    }
    public init(
        id: String, event: String?, transcript: String? = nil, cwd: String? = nil, trigger: String? = nil,
        notification: JSONValue? = nil,
        backgroundTasks: [JSONValue]? = nil, sessionCrons: [JSONValue]? = nil, command: AgentCommand? = nil,
        hookName: String? = nil, agentId: String? = nil, goal: String? = nil, at: TimeInterval? = nil
    ) {
        self.id = id
        self.event = event
        self.transcript = transcript
        self.cwd = cwd
        self.trigger = trigger
        self.notification = notification
        self.backgroundTasks = backgroundTasks
        self.sessionCrons = sessionCrons
        self.command = command
        self.hookName = hookName
        self.agentId = agentId
        self.goal = goal
        self.at = at
    }
}

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

    /// Returns the artifact page a tool starts on, from its PreToolUse hook: a file tool on a file in
    /// `.kelp/artifacts` (reading or editing it), claude-artifacts naming a page by its id or link, or
    /// `kelp artifact reply|ask|suggest <name>` (answering on it). nil for anything else.
    public static func page(of payload: JSONValue) -> PageTouch? {
        guard payload["hook_event_name"]?.string == "PreToolUse", let tool = payload["tool_name"]?.string else {
            return nil
        }
        let input = payload["tool_input"]
        if let file = input?["file_path"]?.string, file.contains("/\(Artifacts.folder)/") {
            if tool == "Read" { return PageTouch(file: file, doing: .reading) }
            if ["Edit", "Write", "MultiEdit"].contains(tool) { return PageTouch(file: file, doing: .editing) }
        }
        if tool.hasPrefix("mcp__claude-artifacts__"), let slug = input?["slug"]?.string, !slug.isEmpty {
            let name = tool.dropFirst("mcp__claude-artifacts__".count)
            if ["publish_version", "publish_files", "edit_version"].contains(name) {
                return PageTouch(service: slug, doing: .editing)
            }
            if ["read_artifact", "read_comments", "read_file", "list_files", "reply_comment"].contains(name) {
                return PageTouch(service: slug, doing: name == "reply_comment" ? .answering : .reading)
            }
        }
        if tool == "Bash", let command = input?["command"]?.string, let cwd = payload["cwd"]?.string,
            let match = command.firstMatch(of: /\bkelp artifact (?:reply|ask|suggest) ([A-Za-z0-9._-]+)/)
        {
            let folder = URL(fileURLWithPath: cwd).appendingPathComponent(Artifacts.folder)
                .appendingPathComponent(String(match.output.1))
            return PageTouch(file: folder.path + "/", doing: .answering)
        }
        return nil
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
