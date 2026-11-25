import CryptoKit
import Foundation

/// A paired phone. Its device key opens requests and its recent request numbers reject repeats.
struct PhoneDevice {
    let key: SymmetricKey
    var name: String
    var push: PushSubscription?
    /// `last` is the newest request number seen, and `saved` is the newest one written down (`PhoneKept.last`).
    private(set) var last: Int64 = 0, saved: Int64 = 0
    /// No request number at or under the floor passes. After a restart the seen numbers are forgotten, so the floor
    /// shuts out every number that could have been seen, which is up to the newest written down plus a second.
    private(set) var floor: Int64 = 0
    private var seen: Set<Int64> = []

    /// JavaScript represents integer request numbers exactly below this limit.
    private static let limit: Int64 = 1 << 53

    /// How far behind the newest a late request may be: five minutes.
    static let window: Int64 = 5 * 60_000 * 4096
    /// How far the newest request number may run ahead of the one written down: one second.
    static let second: Int64 = 1000 * 4096

    /// Makes a phone that pairs now.
    init(key: SymmetricKey, name: String) {
        self.key = key
        self.name = name
    }

    /// Restores a phone that was kept from before this daemon started.
    init?(key: SymmetricKey, kept: PhoneKept) {
        guard (0..<Self.limit).contains(kept.last) else { return nil }
        self.init(key: key, name: kept.name)
        push = kept.push
        last = kept.last
        saved = kept.last
        floor = kept.last + Self.second
    }

    /// Returns whether request `number` is new, and counts it as seen if so. It refuses a number that is not whole,
    /// was seen before, is at or under the floor, or is `window` or more behind the newest.
    mutating func admit(_ number: Double) -> Bool {
        guard number == number.rounded(), number > 0, number < Double(Self.limit) else { return false }
        let value = Int64(number)
        guard value > floor, value > last - Self.window, !seen.contains(value) else { return false }
        seen.insert(value)
        last = max(last, value)
        if seen.count > 512 { seen = seen.filter { $0 > last - Self.window } }
        return true
    }

    /// Whether the newest number has run more than a second ahead of the one written down, so it is time to save.
    var needsSaving: Bool { last - saved > Self.second }
    mutating func wasSaved() { saved = last }
    var kept: PhoneKept { PhoneKept(name: name, last: last, push: push) }
}

/// What the daemon keeps of a phone in its state. The phone's key is in the keychain instead.
struct PhoneKept: Codable, Equatable {
    var name: String, last: Int64, push: PushSubscription?
}

/// The bridge's record in `daemonState`, under the key "phone". It holds this Mac's id at the relay and its paired
/// phones, and nothing secret.
struct PhoneRecord: Codable, Equatable {
    var mac: String
    var devices: [String: PhoneKept] = [:]
    static let key = "phone"
}
