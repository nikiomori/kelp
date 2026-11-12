import CryptoKit
import Foundation

/// A paired phone: the key it took from its pairing link, and which of its requests' numbers were seen. A number is
/// the phone's clock in 1/4096 ms (phone/js/api.js `stamp`) and never repeats, so a request can't be sent twice.
struct PhoneDevice {
    var key: SymmetricKey
    var name: String
    var push: PushSubscription?
    /// The newest number seen, and the one written down (`PhoneKept.last`).
    private(set) var last: Int64 = 0, saved: Int64 = 0
    /// Nothing at or under it passes: after a restart the seen ones are forgotten, so nothing that could have been
    /// seen does, which is the newest written down and a second over it.
    private(set) var floor: Int64 = 0
    private var seen: Set<Int64> = []

    /// How far behind the newest a late request may be: five minutes.
    static let window: Int64 = 5 * 60_000 * 4096
    /// How far the newest may run ahead of the one written down.
    static let second: Int64 = 1000 * 4096

    /// A phone that pairs now.
    init(key: SymmetricKey, name: String) {
        self.key = key
        self.name = name
    }

    /// One kept from before this daemon.
    init(key: SymmetricKey, kept: PhoneKept) {
        self.init(key: key, name: kept.name)
        push = kept.push
        last = kept.last
        saved = kept.last
        floor = kept.last + Self.second
    }

    /// Whether request `number` is new: counted as seen if so. Not a whole number, one seen, one under the floor or
    /// more than `window` behind the newest: refused.
    mutating func admit(_ number: Double) -> Bool {
        guard number == number.rounded(), number > 0, number < 9_007_199_254_740_992 else { return false }
        let n = Int64(number)
        guard n > floor, n > last - Self.window, !seen.contains(n) else { return false }
        seen.insert(n)
        last = max(last, n)
        if seen.count > 512 { seen = seen.filter { $0 > last - Self.window } }
        return true
    }

    /// The newest ran a second ahead of what's written down: time to write.
    var needsSaving: Bool { last - saved > Self.second }
    mutating func wasSaved() { saved = last }
    var kept: PhoneKept { PhoneKept(name: name, last: last, push: push) }
}

/// What's kept of a phone where the daemon keeps its state. Its key is in the keychain.
struct PhoneKept: Codable, Equatable {
    var name: String, last: Int64, push: PushSubscription?
}

/// The bridge's record (`daemonState`, key "phone"): this Mac's id at the relay and its phones. Nothing secret.
struct PhoneRecord: Codable, Equatable {
    var mac: String
    var devices: [String: PhoneKept] = [:]
    static let key = "phone"
}
