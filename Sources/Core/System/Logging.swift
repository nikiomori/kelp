import os

extension Logger {
    /// Returns a library's log (Core, GitKit, AgentData, Agents, Integrations, LSPKit, the CLI, kelp-vm). Read it with
    /// `log stream --predicate 'subsystem == "dev.kelp"'`. The daemon's own logs are its `Log`. Paths and messages stay
    /// private unless marked public.
    public static func kelp(_ category: String) -> Logger { Logger(subsystem: "dev.kelp", category: category) }

    /// Returns `body`'s value, or nil after logging the error. It is for work that may fail without stopping the caller
    /// (a cleanup, a best-effort write) but must not fail unseen, as it would with a bare `try?`.
    @discardableResult
    public func attempt<T>(_ what: @autoclosure () -> String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            let what = what()
            self.error("\(what, privacy: .public): \(error)")
            return nil
        }
    }

}
