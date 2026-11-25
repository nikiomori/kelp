import Foundation

extension Session {
    /// The id the git, PR and CI reads take for this chat's own branch folder (`branchFolder`), which is no workspace.
    public var branchKey: String { Self.branchKeyPrefix + id }
    public static let branchKeyPrefix = "session:"
}
