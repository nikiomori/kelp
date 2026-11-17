import Foundation

// vm.*: the RPCs for machines, and how to reach one (VMConnection).

/// What runs in a running machine; nil while it isn't running (reading never wakes it).
public struct VMDetailRead: InternalMethod {
    public static let name = "vm.detail"
    public typealias Result = VMDetail?
    public var name: String
    public init(name: String) { self.name = name }
}

/// How to run something in a machine: `ssh` and its arguments up to the host, then the command line for the machine's
/// shell, which puts the project folder at the same path inside and goes there.
public struct VMConnection: Codable, Sendable, Equatable {
    public var ssh: [String]
    public var prefix: String
    /// For an iOS machine: its simulator's UDID and its runner's port (`ssh` is then xcrun simctl).
    public var device: String?, port: Int?
    public init(ssh: [String], prefix: String, device: String? = nil, port: Int? = nil) {
        self.ssh = ssh
        self.prefix = prefix
        self.device = device
        self.port = port
    }
}

/// The machines and their state.
public struct VMList: RPCMethod {
    public static let name = "vm.list"
    public typealias Result = [VMInfo]
    public init() {}
}

/// Makes a machine: downloads its image the first time (checked against the distribution's checksums), then its disk and
/// first boot. Answers at once, `creating`; `vm.list` follows it.
public struct VMCreate: RPCMethod {
    public static let name = "vm.create"
    public typealias Result = VMInfo
    /// An agent's asks the user first, on its row, for up to ten minutes (`answerWithin`); the user's makes it at once.
    public static let answerWithin: TimeInterval = 600
    public static var timeout: TimeInterval? { answerWithin + 60 }
    public var name: String
    public var image: String?
    /// Memory in GiB, disk in GiB.
    public var cpus: Int?, memory: Int?, disk: Int?
    /// A file of the user's to make the machine from instead of downloading one: macOS's restore image (.ipsw), or a
    /// Linux cloud image's raw disk (whose account cloud-init sets up, as on Debian).
    public var file: String?
    public init(
        name: String, image: String? = nil, cpus: Int? = nil, memory: Int? = nil, disk: Int? = nil, file: String? = nil
    ) {
        self.name = name
        self.image = image
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
        self.file = file
    }
}

/// `start` boots or wakes the machine; `sleep` saves it to disk (its memory is freed, and what ran inside goes on when
/// it wakes); `stop` shuts it down (what ran inside ends); `delete` stops it and removes it, disk and all. Only the
/// user may stop or delete.
public struct VMControl: RPCMethod {
    public static let name = "vm.control"
    public typealias Result = VMInfo
    /// A start can boot: up to a few minutes, more than a call's usual deadline. Show can be two boots (`showWait`).
    public static var timeout: TimeInterval? { 1200 }
    /// What kelpd waits for a Show (a headless first boot an agent began, then the windowed one): within `timeout`.
    public static let showWait: TimeInterval = 1100
    /// `show`: its screen in a window of its own (a macOS machine's), woken first.
    public enum Action: String, Codable, Sendable, CaseIterable { case start, sleep, stop, show, delete }
    public var name: String, action: Action
    public init(name: String, action: Action) {
        self.name = name
        self.action = action
    }
}

/// Changes a Linux or macOS machine's processors, memory (GB) and disk (GB, only larger: Linux grows into it as it
/// boots) while it is shut down. Only the user may do this, since it sets what every chat's machine has and how much of
/// the Mac's memory it takes.
public struct VMConfigure: RPCMethod {
    public static let name = "vm.configure"
    public typealias Result = VMInfo
    public var name: String, cpus: Int?, memory: Int?, disk: Int?
    public init(name: String, cpus: Int? = nil, memory: Int? = nil, disk: Int? = nil) {
        self.name = name
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
    }
}

/// Types into a macOS machine's screen. `text` nil: the machine's password (from the Keychain), for a dialog inside
/// that asks for it (Privacy & Security, an installer).
public struct VMType: RPCMethod {
    public static let name = "vm.type"
    public typealias Result = Done
    public var name: String, text: String?
    public init(name: String, text: String? = nil) {
        self.name = name
        self.text = text
    }
}

/// Reads and drives a machine's screen through the daemon. `args` are as `kelp vm` takes them: ["screenshot",
/// "/abs/file.png"], ["click", "X", "Y", "--right"?, "--double"?], ["move", "X", "Y"], ["drag", "X", "Y", "X2", "Y2"],
/// ["scroll", "DY", "X"?, "Y"?], ["type", "TEXT"], ["key", "cmd+space"], ["press", "REF|TITLE"]; an Android or iOS
/// machine also takes ["install", "/abs/app"], ["launch", "ID"], ["open", "URL"].
/// A macOS machine is driven from the Mac's side (no permission is needed inside it), in points of its 1280 × 800
/// screen, with clicks, keys and scrolls taking turns by `session`. An Android machine is driven through adb, in its
/// screen's pixels; an iOS machine through Kelp's runner, in points.
public struct VMScreen: RPCMethod {
    public static let name = "vm.screen"
    public typealias Result = Done
    /// A sleeping machine wakes first, an Android or iOS one may boot (`VMConnect.timeout`); another session's turn is
    /// waited for.
    public static var timeout: TimeInterval? { VMConnect.timeout }
    public var name: String, args: [String], session: String?
    public init(name: String, args: [String], session: String? = nil) {
        self.name = name
        self.args = args
        self.session = session
    }
}

/// The controls on a machine's screen, one per line, indented, each with a ref to press (`kelp vm ui`). On a macOS
/// machine they come from the front app (or from `app`) through Kelp Guest inside it; on an Android machine through
/// uiautomator; on an iOS machine through Kelp's runner (`app` is a bundle id).
public struct VMUI: RPCMethod {
    public static let name = "vm.ui"
    public typealias Result = String
    public static var timeout: TimeInterval? { VMConnect.timeout }
    public var name: String, app: String?
    public init(name: String, app: String? = nil) {
        self.name = name
        self.app = app
    }
}

/// What `kelp vm run` needs to run a command in it, in `cwd`'s project folder (shared with the machine at the same path);
/// with no `cwd`, in its own home folder, nothing shared.
public struct VMConnect: RPCMethod {
    public static let name = "vm.connect"
    public typealias Result = VMConnection
    /// The longest the daemon may take: putting idle machines to sleep to make room (60 s each), then a cold start
    /// (Android's or iOS's: 620 s).
    public static var timeout: TimeInterval? { 900 }
    public var name: String, cwd: String?
    public init(name: String, cwd: String?) {
        self.name = name
        self.cwd = cwd
    }
}
