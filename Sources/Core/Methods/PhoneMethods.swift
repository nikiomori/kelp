import Foundation

// The phone.* methods behind Settings › Phone. A phone's page shows the agents, reached through a relay that passes on
// what it can't read (the daemon's PhoneBridge). Agents may not call these, because a pairing link can answer their
// questions.

/// A phone paired with this Mac. `push` is true when the phone takes notifications.
public struct PairedPhone: Codable, Sendable, Equatable, Identifiable {
    public var id: String, name: String, push: Bool
    public init(id: String, name: String, push: Bool) {
        self.id = id
        self.name = name
        self.push = push
    }
}

/// Tailscale's setup steps on this Mac, as Kelp last checked them: installed, signed in, and serving the page (which
/// needs the tailnet's HTTPS certificates).
public struct TailscaleSteps: Codable, Sendable, Equatable {
    public var installed: Bool, signedIn: Bool, serving: Bool
    public init(installed: Bool = false, signedIn: Bool = false, serving: Bool = false) {
        self.installed = installed
        self.signedIn = signedIn
        self.serving = serving
    }
    /// Where Tailscale is downloaded, and where the tailnet's admin console turns HTTPS certificates on.
    public static let download = "https://tailscale.com/download/mac"
    public static let certificates = "https://login.tailscale.com/admin/dns"
}

/// The phone bridge as it is now. `relay` is the relay's address, nil while it is off. `connected` says the relay holds
/// this Mac's connection, and otherwise `error` says why not. `link` is what a new phone opens to pair, until
/// `linkUntil` or until the first phone pairs. `via` is how a phone reaches this Mac ("relay", "tailscale", "address"),
/// nil while the bridge is off. `connected` then means the relay's connection, or this Mac's own server being up (and
/// Tailscale serving it). `address` is where a phone opens the page, once known.
public struct PhoneState: Codable, Sendable, Equatable {
    public var relay: String?, connected: Bool, error: String?
    public var link: String?, linkUntil: Date?
    public var via: String?, address: String?
    /// Where Tailscale's setup stands, while Tailscale is the way phones connect.
    public var tailscale: TailscaleSteps?
    public var phones: [PairedPhone]
    public init(
        relay: String? = nil, connected: Bool = false, error: String? = nil, link: String? = nil,
        linkUntil: Date? = nil, via: String? = nil, address: String? = nil, tailscale: TailscaleSteps? = nil,
        phones: [PairedPhone] = []
    ) {
        self.tailscale = tailscale
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

/// The phone bridge as it is now, sent to whoever watches `phone`.
public struct PhoneEvent: RPCEvent, Equatable {
    public static let name = "event.phone"
    public var state: PhoneState
    public init(state: PhoneState) {
        self.state = state
    }
}

/// Returns the bridge to phones as it is now.
public struct PhoneStatus: InternalMethod {
    public static let name = "phone.status"
    public typealias Result = PhoneState
    public init() {}
}
/// Makes a new pairing link for one phone, valid for ten minutes. The previous link stops working.
public struct PhonePair: InternalMethod {
    public static let name = "phone.pair"
    public typealias Result = PhoneState
    public init() {}
}
/// Forgets the phone `device`, so its key stops opening anything.
public struct PhoneUnpair: InternalMethod {
    public static let name = "phone.unpair"
    public typealias Result = PhoneState
    public var device: String
    public init(device: String) {
        self.device = device
    }
}
