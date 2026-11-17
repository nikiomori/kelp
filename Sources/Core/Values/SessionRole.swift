/// The job Kelp started a session for (`Session.role`). A `reviewer` session reviews another agent's work (Review
/// with…, a pull request's review) and leaves findings, so findings and other text meant for "the agent" never go to
/// it.
public enum SessionRole: String, Codable, Sendable, CaseIterable { case reviewer }

extension SessionCreate {
    /// Returns the same create request, started for the job of `role` (nil for no role).
    public func started(as role: SessionRole?) -> Self {
        var create = self
        create.role = role
        return create
    }
}
