import Core
import CryptoKit
import Foundation

/// Where a phone's browser takes pushes, as the phone said it (`push/subscribe`).
struct PushSubscription: Codable, Equatable, Sendable {
    struct Keys: Codable, Equatable, Sendable {
        var p256dh: String, auth: String
    }
    var endpoint: String, keys: Keys

    /// The browsers' own push services: a phone can't aim this Mac's posts anywhere else.
    static let hosts = ["push.apple.com", "fcm.googleapis.com", "push.services.mozilla.com", "notify.windows.com"]

    /// nil unless it's https on one of `hosts` with a P-256 point and a 16-byte secret.
    init?(_ sent: JSONValue?) {
        guard let endpoint = sent?["endpoint"]?.string, let url = URLComponents(string: endpoint),
            url.scheme == "https", let host = url.host?.lowercased(),
            Self.hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
            let p256dh = sent?["keys"]?["p256dh"]?.string, Data(base64URL: p256dh)?.count == 65,
            let auth = sent?["keys"]?["auth"]?.string, Data(base64URL: auth)?.count == 16
        else { return nil }
        self.endpoint = endpoint
        keys = Keys(p256dh: p256dh, auth: auth)
    }
}

/// A push this Mac sends to a phone's browser itself, through that browser's push service, which can't read it:
/// RFC 8291's `aes128gcm`, signed as this Mac's (VAPID, RFC 8292). The relay has no part in it.
enum WebPush {
    struct BadSubscription: Error {}

    /// The body: salt, record size, this message's public key, then the payload sealed for the phone's key.
    /// `mine` and `salt` are new for each message (given only by the test that checks RFC 8291's example).
    static func body(
        _ payload: Data, to: PushSubscription, mine: P256.KeyAgreement.PrivateKey = .init(),
        salt: Data = PhoneSeal.random(16)
    ) throws -> Data {
        guard let point = Data(base64URL: to.keys.p256dh), let auth = Data(base64URL: to.keys.auth) else {
            throw BadSubscription()
        }
        let theirs = try P256.KeyAgreement.PublicKey(x963Representation: point)
        let ours = mine.publicKey.x963Representation
        let input = try mine.sharedSecretFromKeyAgreement(with: theirs).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: auth, sharedInfo: Data("WebPush: info\0".utf8) + point + ours,
            outputByteCount: 32)
        func derived(_ info: String, _ count: Int) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data(info.utf8), outputByteCount: count)
        }
        let nonce = try derived("Content-Encoding: nonce\0", 12).withUnsafeBytes { try AES.GCM.Nonce(data: Data($0)) }
        // 2 ends the last (here the only) record.
        let sealed = try AES.GCM.seal(
            payload + [2], using: derived("Content-Encoding: aes128gcm\0", 16), nonce: nonce)
        return salt + Data([0, 0, 0x10, 0, UInt8(ours.count)]) + ours + sealed.ciphertext + sealed.tag
    }

    /// "vapid t=<a token this Mac signed for the push service>, k=<its public key>".
    static func authorization(for endpoint: URL, key: P256.Signing.PrivateKey, now: Date = Date()) throws -> String {
        func part(_ fields: [String: JSONValue]) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            return try encoder.encode(fields).base64URL
        }
        let origin = "\(endpoint.scheme ?? "https")://\(endpoint.host ?? "")" + (endpoint.port.map { ":\($0)" } ?? "")
        let claims =
            try part(["typ": .string("JWT"), "alg": .string("ES256")]) + "."
            + part([
                "aud": .string(origin), "exp": .int(Int(now.timeIntervalSince1970) + 43200),
                "sub": .string("https://kelpide.com")
            ])
        let signature = try key.signature(for: Data(claims.utf8)).rawRepresentation
        return "vapid t=\(claims).\(signature.base64URL), k=\(key.publicKey.x963Representation.base64URL)"
    }

    static func request(_ payload: Data, to: PushSubscription, vapid: P256.Signing.PrivateKey) throws -> URLRequest {
        guard let url = URL(string: to.endpoint) else { throw BadSubscription() }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try body(payload, to: to)
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("3600", forHTTPHeaderField: "TTL")
        request.setValue("high", forHTTPHeaderField: "Urgency")
        request.setValue(try authorization(for: url, key: vapid), forHTTPHeaderField: "Authorization")
        return request
    }
}
