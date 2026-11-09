import os

extension Logger {
    /// A library's log (Core, GitKit, AgentData, Agents, Integrations, LSPKit, the CLI, kelp-vm):
    /// `log stream --predicate 'subsystem == "dev.kelp"'`. The daemon's own are its `Log`. Paths and messages stay
    /// private unless marked public.
    public static func kelp(_ category: String) -> Logger { Logger(subsystem: "dev.kelp", category: category) }

    /// `body`'s value, or nil with the error in this log: for what may fail without stopping the caller (a cleanup, a
    /// best-effort write), but must not fail unseen as a bare `try?` would.
    @discardableResult
    public func attempt<T>(_ what: @autoclosure () -> String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            let what = what()
            self.error("\(what, privacy: .public): \(error)")
            return nil
        }
    }

}
