import Foundation

/// A virtual machine Kelp runs for agents on Apple Virtualization: a folder of its own under `<home>/vms/<name>` (its disk,
/// keys, sockets), run by a `kelp-vm` process (the only one with the virtualization entitlement). Agents reach it over SSH
/// through that process (vsock, no network address), each command a connection of its own; it pauses and then sleeps to
/// disk when none is open, and wakes on the next.
public struct VMMachine: Codable, Sendable, Equatable {
    public var name: String
    /// `linux` for now.
    public var os: String
    /// Its `VMImage.id`.
    public var image: String
    public var cpus: Int, memoryMiB: Int, diskGiB: Int
    /// The account inside: the Mac user's name, so paths and prompts read the same.
    public var user: String
    /// x86-64 Linux programs run through Rosetta (when the Mac has it).
    public var rosetta: Bool
    public var network: Bool

    public init(name: String, os: String = "linux", image: String, cpus: Int, memoryMiB: Int, diskGiB: Int, user: String,
                rosetta: Bool = true, network: Bool = true) {
        self.name = name; self.os = os; self.image = image; self.cpus = cpus; self.memoryMiB = memoryMiB; self.diskGiB = diskGiB
        self.user = user; self.rosetta = rosetta; self.network = network
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
    /// What it holds of the Mac's memory while it runs (its balloon's target), MiB.
    public var memoryMiB: Int?
    /// Its disk's size on the Mac's disk, MiB.
    public var diskMiB: Int?
    /// The Kelp sessions with a command running in it now (`kelp vm run` from an agent or a terminal).
    public var sessions: [String]?

    public init(machine: VMMachine, state: VMState, detail: String? = nil, connections: Int? = nil, memoryMiB: Int? = nil, diskMiB: Int? = nil) {
        self.machine = machine; self.state = state; self.detail = detail; self.connections = connections
        self.memoryMiB = memoryMiB; self.diskMiB = diskMiB
    }
}

/// What runs in a machine, read from inside (`VMs.detailScript`), with the folders shared with it.
public struct VMDetail: Codable, Sendable, Equatable {
    /// Its address on the Mac's NAT network: where its ports open from here.
    public var address: String?
    public var ports: [Int]
    public var runs: [Run]
    public var folders: [String]
    /// A macOS machine's Kelp Guest: whether it may record the screen and act on it, and whose turn the screen is. Nil:
    /// not a macOS machine, or Kelp Guest isn't in it.
    public var guest: Guest?

    public init(address: String? = nil, ports: [Int] = [], runs: [Run] = [], folders: [String] = [], guest: Guest? = nil) {
        self.address = address; self.ports = ports; self.runs = runs; self.folders = folders; self.guest = guest
    }

    public struct Guest: Codable, Sendable, Equatable {
        /// False too while Kelp Guest isn't running (its permissions can't be told then).
        public var running: Bool, screenRecording: Bool, accessibility: Bool
        /// The session whose turn the screen is, while it lasts.
        public var screen: String?
        public init(running: Bool, screenRecording: Bool = false, accessibility: Bool = false, screen: String? = nil) {
            self.running = running; self.screenRecording = screenRecording; self.accessibility = accessibility; self.screen = screen
        }
    }

    /// A `kelp vm run`: its command ("" for a shell), how long it has run, and the Kelp session that ran it.
    public struct Run: Codable, Sendable, Equatable {
        public var pid: Int, seconds: Int
        public var session: String?
        public var command: String
        public init(pid: Int, seconds: Int, session: String?, command: String) {
            self.pid = pid; self.seconds = seconds; self.session = session; self.command = command
        }
    }
}

/// What runs in a running machine; nil while it isn't running (reading never wakes it).
public struct VMDetailRead: InternalMethod {
    public static let name = "vm.detail"; public typealias Result = VMDetail?
    public var name: String
    public init(name: String) { self.name = name }
}

/// How to run something in a machine: `ssh` and its arguments up to the host, then the command line for the machine's
/// shell, which puts the project folder at the same path inside and goes there.
public struct VMConnection: Codable, Sendable, Equatable {
    public var ssh: [String]
    public var prefix: String
    public init(ssh: [String], prefix: String) { self.ssh = ssh; self.prefix = prefix }
}

/// The machines and their state.
public struct VMList: RPCMethod {
    public static let name = "vm.list"; public typealias Result = [VMInfo]
    public init() {}
}

/// Makes a machine: downloads its image the first time (checked against the distribution's checksums), then its disk and
/// first boot. Answers at once, `creating`; `vm.list` follows it.
public struct VMCreate: RPCMethod {
    public static let name = "vm.create"; public typealias Result = VMInfo
    public var name: String
    public var image: String?
    /// Memory in GiB, disk in GiB.
    public var cpus: Int?, memory: Int?, disk: Int?
    public init(name: String, image: String? = nil, cpus: Int? = nil, memory: Int? = nil, disk: Int? = nil) {
        self.name = name; self.image = image; self.cpus = cpus; self.memory = memory; self.disk = disk
    }
}

/// `start` boots or wakes it; `sleep` saves it to disk (its memory freed, what ran inside goes on when it wakes); `stop`
/// shuts it down (what ran inside ends); `delete` stops it and removes it, its disk and all. Stop and delete are the user's.
public struct VMControl: RPCMethod {
    public static let name = "vm.control"; public typealias Result = VMInfo
    /// A start can boot: up to a few minutes, more than a call's usual deadline.
    public static var timeout: TimeInterval? { 900 }
    /// `show`: its screen in a window of its own (a macOS machine's), woken first.
    public enum Action: String, Codable, Sendable, CaseIterable { case start, sleep, stop, show, delete }
    public var name: String, action: Action
    public init(name: String, action: Action) { self.name = name; self.action = action }
}

/// What `kelp vm run` needs to run a command in it, in `cwd`'s project folder (shared with the machine at the same path);
/// with no `cwd`, in its own home folder, nothing shared.
public struct VMConnect: RPCMethod {
    public static let name = "vm.connect"; public typealias Result = VMConnection
    public var name: String, cwd: String?
    public init(name: String, cwd: String?) { self.name = name; self.cwd = cwd }
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

    public static let all = [
        VMImage(id: "debian-13", title: "Debian 13",
                url: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.tar.xz",
                sums: "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS", member: "disk.raw"),
        VMImage(id: "macos", title: "macOS", url: "", sums: "", member: "", os: "macos")
    ]
    public static func named(_ id: String) -> VMImage? { all.first { $0.id == id } }
}

/// Between the daemon and a machine's `kelp-vm`: one JSON line each way on its ctl.sock.
public enum VMHelper {
    public struct Request: Codable, Sendable {
        /// `quit`: the machine off at once, and its kelp-vm gone (its folder is about to be).
        public enum Operation: String, Codable, Sendable { case status, start, sleep, stop, share, show, quit }
        public var op: Operation
        /// `share`: the folder here; the answer's `slot` says which of the machine's shares holds it.
        public var path: String?
        public init(op: Operation, path: String? = nil) { self.op = op; self.path = path }
    }
    public struct Reply: Codable, Sendable {
        public var state: VMState
        public var connections: Int, memoryMiB: Int?
        public var error: String?
        /// `share`: its slot, tag `kelp<slot>` inside.
        public var slot: Int?
        public init(state: VMState, connections: Int, memoryMiB: Int? = nil, error: String? = nil, slot: Int? = nil) {
            self.state = state; self.connections = connections; self.memoryMiB = memoryMiB; self.error = error; self.slot = slot
        }
    }
}

public enum VMs {
    /// A host name, a folder name and part of socket paths: short, lowercase, no dots.
    public static func isName(_ s: String) -> Bool {
        (1...20).contains(s.count) && s.first?.isLetter == true && s.allSatisfy { ("a"..."z").contains(String($0)) || $0.isNumber || $0 == "-" }
    }

    /// A Linux account name for the Mac user's, else "kelp".
    public static func user(_ mac: String) -> String {
        let ok = !mac.isEmpty && mac.count <= 32 && mac.first.map { $0.isLowercase || $0 == "_" } == true
            && mac.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-" } && mac != "root"
        return ok ? mac : "kelp"
    }

    /// Rosetta's binfmt line (Apple's "Running Intel binaries in Linux VMs with Rosetta").
    static let rosettaBinfmt = #":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:CF"#

    /// cloud-init's user-data for the first boot: the account with its key, the shared folders' mount, Rosetta.
    public static func userData(_ m: VMMachine, publicKey: String, timeZone: String) -> String {
        var s = """
        #cloud-config
        hostname: \(m.name)
        timezone: \(timeZone)
        ssh_pwauth: false
        users:
          - name: \(m.user)
            sudo: ALL=(ALL) NOPASSWD:ALL
            shell: /bin/bash
            ssh_authorized_keys:
              - \(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        if m.rosetta {
            s += """
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
        return s
    }

    /// The machine's ssh_config (`ssh -F` it, so the user's own config plays no part): `<name>` for agents and people, a
    /// connection each, counted as use; `<name>-own` for kelp-vm's own reads (the clock, memory), not counted.
    public static func sshConfig(_ m: VMMachine, folder: URL) -> String {
        func host(_ alias: String, _ socket: String) -> String {
            """
            Host \(alias)
              HostName \(m.name)
              User \(m.user)
              IdentityFile "\(folder.appendingPathComponent("id_ed25519").path)"
              IdentitiesOnly yes
              UserKnownHostsFile "\(folder.appendingPathComponent("known_hosts").path)"
              StrictHostKeyChecking accept-new
              ProxyCommand /usr/bin/nc -U \(shellQuoted(folder.appendingPathComponent(socket).path))
              ServerAliveInterval 15
              LogLevel ERROR

            """
        }
        // Kelp's own reads come every few seconds while it's watched: over one connection kept a minute, not a handshake each.
        let reuse = """
              ControlMaster auto
              ControlPath "\(folder.appendingPathComponent("own.cm").path)"
              ControlPersist 60

            """
        return host(m.name, "ssh.sock") + host(m.name + "-own", "own.sock") + reuse
    }

    /// Folders shared at once: a virtio-fs device each (tag `kelp<n>`), since giving one device a new set of folders
    /// leaves every handle the guest holds on it stale. A ninth folder takes the slot used longest ago.
    public static let shareSlots = 8

    /// The command line run inside: `folder` mounted at its own path from its slot (again when that path holds another
    /// slot, or went stale), then `cwd`, then the command.
    public static func prefix(slot: Int, folder: String, cwd: String, os: String = "linux") -> String {
        let f = shellQuoted(folder), tag = "kelp\(slot)", cd = "cd \(shellQuoted(cwd)) || exit 1; "
        guard os == "macos" else {
            return "{ [ \"$(findmnt -n -o SOURCE --mountpoint \(f))\" = \(tag) ] && ls \(f) >/dev/null 2>&1; } "
                + "|| { sudo umount -l \(f) 2>/dev/null; sudo mount --mkdir -t virtiofs \(tag) \(f); } || exit 1; " + cd
        }
        // macOS: mount(8) lists it as "kelp3 on /path (virtiofs, …)"; mount_virtiofs needs the folder there first.
        return "{ mount | grep -qF \(shellQuoted("\(tag) on \(folder) (")) && ls \(f) >/dev/null 2>&1; } "
            + "|| { sudo umount -f \(f) 2>/dev/null; sudo mkdir -p \(f) && sudo mount_virtiofs \(tag) \(f); } || exit 1; " + cd
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
        return command.isEmpty ? run : run + " -c " + shellQuoted(trapped + command)
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
        let lines = { (i: Int) in parts.count > i ? parts[i] : [] }
        var d = VMDetail(address: lines(0).first.flatMap { $0.isEmpty ? nil : $0 })
        d.ports = lines(1).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        d.runs = lines(2).compactMap(run)
        if parts.count > 3 {
            let g = lines(3)
            func on(_ key: String) -> Bool { g.contains("\(key): on") }
            let screen = g.first { $0.hasPrefix("screen: ") }.map { String($0.dropFirst("screen: ".count)) }
            d.guest = .init(running: !g.contains("not running") && !g.isEmpty, screenRecording: on("screen recording"),
                            accessibility: on("accessibility"), screen: screen == "free" ? nil : screen)
        }
        return d
    }

    /// "  812     01:02:41 kelp-vm-run:abc -l -c npm test" → pid, seconds, session, command.
    static func run(_ line: String) -> VMDetail.Run? {
        let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard f.count == 3, let pid = Int(f[0]), f[2].hasPrefix("kelp-vm-run:") else { return nil }
        let argv = f[2].dropFirst("kelp-vm-run:".count)
        let session = String(argv.prefix { $0 != " " })
        var command = argv.dropFirst(session.count).trimmingCharacters(in: .whitespaces)
        for flags in ["-l -c " + trapped, "-l -c ", "-l"] where command.hasPrefix(flags) { command = String(command.dropFirst(flags.count)); break }
        return VMDetail.Run(pid: pid, seconds: seconds(f[1]), session: session == "-" ? nil : session, command: command)
    }

    /// ps's elapsed time, "[[dd-]hh:]mm:ss", in seconds.
    static func seconds(_ etime: String) -> Int {
        let dayParts = etime.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    /// Kelp Guest's program inside a macOS machine (`kelp vm screenshot`, `click`…), run over SSH.
    public static let guestProgram = "\"$HOME/Applications/KelpGuest.app/Contents/MacOS/KelpGuest\""

    public static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// Whether `path` may be shared with a machine: a folder below the home folder, not the home folder itself or above.
    public static func mayShare(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        func inside(_ p: String) -> Bool {
            p.hasPrefix(home + "/") && ![".ssh", ".kelp", "Library"].contains(p.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? "")
        }
        // Where it really is too: a link in a project to ~/.ssh shares ~/.ssh.
        return inside(URL(fileURLWithPath: path).standardizedFileURL.path) && Paths.real(path).map(inside) != false
    }
}
