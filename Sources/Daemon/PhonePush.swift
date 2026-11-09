import Core
import CoreGraphics
import Foundation
import os

/// A push to a phone through a service like ntfy (Settings › Agents, off until it has an address), when an agent needs you
/// and you're away from the Mac. In the daemon: closing Kelp's window is when it's needed. It only tells: answering stays on
/// the Mac, so that knowing the channel's address never lets anyone approve a command. A failed send is tried once more.
enum PhonePush {
    /// No input for this long is being away.
    static let awayAfter: TimeInterval = 300
    /// A question asked while you were here, and still standing after this: you left without answering.
    static let askAgainAfter: TimeInterval = 600

    static func url(_ setting: String?) -> URL? {
        guard let setting, let url = URL(string: setting.trimmingCharacters(in: .whitespaces)) else { return nil }
        return ["https", "http"].contains(url.scheme) && url.host != nil ? url : nil
    }

    /// A question, a failure, a plan limit: what stands still until someone looks. Not a failure Kelp goes on from itself.
    static func worthTelling(_ session: Session) -> Bool {
        session.limitHit != nil || session.status == .waiting || (session.status == .error && session.continueAt == nil)
    }

    /// `name`: the agent's. By default it leaves out what the agent said, which goes through someone else's server.
    static func message(_ session: Session, name: String, place: String, details: Bool) -> (title: String, body: String)
    {
        let what =
            session.limitHit != nil ? "hit its limit" : session.status == .waiting ? "needs you" : "ran into an error"
        return ("\(name) \(what)", details && !session.summary.isEmpty ? "\(place): \(session.summary)" : place)
    }

    /// Rows muted past now, as the app keeps them (`Mutes`).
    static func muted(_ mutes: JSONValue?, _ ids: [String?], now: Date = Date()) -> Bool {
        guard case .object(let mutedUntil)? = mutes else { return false }
        return ids.contains { id in
            id.flatMap { mutedUntil[$0]?.number }.map { $0 > now.timeIntervalSince1970 } ?? false
        }
    }

    /// ntfy takes the title in the query: a header would need its own encoding for anything but ASCII.
    static func request(_ url: URL, title: String, body: String) -> URLRequest? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "title", value: title)]
        guard let address = components.url else { return nil }
        var request = URLRequest(url: address, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        return request
    }

    static var inputIdle: TimeInterval {
        guard let any = CGEventType(rawValue: UInt32.max) else { return 0 }   // kCGAnyInputEventType
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}

extension ExtensionEvents {
    private var phoneAway: Bool { clients.uiState == .object([:]) || PhonePush.inputIdle >= PhonePush.awayAfter }

    /// Told once per stop by `heard`.
    func phoneHeard(_ session: Session) {
        guard PhonePush.worthTelling(session), PhonePush.url(settings[SettingKeys.phoneURL]) != nil else { return }
        if phoneAway {
            phoneSend(session)
            return
        }
        queue.asyncAfter(deadline: .now() + PhonePush.askAgainAfter) { [weak self] in
            guard let self, phoneAway, let now = live[session.id]?.snapshot, now.status == session.status,
                now.statusAt == session.statusAt
            else { return }
            phoneSend(now)
        }
    }

    private func phoneSend(_ session: Session) {
        guard let url = PhonePush.url(settings[SettingKeys.phoneURL]) else { return }
        let worktree = session.worktreeId.flatMap { id in
            Log.session.attempt("reading a workspace") { try store.worktree(id) } ?? nil
        }
        let mutes =
            Log.session.attempt("reading mutes") {
                try store.uiState(prefix: "notifications.muted")["notifications.muted"]
            } ?? nil
        guard !PhonePush.muted(mutes, [session.id, worktree?.id, worktree?.repoId]) else { return }
        let name =
            Log.session.attempt("reading a manifest") {
                try setup.manifest(session.agent, command: nil, fallbackArgv: session.argv).name
            }
            ?? session.agent ?? "Agent"
        let (title, body) = PhonePush.message(
            session, name: name, place: worktree?.displayName ?? session.displayTitle,
            details: settings[SettingKeys.phoneDetails])
        guard let request = PhonePush.request(url, title: title, body: body) else { return }
        Task.detached {
            // Once more a little later: right after a wake the network often isn't back yet, and being away is that.
            for wait in [0, 30] {
                do {
                    try await Task.sleep(for: .seconds(wait))
                    _ = try await URLSession.shared.data(for: request)
                    return
                } catch {
                    Log.session.error("phone push: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
