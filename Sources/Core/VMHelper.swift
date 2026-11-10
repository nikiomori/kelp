import Foundation

// Between the daemon and a machine's kelp-vm: the requests and replies on its ctl.sock.

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
        /// A `start` kelpd sends as it wakes the machine (`VMService.wake`): answered as soon as it starts, the boot going
        /// on; `show` along, for a boot with its window.
        public static func begin(show: Bool) -> Request {
            .init(op: .start, args: show ? ["begin", "show"] : ["begin"])
        }
        public var begins: Bool { op == .start && args?.first == "begin" }
        public var beginsShown: Bool { begins && args?.contains("show") == true }
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
