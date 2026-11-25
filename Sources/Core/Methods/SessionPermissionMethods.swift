import Foundation

/// Answers the menu on screen with `answer`: allow, deny, or one of the session's `choices` by its label. Returns
/// false when there is no menu. `question` is what the answer was given to (the session's summary that a banner
/// showed), and the call also returns false once the agent asks something else, or several things at once. `run` is
/// the database run (`DatabaseRun.id`) whose change was shown: the answer goes to that change's question alone.
public struct SessionChoose: RPCMethod {
    public static let name = "session.choose"
    public typealias Result = Bool
    public var id: String, answer: String, question: String?, run: String?
    /// The instance of the permission shown on the phone. A newer question can have the same text.
    public var questionID: String?
    public init(id: String, answer: String, question: String? = nil, run: String? = nil, questionID: String? = nil) {
        self.questionID = questionID
        self.id = id
        self.answer = answer
        self.question = question
        self.run = run
    }
}
/// The hook for a permission question (Claude Code's PermissionRequest) waits here for Allow or Deny given in Kelp.
/// It answers "allow" or "deny", or nil once the question was answered in the terminal or ten minutes passed. The
/// agent's own menu stays on screen meanwhile (Claude Code shows it while the hook runs), so the terminal can answer
/// too.
public struct SessionPermissionWait: InternalMethod {
    public static let name = "session.permissionWait"
    public typealias Result = String?
    public static var timeout: TimeInterval? { 620 }
    public var id: String
    /// The system uptime of the PermissionRequest hook this wait belongs to.
    public var at: TimeInterval?
    public init(id: String, at: TimeInterval? = nil) {
        self.id = id
        self.at = at
    }
}
