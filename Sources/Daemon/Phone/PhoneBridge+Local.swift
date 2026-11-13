import Core
import Foundation

// A phone that reaches this Mac itself: kelpd serves the page and answers its calls on a port of localhost
// (`PhoneServer`), and Tailscale, or a tunnel of the user's own, brings the phone to that port.

extension PhoneBridge {
    /// Starts this Mac's own server on `port`.
    func serve(_ port: Int) {
        do {
            let server = try PhoneServer(
                port: UInt16(clamping: port), page: PhoneHTTP.page,
                call: { [weak self] id, device, box, events in
                    await self?.called(id, device: device, box: box, events) ?? .refused(503)
                },
                left: { [weak self] id in Task { await self?.cut([id], telling: false) } })
            server.start { [weak self] why in Task { await self?.serverFailed(port, why) } }
            self.server = server
            connected = true
            if PhoneHTTP.page == nil { failure = "This Kelp has no phone page in it." }
        } catch {
            serverFailed(port, error.localizedDescription)
        }
    }

    private func serverFailed(_ port: Int, _ why: String) {
        connected = false
        failure = "Kelp can't serve the phone's page on port \(port): \(why)"
    }

    /// One call that came to this Mac's own server: refused, answered sealed, or an event stream now open.
    func called(_ id: String, device: String, box: String, _ events: PhoneServer.Events) async -> PhoneServer.Answer {
        guard way != nil else { return .refused(503) }
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

    /// Keeps Tailscale serving the page at this Mac's name in its tailnet, and the streams open meanwhile. Asked
    /// again every minute: Tailscale may have been signed out, or installed since.
    func followTailscale(_ port: Int) async {
        while !Task.isCancelled {
            let served = await PhoneTailscale.serve(port: port, offloads)
            guard !Task.isCancelled, case .tailscale = way else { return }
            switch served {
            case .success(let address): (tailnet, failure, connected) = (address, nil, server != nil)
            case .failure(let why): (tailnet, failure, connected) = (nil, why.message, false)
            }
            tailscaleSteps = served.steps
            for _ in 0..<4 {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                for stream in streams.values { stream.write("\n") }   // a proxy on the way cuts a silent connection
            }
        }
    }
}

/// Tailscale's own command line, which serves a port of this Mac inside the user's tailnet over HTTPS with a real
/// certificate: the phone, on the same tailnet, reaches the Mac directly. On a port of its own (8443), so a site the
/// user already serves at the name's root stays theirs.
enum PhoneTailscale {
    struct Failed: Error, Equatable {
        var message: String
        var steps = TailscaleSteps()
    }
    static let httpsPort = 8443

    /// Its program: on the login shell's PATH (Homebrew), else inside the app.
    static var program: String? {
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        return LoginPath.find("tailscale") ?? (FileManager.default.isExecutableFile(atPath: app) ? app : nil)
    }

    /// This Mac's address in its tailnet from `tailscale status --json`: nil while it isn't connected.
    static func address(status: Data) -> String? {
        struct Status: Decodable {
            struct Node: Decodable { var DNSName: String? }
            var BackendState: String?
            var `Self`: Node?
        }
        let read = Log.session.attempt("reading Tailscale's status") {
            try JSONDecoder().decode(Status.self, from: status)
        }
        guard let status = read,
            status.BackendState == "Running",
            let name = status.`Self`?.DNSName?.trimmingCharacters(in: ["."]), !name.isEmpty
        else { return nil }
        return "https://\(name):\(httpsPort)"
    }

    /// Has Tailscale serve `port` and says at what address; why not, in words for Settings.
    static func serve(port: Int, _ offloads: Slots) async -> Result<String, Failed> {
        do { return try await offloads.run { served(port) } } catch {
            return .failure(Failed(message: "Kelp is stopping."))
        }
    }

    private static func run(_ program: String, _ arguments: [String]) -> Subprocess.Output? {
        Log.session.attempt("asking Tailscale") {
            try Subprocess.run(
                [program] + arguments, cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 15)
        }
    }

    private static func served(_ port: Int) -> Result<String, Failed> {
        guard let program else { return .failure(Failed(message: "Tailscale isn't installed on this Mac.")) }
        guard let status = run(program, ["status", "--json"]), let address = address(status: status.stdout) else {
            return .failure(
                Failed(
                    message: "Tailscale isn't connected. Open Tailscale and sign in.",
                    steps: TailscaleSteps(installed: true)))
        }
        let target = "http://127.0.0.1:\(port)"
        guard let served = run(program, ["serve", "--bg", "--https=\(httpsPort)", target]), served.status == 0,
            !served.timedOut
        else {
            // Without HTTPS certificates in the tailnet it prints where to turn them on, and waits.
            return .failure(Failed(message: certificates, steps: TailscaleSteps(installed: true, signedIn: true)))
        }
        return .success(address)
    }

    static let certificates =
        "Tailscale didn't serve the page. Turn on HTTPS certificates for your tailnet (Tailscale's admin console, "
        + "DNS), then try again."

    /// Takes the page off the tailnet again.
    static func stopServing(_ offloads: Slots) {
        guard let program else { return }
        Task {
            do { _ = try await offloads.run { run(program, ["serve", "--https=\(httpsPort)", "off"]) } } catch {
                Log.session.error("Tailscale still serves the phone's page: Kelp stopped first")
            }
        }
    }
}

extension Result where Success == String, Failure == PhoneTailscale.Failed {
    /// Every step done when it serves; else as far as it got.
    var steps: TailscaleSteps {
        switch self {
        case .success: TailscaleSteps(installed: true, signedIn: true, serving: true)
        case .failure(let why): why.steps
        }
    }
}
