import Foundation

// The vm.* methods for machines, and how to reach a machine (VMConnection).

/// Returns what runs in a running machine. nil while the machine isn't running, because reading never wakes it.
public struct VMDetailRead: InternalMethod {
    public static let name = "vm.detail"
    public typealias Result = VMDetail?
    public var name: String
    public init(name: String) { self.name = name }
}

/// How to run something in a machine: `ssh` and its arguments up to the host, then the command line for the machine's
/// shell, which mounts the project folder at the same path inside and changes to it.
public struct VMConnection: Codable, Sendable, Equatable {
    public var ssh: [String]
    public var prefix: String
    /// For an iOS machine, the simulator's UDID and the runner's port. `ssh` is then xcrun simctl.
    public var device: String?, port: Int?
    public init(ssh: [String], prefix: String, device: String? = nil, port: Int? = nil) {
        self.ssh = ssh
        self.prefix = prefix
        self.device = device
        self.port = port
    }
}

/// Lists the machines and their state.
public struct VMList: RPCMethod {
    public static let name = "vm.list"
    public typealias Result = [VMInfo]
    public init() {}
}

/// Makes a machine. It downloads the image the first time (checked against the distribution's checksums), then makes
/// the disk and runs the first boot. It answers at once with `creating`, and `vm.list` shows the progress.
public struct VMCreate: RPCMethod {
    public static let name = "vm.create"
    public typealias Result = VMInfo
    /// A create from an agent first asks the user on the agent's row, for up to ten minutes (`answerWithin`). A create
    /// from the user makes the machine at once.
    public static let answerWithin: TimeInterval = 600
    public static var timeout: TimeInterval? { answerWithin + 60 }
    public var name: String
    public var image: String?
    /// The memory and the disk are in GiB.
    public var cpus: Int?, memory: Int?, disk: Int?
    /// A file of the user's to make the machine from instead of downloading an image. It is a macOS restore image
    /// (.ipsw), or a Linux cloud image's raw disk, whose account cloud-init sets up (as on Debian).
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

/// Controls a machine. `start` boots or wakes it. `sleep` saves it to disk, which frees its memory, and what ran inside
/// goes on when it wakes. `stop` shuts it down, which ends what ran inside. `delete` stops it and removes it, disk and
/// all. Only the user may stop or delete.
public struct VMControl: RPCMethod {
    public static let name = "vm.control"
    public typealias Result = VMInfo
    /// A start can boot the machine, which takes up to a few minutes, more than a call's usual deadline. Show can mean
    /// two boots (`showWait`).
    public static var timeout: TimeInterval? { 1200 }
    /// How long kelpd waits for a Show, which can mean a headless first boot that an agent began and then the windowed
    /// boot. It fits within `timeout`.
    public static let showWait: TimeInterval = 1100
    /// `show` wakes the machine first and then shows its screen in a window of its own (a macOS machine's).
    public enum Action: String, Codable, Sendable, CaseIterable { case start, sleep, stop, show, delete }
    public var name: String, action: Action
    public init(name: String, action: Action) {
        self.name = name
        self.action = action
    }
}

/// Changes a Linux or macOS machine's processors, memory (GB) and disk (GB) while it is shut down. The disk can only
/// get larger, and Linux grows into it as it boots. Only the user may do this, because it sets what every chat's
/// machine has and how much of the Mac's memory it takes.
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

/// Types into a macOS machine's screen. When `text` is nil, it types the machine's password (from the Keychain), for a
/// dialog inside that asks for it (Privacy & Security, an installer).
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
/// ["scroll", "DY", "X"?, "Y"?], ["type", "TEXT"], ["key", "cmd+space"], ["press", "REF|TITLE"]. An Android or iOS
/// machine also takes ["install", "/abs/app"], ["launch", "ID"] and ["open", "URL"]. A macOS machine is driven from the
/// Mac's side (no permission is needed inside it), in points of its 1280 × 800 screen, and sessions take turns with
/// clicks, keys and scrolls by `session`. An Android machine is driven through adb, in screen pixels, and an iOS
/// machine through Kelp's runner, in points.
public struct VMScreen: RPCMethod {
    public static let name = "vm.screen"
    public typealias Result = Done
    /// A sleeping machine wakes first, and an Android or iOS machine may boot (`VMConnect.timeout`). The call also
    /// waits for another session's turn to end.
    public static var timeout: TimeInterval? { VMConnect.timeout }
    public var name: String, args: [String], session: String?
    public init(name: String, args: [String], session: String? = nil) {
        self.name = name
        self.args = args
        self.session = session
    }
}

/// Returns the controls on a machine's screen, one per line, indented, each with a ref to press (`kelp vm ui`). On a
/// macOS machine they come from the front app (or from `app`) through Kelp Guest inside it. On an Android machine they
/// come through uiautomator, and on an iOS machine through Kelp's runner, where `app` is a bundle id.
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

/// Returns what `kelp vm run` needs to run a command in the machine, in the project folder of `cwd`, which is shared
/// with the machine at the same path. With no `cwd`, the command runs in the machine's own home folder and nothing is
/// shared.
public struct VMConnect: RPCMethod {
    public static let name = "vm.connect"
    public typealias Result = VMConnection
    /// The longest the daemon may take. It may put idle machines to sleep to make room (60 s each), then do a cold
    /// start (620 s for Android or iOS).
    public static var timeout: TimeInterval? { 900 }
    public var name: String, cwd: String?
    public init(name: String, cwd: String?) {
        self.name = name
        self.cwd = cwd
    }
}
