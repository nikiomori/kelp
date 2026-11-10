import Foundation

/// A virtual machine Kelp runs for agents on Apple Virtualization: a folder of its own under `<home>/vms/<name>` (its disk,
/// keys, sockets), run by a `kelp-vm` process (the only one with the virtualization entitlement). Agents reach it over SSH
/// through that process (vsock, no network address), each command a connection of its own; it pauses and then sleeps to
/// disk when none is open, and wakes on the next.
public struct VMMachine: Codable, Sendable, Equatable {
    public var name: String
    /// What it is, as the wire and machine.json have it: `linux`, `macos`, `android` or `ios` (`kind`).
    public var os: String
    /// Its `VMImage.id`.
    public var image: String
    public var cpus: Int, memoryMiB: Int, diskGiB: Int
    /// The account inside: the Mac user's name, so paths and prompts read the same.
    public var user: String
    /// x86-64 Linux programs run through Rosetta (when the Mac has it).
    public var rosetta: Bool
    public var network: Bool

    public init(
        name: String, os: String = "linux", image: String, cpus: Int, memoryMiB: Int, diskGiB: Int, user: String,
        rosetta: Bool = true, network: Bool = true
    ) {
        self.name = name
        self.os = os
        self.image = image
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.diskGiB = diskGiB
        self.user = user
        self.rosetta = rosetta
        self.network = network
    }
}

extension VMMachine {
    public var kind: VMKind { VMKind(os) }
}

/// What a machine is (`VMMachine.os` and `VMImage.os` on the wire), and what follows from that.
public enum VMKind: String, Sendable, CaseIterable {
    case linux, macos, android, ios

    /// One the wire names; a name this build doesn't know reads as Linux, as it always has.
    public init(_ os: String) { self = VMKind(rawValue: os) ?? .linux }

    /// A screen of its own: shown in a window (`vm.control` show), read and driven by agents (`vm.screen`).
    public var hasScreen: Bool { self != .linux }
    /// Its processors, memory and disk change after it's made (`vm.configure`): an Android or iOS device's are its own.
    public var resizable: Bool { self == .linux || self == .macos }
    /// Folders of the Mac shared into it: a project at its own path, the exchange folder (`VMInfo.files`). Android and
    /// iOS take files through adb and simctl.
    public var sharesFolders: Bool { self == .linux || self == .macos }
    /// The memory it may be given, GB: up to half the Mac's (`macGiB`), and at least what it needs (macOS: 4).
    public func memoryRange(macGiB: Int = Int(ProcessInfo.processInfo.physicalMemory >> 30)) -> ClosedRange<Int> {
        let least = self == .macos ? 4 : 1
        return least...max(least, macGiB / 2)
    }
}

public enum VMState: String, Codable, Sendable, CaseIterable {
    /// Its image is downloading or its disk being made (`VMInfo.detail` says how far).
    case creating
    /// Shut down: the next command boots it (a few seconds).
    case off
    /// Saved to disk, holding none of the Mac's memory: the next command wakes it in under a second.
    case sleeping
    case starting, running
    /// Stopped where it was, its memory still held: wakes at once.
    case paused
    case error
}

public struct VMInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { machine.name }
    public var machine: VMMachine
    public var state: VMState
    /// While creating, how far ("Downloading Debian 13: 43%"); after an error, what went wrong.
    public var detail: String?
    /// Commands and shells open in it now.
    public var connections: Int?
    /// What it holds of the Mac's memory while it runs (its process's footprint, else its balloon's target), MiB.
    public var memoryMiB: Int?
    /// While it runs: the Mac's CPU it took over the last 5 s, % of one core, as Activity Monitor counts it.
    public var cpu: Double?
    /// Its disk's size on the Mac's disk, MiB.
    public var diskMiB: Int?
    /// The Kelp sessions working in it now: a command running there (`kelp vm run` from an agent or a terminal), or the
    /// turn of a macOS machine's screen.
    public var sessions: [String]?
    /// While it's being made: the step it's at, and how far that step got (0…1) when that's known. `detail` names what
    /// it's made from then ("macOS 27.2").
    public var step: VMStep?, progress: Double?
    /// A Linux or macOS machine's exchange folder on the Mac, `~/Kelp` inside it (`VMs.filesSetup`).
    public var files: String?

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

/// What a machine's `creating` file holds while it's made: its step, how far, and what it's made from.
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

public enum VMs {
    /// A host name, a folder name and part of socket paths: short, lowercase, no dots.
    public static func isName(_ name: String) -> Bool {
        (1...20).contains(name.count) && name.first?.isLetter == true
            && name.allSatisfy { ("a"..."z").contains(String($0)) || $0.isNumber || $0 == "-" }
    }

    /// A Linux account name for the Mac user's, else "kelp".
    public static func user(_ mac: String) -> String {
        let ok =
            !mac.isEmpty && mac.count <= 32 && mac.first.map { $0.isLowercase || $0 == "_" } == true
            && mac.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-" } && mac != "root"
        return ok ? mac : "kelp"
    }

    /// Rosetta's binfmt line (Apple's "Running Intel binaries in Linux VMs with Rosetta").
    static let rosettaBinfmt =
        #":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:CF"#

    /// cloud-init's user-data for the first boot: the account with its key, the shared folders' mount, Rosetta.
    public static func userData(_ machine: VMMachine, publicKey: String, timeZone: String) -> String {
        var config = """
            #cloud-config
            hostname: \(machine.name)
            timezone: \(timeZone)
            ssh_pwauth: false
            users:
              - name: \(machine.user)
                sudo: ALL=(ALL) NOPASSWD:ALL
                shell: /bin/bash
                ssh_authorized_keys:
                  - \(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))

            """
        if machine.rosetta {
            config += """
                mounts:
                  - [rosetta, /mnt/rosetta, virtiofs, "defaults,nofail", "0", "0"]
                write_files:
                  - path: /etc/binfmt.d/rosetta.conf
                    content: |
                      \(rosettaBinfmt)
                runcmd:
                  - [systemctl, restart, systemd-binfmt]

                """
        }
        return config
    }

    /// The machine's ssh_config (`ssh -F` it, so the user's own config plays no part): `<name>` for agents and people, a
    /// connection each, counted as use; `<name>-own` for kelp-vm's own reads (the clock, memory), not counted.
    public static func sshConfig(_ machine: VMMachine, folder: VMFolder) -> String {
        func host(_ alias: String, _ socket: URL) -> String {
            """
            Host \(alias)
              HostName \(machine.name)
              User \(machine.user)
              IdentityFile "\(folder.key.path)"
              IdentitiesOnly yes
              UserKnownHostsFile "\(folder.knownHosts.path)"
              StrictHostKeyChecking accept-new
              ProxyCommand /usr/bin/nc -U \(ShellQuote.word(socket.path))
              ServerAliveInterval 15
              LogLevel ERROR

            """
        }
        // Kelp's own reads come every few seconds while it's watched: over one connection kept a minute, not a handshake each.
        let reuse = """
              ControlMaster auto
              ControlPath "\(folder.file("own.cm").path)"
              ControlPersist 60

            """
        return host(machine.name, folder.ssh) + host(machine.name + "-own", folder.own) + reuse
    }

    /// Folders shared at once: a virtio-fs device each (tag `kelp<n>`), since giving one device a new set of folders
    /// leaves every handle the guest holds on it stale. A ninth folder takes the slot used longest ago.
    public static let shareSlots = 8

    /// The command line run inside: `folder` mounted at its own path from its slot (again when that path holds another
    /// slot, or went stale), then `cwd`, then the command.
    public static func prefix(slot: Int, folder: String, cwd: String, os: VMKind = .linux) -> String {
        let dir = ShellQuote.word(folder), tag = "kelp\(slot)", cd = "cd \(ShellQuote.word(cwd)) || exit 1; "
        guard os == .macos else {
            return "{ [ \"$(findmnt -n -o SOURCE --mountpoint \(dir))\" = \(tag) ] && ls \(dir) >/dev/null 2>&1; } "
                + "|| { sudo umount -l \(dir) 2>/dev/null; sudo mount --mkdir -t virtiofs \(tag) \(dir); } || exit 1; "
                + cd
        }
        // macOS: mount(8) lists it as "kelp3 on /path (virtiofs, …)"; mount_virtiofs needs the folder there first.
        return "{ mount | grep -qF \(ShellQuote.word("\(tag) on \(folder) (")) && ls \(dir) >/dev/null 2>&1; } "
            + "|| { sudo umount -f \(dir) 2>/dev/null; sudo mkdir -p \(dir) && sudo mount_virtiofs \(tag) \(dir); } || exit 1; "
            + cd
    }

    /// What the guest keeps beyond what it uses, so a build that starts doesn't wait for memory.
    public static let headroomMiB = 1024

    /// The balloon's next target, MiB: what the guest uses plus `headroomMiB` (at least 1 GiB, at most all of it), a GiB
    /// more at once when it runs short, unchanged for less than 256 MiB. The guest counts the balloon's share as used.
    public static func memoryTarget(totalMiB: Int, availableMiB: Int, targetMiB: Int, machineMiB: Int) -> Int {
        let used = totalMiB - availableMiB - (machineMiB - targetMiB)
        var want = max(1024, used + headroomMiB)
        if availableMiB < 512 { want = max(want, targetMiB + 1024) }
        want = min(machineMiB, want)
        return abs(want - targetMiB) < 256 ? targetMiB : want
    }

    /// What runs after `prefix`: the command (a login shell for none) under bash's login profile, its name (argv[0])
    /// `kelp-vm-run:<session>` ("-" for none), which `detailScript` finds with ps on Linux and macOS alike. The EXIT trap
    /// keeps that bash: without one it would exec a lone command in its place, name and all.
    public static func command(_ command: String, session: String?) -> String {
        let id = (session ?? "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let run = "exec -a kelp-vm-run:\(id.isEmpty ? "-" : id) bash -l"
        return command.isEmpty ? run : run + " -c " + ShellQuote.word(trapped + command)
    }
    static let trapped = "trap : EXIT; "

    /// Run inside over `<name>-own`: its address, the TCP ports the account's own programs listen on (the system's DNS
    /// isn't news), then each `kelp vm run` still going (pid, elapsed, its argv), sections split by "@". Linux and macOS.
    public static let detailScript = #"""
        { hostname -I 2>/dev/null || ipconfig getifaddr en0; } | cut -d' ' -f1
        echo @
        if command -v ss >/dev/null; then ss -ltnpH 2>/dev/null | grep 'users:' | awk '{n=split($4,a,":"); print a[n]}'
        else lsof -nP -iTCP -sTCP:LISTEN -a -u "$(id -u)" 2>/dev/null | awk 'NR>1 {n=split($9,a,":"); print a[n]}'; fi | sort -un
        echo @
        ps -U "$(id -u)" -o pid=,etime=,args= | awk '$3 ~ /^kelp-vm-run:/'
        g="$HOME/Applications/KelpGuest.app/Contents/MacOS/KelpGuest"
        [ -x "$g" ] && { echo @; "$g" status 2>&1 || echo "not running"; }
        """#

    public static func parseDetail(_ text: String) -> VMDetail {
        // Sections a line "@" apart; an empty one is two such lines in a row.
        var parts: [[String]] = [[]]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "@" { parts.append([]) } else if !line.isEmpty { parts[parts.count - 1].append(String(line)) }
        }
        let lines = { (index: Int) in parts.count > index ? parts[index] : [] }
        var detail = VMDetail(address: lines(0).first.flatMap { $0.isEmpty ? nil : $0 })
        detail.ports = lines(1).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        detail.runs = lines(2).compactMap(run)
        if parts.count > 3 {
            let guest = lines(3)
            func on(_ key: String) -> Bool { guest.contains("\(key): on") }
            let screen = guest.first { $0.hasPrefix("screen: ") }.map { String($0.dropFirst("screen: ".count)) }
            detail.guest = .init(
                running: !guest.contains("not running") && !guest.isEmpty, screenRecording: on("screen recording"),
                accessibility: on("accessibility"), screen: screen == "free" ? nil : screen)
        }
        return detail
    }

    /// "  812     01:02:41 kelp-vm-run:abc -l -c npm test" → pid, seconds, session, command.
    static func run(_ line: String) -> VMDetail.Run? {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 3, let pid = Int(fields[0]), fields[2].hasPrefix("kelp-vm-run:") else { return nil }
        let argv = fields[2].dropFirst("kelp-vm-run:".count)
        let session = String(argv.prefix { $0 != " " })
        var command = argv.dropFirst(session.count).trimmingCharacters(in: .whitespaces)
        for flags in ["-l -c " + trapped, "-l -c ", "-l"] where command.hasPrefix(flags) {
            command = String(command.dropFirst(flags.count))
            break
        }
        return VMDetail.Run(
            pid: pid, seconds: seconds(fields[1]), session: session == "-" ? nil : session, command: command)
    }

    /// ps's elapsed time, "[[dd-]hh:]mm:ss", in seconds.
    static func seconds(_ etime: String) -> Int {
        let dayParts = etime.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    /// Its exchange folder's share: a macOS guest mounts it by itself under /Volumes/My Shared Files/Kelp, a Linux one
    /// takes the tag; `filesSetup` makes it `~/Kelp` either way, as the machine boots.
    public static let filesTag = "kelpfiles"
    public static func filesSetup(os: VMKind) -> String {
        os == .macos
            ? #"[ -e ~/Kelp ] || ln -s "/Volumes/My Shared Files/Kelp" ~/Kelp"#
            : "mountpoint -q ~/Kelp || { mkdir -p ~/Kelp && sudo mount -t virtiofs \(filesTag) ~/Kelp; }"
    }

    /// Kelp Guest's program inside a macOS machine (`kelp vm ui`, `press`), run over SSH.
    public static let guestProgram = "\"$HOME/Applications/KelpGuest.app/Contents/MacOS/KelpGuest\""

    /// Whether `path` may be shared with a machine: a folder below the home folder, not the home folder itself or above.
    public static func mayShare(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        func inside(_ candidate: String) -> Bool {
            candidate.hasPrefix(home + "/")
                && ![".ssh", ".kelp", "Library"].contains(
                    candidate.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? "")
        }
        // Where it really is too: a link in a project to ~/.ssh shares ~/.ssh.
        return inside(URL(fileURLWithPath: path).standardizedFileURL.path) && Paths.real(path).map(inside) != false
    }
}
