import Core
import CryptoKit
import Foundation
import os

extension PhoneBridge {
    /// Returns this Mac's signing key for pushes. The key is made when the first phone asks for it.
    func vapid() -> P256.Signing.PrivateKey? {
        Log.session.attempt("getting the push key") {
            if let kept = try Keychain.find("phone.vapid") {
                guard let bytes = Data(base64URL: kept) else { throw RPCError.internalError("Unreadable push key.") }
                return try P256.Signing.PrivateKey(rawRepresentation: bytes)
            }
            let key = P256.Signing.PrivateKey()
            try Keychain.set(key.rawRepresentation.base64URL, account: "phone.vapid")
            return key
        }
    }

    /// Sends a push to every phone that takes pushes. `ExtensionEvents` (PhonePush) decides when to send one and what
    /// its words may say.
    func push(title: String, body: String, agent: String) {
        let to = devices.compactMapValues(\.push)
        guard way != nil, !to.isEmpty, let key = vapid() else { return }
        let waiting = shown.values.filter { $0["status"]?.string == AgentStatus.waiting.rawValue }.count
        let payload: [String: JSONValue] = [
            "title": .string(title), "body": .string(body), "agent": .string(agent), "waiting": .int(waiting)
        ]
        for (device, subscription) in to {
            Task {
                do {
                    let request = try WebPush.request(try JSONEncoder().encode(payload), to: subscription, vapid: key)
                    let status = (try await http.data(for: request).1 as? HTTPURLResponse)?.statusCode ?? 0
                    // A 404 or 410 means the phone took the subscription away.
                    if status == 404 || status == 410 { unsubscribed(device, from: subscription) }
                    if status >= 400 { Log.session.error("phone push: its service answered \(status)") }
                } catch { Log.session.error("phone push: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    private func unsubscribed(_ device: String, from subscription: PushSubscription) {
        guard var phone = devices[device], phone.push == subscription else { return }
        phone.push = nil
        Log.session.attempt("removing a phone's expired subscription") { try save(phone, id: device) }
    }
}
