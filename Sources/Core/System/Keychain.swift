import Foundation
import Security

/// Secrets (API keys) live in the login keychain, never in config files.
public enum Keychain {
    /// "dev.krill" is from when the app was called Krill, and it is kept so saved keys stay readable.
    /// `KELP_KEYCHAIN_SERVICE` names another service, so tests never touch the real keys. It is read at each call, so
    /// nothing caches the first answer.
    static var service: String { ProcessInfo.processInfo.environment["KELP_KEYCHAIN_SERVICE"] ?? "dev.krill" }

    /// Stores `value`, updating in place, so a failure never leaves the account without its old value (as
    /// delete-then-add would).
    public static func set(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        let fields: [String: Any] = [
            kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(fields) { $1 } as CFDictionary, nil)
            // Another process added it between the two calls (two daemons starting at once).
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, fields as CFDictionary) }
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public static func get(_ account: String) -> String? {
        do { return try read(account) } catch { return nil }
    }

    /// Returns the value, or nil when there is none. Any other failure (a locked keychain, access refused) is thrown
    /// rather than read as "none", which would ask for credentials that are already there.
    public static func find(_ account: String) throws -> String? {
        do { return try read(account) } catch let error as NSError where error.code == Int(errSecItemNotFound) {
            return nil
        }
    }

    /// Returns the value, or throws the keychain's reason it can't be read as an OSStatus (-25300 means not there,
    /// -25308 means not allowed now…).
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
