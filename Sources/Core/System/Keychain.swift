import Foundation
import Security

/// Secrets (API keys) live in the login keychain, never in config files.
public enum Keychain {
    /// "dev.krill" is from when the app was called Krill; kept so saved keys stay readable. `KELP_KEYCHAIN_SERVICE` names
    /// another, so tests never touch the real keys. Read at each call: nothing caches the first answer.
    static var service: String { ProcessInfo.processInfo.environment["KELP_KEYCHAIN_SERVICE"] ?? "dev.krill" }

    /// Updates in place, so a failure never leaves the account without its old value (delete-then-add would).
    public static func set(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        var status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
                as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public static func get(_ account: String) -> String? {
        do { return try read(account) } catch { return nil }
    }

    /// The value, or the keychain's reason it can't be had (its OSStatus: -25300 not there, -25308 not allowed now…).
    public static func read(_ account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        (SecCopyErrorMessageString(status, nil) as String? ?? "keychain error") + " (\(status))"
                ])
        }
        return value
    }

    public static func delete(_ account: String) {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
    }
}
