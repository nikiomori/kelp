/// What a session Kelp started for a job is for (`Session.role`). `reviewer`: it reviews another agent's work (Review
/// with…, a pull request's review) and leaves findings, so findings and other text for "the agent" never go to it.
public enum SessionRole: String, Codable, Sendable, CaseIterable { case reviewer }

extension SessionCreate {
    /// The same session, started for `role`'s job (nil: none).
    public func started(as role: SessionRole?) -> Self {
        var create = self
        create.role = role
        return create
    }
}
