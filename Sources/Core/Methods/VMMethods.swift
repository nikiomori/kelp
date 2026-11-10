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
    /// An iOS machine's: its simulator's UDID and its runner's port (`ssh` is then xcrun simctl).
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
    public var name: String
    public var image: String?
    /// Memory in GiB, disk in GiB.
    public var cpus: Int?, memory: Int?, disk: Int?
    /// A file of the user's to make it from instead of downloading: macOS's restore image (.ipsw), or a Linux cloud image's
    /// raw disk (cloud-init sets its account up, as Debian's).
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

/// `start` boots or wakes it; `sleep` saves it to disk (its memory freed, what ran inside goes on when it wakes); `stop`
/// shuts it down (what ran inside ends); `delete` stops it and removes it, its disk and all. Stop and delete are the user's.
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
/// boots) while it's shut down. The user's: what every chat's machine has, and the Mac's memory.
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

/// A machine's screen, read and driven by the daemon: `args` as `kelp vm` takes them, ["screenshot", "/abs/file.png"],
/// ["click", "X", "Y", "--right"?, "--double"?], ["move", "X", "Y"], ["drag", "X", "Y", "X2", "Y2"],
/// ["scroll", "DY", "X"?, "Y"?], ["type", "TEXT"], ["key", "cmd+space"], ["press", "REF|TITLE"]; an Android or iOS
/// one's also ["install", "/abs/app"], ["launch", "ID"], ["open", "URL"]. A macOS machine's from the Mac's side (no
/// permission inside it), points of its 1280 × 800 screen, clicks, keys and scrolls taking turns by `session`; an
/// Android one's through adb, in its screen's pixels; an iOS one's through Kelp's runner, in points.
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

/// The controls on a machine's screen, a line each, indented, with a ref to press (`kelp vm ui`): a macOS machine's
/// front app (or `app`'s) through Kelp Guest inside it, an Android one's through uiautomator, an iOS one's through
/// Kelp's runner (`app`: a bundle id).
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
    /// As long as the daemon may take: idle machines put to sleep for room (60 s each), then a cold start (Android's, iOS's: 620 s).
    public static var timeout: TimeInterval? { 900 }
    public var name: String, cwd: String?
    public init(name: String, cwd: String?) {
        self.name = name
        self.cwd = cwd
    }
}
