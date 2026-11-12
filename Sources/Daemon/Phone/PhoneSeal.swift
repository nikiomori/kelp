import CryptoKit
import Foundation

/// What passes between a phone and this Mac, sealed so the relay on the way reads none of it: base64url of
/// AES-256-GCM's nonce (12 bytes), ciphertext and tag (16), JSON inside. `about` goes in as additional data and says
/// which way a box goes ("q" a request, "r<n>" its answer, "e<n>.<i>" the i-th event of the stream request n opened),
/// so one can't be passed off as another. The key came in the pairing link's fragment, which the relay never sees.
enum PhoneSeal {
    struct NotABox: Error {}

    static func seal(_ value: some Encodable, about: String, key: SymmetricKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let box = try AES.GCM.seal(try encoder.encode(value), using: key, authenticating: Data(about.utf8))
        guard let bytes = box.combined else { throw NotABox() }
        return bytes.base64URL
    }

    static func open<Value: Decodable>(_ box: String, about: String, key: SymmetricKey) throws -> Value {
        guard let bytes = Data(base64URL: box) else { throw NotABox() }
        let plain = try AES.GCM.open(
            try AES.GCM.SealedBox(combined: bytes), using: key, authenticating: Data(about.utf8))
        return try JSONDecoder().decode(Value.self, from: plain)
    }

    static func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: .min ... .max) }) }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        let plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: plain + String(repeating: "=", count: (4 - plain.count % 4) % 4))
    }
}
