extension Session {
    /// What Kelp types into an agent whose turn its going down cut short (`interruptedAt`), once the agent is back, so
    /// the turn goes on instead of waiting at the prompt.
    public static var goOnText: String { String(localized: "Continue from where you stopped.") }
}
