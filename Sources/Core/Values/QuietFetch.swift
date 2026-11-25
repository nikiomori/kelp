import Foundation

/// What a background fetch did (`GitFetchQuietly`): whether it ran, why it failed, and when the last fetch that worked
/// was.
public struct QuietFetch: Codable, Sendable, Equatable {
    /// Why a fetch failed, as far as git's words tell: no network (or a host that doesn't answer), a remote that wants
    /// a sign-in or a key it can't use without asking, or anything else.
    public enum Trouble: String, Codable, Sendable, CaseIterable { case offline, signIn, other }
    /// False when it didn't run: a remote project whose host has no connection open.
    public var ran: Bool
    public var trouble: Trouble?
    /// The remote's host, as git named it in its error ("github.com"), when it did.
    public var host: String?
    /// When the last fetch that worked was (FETCH_HEAD), in seconds since 1970; nil for a remote project.
    public var fetched: Double?
    public init(ran: Bool, trouble: Trouble? = nil, host: String? = nil, fetched: Double? = nil) {
        self.ran = ran
        self.trouble = trouble
        self.host = host
        self.fetched = fetched
    }
}
