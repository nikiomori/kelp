import Foundation

// phone.*: Settings › Phone. The agents on a phone's page, through a relay that passes what it can't read (the daemon's
// PhoneBridge). Not for agents: a pairing link answers their questions.

/// A phone paired with this Mac. `push`: it takes notifications.
public struct PairedPhone: Codable, Sendable, Equatable, Identifiable {
    public var id: String, name: String, push: Bool
    public init(id: String, name: String, push: Bool) {
        self.id = id
        self.name = name
        self.push = push
    }
}

/// The bridge now. `relay`: its address, nil while it's off. `connected`: the relay holds this Mac's connection, else
/// `error` says why not. `link`: what a new phone opens to pair, until `linkUntil` or the first phone that does.
/// `via`: how a phone reaches this Mac ("relay", "tailscale", "address"), nil while it's off; then `connected` is
/// the relay's connection, or this Mac's own server being up (and Tailscale serving it). `address`: where a phone
/// opens the page, once known.
public struct PhoneState: Codable, Sendable, Equatable {
    public var relay: String?, connected: Bool, error: String?
    public var link: String?, linkUntil: Date?
    public var via: String?, address: String?
    public var phones: [PairedPhone]
    public init(
        relay: String? = nil, connected: Bool = false, error: String? = nil, link: String? = nil,
        linkUntil: Date? = nil, via: String? = nil, address: String? = nil, phones: [PairedPhone] = []
    ) {
        self.via = via
        self.address = address
        self.relay = relay
        self.connected = connected
        self.error = error
        self.link = link
        self.linkUntil = linkUntil
        self.phones = phones
    }
}

/// The bridge as it is now, to whoever watches `phone`.
public struct PhoneEvent: RPCEvent, Equatable {
    public static let name = "event.phone"
    public var state: PhoneState
    public init(state: PhoneState) {
        self.state = state
    }
}

/// The bridge to phones as it is now.
public struct PhoneStatus: InternalMethod {
    public static let name = "phone.status"
    public typealias Result = PhoneState
    public init() {}
}
/// A new pairing link, for one phone and ten minutes; the one before it stops working.
public struct PhonePair: InternalMethod {
    public static let name = "phone.pair"
    public typealias Result = PhoneState
    public init() {}
}
/// Forgets the phone `device`: its key stops opening anything.
public struct PhoneUnpair: InternalMethod {
    public static let name = "phone.unpair"
    public typealias Result = PhoneState
    public var device: String
    public init(device: String) {
        self.device = device
    }
}
