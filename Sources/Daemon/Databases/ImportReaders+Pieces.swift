import CommonCrypto
import Core
import Foundation
import Security

// Helpers every app's reader uses: engines and SSH in Kelp's terms, the keychain, decryption, reading plists and JSON.

extension ImportReaders {
    /// Maps an app's driver name to Kelp's engine, or returns nil for a driver Kelp doesn't speak.
    static func engine(_ driver: String) -> DatabaseInfo.Engine? {
        let name = driver.lowercased()
        if ["postgres", "cockroach", "redshift", "greenplum", "timescale", "supabase", "neon"].contains(
            where: name.contains)
        {
            return .postgres
        }
        if name.contains("mysql") || name.contains("maria") || name.contains("tidb") || name.contains("planetscale") {
            return .mysql
        }
        if name.contains("duckdb") { return .duckdb }
        if name.contains("sqlite") || name.contains("libsql") { return .sqlite }
        return nil
    }

    /// Turns an SSH tunnel into the form Kelp keeps, `user@host`, and leaves the rest to ssh's own config. The second
    /// value is a note on what that form can't hold (another port, a key of its own).
    static func ssh(host: String, user: String?, port: Int?, key: Bool) -> (String?, String?) {
        guard !host.isEmpty else { return (nil, nil) }
        let alias = user.map { $0 + "@" + host } ?? host
        if let port, port != 22 {
            return (alias, "SSH on port \(port): give \(host) a Port line in ~/.ssh/config.")
        }
        return (alias, key ? "An SSH key of its own: give \(host) an IdentityFile in ~/.ssh/config." : nil)
    }

    /// Sets the stage the user gave the database in that app, and only that, because Production is never guessed from
    /// where the database is. TablePlus' "local" and DBeaver's "dev" are what every new connection gets in those apps,
    /// so they say nothing. Returns a note when the database is Production.
    @discardableResult
    static func production(_ db: inout DatabaseInfo, tag: String?, app: String) -> String? {
        let tag = tag?.lowercased() ?? ""
        if ["production", "prod"].contains(tag) {
            db.set(stage: .production)
            return "Production in \(app): agents only read it."
        }
        if ["development", "dev"].contains(tag) {
            db.set(stage: .development)
        } else if ["staging", "testing", "test"].contains(tag) {
            db.set(stage: .staging)
        }
        return nil
    }

    /// Returns a keychain item in the form that `DatabaseInfo.passwordIn` keeps it.
    static func keychainItem(_ service: String, _ account: String?) -> String {
        service + "\u{1F}" + (account ?? "")
    }

    /// Reads the keychain item that `passwordIn` names, which makes macOS ask the user. Returns nil when the item isn't
    /// there.
    static func borrowed(_ item: String) throws -> String? {
        let parts = item.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return try otherKeychain(service: parts[0], account: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    /// Reads another app's keychain item, and macOS asks the user whether Kelp may read it. Returns nil when there's
    /// no such item.
    static func otherKeychain(service: String, account: String?) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        if [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed].contains(status) {
            throw KeychainDenied()
        }
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func aes128CBC(_ data: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, data.count,
                            output.baseAddress, capacity,
                            &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    static func plist(_ url: URL) -> Any? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return optional { try PropertyListSerialization.propertyList(from: data, format: nil) }
    }

    static func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return optional { try JSONSerialization.jsonObject(with: data) } as? [String: Any]
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: ""
        }
    }

    static func nonEmpty(_ value: Any?) -> String? {
        let text = string(value).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func int(_ value: Any?) -> Int? { Int(string(value)) }

    /// Joins two notes into one line: what SSH needs, then why the database is Production.
    static func both(_ first: String?, _ second: String?) -> String? {
        let parts = [first, second].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Runs a read of another app's file and returns nil when it fails. The file may be missing, cut short, or of a
    /// version Kelp doesn't know, and then there is nothing to bring in.
    static func optional<T>(_ body: () throws -> T?) -> T? {
        do { return try body() } catch { return nil }
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
