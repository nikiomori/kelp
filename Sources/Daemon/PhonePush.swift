import CoreGraphics
import Foundation
import Core
import os

/// A push to a phone through a service like ntfy (Settings › Agents, off until it has an address), when an agent needs you
/// and you're away from the Mac. In the daemon: closing Kelp's window is when it's needed. It only tells: answering stays on
/// the Mac, so that knowing the channel's address never lets anyone approve a command. A failed send is lost, unretried.
enum PhonePush {
    /// No input for this long is being away.
    static let awayAfter: TimeInterval = 300
    /// A question asked while you were here, and still standing after this: you left without answering.
    static let askAgainAfter: TimeInterval = 600

    static func url(_ setting: String?) -> URL? {
        guard let setting, let u = URL(string: setting.trimmingCharacters(in: .whitespaces)) else { return nil }
        return ["https", "http"].contains(u.scheme) && u.host != nil ? u : nil
    }

    /// A question, a failure, a plan limit: what stands still until someone looks.
    static func worthTelling(_ s: Session) -> Bool { s.limitHit != nil || s.status == .waiting || s.status == .error }

    /// `name`: the agent's. By default it leaves out what the agent said, which goes through someone else's server.
    static func message(_ s: Session, name: String, place: String, details: Bool) -> (title: String, body: String) {
        let what = s.limitHit != nil ? "hit its limit" : s.status == .waiting ? "needs you" : "ran into an error"
        return ("\(name) \(what)", details && !s.summary.isEmpty ? "\(place): \(s.summary)" : place)
    }

    /// Rows muted past now, as the app keeps them (`Mutes`).
    static func muted(_ mutes: JSONValue?, _ ids: [String?], now: Date = Date()) -> Bool {
        guard case .object(let o)? = mutes else { return false }
        return ids.contains { id in id.flatMap { o[$0]?.number }.map { $0 > now.timeIntervalSince1970 } ?? false }
    }

    /// ntfy takes the title in the query: a header would need its own encoding for anything but ASCII.
    static func request(_ url: URL, title: String, body: String) -> URLRequest? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "title", value: title)]
        guard let u = c.url else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.httpBody = Data(body.utf8)
        return r
    }

    static var inputIdle: TimeInterval {
        guard let any = CGEventType(rawValue: UInt32.max) else { return 0 }   // kCGAnyInputEventType
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}

extension Sessions {
    private var phoneAway: Bool { clients.uiState == .object([:]) || PhonePush.inputIdle >= PhonePush.awayAfter }

    /// Told once per stop by `eventsHeard`.
    func phoneHeard(_ s: Session) {
        guard PhonePush.worthTelling(s), PhonePush.url(settings["phone.url"]?.string) != nil else { return }
        if phoneAway { phoneSend(s); return }
        events.queue.asyncAfter(deadline: .now() + PhonePush.askAgainAfter) { [weak self] in
            guard let self, phoneAway, let now = existing(s.id)?.snapshot, now.status == s.status, now.statusAt == s.statusAt else { return }
            phoneSend(now)
        }
    }

    private func phoneSend(_ s: Session) {
        guard let url = PhonePush.url(settings["phone.url"]?.string) else { return }
        let w = s.worktreeId.flatMap { id in Log.session.attempt("reading a workspace") { try store.worktree(id) } ?? nil }
        let mutes = Log.session.attempt("reading mutes") { try store.uiState(prefix: "notifications.muted")["notifications.muted"] } ?? nil
        guard !PhonePush.muted(mutes, [s.id, w?.id, w?.repoId]) else { return }
        let name = Log.session.attempt("reading a manifest") { try manifest(s.agent, command: nil, fallbackArgv: s.argv).name } ?? s.agent ?? "Agent"
        let (title, body) = PhonePush.message(s, name: name, place: w?.displayName ?? s.displayTitle, details: settings["phone.details"]?.bool == true)
        guard let request = PhonePush.request(url, title: title, body: body) else { return }
        Task.detached {
            do { _ = try await URLSession.shared.data(for: request) } catch {
                Log.session.error("phone push: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
