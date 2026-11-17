import Foundation

public struct VMInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { machine.name }
    public var machine: VMMachine
    public var state: VMState
    /// While creating, how far ("Downloading Debian 13: 43%"); after an error, what went wrong.
    public var detail: String?
    /// Commands and shells open in it now.
    public var connections: Int?
    /// How much of the Mac's memory the machine holds while it runs, in MiB (its process's footprint, else its
    /// balloon's target).
    public var memoryMiB: Int?
    /// While it runs: the Mac's CPU it took over the last 5 s, % of one core, as Activity Monitor counts it.
    public var cpu: Double?
    /// How much of the Mac's disk the machine's disk takes, in MiB.
    public var diskMiB: Int?
    /// The Kelp sessions working in it now: a command running there (`kelp vm run` from an agent or a terminal), or the
    /// turn of a macOS machine's screen.
    public var sessions: [String]?
    /// While the machine is being made: the step it is at, and how far that step got (0…1) when that is known. `detail`
    /// names what it is made from at that step ("macOS 27.2").
    public var step: VMStep?, progress: Double?
    /// A Linux or macOS machine's exchange folder on the Mac, `~/Kelp` inside it (`VMs.filesSetup`).
    public var files: String?
    /// In `error`: true when making it failed (nothing to start: made again or deleted), nil when it was made and its
    /// last start failed (starting it again tries again).
    public var notMade: Bool?
    /// Its kelp-vm's log on the Mac, once there is one: what went wrong in more words than `detail` has.
    public var log: String?

    public init(
        machine: VMMachine, state: VMState, detail: String? = nil, connections: Int? = nil, memoryMiB: Int? = nil,
        diskMiB: Int? = nil
    ) {
        self.machine = machine
        self.state = state
        self.detail = detail
        self.connections = connections
        self.memoryMiB = memoryMiB
        self.diskMiB = diskMiB
    }
}

/// A step of making a machine, as its `creating` file says (`VMMaking`).
public enum VMStep: String, Codable, Sendable, CaseIterable {
    case asking, downloading, checking, unpacking, disk, installing, firstBoot, lettingIn, device, building, starting

    /// In English, for the CLI and logs (the app says it in the user's language).
    public func text(_ detail: String?) -> String {
        let what = detail ?? ""
        switch self {
        case .asking: return "Asking Apple for the latest macOS"
        case .downloading: return "Downloading \(what)"
        case .checking: return "Checking \(what)"
        case .unpacking: return "Unpacking \(what)"
        case .disk: return "Making its disk"
        case .installing: return "Installing \(what)"
        case .firstBoot: return "Setting macOS up: its first boot takes a few minutes"
        case .lettingIn: return "Letting Kelp in"
        case .device: return "Making its device from \(what)"
        case .building: return "Building Kelp's runner with Xcode"
        case .starting: return "Starting for the first time"
        }
    }
}

/// What a machine's `creating` file holds while the machine is being made: its step, how far it got, and what it is
/// made from.
public struct VMMaking: Codable, Sendable, Equatable {
    public var step: VMStep, progress: Double?, detail: String?
    public init(step: VMStep, progress: Double? = nil, detail: String? = nil) {
        self.step = step
        self.progress = progress
        self.detail = detail
    }
    public var data: Data { do { return try JSONEncoder().encode(self) } catch { return Data() } }
}

/// What runs in a machine, read from inside (`VMs.detailScript`), with the folders shared with it.
public struct VMDetail: Codable, Sendable, Equatable {
    /// Its address on the Mac's NAT network: where its ports open from here.
    public var address: String?
    public var ports: [Int]
    public var runs: [Run]
    public var folders: [String]
    /// A macOS machine's Kelp Guest: whether it may read controls (Accessibility), and whose turn the screen is (kelp-vm
    /// says). Nil: not a macOS machine, or Kelp Guest isn't in it. `screenRecording` is no longer asked for: always false.
    public var guest: Guest?

    public init(
        address: String? = nil, ports: [Int] = [], runs: [Run] = [], folders: [String] = [], guest: Guest? = nil
    ) {
        self.address = address
        self.ports = ports
        self.runs = runs
        self.folders = folders
        self.guest = guest
    }

    public struct Guest: Codable, Sendable, Equatable {
        /// False too while Kelp Guest isn't running (its permissions can't be told then).
        public var running: Bool, screenRecording: Bool, accessibility: Bool
        /// The session whose turn the screen is, while it lasts.
        public var screen: String?
        public init(running: Bool, screenRecording: Bool = false, accessibility: Bool = false, screen: String? = nil) {
            self.running = running
            self.screenRecording = screenRecording
            self.accessibility = accessibility
            self.screen = screen
        }
    }

    /// A `kelp vm run`: its command ("" for a shell), how long it has run, and the Kelp session that ran it.
    public struct Run: Codable, Sendable, Equatable {
        public var pid: Int, seconds: Int
        public var session: String?
        public var command: String
        public init(pid: Int, seconds: Int, session: String?, command: String) {
            self.pid = pid
            self.seconds = seconds
            self.session = session
            self.command = command
        }
    }
}

/// An image a machine can start from: a distribution's own cloud image, checked against its published checksums.
public struct VMImage: Sendable, Equatable {
    public var id: String, title: String
    /// The archive and the checksum file that lists it (SHA-512). macOS has neither: Apple's latest restore image for this
    /// Mac is asked for when it's made (`kelp-vm --latest`), and the installer checks Apple's signature on it.
    public var url: String, sums: String
    /// The raw disk inside the archive.
    public var member: String
    public var os = "linux"
    public var kind: VMKind { VMKind(os) }

    public static let all = [
        VMImage(
            id: "debian-13", title: "Debian 13",
            url: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.tar.xz",
            sums: "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS", member: "disk.raw"),
        VMImage(id: "linux", title: "Linux", url: "", sums: "", member: ""),   // from a raw disk of the user's (--file)
        VMImage(id: "macos", title: "macOS", url: "", sums: "", member: "", os: "macos"),
        VMImage(id: "android", title: "Android", url: "", sums: "", member: "", os: "android"),
        VMImage(id: "ios", title: "iOS", url: "", sums: "", member: "", os: "ios")
    ]
    public static func named(_ id: String) -> VMImage? { all.first { $0.id == id } }
}
