import Foundation

// What passes between the daemon and a machine's kelp-vm: the requests and replies on its ctl.sock, and the folder they
// share.

/// A machine's folder, `<home>/vms/<name>`. It names, in one place, the files that kelpd and the machine's kelp-vm read
/// and write.
public struct VMFolder: Sendable, Equatable {
    public let url: URL
    public init(_ url: URL) { self.url = url }
    public var path: String { url.path }
    /// Returns any file in the machine's folder that has no name of its own here, such as a file a process keeps for
    /// itself (a log, a work folder).
    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    /// The machine's description (`VMMachine`). kelpd writes it when the machine is made and resized, and kelp-vm reads
    /// it at start.
    public var machine: URL { file("machine.json") }
    /// How far making the machine has got (`VMMaking`), while it is being made. It holds kelpd's steps and the progress
    /// of `kelp-vm --install`.
    public var creating: URL { file("creating") }
    /// Why making the machine failed, written by kelpd.
    public var failed: URL { file("failed") }
    /// The user's own file the machine is made from. kelpd writes it so it can make the machine again after a
    /// restart.
    public var source: URL { file("source") }
    /// A lock that the machine's kelp-vm holds while it runs (`Lifecycle.hold`, `VMService.alive`), and that kelpd
    /// holds while it changes the machine's size.
    public var lock: URL { file("kelp-vm.lock") }
    /// kelp-vm's sockets: one for kelpd's requests (`VMHelper`), one for SSH from agents and people (which counts as
    /// use), and one for Kelp's own reads.
    public var control: URL { file("ctl.sock") }
    public var ssh: URL { file("ssh.sock") }
    public var own: URL { file("own.sock") }
    /// The folder in each share slot. kelp-vm writes it and kelpd lists it.
    public var shares: URL { file("shares.json") }
    /// A Linux or macOS machine's disk. kelpd makes and grows it, and kelp-vm runs it.
    public var disk: URL { file("disk.img") }
    /// A Linux machine's cloud-init seed. kelpd makes it, and kelp-vm attaches it.
    public var seed: URL { file("seed.iso") }
    /// The saved state of a Linux or macOS machine while it sleeps. kelp-vm writes it, and kelpd discards it on Shut
    /// Down.
    public var savedState: URL { file("state.vzsave") }
    /// How to reach the machine over SSH (`VMs.sshConfig`), with its key and the guest's host key.
    public var sshConfig: URL { file("ssh_config") }
    public var key: URL { file("id_ed25519") }
    public var knownHosts: URL { file("known_hosts") }
    /// The machine's exchange folder, which is `~/Kelp` inside it (`VMInfo.files`). Whichever of kelpd and kelp-vm
    /// looks for it first makes it.
    public var files: URL { file("files") }
    /// A macOS machine's password, kept until Kelp has logged itself in. kelpd writes it, and the first boot reads it.
    public var password: URL { file("password") }
    /// A marker kelp-vm writes once the machine's first boot finished.
    public var booted: URL { file("booted") }
    /// An Android machine's AVD home (ANDROID_AVD_HOME). kelpd makes the device there, and kelp-vm runs it.
    public var avd: URL { file("avd") }
    /// The UDID of an iOS machine's simulator. kelpd makes the simulator, and kelp-vm boots it.
    public var udid: URL { file("udid") }
    /// An iOS machine's runner as Xcode built it (its derived data). kelpd builds it, and kelp-vm runs it.
    public var runnerBuild: URL { file("dd") }
    /// The output of the machine's kelp-vm, which kelpd sends here when it starts kelp-vm.
    public var log: URL { file("helper.log") }
    /// A note on a child process that kelp-vm started (an emulator, an iOS runner), written as "<pid> <start time>"
    /// (`Lifecycle.remember`).
    public func child(_ name: String) -> URL { file(name + ".child") }
    /// The name of kelp-vm's note about itself. It is written the same way as a child's, so kelpd can end a kelp-vm
    /// that holds its lock and no longer answers.
    public static let helperNote = "kelp-vm"

    /// Ends the child noted as `name` if that same process (matched by its start time) still runs. It sends SIGTERM to
    /// the process tree and then SIGKILL, before it returns, and removes the note either way. Returns the pid when a
    /// process was ended. It cleans up after a kelp-vm that was killed, at kelp-vm's next boot and in kelpd's sweep
    /// before it makes a machine again. An emulator names its AVD in its environment, not its arguments, so
    /// `pkill -f <folder>` doesn't find it.
    @discardableResult public func endChild(_ name: String) -> pid_t? {
        guard let words = String(contentsIfAny: child(name))?.split(separator: " "), words.count == 2,
            let pid = pid_t(words[0]), let start = UInt64(words[1])
        else { return nil }
        FileManager.default.removeIfAny(child(name))
        guard start != 0, Subprocess.started(pid) == start else { return nil }
        Subprocess.stopTreeNow(pid)
        return pid
    }

    /// An Android machine's quickboot snapshot, which the emulator saves when the machine sleeps.
    public func snapshot(_ machine: String) -> URL {
        avd.appendingPathComponent("\(machine).avd/snapshots/default_boot")
    }

    /// Returns what the machine keeps while it sleeps: the saved state for Linux or macOS, and the snapshot for
    /// Android. An iOS simulator keeps none.
    public func sleepState(_ machine: VMMachine) -> URL? {
        switch machine.kind {
        case .linux, .macos: savedState
        case .android: snapshot(machine.name)
        case .ios: nil
        }
    }

    /// Returns the machine's state while no kelp-vm runs it: sleeping while it keeps a state to wake from, and off
    /// otherwise. kelpd lists the machine with this state, and a kelp-vm starts from it.
    public func restingState(_ machine: VMMachine) -> VMState {
        sleepState(machine).map { FileManager.default.fileExists(atPath: $0.path) } == true ? .sleeping : .off
    }
}

/// The protocol between the daemon and a machine's `kelp-vm`: one JSON line each way on the machine's ctl.sock.
public enum VMHelper {
    public struct Request: Codable, Sendable {
        /// `quit` turns the machine off at once and ends its kelp-vm, because the machine's folder is about to go.
        /// `screen` reads or drives a macOS machine's screen from the Mac's side, with `args` as `kelp vm` takes them
        /// (["click", "640", "400"], ["screenshot", "/path.png"]…), during the turn of `session`.
        public enum Operation: String, Codable, Sendable { case status, start, sleep, stop, share, show, quit, screen }
        public var op: Operation
        /// For `share`, the folder on the Mac. The answer's `slot` says which of the machine's shares holds it.
        public var path: String?
        public var args: [String]?, session: String?
        /// True for a `begin` request (`begin(show:)`) that boots the machine with its window.
        public var show: Bool?
        /// True for a `quit` before a resize (`quitIfDown`), which quits only if the machine is down.
        public var ifDown: Bool?
        /// The `start` request kelpd sends when it wakes the machine (`VMService.wake`). kelp-vm answers as soon as the
        /// machine starts, while the boot goes on. `show` asks for a boot with the window. `args` carries the same
        /// request for a kelp-vm older than `show` (one that outlived an upgrade of kelpd), and kelp-vm reads `args`
        /// when `show` is missing, for a kelpd older than `show`.
        public static func begin(show: Bool) -> Request {
            var request = Request(op: .start, args: show ? ["begin", "show"] : ["begin"])
            request.show = show
            return request
        }
        public var begins: Bool { op == .start && args?.first == "begin" }
        public var beginsShown: Bool { begins && (show ?? args?.contains("show") == true) }
        /// The `quit` request kelpd sends before it writes a new size (`VMService.configure`). A machine that is up
        /// refuses it (`Lifecycle.refusesQuit`), because a command may have woken it since. `args` carries the same
        /// request too, as for `begin`.
        public static var quitIfDown: Request {
            var request = Request(op: .quit, args: ["if-down"])
            request.ifDown = true
            return request
        }
        public var quitsIfDown: Bool { op == .quit && (ifDown ?? (args == ["if-down"])) }
        /// The `sleep` request that kelpd's memory budget sends (`VMService.admit`). A machine in use at that moment
        /// refuses it. A sleep the user asks for has no args and is never refused.
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
        /// For `share`, the slot that holds the folder, whose tag inside the machine is `kelp<slot>`.
        public var slot: Int?
        /// An Android machine's adb serial while its emulator runs ("emulator-5600"), or an iOS machine's simulator
        /// UDID.
        public var serial: String?
        /// The loopback port of an iOS machine's runner on the Mac.
        public var port: Int?
        /// For a macOS machine, the session whose turn it is to use the screen, while the turn lasts.
        public var screen: String?
        /// The machine's CPU use over the last 5 s while it runs, as a percentage of one core (`VMInfo.cpu`).
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
