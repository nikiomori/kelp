import Core
import Foundation

// This file handles a phone that reaches this Mac directly. kelpd serves the page and answers the phone's calls on a
// localhost port (`PhoneServer`), and Tailscale, or a tunnel the user set up, brings the phone to that port.

extension PhoneBridge {
    /// Retry timers and heartbeats end as soon as the transport changes.
    func waitWhileActive(_ duration: Duration) async -> Bool {
        do { try await Task.sleep(for: duration) } catch { return false }
        return !Task.isCancelled
    }

    /// Starts this Mac's own server on `port`.
    func serve(_ port: UInt16) {
        guard port != 0 else {
            failure = "Set phone.port to a whole number from 1 to 65535."
            return
        }
        guard let page = PhoneHTTP.page else {
            failure = "This Kelp has no phone page in it."
            return
        }
        do {
            let server = try PhoneServer(
                port: port, page: page,
                call: { [weak self] server, id, device, box, events in
                    await self?.called(on: server, id, device: device, box: box, events) ?? .refused(503)
                },
                left: { [weak self] id in Task { await self?.cut([id], telling: false) } })
            self.server = server
            server.start { [weak self, weak server] error in
                guard let server else { return }
                Task { await self?.serverChanged(server, port: port, error: error) }
            }
        } catch {
            serverFailed(port, error.localizedDescription)
        }
    }

    private func serverChanged(_ server: PhoneServer, port: UInt16, error: String?) {
        guard self.server === server else { return }
        if let error {
            self.server = nil
            server.stop()
            serverFailed(port, error)
        } else if case .tailscale = way {
            publishTailscale(port)
        } else {
            (connected, failure) = (true, nil)
        }
    }

    private func serverFailed(_ port: UInt16, _ error: String) {
        (connected, tailnet, pairing) = (false, nil, nil)
        failure = "Kelp can't serve the phone's page on port \(port): \(error)"
        let previous = following
        previous?.cancel()
        following = Task {
            await previous?.value
            if !Task.isCancelled { await recoverPublication() }
            if await waitWhileActive(.seconds(15)) { serve(port) }
        }
    }

    /// Handles one call that came to this Mac's own server. It refuses the call, answers it sealed, or keeps it open as
    /// an event stream.
    func called(on server: PhoneServer, _ id: String, device: String, box: String, _ events: PhoneServer.Events) async
        -> PhoneServer.Answer
    {
        guard self.server === server else { return .refused(503) }
        switch admit(Sent(id: id, device: device, box: box)) {
        case .refused(let status): return .refused(status)
        case .answer(let box): return .box(box)
        case .events(var stream):
            stream.write = events.write
            stream.end = { _ in events.end() }
            streams[id] = stream
            return .stream
        case .ask(let ask, let device, let key):
            let reply = await answer(ask, from: device)
            let box = Self.sealed { try PhoneSeal.seal(reply, about: "r\(Int64(ask.n))", key: key) }
            return box.map(PhoneServer.Answer.box) ?? .refused(500)
        }
    }

    /// Keeps Tailscale serving the page at this Mac's name in its tailnet, and keeps the phones' streams open
    /// meanwhile. It asks Tailscale again every minute, because Tailscale may have been signed out, or installed since.
    func followTailscale(_ port: UInt16) async {
        let tailscale = tailscale
        while !Task.isCancelled {
            let served: Result<String, PhoneTailscale.Failed>
            do { served = try await Slots.elsewhere { tailscale.serve(port) } } catch {
                served = .failure(PhoneTailscale.Failed(message: error.rpcMessage))
            }
            guard !Task.isCancelled else { break }
            switch served {
            case .success(let address):
                if tailnet != address { pairing = nil }
                (tailnet, failure, connected) = (address, nil, true)
            case .failure(let why): (tailnet, failure, connected, pairing) = (nil, why.message, false, nil)
            }
            tailscaleSteps = served.steps
            for _ in 0..<4 {
                guard await waitWhileActive(.seconds(15)) else { break }
                for stream in streams.values { stream.write("\n") }   // A proxy on the way cuts a silent connection.
            }
        }
        await withdrawPublication()
    }

    /// On launch, even when Phone is off or its listener cannot start, retire the previous process’s background route.
    func recoverPublication() async {
        do {
            guard try !tailscale.owners().isEmpty else {
                cleanupError = nil
                return
            }
        } catch {
            retryWithdrawal(error)
            return
        }
        guard beginPublicationWork() else { return }
        defer { publications.leave() }
        await withdrawPublication(leavingLiveKelp: true)
    }

    /// `leavingLiveKelp`: the route is a previous process's, so one that another Kelp serves now (a second Kelp home on
    /// the same port) stays.
    private func withdrawPublication(leavingLiveKelp: Bool = false) async {
        cleanupRetry?.cancel()
        let tailscale = tailscale
        do {
            // A route left in a profile that isn't selected goes at the next launch or Phone change, not on a timer.
            _ = try await Slots.elsewhere { try tailscale.withdraw(leavingLiveKelp: leavingLiveKelp) }
            cleanupError = nil
        } catch { retryWithdrawal(error) }
    }

    private func retryWithdrawal(_ error: Error? = nil) {
        if let error {
            let why = "Couldn’t remove the phone’s Tailscale route: " + error.rpcMessage
            cleanupError = why
            Log.session.error("\(why, privacy: .public)")
        }
        // A disconnected profile can be selected again while Phone stays off.
        guard !stopping.withLock({ $0 }) else { return }
        cleanupRetry?.cancel()
        cleanupRetry = Task {
            if await waitWhileActive(.seconds(60)) { hear(.reconcile) }
        }
    }
}

/// Drives Tailscale's own command line, which serves a port of this Mac inside the user's tailnet over HTTPS with a
/// real certificate. A phone on the same tailnet then reaches the Mac directly. The page gets a port of its own (8443),
/// so a site that the user already serves at the root of the Mac's name stays theirs.
struct PhoneTailscale: Sendable {
    let store: Store
    var executable: @Sendable () -> String? = { PhoneTailscale.program }
    /// A route is owned only if Kelp recorded the intent before publishing it. Keys identify the tailnet host.
    static let ownersKey = "phone.tailscale.routes"

    func owners() throws -> [String: UInt16] {
        try store.daemonState(Self.ownersKey, as: [String: UInt16].self) ?? [:]
    }

    struct Failed: Error, Equatable {
        var message: String
        var steps = TailscaleSteps()
    }
    static let httpsPort = 8443

    /// The path to the `tailscale` program, found on the login shell's PATH (Homebrew) or else inside Tailscale.app.
    static var program: String? {
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        return LoginPath.find("tailscale") ?? (FileManager.default.isExecutableFile(atPath: app) ? app : nil)
    }

    /// Reads this Mac's address in its tailnet from `tailscale status --json`. Returns nil while Tailscale isn't
    /// connected.
    static func address(status: Data, requireRunning: Bool = true) -> String? {
        struct Status: Decodable {
            struct Node: Decodable { var DNSName: String? }
            var BackendState: String?
            var `Self`: Node?
        }
        let read = Log.session.attempt("reading Tailscale's status") {
            try JSONDecoder().decode(Status.self, from: status)
        }
        guard let status = read,
            !requireRunning || status.BackendState == "Running",
            let name = status.`Self`?.DNSName?.trimmingCharacters(in: ["."]), !name.isEmpty
        else { return nil }
        return "https://\(name):\(httpsPort)"
    }

    enum Route { case available, phone, occupied }

    /// Only an exclusively private HTTPS root for our loopback target can be advertised or removed.
    struct Config: Decodable {
        var TCP: [String: JSONValue]?, Web: [String: JSONValue]?, AllowFunnel: [String: Bool]?,
            Foreground: [String: Config]?

        func route(host: String, target: String) -> Route {
            let port = String(PhoneTailscale.httpsPort), hostPort = "\(host):\(port)"
            if Foreground?.values.contains(where: { $0.route(host: host, target: target) != .available }) == true
                || AllowFunnel?.contains(where: { $0.key.hasSuffix(":\(port)") && $0.value }) == true
            {
                return .occupied
            }
            let sites = Web?.filter { $0.key.hasSuffix(":\(port)") } ?? [:]
            guard TCP?[port] != nil || !sites.isEmpty else { return .available }
            let site = JSONValue.object(["Handlers": .object(["/": .object(["Proxy": .string(target)])])])
            return TCP?[port] == .object(["HTTPS": .bool(true)]) && sites == [hostPort: site] ? .phone : .occupied
        }
    }

    private static func route(_ program: String, address: String, target: String) throws -> Route {
        guard let host = URL(string: address)?.host else { return .occupied }
        let data = try Subprocess.output([program, "serve", "status", "--json"], cwd: "/", timeLimit: 15)
        return try JSONDecoder().decode(Config?.self, from: data)?.route(host: host, target: target) ?? .available
    }

    func serve(_ port: UInt16) -> Result<String, Failed> {
        guard let program = executable() else {
            return .failure(Failed(message: "Tailscale isn't installed on this Mac."))
        }
        var steps = TailscaleSteps(installed: true)
        do {
            let status = try Subprocess.output([program, "status", "--json"], cwd: "/", timeLimit: 15)
            guard let address = Self.address(status: status) else {
                return .failure(Failed(message: "Tailscale isn't connected. Open Tailscale and sign in.", steps: steps))
            }
            steps.signedIn = true
            let target = "http://127.0.0.1:\(port)"
            var owners = try owners()
            if let previous = owners[address], previous != port {
                try Self.remove(program, address: address, port: previous)
                owners.removeValue(forKey: address)
                try store.setDaemonState(Self.ownersKey, owners)
            }
            switch try Self.route(program, address: address, target: target) {
            case .occupied:
                if owners.removeValue(forKey: address) != nil {
                    try store.setDaemonState(Self.ownersKey, owners.isEmpty ? nil : owners)
                }
                return .failure(
                    Failed(message: "Tailscale port \(Self.httpsPort) already serves another site.", steps: steps))
            case .phone: break   // An exact pre-existing route can be borrowed without taking ownership.
            case .available:
                if owners[address] != port {
                    owners[address] = port
                    try store.setDaemonState(Self.ownersKey, owners)
                }
                let result = try Subprocess.run(
                    [program, "serve", "--bg", "--https=\(Self.httpsPort)", target], cwd: "/",
                    env: ProcessInfo.processInfo.environment, timeLimit: 15)
                if result.timedOut || result.status != 0 {
                    let output = result.stderr.isEmpty ? result.stdout : result.stderr
                    let reason =
                        ProgramError.firstSentence(String(decoding: output, as: UTF8.self))
                        ?? (result.timedOut
                            ? "Tailscale timed out publishing the page."
                            : "Tailscale serve exited with status \(result.status).")
                    return .failure(Failed(message: reason, steps: steps))
                }
                let current = try Subprocess.output([program, "status", "--json"], cwd: "/", timeLimit: 15)
                guard Self.address(status: current) == address,
                    try Self.route(program, address: address, target: target) == .phone
                else {
                    return .failure(
                        Failed(message: "Tailscale hasn't confirmed the private phone route.", steps: steps))
                }
            }
            return .success(address)
        } catch {
            return .failure(
                Failed(message: (error as? ProgramError)?.message ?? error.localizedDescription, steps: steps))
        }
    }

    /// Returns true if another profile still has a recorded publication. Its config is visible only when selected.
    func withdraw(leavingLiveKelp: Bool = false) throws -> Bool {
        var owners = try owners()
        guard !owners.isEmpty else { return false }
        guard let program = executable() else {   // Tailscale is gone, and its routes with it
            try store.setDaemonState(Self.ownersKey, nil as [String: UInt16]?)
            return false
        }
        let status = try Subprocess.output([program, "status", "--json"], cwd: "/", timeLimit: 15)
        guard let address = Self.address(status: status, requireRunning: false), let port = owners[address] else {
            return true
        }
        if try !leavingLiveKelp || !Self.kelpServes(port) { try Self.remove(program, address: address, port: port) }
        owners.removeValue(forKey: address)
        try store.setDaemonState(Self.ownersKey, owners.isEmpty ? nil : owners)
        return !owners.isEmpty
    }

    /// Whether a Kelp's phone page answers on `port` of this Mac now.
    static func kelpServes(_ port: UInt16) throws -> Bool {
        let page = try Subprocess.run(
            ["/usr/bin/curl", "-sf", "-m", "2", "http://127.0.0.1:\(port)/"], cwd: "/", env: [:], timeLimit: 5)
        return page.status == 0 && String(decoding: page.stdout, as: UTF8.self).contains("id=\"a-retry\"")
    }

    private static func remove(_ program: String, address: String, port: UInt16) throws {
        guard try route(program, address: address, target: "http://127.0.0.1:\(port)") == .phone else { return }
        _ = try Subprocess.checked(
            [program, "serve", "--https=\(httpsPort)", "--set-path=/", "off"], cwd: "/", timeLimit: 15)
    }
}

extension Result where Success == String, Failure == PhoneTailscale.Failed {
    /// Returns every step as done when Tailscale serves the page, or else the steps as far as Tailscale got.
    var steps: TailscaleSteps {
        switch self {
        case .success: TailscaleSteps(installed: true, signedIn: true, serving: true)
        case .failure(let why): why.steps
        }
    }
}
