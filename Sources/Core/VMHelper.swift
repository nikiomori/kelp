import Foundation

// Between the daemon and a machine's kelp-vm: the requests and replies on its ctl.sock, and the folder they share.

/// A machine's folder, `<home>/vms/<name>`: the files kelpd and the machine's kelp-vm read and write, named here once.
public struct VMFolder: Sendable, Equatable {
    public let url: URL
    public init(_ url: URL) { self.url = url }
    public var path: String { url.path }
    /// One of its files this doesn't name: a process's own (a log, a work folder).
    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    /// The machine (`VMMachine`): kelpd writes it as it's made and resized, kelp-vm reads it as it starts.
    public var machine: URL { file("machine.json") }
    /// While it's being made, how far (`VMMaking`): kelpd's steps, and `kelp-vm --install`'s progress.
    public var creating: URL { file("creating") }
    /// Why making it failed (kelpd's).
    public var failed: URL { file("failed") }
    /// The user's own file it's made from, to make it again after kelpd restarts (kelpd's).
    public var source: URL { file("source") }
    /// Held by its kelp-vm while that runs (`Lifecycle.hold`, `VMService.alive`), and by kelpd while it changes its size.
    public var lock: URL { file("kelp-vm.lock") }
    /// kelp-vm's sockets: kelpd's requests (`VMHelper`); SSH for agents and people, counted as use; Kelp's own reads.
    public var control: URL { file("ctl.sock") }
    public var ssh: URL { file("ssh.sock") }
    public var own: URL { file("own.sock") }
    /// The folder in each share slot (kelp-vm writes it, kelpd lists it).
    public var shares: URL { file("shares.json") }
    /// A Linux or macOS machine's disk: kelpd makes and grows it, kelp-vm runs it.
    public var disk: URL { file("disk.img") }
    /// A Linux machine's cloud-init seed: kelpd makes it, kelp-vm attaches it.
    public var seed: URL { file("seed.iso") }
    /// A Linux or macOS machine's state while it sleeps (kelp-vm's; kelpd forgets it on Shut Down).
    public var savedState: URL { file("state.vzsave") }
    /// How to reach it over SSH (`VMs.sshConfig`), with its key and the guest's host key.
    public var sshConfig: URL { file("ssh_config") }
    public var key: URL { file("id_ed25519") }
    public var knownHosts: URL { file("known_hosts") }
    /// Its exchange folder, `~/Kelp` inside (`VMInfo.files`): whichever of the two looks first makes it.
    public var files: URL { file("files") }
    /// A macOS machine's password until Kelp let itself in: kelpd writes it, its first boot reads it.
    public var password: URL { file("password") }
    /// There once its first boot finished (kelp-vm's).
    public var booted: URL { file("booted") }
    /// An Android machine's AVD home (ANDROID_AVD_HOME): kelpd makes its device there, kelp-vm runs it.
    public var avd: URL { file("avd") }
    /// An iOS machine's simulator, by its UDID: kelpd makes it, kelp-vm boots it.
    public var udid: URL { file("udid") }
    /// An iOS machine's runner as Xcode built it (its derived data): kelpd builds it, kelp-vm runs it.
    public var runnerBuild: URL { file("dd") }
    /// What its kelp-vm prints (kelpd starts it so).
    public var log: URL { file("helper.log") }

    /// An Android machine's quickboot snapshot, which its emulator saves as it sleeps.
    public func snapshot(_ machine: String) -> URL {
        avd.appendingPathComponent("\(machine).avd/snapshots/default_boot")
    }

    /// What the machine keeps while it sleeps: a Linux or macOS one's saved state, an Android one's snapshot. An iOS
    /// simulator keeps none.
    public func sleepState(_ machine: VMMachine) -> URL? {
        switch machine.kind {
        case .linux, .macos: savedState
        case .android: snapshot(machine.name)
        case .ios: nil
        }
    }

    /// How the machine is with no kelp-vm running it: asleep while it keeps a state to wake from, else off. kelpd lists
    /// it so, and a kelp-vm starts from it.
    public func restingState(_ machine: VMMachine) -> VMState {
        sleepState(machine).map { FileManager.default.fileExists(atPath: $0.path) } == true ? .sleeping : .off
    }
}

/// Between the daemon and a machine's `kelp-vm`: one JSON line each way on its ctl.sock.
public enum VMHelper {
    public struct Request: Codable, Sendable {
        /// `quit`: the machine off at once, and its kelp-vm gone (its folder is about to be).
        /// `screen`: a macOS machine's screen read or driven from the Mac's side, `args` as `kelp vm` takes them
        /// (["click", "640", "400"], ["screenshot", "/path.png"]…), in `session`'s turn.
        public enum Operation: String, Codable, Sendable { case status, start, sleep, stop, share, show, quit, screen }
        public var op: Operation
        /// `share`: the folder here; the answer's `slot` says which of the machine's shares holds it.
        public var path: String?
        public var args: [String]?, session: String?
        /// A `begin` (`begin(show:)`) for a boot with its window.
        public var show: Bool?
        /// A `quit` for a new size (`quitIfDown`): only if the machine is down.
        public var ifDown: Bool?
        /// A `start` kelpd sends as it wakes the machine (`VMService.wake`): answered as soon as it starts, the boot going
        /// on; `show` along, for a boot with its window. `args` says so too, for a kelp-vm from before `show` (one that
        /// outlived an upgrade of kelpd), and is read when `show` isn't there, for a kelpd from before it.
        public static func begin(show: Bool) -> Request {
            var request = Request(op: .start, args: show ? ["begin", "show"] : ["begin"])
            request.show = show
            return request
        }
        public var begins: Bool { op == .start && args?.first == "begin" }
        public var beginsShown: Bool { begins && (show ?? args?.contains("show") == true) }
        /// A `quit` kelpd sends before it writes a new size (`VMService.configure`): refused by a machine that's up
        /// (`Lifecycle.refusesQuit`), which a command may have woken since. `args` says so too, as for `begin`.
        public static var quitIfDown: Request {
            var request = Request(op: .quit, args: ["if-down"])
            request.ifDown = true
            return request
        }
        public var quitsIfDown: Bool { op == .quit && (ifDown ?? (args == ["if-down"])) }
        /// A `sleep` kelpd's memory budget sends (`VMService.admit`): refused by a machine in use at that moment. The
        /// user's own sleep has no args, and isn't.
        public static var sleepIfIdle: Request { .init(op: .sleep, args: ["if-idle"]) }
        public var ifIdle: Bool { op == .sleep && args == ["if-idle"] }
        public init(op: Operation, path: String? = nil, args: [String]? = nil, session: String? = nil) {
            self.op = op
            self.path = path
            self.args = args
            self.session = session
        }
    }
    public struct Reply: Codable, Sendable {
        public var state: VMState
        public var connections: Int, memoryMiB: Int?
        public var error: String?
        /// `share`: its slot, tag `kelp<slot>` inside.
        public var slot: Int?
        /// An Android machine's adb serial while its emulator runs ("emulator-5600"); an iOS one's simulator UDID.
        public var serial: String?
        /// An iOS machine's runner, on the Mac's loopback.
        public var port: Int?
        /// A macOS machine's screen: the session whose turn it is, while it lasts.
        public var screen: String?
        /// While it runs: its CPU over the last 5 s, % of one core (`VMInfo.cpu`).
        public var cpu: Double?
        public init(
            state: VMState, connections: Int, memoryMiB: Int? = nil, error: String? = nil, slot: Int? = nil,
            serial: String? = nil
        ) {
            self.state = state
            self.connections = connections
            self.memoryMiB = memoryMiB
            self.error = error
            self.slot = slot
            self.serial = serial
        }
    }
}
